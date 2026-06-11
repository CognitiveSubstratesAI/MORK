# Root cause — `two_bipolar_equal_crossed` (port drops a nondeterministic match)

**Date:** 2026-06-11 · **Status:** confirmed real port divergence (upstream `main.rs` runs+asserts it) · **Verdict:** DEEP query-engine gap, not a localized bug.

## Symptom
```
(exec 0 (, (Something $x $y) (Else $x $y)) (, (MATCHED $x $y)))
(Something (foo $x) (foo $x))
(Else ($x bar) ($x bar))
```
Upstream emits **two** `MATCHED`; the port emits **one**:

| result | upstream | port |
|---|---|---|
| `(MATCHED (foo bar) (foo bar))` (ground) | ✅ | ✅ |
| `(MATCHED (foo $) (foo _1))` (variable-preserving) | ✅ | ❌ **dropped** |

Neighbours that PASS isolate it: `two_positive_equal_crossed` (ground data) ✅ and single `bipolar` ✅ — only **crossed pattern + variable-containing data** breaks.

## Where it's dropped — QUERY, not apply (traced)
Instrumented the unify-success point in `_space_query_multi_inner!` (`Space.jl`, the `candidate += 1` / `effect(...)` site). For the `Something/Else` conjunction the trace printed **exactly one `QUERY_MATCH`** combined path. Since the two expected `MATCHED` are distinct byte sequences (a set-trie can't collapse them), one query match ⟹ one output. **The second unifier is never enumerated** — the loss is on the query/unification side (the `ProductZipper` enumeration + `_expr_unify_inplace!`), **not** in `expr_apply`/insert.

So: matching a variable pattern against variable-containing data (the bipolar case) should yield **two** unifiers — the grounding one *and* the variable-preserving one — and the port's crossed-conjunction enumeration produces only one.

## Upstream context (this is a known-hard area upstream)
Upstream has active unification-correctness work, which is exactly where the fix lives:
- branch `enforce_occurs_check_after_apply`: *"first pass on unification fix and deprecation of old functions"*, *"I introduced a bug, but I need to save this for later"*, *"the major bug was a false alarm"*.
- branch `query_bug_unification_test` / `experiments/unification_test_laws` (Rust): dedicated unification-law tests.
- `func_type_unification` and `logic_query` are commented out in upstream `main()` too.

## Recommendation
This is **the deep multi-result/bipolar-unification gap**, in MORK's query engine, in an area upstream itself is still stabilizing. **Do not hand-patch it from scratch.** The fix path is to evaluate and port upstream's unification work (`enforce_occurs_check_after_apply` + `unification_test_laws`) and re-run this fixture.

**Why it matters for E1→B:** MORK's *own* engine drops nondeterministic results here, so wiring Core onto MORK's engine (E1) would **inherit** the gap. The multi-result phase (B) must therefore include **completing MORK's bipolar query enumeration** — it is not satisfied by "just use `expr_unify`". Sequence this into the multi-result phase; it's not a quick pre-E1 fix.
