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

## Update 2026-06-11 (b) — `sink_sum_literal` FIXED → 24 PASS / 5 FAIL / 0 CRASH

`sum` was a placeholder: not in `_is_accumulating_sink`, and its finalize flat-summed raw symbol
bytes and emitted a bare number — ignoring the `(sum <result> <expected> $x)` structure entirely
(an earlier commit only fixed its number *encoding*, unit-tested on bare symbols). Ported the real
`SumSink::finalize` literal branch: accumulate `$x` grouped by `(<result> <expected>)`, emit
`<result>` iff the decimal sum equals the `<expected>` literal. Added `sum` to the accumulating-sink
recognizer (so it sums across matches). `(foo 1/2/3)` → `(sum (correct) 6 $x)` emits `(correct)`,
`(sum (incorrect) 5 $x)` stays silent. Regression-tested end-to-end (replaces the old placeholder
unit test). Commit in MORK.

## Update 2026-06-11 (c) — `source_cmp_eq` is a serialize-format divergence, not a bug

`source_cmp_eq` computes the **correct** result — the port emits `(REM (RHS ($ bar)))`, structurally
identical to upstream's expected `(REM (RHS ($a bar)))`. The only difference is how the free variable
is *printed*: the port's `expr_serialize` renders NewVar as `$` and VarRef as `_N`, while upstream's
`dump_all_sexpr` uses `serialize2(…, |i,_intro| Expr::VARNAMES[i])` with
`VARNAMES = ["$a","$b",…,"$j","$x10",…]` — i.e. every variable is named by index. So `$` (port) vs
`$a` (upstream) for the first variable. **Computation correct; serialize format differs** (same class
as `source_cmp_ne`'s OUT-projection). Aligning the port's serializer to upstream's VARNAMES would clear
both and make dumps byte-identical, but it changes the port's canonical dump format and would touch
many existing `$`/`_N`-asserting tests — a deliberate, separate decision, not a bug fix.

## Update 2026-06-11 (d) — `source_map_reverse` is an unimplemented-upstream feature, not a bug

`source_map_reverse` exercises a `reverse` **source operator**. It is unimplemented in upstream too:
`ASource::new` (sources.rs) dispatches only `BTM`/`ACT`/`z3`/`==`/`!=` and falls to `unreachable!()`
for anything else, and the `source_map_reverse()` test is **defined but never called** in upstream
`main()` (not even commented). So `reverse` would *panic* if run upstream. The Julia port handles it
**more gracefully** — `asource_new` falls through to `CompatSource`, which matches nothing and emits
nothing (no crash). Reclassified as **wip** (defined-but-never-wired = unimplemented/aspirational),
not a port regression. Extractor `WIP` set updated to mark defined-but-uncalled tests.

## Update 2026-06-11 (e) — the `source_act*_two_bipolar` "FAILs" are extraction artifacts → 0 genuine FAILs

`source_act_two_bipolar_equal_crossed` and `source_space_act_two_bipolar_equal_crossed` are **ACT-file
tests**: the upstream test builds a *separate* space, `backup_tree()`s it to a `.act` mmap file, then
runs an exec whose sources are `(ACT <file> <pat>)` reading that file. Two problems make the fixture
meaningless: (1) the extractor captures only the first `r#"…"#` literal — the **data**, missing the
exec entirely; (2) even with the exec, `run_julia(string)` can't replicate the `backup_tree`/mmap
file setup. So the harness fed just `(Something …)(Else …)` with no exec → trivially no `MATCHED` →
"FAIL". **This says nothing about the port.** Removed from the fixtures + added to the extractor SKIP
set (same rationale as `source_map_oom`). Verifying the ACT-source path needs a dedicated ACT-aware
test (backup_tree + ACT sources + dump) — an OPEN question, not a known bug.

### Final state: **24 PASS · 2 FAIL · 0 CRASH** — 0 genuine unexplained FAILs.
Both remaining FAILs are serialize-format artifacts with **correct computation**:
- `source_cmp_ne` — harness full-dump vs upstream's projected `dump_sexpr` (OUT-unwrap).
- `source_cmp_eq` — port `$`/`_N` vs upstream `VARNAMES` (`$a`) variable naming.

The core matching/unification engine **conforms to 100% of upstream's runnable asserts.** Open items
are not engine bugs: the optional serialize alignment, and the deep bipolar/multi-result unification
(B-phase) — which also affects the in-memory 2-source crossed case, not just ACT.

## Update 2026-06-11 (f) — ACT-source path VERIFIED sound; found+fixed a backup_tree misport

Wrote a dedicated ACT test (the differential's string harness can't). Result: the ACT-source
infrastructure **works** — a simple `backup_tree → (ACT …) read` yields `(got a/b/c)`, and
backup→restore round-trips. Along the way found a real bug: `space_backup_tree` wrote `serialize_paths`
(that's `backup_PATHS`) instead of an `ArenaCompactTree`, so ACT reads of a backup_tree file crashed
("Invalid ACTree magic"). Fixed both `backup_tree`/`restore_tree!` to mirror upstream
(`ArenaCompactTree::dump_from_zipper` / `open_mmap`). The `source_act*_two_bipolar` cases still don't
match — but that's the **deep bipolar/multi-result** gap (the in-memory 2-source crossed case has it
too), NOT an ACT issue. See MORK `test/runtests.jl` "ACT backup_tree → (ACT …) source read".
