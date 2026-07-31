# Cross-check: every upstream issue vs our Julia port (2026-07-31)

Fetched ALL issues from both upstreams and ran every behavioural reproducer through our engine.

    trueagi-io/MORK             20 issues   (2 open, 18 closed)  + 119 PRs
    Adam-Vandervorst/PathMap     0 issues                        +  60 PRs

⚠️ The repo metadata's `open_issues_count` (35 and 6) COUNTS PULL REQUESTS. PathMap has never had an
issue filed — our two reports would be the first.

## Result: every CLOSED behavioural issue is correctly handled in our port

| # | issue | ours | verdict |
|---|---|---|---|
| 22 | MM2 removal not working | `(bar a)`, no `(foo a)` | ✅ |
| 29 | decreasing specificity skips unifications | `OK` present | ✅ |
| 37 | variable introduction in templates | `(count0-2 4)`, not `(count0-2 (count0-2 $a))` | ✅ |
| 39 | exec fires on a removed expression | no spurious `(constant "x")`; conflict error raised | ✅ |
| 43 | coreferential_transition out of bounds | no crash, transition produced | ✅ |
| 53 | tail sink wrong for N ≥ 2 *(filed by us)* | tail2 `{b,e}`, tail3 `{c,d,e}`, head2 `{a,b}` | ✅ |
| 133 | pure `tuple` ignores tuple arguments | quoted form yields BOTH atoms | ✅ |

**#133 is worth reading before assuming it is a gap.** The unquoted program still yields only
`(S 0 Z)` — in ours AND upstream — because the issue was closed as USAGE, not as a code fix. The
accepted resolution is to quote the argument: `(tuple S $x (' $y))`. With that, ours produces both
atoms. There was never a fix to port. (An earlier pass here recorded it as a missing fix; running the
resolution's own program corrected that.)

## Open upstream issues

| # | issue | ours |
|---|---|---|
| 135 | quotation does not handle variable references | **same behaviour** — `(R ($a $b))`. Faithful parity with current upstream. |
| 136 | pure fails to capture a pattern output | upstream PANICS (`unrecognized sink`); ours produces no atoms. Both fail; ours does not abort. |

## Divergence worth knowing about

**#47** (variable in `exec` priority) was closed by making it ASSERT — `assertion failed:
loc.variables() == 0` (commit 28da5f9). Ours silently skips the exec instead. Same family as
`upstream_panics/`: we never abort mid-saturation, so "match upstream" has no useful meaning here.

## Not applicable

`#1` `#2` `#4` `#5` `#15` `#16` `#30` `#33` — licence, docs, build, `Debug` derives.
`#35` — Rust API usage (`parse_sexpr` signature), not a kernel behaviour.
`#36` — a PeTTa vs hyperon-experimental `superpose`/`if` discrepancy at the MeTTa layer, not MORK.

## Duplicate check for our seven reports

Scanned all 20 issue titles and bodies. **No duplicates.** One genuine adjacency:

* `mork-3` (quote cursor) vs **#135** (quote variable identity) — different symptoms, both in the
  quote branch. `mork-3` now says so at the top so a maintainer can judge whether to merge them.

Two keyword matches were false positives: `mork-1` hit "modulo" in an unrelated S-expression
discussion, `mork-4` hit "varref" in #43.
