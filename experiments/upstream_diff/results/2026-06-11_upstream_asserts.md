# Upstream-ASSERT differential — 2026-06-11

Checks upstream `main.rs` `assert!(res.contains(...))` (the real spec), not self-recorded dumps.

**12 PASS · 0 FAIL · 2 FAIL(wip, upstream-disabled) · 0 CRASH** of 14

| case | status | missing |
|---|---|---|
| `lookup` | PASS |  |
| `positive` | PASS |  |
| `positive_equal` | PASS |  |
| `negative` | PASS |  |
| `negative_equal` | PASS |  |
| `bipolar` | PASS |  |
| `two_positive_equal` | PASS |  |
| `two_positive_equal_crossed` | PASS |  |
| `two_bipolar_equal_crossed` | PASS |  |
| `variable_priority` | FAIL(wip) | `(B Z)
` |
| `variables_in_priority` | FAIL(wip) | `(B Z)
` |
| `func_type_unification` | PASS |  |
| `source_space_two_bipolar_equal_crossed` | PASS |  |
| `sink_two_bipolar_equal_crossed` | PASS |  |
