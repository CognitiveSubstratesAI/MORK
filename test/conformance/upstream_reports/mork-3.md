`'` (quote) does not advance the evaluation cursor — later arguments shift by one and the last is dropped

---
> **Related to #135, but a different mechanism.** #135 reports that quotation loses variable identity
> (`(' ($a $a))` yields `($a $b)`). This is about the cursor POSITION: the number and placement of the
> *arguments* is wrong, independently of variables. Both live in the quote branch and may share a root
> cause — flagging that rather than assuming either way.

`push_eval`'s quote branch (`experiments/eval/src/lib.rs:99-107`) writes the quoted sub-expression's
items into the parent sink but never advances `self.expr.position` past it. The cursor is left one
item behind, so every later argument reads one position early and the final argument is dropped.

## Measured

```
(tuple (' qq) ww)       -> (qq qq)     ww replaced by a copy of the quoted argument
(tuple (' qq) ww zz)    -> (qq qq ww)  the sequence SHIFTS BY ONE; zz is dropped
(tuple aa (' qq) ww)    -> (aa qq qq)  same shift, mid-position
(tuple (' (pp rr)) ww)  -> (nothing)   the re-read CALLS head `pp` => unknown function, no atom
(tuple aa qq ww)        -> (aa qq ww)  control: no quote, untouched
(tuple aa ww (' qq))    -> (aa ww qq)  control: quote LAST, correct (nothing follows to shift)
```

Row 2 is what fixes the magnitude at exactly one item — a two-argument probe cannot distinguish
"rewound by one" from "duplicated". One mechanism predicts all six outcomes, including both controls.

The quoted-EXPRESSION case is the most damaging in practice: re-reading `(pp rr)` treats `pp` as a
function name, so the call fails and the atom is silently skipped rather than producing a wrong value.

## Note on reproducing

`'` is an ORDINARY SYMBOL here, not a prefix reader macro — `'(b c)` lexes as two tokens, and the
quote form is `(' X)`. Probes written as `'(b c)` are malformed and will mislead; that produced two
wrong conclusions here before the form was checked against upstream's own test
(`sink_pure_quote_collapse_symbol`, `kernel/src/main.rs:1097`).

Found while porting the `eval` crate to Julia; our port advances the cursor, which is the only reason
the surrounding test expectations line up.
