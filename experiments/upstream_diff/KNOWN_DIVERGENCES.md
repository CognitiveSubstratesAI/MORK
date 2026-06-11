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
