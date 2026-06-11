# `Control_08_Halts_on_fail` never halts — multi-factor query matches value-removed atoms

**Date:** 2026-06-11 · **Status:** 🔴 **Confirmed reproducible port bug, root cause PINNED to a
minimal substrate repro.** `remove_val_at!` is correct and the removal IS durable; the bug is that
the **multi-factor conjunction query (`space_query_multi` / `_space_query_multi_inner!`) emits a match
for an atom whose value was removed** — it leaves a dangling path-node and the product-zipper
enumeration doesn't gate the emitted match on value-presence.

> **History (two wrong hypotheses, corrected by diagnostics — kept as a caution):** first guessed
> "hidden var-source-id state"; then "O-sink `(-)` write-back isn't mutating `s.btm`". **Both wrong.**
> A read-only diagnostic (`diag_remove.jl`) showed `space_val_count(s.btm) == 2` and `get_val_at`
> ABSENT for the three decremented atoms — i.e. removal *is* durable. The minimal repro below pins it
> to the query layer. Always diagnose substrate state before patching.

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

## Symptom contrast — same visible state, different query result
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
`(- (counter (S $N)))` effect as the counter decremented `(S(S(S Z)))→Z`. They are gone from the
dump but still matched by the conjunction query. Fresh-built never added-then-removed those atoms,
so it has nothing stale to re-match → 0.

## Root cause — minimal substrate repro (PINNED)
`diag_remove.jl` then `diag_pathmap.jl` strip away the metta-calculus entirely. Add two atoms,
`remove_val_at!` one, then query a 2-factor conjunction:

```
space_add_all_sexpr!(s, "(counter (S Z))\n(marker a)\n")
remove_val_at!(s.btm, sexpr_to_expr("(counter (S Z))").buf)
```

| check | result |
|---|---|
| `space_val_count(s.btm)` | **1** |
| `get_val_at(s.btm, "(counter (S Z))")` | **ABSENT** |
| `dump` | `(marker a)` only |
| raw `zipper_to_next_val!` over `s.btm` | `(marker a)` only ✓ |
| `space_query_multi(s, "(, (counter (S $N)) (marker $x))")` | **matches the removed atom (1)** ✗ |

Five value-checks agree the atom is gone; **only the multi-factor conjunction query still emits it.**
So `remove_val_at!` is correct (durable; even the raw value-iterating zipper skips it). The bug is in
the multi-factor query enumeration: `remove_val_at!` clears the value but leaves a **dangling
path-node** (no pruning), and `_space_query_multi_inner!` / the ProductZipper emit a match when the
pattern is fully consumed **without a final value-presence check** — the `pzg_child_count(prz) != 0`
gate at `src/kernel/Space.jl:521` passes for a childless, *valueless* leaf. The raw zipper gates on
value (`to_next_val`); the product-zipper path does not.

## Why it matters for E1
Core wires onto this exact query engine. Any delete-then-query (retraction, garbage rules, the
metta-calculus fixed-point loop) can re-match deleted data. Fix before/with E1.

## Repro (warm REPL)
```
cd ~/code/CognitiveSubstratesAI/MORK
printf 'include("experiments/mm2_programs/probe_control08.jl"); exit()\n' | julia --project=. -i tools/repl.jl
#   → DECREMENT-REACHED conj=3 / FRESH-BUILT conj=0 / dump(A)==dump(B)? true  + binding dump
printf 'include("experiments/mm2_programs/diag_remove.jl"); exit()\n'   | julia --project=. -i tools/repl.jl
#   → val_count=2, get_val_at ABSENT for the removed atoms (removal IS durable)
printf 'include("experiments/mm2_programs/diag_pathmap.jl"); exit()\n'  | julia --project=. -i tools/repl.jl
#   → MINIMAL: add 2 / remove 1 / conj matches=1  (the isolated bug)
```

## Next step (fix) — two candidates, cross-check upstream first
1. **Query-layer gate (localized, lower risk):** in `_space_query_multi_inner!` (and the `_i` sibling),
   require the matched factor leaf to carry a value before emitting — mirror what `to_next_val` already
   does. Every real atom has a value, so this only drops dangling-path phantoms.
2. **Prune on remove (uniform, higher risk):** make `remove_val_at!` prune now-empty branches so no
   dangling path exists for any traversal — but this touches PathMap COW/sharing and needs the
   COW-soundness gate.

Check upstream MORK's PathMap remove + query semantics (does Rust prune on remove, or gate the query
on value?) to pick the port-faithful option before patching. Until fixed this is a **known, isolated,
reproducible** non-termination; it does **not** crash, and the other 32 corpus programs are unaffected.
