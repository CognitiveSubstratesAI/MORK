# Known upstream divergences (interpretation of the diff results)

A raw `FAIL` in `results/*.md` is not automatically a port bug — the golden fixtures cover
cases that upstream itself disables. Cross-check each FAIL against upstream's *own* test runner
(`kernel/src/main.rs` `main()`) before acting. Status as of 2026-06-11 (3 FAIL / 14):

| fixture | upstream `main()` status | verdict |
|---|---|---|
| `variable_priority` | **commented out** (`// variable_priority();`) | WIP upstream — variable-priority exec not implemented anywhere. Port emits `(A Z)` (rule doesn't fire); upstream *asserts* `(B Z)` but never runs it. **Not a clean port regression — a shared unimplemented feature.** |
| `variables_in_priority` | **commented out** (`// variables_in_priority();`) | same — WIP upstream. |
| `two_bipolar_equal_crossed` | **ACTIVE** (`assert!` runs) | **REAL port divergence.** Port drops one nondeterministic result (`(MATCHED (foo $) (foo _1))`). A multi-result/unification gap in crossed-bipolar-variable matching — **directly relevant to the E1→B engine work; investigate + fix.** |

Other upstream-disabled cases to be aware of when expanding fixtures:
- `// func_type_unification(); // failing!` — marked failing upstream (the Julia port currently
  PASSes its recorded fixture, but the recorded golden may not be upstream-verified).
- `// logic_query(); // possibly faulty test`.

## Action

1. **`two_bipolar_equal_crossed`** is the one real bug here — a missing nondeterministic
   MATCHED result. Reproduce minimally, compare against the live Rust binary if built, fix the
   multi-result emission. (Pairs with E1's multi-result work.)
2. Variable-priority execs: track as a shared WIP gap; don't treat the FAIL as a regression.
3. When recording new fixtures from the wiki/main.rs, note each case's upstream `main()` status
   here so the diff stays interpretable.

---

## Update 2026-06-11 — full 32-fixture run (23 PASS / 6 FAIL / 0 CRASH)

**Both CRASHes fixed.** `source_cmp_ne` and `source_cmp_rel` crashed with
`MethodError: no read_zipper(::AlgResElement)`. Root cause was two layered bugs, both fixed:
- **MORK** `CmpSource` `!=` path passed `psubtract`'s `AlgebraicResult` straight to `read_zipper`
  instead of unwrapping it (Element→`.value`, Identity→`btm`, None→empty). Fixed in `Sources.jl`.
- **PathMap** `psubtract` over a node with an empty-child rc crashed on `node_is_empty(::Nothing)`
  (the `nothing` EmptyNode sentinel). Fixed by adding `node_is_empty(::Nothing) = true`.

Result: `source_cmp_rel` now **PASSES** upstream's assert. `source_cmp_ne` is **correct** but shows
as **FAIL** — a **harness artifact**: upstream asserts on a *projected* dump
(`dump_sexpr(expr!("[2] OUT $"), "_1")`, which unwraps `(OUT …)` → bare `(X != Y)`), while our
`run_asserts` harness uses the full `space_dump_all_sexpr` (keeps the `(OUT …)` wrapper). The port
emits the correct `(OUT (X != Y))` for all 6 pairs. **To clear it, teach the harness upstream's
projected-dump form; not a port bug.** Regression-tested in MORK `runtests.jl` (`!=` comparison source).

**`two_bipolar_equal_crossed` — earlier "REAL divergence" verdict (rows above) is RETRACTED**
(see `experiments/upstream_diff/findings/two_bipolar_equal_crossed.md`): the port satisfies upstream's
*actual* `assert!(res.contains("(MATCHED (foo bar) (foo bar))"))`; the "dropped" second result is a
nondeterministic extra upstream does not assert. Not a confirmed bug.

Remaining real FAILs to triage next: `source_cmp_eq`, `source_map_reverse`,
`source_act*_two_bipolar`, `sink_sum_literal` (still fails after the SumSink encoding fix — revisit).
