# Upstream-ASSERT differential — 2026-06-11

Checks upstream `main.rs` `assert!(res.contains(...))` (the real spec). `(wip)` = upstream comments the test out in its own `main()` (WIP/known-faulty), not a port regression.

**24 PASS · 4 FAIL · 0 CRASH** (real)  +  1 PASS(wip) · 3 FAIL(wip)  of 32

| case | status | missing assert |
|---|---|---|
| `variable_priority` | FAIL(wip) | `(B Z)
` |
| `variables_in_priority` | FAIL(wip) | `(B Z)
` |
| `lookup` | PASS |  |
| `positive` | PASS |  |
| `positive_equal` | PASS |  |
| `negative` | PASS |  |
| `negative_equal` | PASS |  |
| `bipolar` | PASS |  |
| `bipolar_equal` | PASS |  |
| `two_positive_equal` | PASS |  |
| `two_positive_equal_crossed` | PASS |  |
| `two_bipolar_equal_crossed` | PASS |  |
| `func_type_unification` | PASS(wip) |  |
| `top_level_match` | PASS |  |
| `source_space_two_bipolar_equal_crossed` | PASS |  |
| `source_act_two_bipolar_equal_crossed` | FAIL | `(MATCHED (foo bar) (foo bar))
` |
| `source_space_act_two_bipolar_equal_crossed` | FAIL | `(MATCHED (foo bar) (foo bar))
` |
| `source_cmp_eq` | FAIL | `(REM (RHS ($a bar)))
` |
| `source_sink_cmp_eq_remove` | PASS |  |
| `source_sink_cmp_eq_remove_both` | PASS |  |
| `source_sink_annihilate` | PASS |  |
| `source_cmp_ne` | FAIL | `(X != Y)
(X != Z)
(Y != X)
(Y != Z)
(Z != X)
(Z != Y)
` |
| `source_cmp_rel` | PASS |  |
| `source_map_reverse` | FAIL(wip) | `(res Z) (res R)
` |
| `sink_two_bipolar_equal_crossed` | PASS |  |
| `sink_two_positive_equal_crossed` | PASS |  |
| `sink_add_remove` | PASS |  |
| `sink_add_remove_var` | PASS |  |
| `sink_sum_literal` | PASS |  |
| `sink_exec_remove_trigger` | PASS |  |
| `sink_count_double` | PASS |  |
| `sink_count_double_repeated` | PASS |  |
