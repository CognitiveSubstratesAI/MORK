`'` (quote) rewinds the evaluation cursor by one item

---
The quote branch of the evaluator does not advance past the item it quoted, so the following step
re-reads it. Measured against the built binary: after a quote, the cursor position differs by exactly
one item from where the surrounding code expects it.

Observable as a quoted sub-expression being consumed twice in an evaluation that mixes quote with
subsequent reads.

Reported from a 1:1 Julia port of the `eval` crate, where advancing was necessary to reproduce
upstream's own test expectations elsewhere in the suite.
