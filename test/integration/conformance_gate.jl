# conformance_gate.jl — the differential corpus as a REGRESSION GATE.
#
# 277 MM2 probes, each paired with the vendored output of the upstream `mork` release binary
# (see test/conformance/run_conformance.jl for the full rationale and the rendering caveat).
#
# The gate is deliberately a RATCHET, not a demand for 277/277:
#   * every probe listed in EXPECTED_PASS.txt must still match upstream  -> else FAIL (regression)
#   * a probe outside the list that starts matching                      -> INFO, add it to the list
# So it stays green at today's conformance level and can only get tighter. The probes outside the
# list are KNOWN divergences (root-doubling, HashSink's non-gxhash function, locvar back-ref scoping,
# USink, chain4, FloatReduction grouping, some Pure op semantics) — each tracked in CODEMAP.
#
# WHY A RATCHET AND NOT A FLAT ASSERTION. Nine silent defects were fixed on 2026-07-25/26 that the
# then-1933-test suite could not catch, because no fixture exercised the shapes. Nothing in the repo
# would have noticed any of them being reverted. This file is what makes that impossible.
using MORK, Test

include(joinpath(@__DIR__, "..", "conformance", "run_conformance.jl"))

@testset "MM2 differential conformance gate (vs upstream binary)" begin
    baseline_path = joinpath(@__DIR__, "..", "conformance", "EXPECTED_PASS.txt")
    @test isfile(baseline_path)

    # The corpus costs ~70s (277 probes) on a ~3min suite. `MORK_SKIP_CONFORMANCE=1` skips it for a
    # tight local edit loop — but it is DEFAULT-ON and CI MUST NOT SET IT. This gate is the only thing
    # in the repo that would notice the 2026-07-25/26 fixes being reverted; skipping it by habit puts
    # them back at the mercy of a suite that already failed to catch them once.
    if get(ENV, "MORK_SKIP_CONFORMANCE", "") == "1"
        @info "conformance corpus SKIPPED (MORK_SKIP_CONFORMANCE=1) — do not set this in CI"
        return
    end

    expected = Set{String}(strip(l) for l in eachline(baseline_path) if !isempty(strip(l)))
    passing, total, orphans = conformance_results()
    # A .mm2 with no .expected is INERT — it never ran. Fail loudly rather than let the
    # corpus count look healthy while a probe silently does nothing.
    isempty(orphans) || @info "conformance: .mm2 with NO .expected (inert, never run)" orphans
    @test isempty(orphans)

    @test total > 0
    @info "conformance corpus" total passing = length(passing) baseline = length(expected)

    # (1) RATCHET — nothing that matched upstream may stop matching.
    regressed = sort(collect(setdiff(expected, passing)))
    if !isempty(regressed)
        @error "CONFORMANCE REGRESSION — these probes matched upstream and no longer do" regressed
    end
    @test isempty(regressed)

    # (2) IMPROVEMENTS — informational, never a failure. Tighten the baseline when they appear.
    improved = sort(collect(setdiff(passing, expected)))
    isempty(improved) || @info(
        "conformance IMPROVED — add these to test/conformance/EXPECTED_PASS.txt to lock them in",
        improved)
end
