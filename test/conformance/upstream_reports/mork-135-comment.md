COMMENT on existing issue #135 — do NOT open a new issue

---
Independent confirmation, plus a cause and a candidate fix. Found while porting MORK to Julia: our
port reproduces this **byte for byte**, which is how we ended up tracing it.

## It is a SCOPE MISMATCH, not a corruption

No stage rewrites the variable. Every stage is individually correct — that is what makes this hard to
see. Instrumenting each one with the actual encodings:

| stage | bytes | reading |
|---|---|---|
| parse `(exec 0 (,) (O (pure $r $r (tuple R (' ($a $a))))))` | `… 02 c0 81` | `Arity(2), NewVar, VarRef(1)` ✅ correct |
| `apply` on the template | `… 02 c0 81` | unchanged ✅ |
| evaluate the quoted payload alone | `02 c0 80` | `Arity(2), NewVar, VarRef(0)` → `($a $a)` ✅ |
| `substitute_one_de_bruijn(k, res, oz)` | — | `(R ($a $a))` ✅ |

In the enclosing expression `$r` is binder **0**, so the quoted `$a` is binder **1** and its
back-reference is `VarRef(1)`. Correct there.

`PureSink` then evaluates the formula **standalone**:

```rust
// kernel/src/sinks.rs:1165
let mut res = match self.scope.eval(ExprSource::new(&p[clen])) { … };
```

In that slice the same bytes mean something different: the `NewVar` is now binder **0**, so
`VarRef(1)` points one past it and is rendered as a second, unrelated variable — `$b`. Nothing
mutated the expression; it is simply read in a scope with one fewer enclosing binder.

## Why the plain rewrite works

The issue notes that

```
(exec 0 (,) (, (R ($a $a))))
```

behaves correctly. That fits: the template is never lifted out of its enclosing scope, so the
`VarRef` is always read against the binder set it was written against. Only the `pure` path slices a
sub-expression out and evaluates it on its own.

## The mechanism PREDICTS unreported cases — checked before posting

If the reading above is right, any back-reference inside a `pure` formula is off by exactly the
number of binders preceding the formula (here `$r`, so one). Two shapes were predicted first and then
run, on the release binary:

```
(pure $r $r (tuple R (' ($a $b $a))))   predicted (R ($a $b $b))   observed (R ($a $b $b))  ✅
(pure $r $r (tuple R (' ($a $b $b))))   predicted (R ($a $b $c))   observed (R ($a $b $c))  ✅
```

The first shows the back-reference to `$a` landing on `$b` — shifted by one. The second is sharper:
the back-reference to `$b` lands one PAST the last binder, so it materialises as a THIRD, entirely
fresh variable `$c` that appears nowhere in the input. Both follow from the single off-by-one and
were not part of the original report.

## Candidate fix — the correct base is ALREADY COMPUTED, it is just discarded

`ExprEnv::args` threads the de Bruijn base across siblings (`env.v += se_c`), so the formula's env
already carries the number of binders that precede it. Measured on this exact program:

```
arg 1  v=0   pure
arg 2  v=0   $a                          <- template
arg 3  v=1   $a                          <- pattern
arg 4  v=1   (tuple R (' ($a $b)))       <- call; its VarRefs are relative to base 1
```

`v=1` is exactly the observed off-by-one. But `PureSink` then evaluates the call as a bare slice —
`self.scope.eval(ExprSource::new(&p[clen]))` — which throws that base away.

So the fix is to honour the base the env already has: re-base the call's `VarRef`s down by
`call_env.v` before evaluating (erroring if an index would go negative, i.e. a reference to a binder
genuinely outside the call, unresolvable standalone). Equivalently, give `EvalScope::eval` the base
and let it resolve against it — the bare `ExprSource` is what makes the information unavailable today.

Worth noting: **#137 already introduces the right vehicle.** Its `ExprEnv::subterms(k, dest)` extracts
exactly this threading so it works on the sinks' bare operand run, and its own comment says the three
subterms then "share one variable namespace and the pattern's VarRefs resolve to the template's
introductions". Routing the *call* operand through the same path — and using its `v` when evaluating
— looks like it would close this issue on the same mechanism, rather than needing a separate one.

## Note on a possibly-related defect in the same branch

While tracing this we also measured that `push_eval`'s quote branch
(`experiments/eval/src/lib.rs:99-107`) writes the quoted sub-expression into the parent sink without
advancing `self.expr.position`, so later arguments read one item early and the last is dropped:

```
(tuple (' qq) ww)      -> (qq qq)     ww replaced by a copy of the quoted argument
(tuple (' qq) ww zz)   -> (qq qq ww)  shifts by one; zz dropped
(tuple aa ww (' qq))   -> (aa ww qq)  control: quote LAST is correct, nothing follows to shift
```

That is about argument POSITION rather than variable identity, so it may be a separate bug — but it
lives in the same branch, so flagging it here rather than opening a second issue until you have
looked. Happy to split it out if you prefer.

(For anyone reproducing: `'` is an ordinary symbol here, not a prefix reader macro — `'(b c)` lexes
as two tokens and the quote form is `(' X)`. Probes written the other way mislead.)
