# `Control_08_Halts_on_fail` never halts — removed atoms stay queryable

**Date:** 2026-06-11 · **Status:** 🔴 **Confirmed reproducible port bug, root cause PINNED.**
A metta-calculus `(- …)` removal disappears from `space_dump_all_sexpr` but is still enumerated
by `space_query_multi` on the next step. Fix-level mechanism (COW/snapshot) localized below;
the exact patch is not yet written.

> **Upstream-confirmation caveat (two_bipolar lesson):** "should halt" is inferred from the
> corpus author's name (`Halts_on_fail`), the program's logic (counter→`Z` makes `(counter (S $N))`
> unsatisfiable), and the sibling `Control_09_Halts_on_success` halting in 11 steps — **not** from
> running upstream Rust (no `cargo` here). Upstream MORK's `(-)` persists across steps, so the port
> failing to is a real divergence, but the live-binary check remains a TODO.

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

## Root cause — `(-)` removals stay queryable (PINNED)
Printing what the 3 phantom matches actually bind (`probe_control08.jl` → match-dump variant)
settles it. The `(counter (S $N))` factor binds to:

```
match 1: (counter (S (S (S Z))))     ← $N = (S (S Z))
match 2: (counter (S (S Z)))         ← $N = (S Z)
match 3: (counter (S Z))             ← $N = Z
```

These are **exactly the three historical counter values that were removed** by the exec's
`(- (counter (S $N)))` effect as the counter decremented `(S(S(S Z)))→Z`. They are **gone from the
dump** but **still enumerated by the query**. So it is *not* a conjunction-logic bug and *not*
hidden var-source-id state — it is a **read/write consistency bug on removal**: a metta-calculus
`(-)` removal is invisible to `space_dump_all_sexpr` yet visible to `space_query_multi` on the next
step. Fresh-built never added-then-removed those atoms, so it has nothing stale to re-match → 0.

Two independent lines of evidence agree: direct (conj=3 vs 0) and indirect (`space_metta_calculus!`
loops vs halts).

## Where (fix-level localization)
Control_08 is the `comma` pattern / `O`-sink template path →
`space_transform_multi_multi!(…, no_source=true, no_sink=false)` (`src/kernel/Space.jl:1196`). Its
pattern contains `(exec LOOP $p $t)`, so `_pat_overlaps_exec_prefix` is **true** → the **meta-pattern
slow path** runs: `read_btm = pjoin(s.btm, _exec_singleton)` (a snapshot), while `+`/`-` O-sink
writes target `sink_btm = s.btm` (`Space.jl:1243-1251`, 1210). For halting, each `(-)` must persist
into `s.btm` so the *next* step's freshly-rebuilt `read_btm` no longer contains it. The evidence
shows the removed atoms survive — so the O-sink `(-)` removal is **not durably mutating `s.btm`**
(written to a discarded COW fork, or the O-sink applies `-` only to its snapshot/accumulator, not the
backing trie). That `(-)` write-back is the fix site. Confirm by instrumenting the O-sink minus
branch to assert `remove_val_at!(s.btm, …)` runs and that the atom is absent from `s.btm` immediately
after the step.

## Why it matters for E1
Core's interpreter will wire onto this same engine. A `(-)` removal that isn't durable in the query
path means any client that deletes-then-queries (retraction, garbage rules, the whole metta-calculus
fixed-point loop) can re-read deleted data. Fix the O-sink `(-)` write-back before/with E1.

## Repro (warm REPL)
```
cd ~/code/CognitiveSubstratesAI/MORK
printf 'include("experiments/mm2_programs/probe_control08.jl"); exit()\n' | julia --project=. -i tools/repl.jl
# → DECREMENT-REACHED conj=3  / FRESH-BUILT conj=0  / dump == ? true
#   match 1..3 bind (counter (S $N)) to the three REMOVED counter values
```
(Single-factor `space_query_multi` probes are unreliable — that API is for `(, …)` conjunctions;
the conj=3-vs-0 comparison on dump-equal spaces is the valid apples-to-apples test.)

## Next step (fix)
Instrument the O-sink `(-)` branch in `space_transform_multi_multi!` to confirm it calls
`remove_val_at!(s.btm, …)` durably (not on a COW fork / snapshot that's discarded after the step),
then re-run `Control_08` — it should halt in ~4 steps. Cross-check upstream Rust `(-)` semantics
once `cargo` is available. Until fixed this is a **known, isolated, reproducible** non-termination;
it does **not** crash, and the other 32 corpus programs are unaffected.
