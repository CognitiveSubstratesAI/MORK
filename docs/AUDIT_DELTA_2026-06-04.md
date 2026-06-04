# MORK — Delta Audit Closeout (2026-06-04)

Reconciliation of the external MORK delta audit (`MORK_DELTA_AUDIT_V2.md`) against the
migrated MORK. Every finding verified against the code by reading before acting.
Verified: warm-REPL/`runtests` **1723/1724** (1 broken = threads-only test).

## FIXED this pass
| ID | Sev | Finding | Fix |
|----|-----|---------|-----|
| **D-P1** | Med (real bug) | ~16 i128 ops in `Pure.jl` still read via `_read_i64`/returned `Int64`/`Int8` — only the low 8 of 16 bytes → silent wrong result for \|x\| ≥ 2^63 (mod/pow/sub/div/one/from_string/to_string/i128_as_* + i*_as_i128) | Switched to `_read_i128` + return `Int128` (16-byte `_be_bytes`). Regression test with operands > 2^80 (`Pure i128 ops` testset). |
| **SP-1** | Med | `space_query_multi_i` wrapped unify in blanket `try…catch; nothing` — swallowed REAL bugs as no-match (unify returns failure as a VALUE, only throws on bugs; root paths don't catch) | Removed the catch; call directly + check `=== true`, matching `_space_query_multi_inner!`. |
| **SRC-1** | Med | `CmpSource` `!=` did `deepcopy(btm)` at setup AND `deepcopy(map_clone)` PER enrolled path — O(space) copy each, anti-COW | Replaced both with `psubtract(btm, {path})` — non-mutating + COW-shared. |
| **ML-1** | Med | `MorkL._binary_space_op!` `deepcopy`'d an input before non-mutating `pjoin`/`pmeet`/`psubtract`/`prestrict` — full O(space) copy fighting COW | Dropped the deepcopy (ops are non-mutating, COW-share results). Subroutine-snapshot deepcopies (127/201/469/502) → COW `copy()` deferred (widens sharing surface — gated; see Deferred). |
| **EA-1** | Low-Med (soundness-adjacent) | `_occurs_check` ended with `found isa Tuple ? found[2] : found` coalescing on an Any-typed accumulator, defaulting unexpected shapes toward `false` (= allow binding = unsound) | Verified `expr_traverseh` returns `(h, value, j)` with every occurs callback's value strict-Bool; `found` is only ever Bool-or-`nothing` (leaf-only → correctly `false`). Dropped the dead Tuple branch so any non-Bool surfaces via `::Bool`. |

## VERIFIED + DOCUMENTED (refuted / explained, no behavioural change)
- **E-1 (Med):** `expr_span` traced + verified CORRECT (the audit's "correct-by-coincidence"
  refuted) — it is the standard flat-arity expression-end walk, producing spans identical to
  `_expr_end_offset`. The suite already carries an "expr_span ≡ _expr_end_offset (E-1
  retracted)" equivalence test (33 cases). Added a docstring explaining the invariant +
  noting the duplication for a future consolidation (deferred; not worth a backward
  expr→kernel dependency).
- **SP-3 (Med, test-coverage):** the `read_btm = s.btm` COW-snapshot optimization is
  load-bearing. COVERAGE ALREADY EXISTS: `wiki: transitive.mm2` runs the self-feeding rule
  `(exec 1 (, (edge $x $y) (edge $y $z)) (, (edge $x $z)))` over the snapshot. Added a minimal
  single-step self-feed guard (`SP-3` testset) asserting `(edge a c)` is derived. (A strict
  deep-closure marker test was dropped — uniform-priority full closure to a specific deep
  pair is a dialect iteration nuance, not a COW issue.)

## FIXED — second pass (Tier-4 cleanup, 2026-06-04)
- **D-1 (Med-perf):** DyckZipper `NTuple{32}` stack rebuilt O(32)/move → length-32
  `Vector{SubtreeSlice}` (O(1) in-place sets). Julia-native, no StaticArrays dep. Aliasing
  in `dsz_breadth_first_leaves` (now `copy(z.stack)`) handled. (commit `163c07e`)
- **D-2 (trivial):** removed the dead `word = valid ? structure : structure` `cond?x:x` no-op.
- **SP-2 (Low):** removed the dead `bindings_out = copy(...)` per-match allocation in
  `space_query_coref` (the effect contract is `effect(loc)`, doesn't take bindings).
- **SP-4 (Low):** Space.jl header corrected — coref DFS is IMPLEMENTED, not "deferred".
- **MAIN-1 (Low):** `paths` INPUT branch now `error()`s (fail-loud), symmetric with the
  OUTPUT branch — was a silent-empty load.
- **SNK-1 (Low-Med):** PureSink `ifnz` now VALIDATES the `then`/`else` keyword positions
  `(ifnz COND then THEN [else ELSE])` and returns `nothing` on a malformed shape — was
  skipping the keywords unchecked, so `(ifnz cond X Y)` could silently mis-branch.

## DEFERRED / DOCUMENTED (genuinely not-now)
- **ML-1 tail:** MorkL subroutine-snapshot deepcopies → COW `copy()` when MorkL is promoted
  (sharing-surface gate required — not a fix to apply blind).
- **ML-2 (Low):** `parse_routine_with_args_paths` is a declared stub (upstream `todo!()`) —
  MorkL argument-passing unimplemented (functional limitation, tracked).
- **Float/number-format contract (SNK-2 FloatReductionSink/SumSink, PUR-NEW1 Pure
  `*_to_string`, FP-1 JSON WriteTranscriber) — CONTRACT DECIDED:** MORK uses Julia's default
  `string()`/`parse()` for numeric text. This is self-round-trippable WITHIN Julia and is the
  correct behaviour as long as numeric output stays inside the Julia stack. It is NOT changed
  now (no demonstrated break). IF/WHEN a numeric value crosses the Julia↔Rust or
  Julia↔external-MeTTa-consumer boundary, those specific sites switch to a Rust-`format!`-
  matching formatter. Documented here so it doesn't get "fixed" speculatively (the audit's
  own guidance: implement only at an actual boundary).

## CONFIRMED FIXED (prior close-outs spot-checked) — no action
I-1/I-2/I-3 (interning, incl. the `with_write_permit` RAII that PathMap's ZT-1 mirrors),
M-1 (MorkL OP_DROP_HEAD), P-1 (u128 bitwise), P-2 (ternarylogic), HeadSink join, coref-DFS
implemented. Defensible-by-design (not defects): MM-PERF1, DPZ/PZG-PERF1, FP-2/FP-3.

## Bottom line
No outright correctness defect crashing/corrupting the common data path. The real bugs
(D-P1 silent i128 truncation, SP-1 swallowed-exception gate) are fixed + tested; the
anti-COW deepcopy perf items (SRC-1, ML-1) are fixed; EA-1 soundness-default tightened.
MORK's kernel query/transform/calculus engine, interning, and parsers are high quality.
