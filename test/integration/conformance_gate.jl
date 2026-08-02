# conformance_gate.jl — the differential corpus as a REGRESSION GATE.
#
# 285 MM2 probes (156 sinks + 129 space), each paired with the vendored output of the upstream
# `mork` release binary (see test/conformance/run_conformance.jl for the rationale and the
# rendering caveat). The count is not fixed — probes get vendored; it was 277 on 2026-07-26.
#
# The gate is deliberately a RATCHET, not a demand for 285/285 — but it ratchets BOTH WAYS:
#   * every probe listed in EXPECTED_PASS.txt must still match upstream  -> else FAIL (regression)
#   * a probe outside the list that starts matching                      -> FAIL, harvest it
#     (`julia --project=. tools/harvest_conformance.jl`)
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

    # The corpus costs ~70s (285 probes) on a ~3min suite. `MORK_SKIP_CONFORMANCE=1` skips it for a
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

    # (2) RATCHET, OTHER SIDE — a probe that starts matching may not stay OUT of the baseline.
    # This was `@info`-only until 2026-08-01, which made the recorded number a LAGGING indicator:
    # a fix could raise real conformance while the baseline stood still, and nothing anywhere
    # forced the two back together. Four CODEMAP rows drifted that way, one by ~2x (recorded
    # 46/150, measured 27/156). An informational message does not maintain an invariant.
    improved = sort(collect(setdiff(passing, expected)))
    if !isempty(improved)
        @error """
               CONFORMANCE IMPROVED but NOT LOCKED IN — $(length(improved)) probe(s) now match \
               upstream and are missing from EXPECTED_PASS.txt. This is good news that must be \
               recorded, because an unharvested improvement lets the baseline drift below reality.
               Harvest it:  julia --project=. tools/harvest_conformance.jl""" improved
    end
    @test isempty(improved)
end
