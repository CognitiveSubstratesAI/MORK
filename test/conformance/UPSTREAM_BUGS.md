# Upstream defects found while porting — WRONG ANSWERS, not crashes

> **Looking for where WE differ from a CORRECT upstream?** That is the other category and it
> lives in `ADAPTATIONS.md` (same directory) — the absolute-path sink model, `PrefixBtm`, the
> chain-projection pushdown, `MorkL`. This file is only for cases where upstream is WRONG.

`upstream_panics/` records the 49 programs where `mork run` **aborts**: no output, so nothing to
compare against. This file is the other category — upstream **runs, returns, and is wrong**. Each
entry was suspected by reading and then **settled by execution**, and each says what our port does
instead and why.

Mirrors `PathMap/test/differential/UPSTREAM_BUGS.md`, which carries the same rule of thumb:

> The project's standing principle is *if upstream has it, we implement it* — we do not get to judge
> whether it matters. This file is the narrow exception: reproducing **silent data loss or
> corruption** is worse than deviating. An entry here needs a demonstrated wrong ANSWER, not a
> disagreement of taste.

To re-check any of these after an upstream rebuild:

```bash
mork run probe.mm2 probe.raw    # ALWAYS to a FILE — stdout mangles the high bytes these ops emit
```

---


## 6. `#135` — quote loses variable coreference. CAUSE LOCALISED; fix is a DEVIATION, not a port

Upstream issue **#135** (OPEN). `(exec 0 (,) (O (pure $r $r (tuple R (' ($a $a))))))` yields
`(R ($a $b))` where `(R ($a $a))` is expected. **Our port reproduces it exactly.**

⚠️ **There is NO upstream fix to port.** Upstream's latest commit is `45bdb9a` (2026-07-14) and the
three commits ahead of our vendored `5464713` are all linalg work; the issue was filed 2026-07-20.
Fixing this means DEVIATING from upstream on an OPEN issue.

### Cause — every stage is individually correct, which is why it is hard to see

Traced by instrumenting each stage with the real byte encodings:

```
parse (exec … (' ($a $a)))   -> …02 c0 81      NewVar + VarRef(1)   CORRECT
expr_apply on the template   -> …02 c0 81      unchanged            CORRECT
scope_eval! of (' ($a $a))   -> 02 c0 80       -> ($a $a)           CORRECT
_expr_substitute_one_de_bruijn(tpl, result)  -> (R ($a $a))         CORRECT
```

The defect is a **scope mismatch, not a corruption**. In the enclosing expression `$r` is binder 0,
so the quoted `$a` is binder **1** and its back-reference is `VarRef(1)`. The PureSink then evaluates
the formula STANDALONE — `scope_eval!(s.scope, ExprSource(formula_buf, formula_start))`
(`Sinks.jl:1065`) — where the same bytes mean something else: the NewVar is now binder **0**, so
`VarRef(1)` points one past it and renders as a second, unrelated variable.

Nothing rewrites the bytes; they are simply read in a scope with one fewer enclosing binder.

### The fix, if we decide to deviate

Re-base the formula's variable references when it is EXTRACTED, so the buffer handed to
`scope_eval!` is self-contained: subtract `_expr_newvars(formula_buf, 1, formula_start - 1)` — the
count of binders preceding the formula — from every `VarRef` in the span, and raise if any index
would go negative (that would be a reference to a binder genuinely outside the formula).

This belongs at the extraction site (`Sinks.jl:1030-1037`), NOT at the quote splice: `scope_eval!`
receives a bare `(buf, position)` and has no way to know how many enclosing binders were dropped.

✅ **APPLIED 2026-07-31** as `_expr_rebase_varrefs` (`Sinks.jl`), after one further measurement made
the case decisive: **upstream's `hash_expr` is not content-addressed.** The same expression hashed
from templates differing only in how many binders precede the call gives `bssGabbteWo` vs
`0Z2xrn_VwuU` on the release binary; ours gives one digest either way. A content hash that changes
with syntactic position defeats the op's purpose, and that is silent — a variable-free expression is
unaffected, so it hides.

The deviation is WIDER than #135's own symptom and that is recorded where it bites:
`sink_pure_advanced.jl`'s byte-parity assertion now differs from `main.rs:1201-1225` for the
expression containing a back-reference (the variable-free one still matches exactly). The expected
value was changed WITH the reason attached, not silently.

Shaped to converge: it honours the de Bruijn base `ee_args!`/`args` already thread — the same value
PR #137 extracts as `ExprEnv::subterms` — so an upstream fix should look like this one. Reconcile
when #135 or #137 lands.

## 1. `mod_i*` aborts on divisor 0 and on `typemin % -1`

`kernel/src/pure.rs`, the `mod_i8/16/32/64/128` arms. Rust's `%` panics on a zero divisor, and
`i64::MIN % -1` overflows the same way `i64::MIN / -1` does. The `op!` arms apply `%` directly with
no guard, so both shapes abort the process mid-saturation — every atom of the run is lost, not just
the offending one.

**Ours:** the op raises and the atom is skipped, matching how upstream's own `Err` paths behave for
every other failure mode in the file. Recorded in `Pure.jl` at the arm.

---

## 2. `encode_hex` corrupts at 32 bytes and aborts at 33

`pure.rs:748-760`. It writes into a fixed `[0u8; 64]` and emits `buf[..2*len]`.

* a **32-byte** input produces a 64-byte symbol — which violates the Rule of 64 (`SymbolSize` is
  1..63), so the emitted atom is structurally invalid, silently
* a **33-byte** input writes past the array and **panics** — a non-unwinding abort that kills the
  process and writes no output at all

**Ours:** raises before emitting, so the atom is skipped and the run continues. `sink_write!`
enforces the 63-byte limit independently. Documented at `_nat_encode_hex` (`Pure.jl:1192`).

---

## 3. `'` (quote) rewinds the evaluation cursor by one item

The `quote` branch of the evaluator does not advance past the item it quoted, so the next step
re-reads it. Settled by execution against the binary: our cursor position and upstream's differ by
exactly one item after a quote.

**Ours:** advances. This is the one place the port deliberately does NOT reproduce upstream's cursor
arithmetic, noted at the `_push_eval!` quote branch in `Eval.jl`.

---

## 4. `unbind` writes its own 255 sentinel as a `VarRef`

For the input `($x $x)` — `[2] $ _1` — upstream's `unbind` emits its internal 255 sentinel into the
output as a `VarRef` index. 255 is not a legal VarRef under the Rule of 64 (max 63), so the result
does not decode.

**Ours:** raises rather than emitting an undecodable index. The behaviour is pinned by a test in
`test_expr_queries.jl` ("unbind — and the `VarRef(255)` sentinel path") which records `:raised`
explicitly, so a future change of heart is visible.

---

## 5. `load_jsonl` writes the line index UNTAGGED — the document lands outside the expression

Found 2026-07-31 while porting `jsonl_to_paths`. Upstream's two JSONL writers disagree:

| | line index | site |
|---|---|---|
| `load_jsonl` | 8 bytes, **no tag** | `space.rs:628` — `wz.descend_to(lines.to_be_bytes())` |
| `jsonl_to_paths` | 8 bytes, **`SymbolSize(8)`** | `space.rs:596` |

The untagged path `[3] (5)JSONL 00*8 [2] (1)a (1)1` parses as an expression only **nine bytes**
long, rendering `(JSONL () ())`: the first two zero index bytes are consumed as two `Arity(0)`
empties, which satisfies the `Arity(3)`, and the remaining six index bytes **and the entire
document** sit outside the expression span. Verified by measuring the span, not by reading.

It survives as a trie KEY — still unique per line — which is why it works in practice for
`load_jsonl`'s own purposes. It does not read back. `jsonl_to_paths`, which writes a `.paths` stream
meant to be deserialized, tags it and is correct.

**Ours:** each of our two functions mirrors ITS OWN upstream counterpart, so we reproduce the
difference rather than silently "fixing" `space_load_jsonl!` — that would break parity with the
release binary. The difference is pinned byte-for-byte in `test_json_to_paths.jl`, including that
our `jsonl_to_paths` output spans the whole path while the `load_jsonl` shape stops early.

---

## Reporting these upstream

None of these has been filed with `trueagi-io/MORK`. Each entry above has the reproducer and the
evidence, so filing is mechanical. #2 and #5 are the ones with the strongest case: a corrupted
symbol and an expression that cannot be read back, both silent.
