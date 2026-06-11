# Upstream differential test — 2026-06-11

Fixtures: `tools/diff_upstream.jl` UPSTREAM_INPUTS (upstream `kernel/src/main.rs`)

**11 PASS · 3 FAIL · 0 CRASH · 0 MISS** of 14 fixtures

| fixture | status |
|---|---|
| `lookup` | PASS |
| `positive` | PASS |
| `positive_equal` | PASS |
| `negative` | PASS |
| `negative_equal` | PASS |
| `bipolar` | PASS |
| `top_level` | PASS |
| `two_positive_equal` | PASS |
| `two_positive_equal_crossed` | PASS |
| `two_bipolar_equal_crossed` | FAIL |
| `variable_priority` | FAIL |
| `variables_in_priority` | FAIL |
| `func_type_unification` | PASS |
| `issue_43` | PASS |

## FAIL — `two_bipolar_equal_crossed`

- expected: `"(Else (\$ bar) (_1 bar))\n(MATCHED (foo \$) (foo _1))\n(MATCHED (foo bar) (foo bar))\n(Something (foo \$) (foo _1))\n"`
- got:      `"(Else (\$ bar) (_1 bar))\n(MATCHED (foo bar) (foo bar))\n(Something (foo \$) (foo _1))\n"`

## FAIL — `variable_priority`

- expected: `"(A Z)\n(B Z)\n"`
- got:      `"(A Z)\n"`

## FAIL — `variables_in_priority`

- expected: `"(A Z)\n(B Z)\n"`
- got:      `"(A Z)\n"`
