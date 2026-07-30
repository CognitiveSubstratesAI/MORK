# PORT COVERAGE RATCHET — fails when a previously-ported upstream symbol goes missing, and when the
# unported set grows. This is the instrument the suite did not have.
#
# WHY (2026-07-29). 30+ days of porting, 2436 passing tests, a 277-probe byte-exact differential
# against the upstream binary, and a PathMap differential — and an ENTIRE upstream family was absent:
# all 42 typed comparison ops in `kernel/src/pure.rs` (`eq_/ne_/lt_/lte_/gt_/gte_` x
# `i8/i16/i32/i64/i128/f32/f64`). It was found by set-comparing NAMES, by hand, by accident.
#
# 🔴 NO BEHAVIOURAL TEST CAN FIND THAT, and the reason is structural, not a matter of diligence:
#   * A DIFFERENTIAL compares outputs, so BOTH sides must be able to express the program. A wrong op
#     produces a wrong answer and gets caught. A MISSING op has no probe — you would have to author an
#     MM2 program calling `lt_i64`, and nobody writes a probe for an op their engine lacks. The corpus
#     is self-selecting.
#   * A TEST SUITE tests written code. Unwritten code has no test to fail.
#   * `EXPECTED_PASS` is a RATCHET over probes that exist; it is silent about what is not probed.
#   * And our op count is HIGHER than upstream's (490 `PURE_OPS` keys vs 371 upstream registrations),
#     so any count-based sanity check REASSURES. A superset by count can still be missing a family.
#
# The one measurement that would have caught it WAS made — `test/conformance/pure_ops/README.md`,
# 2026-07-28: "covers 18 of upstream's 360 pure ops (5%) … covered=18 UNCOVERED=342" — and it sat next
# to an UNWIRED harness (`cmp_pure.jl` requires `ENV["PROBES"]`; nothing calls it). Knowledge that
# nothing executes changes nothing. Hence this file: the check runs in the suite, every time.
#
# HOW THE RATCHET WORKS
#   `tools/port_inventory.jl` set-compares the VENDORED upstream symbol inventory
#   (`test/conformance/PORT_INVENTORY.txt`, 636 symbols) against the names our `src/` defines. This
#   file pins the CURRENT missing counts. A count that GROWS fails — something that was ported is gone,
#   or upstream grew and we did not follow. A count that SHRINKS also fails, telling you to lower the
#   pin, so progress is recorded rather than silently absorbed.
#
# ⚠️ LENIENT BY CONSTRUCTION. `port_has` accepts our renaming conventions (`query_multi` ->
# `space_query_multi`, `!` suffixes) including a loose suffix match, so a coincidental hit counts as
# present. **Absence is proof of a gap; presence is NOT proof of equivalence.** Behavioural
# conformance is what `run_conformance.jl` is for. These two instruments answer different questions
# and neither substitutes for the other.
using Test

include(joinpath(@__DIR__, "..", "tools", "port_inventory.jl"))

@testset "port inventory ratchet (upstream symbol coverage)" begin
    c = coverage()

    @test c.fns_total >= 550          # the vendored baseline is present and plausible
    @test c.tys_total >= 75

    # The baseline MUST record which upstream revision it was taken from, and it must be MAIN.
    # Without a pinned revision this whole file is unfalsifiable — it cannot distinguish "we never
    # ported X" from "upstream added X after we ported". That is not hypothetical: the 42 typed
    # comparison ops read as a 30-day miss until the pin showed they landed upstream 2026-07-02
    # (PR #125 `add-comparison`, which IS main's HEAD). And MAIN specifically, because the release
    # binary the 277-probe differential grades us against is built from main, while our port also
    # draws from a `server` branch that is ~55 days staler.
    rev = baseline_revision()
    @test !occursin("UNPINNED", rev)
    @test !occursin("NO BASELINE", rev)
    @test startswith(rev, "main @")
    @info "port inventory baseline" upstream = rev

    # ── the pins. Update DELIBERATELY, in a commit that says which symbols moved and why. ─────────
    # Recorded 2026-07-29 against upstream MORK @ dev-zone. Two of these gaps are DOCUMENTED
    # decisions, not drift, and should not be "fixed" without revisiting the decision:
    #   * expr/lib.rs — memory `reference_mork_port_state_and_rule64`: "DELIBERATE PARTIAL
    #     (38/74 expr fns)". Matches: 31 of 43 present here.
    #   * linalg/*    — CODEMAP: "linalg = standalone, NOT wired to MM2". Deliberately unported.
    # The rest are genuine gaps. `kernel/pure.rs` prompted this file and is now at ZERO — not because
    # anything was ported today, but because the tool was WRONG: it read source text instead of the
    # live registries and invented a 42-op gap (see the header). 148 -> 106 is that fiction being
    # removed from the measurement, so the pin must come down with it or it re-admits the fiction.
    #
    # 106 -> 111 and TYS 32 -> 35 on the same day, and this rise is HONEST: `experiments/eval` was
    # added to CRATES because the tool had never scanned the crate that DEFINES the evaluator it was
    # measuring registrations into (`EvalScope`, `FuncType{Macro,Pure}`, `Func`, `StackFrame`,
    # `add_func`, `push_eval`, `eval_impl`, `alloc_pool`). Nothing regressed; we started looking
    # somewhere we never had. The user spotted the omission, not the tool.
    # ⚠️ STILL UNSCANNED: `experiments/eval-ffi` (a KERNEL dependency), `experiments/eval-examples`,
    # `experiments/unification_test_laws` (883 lines of unification LAWS — a ready-made oracle we have
    # never run), and ALL of PathMap. Do not read this percentage as whole-port coverage.
    PIN_FNS = 111
    # ⚠️ The TYPE figure is NOT an actionable gap measure and must not be treated as one. A first cut
    # reported 35% and named `ASink`, `ASource`, `AFactor`, `HeadTailSink`, `ParDataParser`,
    # `SourceItem` and `Tag` as unported — ALL SEVEN ARE PRESENT, as `const X = Union{…}` dispatch
    # unions (`Sinks.jl:1363` is literally "ASink — dispatch union"). The port maps Rust ENUM wrappers
    # onto Julia UNION ALIASES deliberately. After widening the extractor it reads 46/78; the residue
    # is dominated by Rust IDIOM with no Julia counterpart (GxHasher, HashMapExt/HashSetExt extension
    # traits, Traversal/TraverseSide iterator types, serde derive types) plus the deliberate `linalg`
    # skip. Only ~5 names are worth a look: WriteResourceRequest, ASpaceTranscriber, ATranscriber,
    # DebugTranscriber, Tables. So this pin is a REGRESSION guard, not a target to drive to zero.
    PIN_TYS = 35

    @test c.fns_missing <= PIN_FNS
    @test c.tys_missing <= PIN_TYS
    if c.fns_missing < PIN_FNS || c.tys_missing < PIN_TYS
        @info "port coverage IMPROVED — lower the pins in this file" fns = c.fns_missing tys = c.tys_missing
    end
    @test c.fns_missing >= 0

    # ── named guards: families whose absence is a KNOWN, ACTIONABLE gap. ───────────────────────────
    bysite = Dict(f => m for (f, m) in c.report)

    @testset "kernel/pure.rs — inventory is COMPLETE (the 42 comparison ops are PORTED)" begin
        fm, _ = bysite["kernel/pure.rs"]
        # 🔴🔴 THIS ASSERTION USED TO READ `== 42`, AND IT WAS A FALSE FACT FROZEN AS AN EXPECTATION.
        # The ops were ported in `a1fef45` (2026-07-26) and verified 79/79 by the differential in
        # `integration/pure_comparison_ops.jl` — which is wired into THIS SAME SUITE. So the suite was
        # green while asserting both "these 42 are missing" and "these 42 match upstream".
        #
        # Cause: the tool regexed source text for literal `"name" =>` pairs, and our 42 keys are
        # interpolated (`PURE_OPS["$(name)_$(suffix)"]`, Pure.jl:1002) — invisible to any grep.
        # `tools/port_inventory.jl` now reads the LIVE registries, so this is a real measurement.
        #
        # ⚠️ WHAT THIS TEST DOES AND DOES NOT PROVE. It proves upstream registers no `pure.rs` op name
        # we lack. It says NOTHING about behaviour: the per-op differential probes each op at ONE input
        # (`gen_pure_probes.py` FEED = one value per type, nary ops fed exactly 2 args), and a
        # 2026-07-30 edge-domain audit found 16 BEHAVIOURAL divergences among these very ops — nary
        # min/max folded as binary, NaN, 0-arg sum/product, shift >= width, signum(-0.0), `tuple`
        # flattening nested exprs. A complete inventory with divergent bodies is exactly the state a
        # name diff reports as perfect. Do not read this green as "pure.rs is ported correctly".
        cmpops = filter(n -> any(startswith(n, p) for p in ("eq_", "ne_", "lt_", "lte_", "gt_", "gte_")), fm)
        @test isempty(cmpops)
        @test isempty(fm)                   # NOTHING in pure.rs is missing by name (370/370 registered)
    end

    @testset "documented-deliberate gaps stay bounded" begin
        @test length(bysite["expr/lib.rs"][1])   <= 43   # DELIBERATE PARTIAL (38/74), see memory note
        @test length(bysite["expr/lib.rs"][2])   <= 12   # …and its unported TYPES
        @test length(bysite["kernel/space.rs"][1]) <= 16  # JSON/JSONL/neo4j loaders + transform variants
    end
end
