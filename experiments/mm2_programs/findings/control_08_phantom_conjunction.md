# `Control_08_Halts_on_fail` never halts — phantom conjunction matches (state-dependent)

**Date:** 2026-06-11 · **Status:** 🔴 **Confirmed reproducible port bug.** Root cause (which hidden
state) **not yet pinned** — do not overstate beyond what's verified below.

## Symptom
`Control_08_Halts_on_fail.mm2` (ClarkeRemy MM2 corpus) is a counter that decrements
`(S(S(S Z))) → Z`; once the counter hits `Z` its query conjunct `(counter (S $N))` can no
longer match, so the exec should **fail-and-halt** in ~4 steps. Its sibling
`Control_09_Halts_on_success` halts in 11. The port runs `Control_08` to the **step cap (10 000)**.

The data is correct: the counter decrements `(S(S(S Z)))→(S(S Z))→(S Z)→Z` over steps 1–3 and
then sits at `Z`. But the engine keeps stepping — the exec keeps firing and re-adding itself.

## The smoking gun — query results depend on hidden state
Take the state at `counter=Z` two ways and compare. **Their `space_dump_all_sexpr` is byte-identical**
(`(counter Z)` + the one exec atom):

| reached how | `space_query_multi(s, "(, (counter (S $N)) (exec LOOP $p $t))")` | `space_metta_calculus!` |
|---|---|---|
| **by decrement** (run `Control_08` to cap=4) | **3 matches** | never halts (cap) |
| **fresh-built** (`add` the same two atoms) | **0 matches** | halts in 1 step (exec consumed) |

Same query API, same pattern, **dump-equal** spaces → different match counts. A join of two
patterns cannot yield matches when a conjunct is unsatisfiable, so **3 is phantom**. The phantom
matches re-instantiate the exec's output (including `(+ (exec LOOP …))`), so the exec perpetually
re-adds itself and the calculus never reaches a fixed point.

Two independent lines of evidence agree:
1. **Direct:** `space_query_multi` returns conj=3 (decrement) vs 0 (fresh).
2. **Indirect:** `space_metta_calculus!` loops in the decrement run, halts in the fresh run.

## What is NOT the cause
- Not query *semantics at Z*: freshly built `(counter Z)` + exec yields 0 matches and halts
  correctly. The conjunction logic is right on a clean space.
- Not visible trie contents: the two spaces are dump-equal.

⟹ There is **per-`Space` mutable state beyond the trie** (likely the de-Bruijn variable
source-id counter, an interner entry, or leftover query/zipper scratch left by the self-re-adding
exec) that makes `_space_query_multi_inner!` (`src/kernel/Space.jl:439`) enumerate phantom
combined matches. **Which one is not yet pinned** — that's the next probe.

## Why it matters for E1
Core's interpreter will wire onto this same multi-factor query engine. A query whose result
depends on how the space was *reached* (not just its contents) is a correctness hazard for any
client. Pin the hidden-state source before/with E1.

## Repro (warm REPL)
```
cd ~/code/CognitiveSubstratesAI/MORK
printf 'include("/tmp/probe_state.jl"); exit()\n' | julia --project=. -i tools/repl.jl
# → DECREMENT-REACHED conj=3 … / FRESH-BUILT conj=0 … / dump == ? true
```
(`Going_Wide_06` style single-factor probes via `space_query_multi` are unreliable — that API is
for `(, …)` conjunctions; the conj=3-vs-0 comparison above is the valid apples-to-apples test.)

## Next step
Instrument `_space_query_multi_inner!` to dump the per-factor zipper/binding state in both spaces
and diff — find the non-trie state that diverges. Until then this is a **known, isolated,
reproducible** non-termination, recorded here; it does **not** crash and the other 32 corpus
programs are unaffected.
