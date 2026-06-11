# `two_bipolar_equal_crossed` — port drops a nondeterministic match (CORRECTED)

**Date:** 2026-06-11 · **Status:** ⚠️ **DOWNGRADED after checking upstream's actual assert.**

## CORRECTION (read first)
My initial verdict ("confirmed real port divergence, upstream runs+asserts it") was **overstated**.
Two facts I missed:
1. **The golden fixtures are auto-recorded from the PORT itself** (`tools/diff_upstream.jl` `record_fixtures()` runs `run_julia` = the Julia port). So the full-dump golden is the **port's own earlier output**, NOT upstream Rust. A FAIL = the port disagreeing with **its own recorded baseline** (a self-regression detector), not a confirmed upstream divergence.
2. **Upstream's actual `main.rs` test asserts only `res.contains("(MATCHED (foo bar) (foo bar))")`** — the ground match. **The port produces that → the port PASSES upstream's real test.** The dropped `(MATCHED (foo $) (foo _1))` is a nondeterministic extra upstream **does not assert**, and we **cannot confirm upstream emits it** (no cargo to run the Rust binary).

So the accurate statement: the port **self-regressed** on a nondeterministic output relative to its own recorded fixture; it still satisfies upstream's actual assertion. **Lower severity; NOT a confirmed upstream divergence.** Lesson: the self-recorded full-dump fixtures only catch regressions — port-vs-upstream must use upstream's own `assert!(res.contains(...))`.

## EMPIRICAL CONFIRMATION (`run_asserts.jl`, 2026-06-11)
Built the correct differential (upstream's `assert!(res.contains(...))`) and ran it:
**12 PASS · 0 FAIL · 2 FAIL(wip, upstream-disabled) of 14.** The port satisfies **100% of
upstream's real assertions** — including `two_bipolar_equal_crossed`, `source_space_…`, and
`sink_two_bipolar_…` (all emit the ground `(MATCHED (foo bar) (foo bar))` upstream requires).
The only fails are `variable_priority`/`variables_in_priority`, which upstream itself comments
out (WIP).

## RETRACTION of the E1→B claim
My "this reshapes E1→B; MORK's engine drops nondeterministic results" conclusion is **RETRACTED**.
The MORK engine **conforms to upstream's own test spec** on these matching/unification cases — E1
can build on it. **Caveat:** upstream's asserts are *partial* (`contains`, ground-match only), so
they do not fully pin down nondeterministic multi-result *completeness* — that remains unverified
for BOTH the port and upstream's tests, and would need the live Rust binary or richer assertions to
settle. But it is **not a confirmed port bug**, and **not a blocker for E1**.

---

(original analysis below — the query-side trace is still valid as a characterization of *where* the
second result is enumerated, but its severity framing is superseded by the correction above)

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
