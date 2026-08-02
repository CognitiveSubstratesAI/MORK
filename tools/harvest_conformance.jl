# tools/harvest_conformance.jl — lock newly-matching probes into the conformance baseline.
#
# Usage:
#   julia --project=. tools/harvest_conformance.jl          # report + rewrite EXPECTED_PASS.txt
#   julia --project=. tools/harvest_conformance.jl --check   # report only, exit 1 if work is pending
#
# WHY THIS EXISTS (2026-08-01). `test/integration/conformance_gate.jl` is a two-sided ratchet:
# probes may not fall OUT of EXPECTED_PASS.txt (regression -> FAIL), and probes that start matching
# may not stay OUT of it either (improvement -> FAIL). The second half is new. Before it, an
# improvement was `@info`-only, so a fix could raise real conformance while the recorded number
# stood still — and four CODEMAP rows drifted up to 2x off that way (46/150 recorded vs 27/156
# measured). Making the gate fail on an unharvested improvement is only reasonable if harvesting is
# trivial, which is what this script is for.
#
# THE SAFETY PROPERTY, and the reason this is not just `write(sort(passing))`:
# if ANY probe has REGRESSED, rewriting the baseline to the current passing set would DELETE that
# probe's entry and silently accept the regression — converting the gate's loudest failure into a
# no-op commit. So a regression is a hard refusal here, never a rewrite. Fix the regression first.

using MORK

include(joinpath(@__DIR__, "..", "test", "conformance", "run_conformance.jl"))

const BASELINE = joinpath(@__DIR__, "..", "test", "conformance", "EXPECTED_PASS.txt")

function harvest(; check_only::Bool=false)
    expected = Set{String}(strip(l) for l in eachline(BASELINE) if !isempty(strip(l)))
    passing, total, orphans = conformance_results()

    if !isempty(orphans)
        @error "REFUSING — .mm2 probes with no .expected (inert, never run). Fix these first." orphans
        return 1
    end

    regressed = sort(collect(setdiff(expected, passing)))
    if !isempty(regressed)
        @error """
               REFUSING TO HARVEST — $(length(regressed)) probe(s) REGRESSED.
               Rewriting the baseline now would delete these entries and silently accept the
               regression. Fix the regression, then harvest.""" regressed
        return 1
    end

    improved = sort(collect(setdiff(passing, expected)))
    if isempty(improved)
        @info "conformance baseline is already exact" total baseline = length(expected)
        return 0
    end

    if check_only
        @warn "conformance IMPROVED — $(length(improved)) probe(s) are unharvested" improved
        return 1
    end

    # `passing` is a superset of `expected` here (regressed is empty), so this only ever ADDS.
    # Byte-order sort matches the file's existing order (LC_ALL=C).
    open(BASELINE, "w") do io
        for name in sort(collect(passing))
            println(io, name)
        end
    end
    @info("harvested — EXPECTED_PASS.txt tightened",
          added = length(improved), improved,
          baseline = "$(length(expected)) -> $(length(passing))", total)
    return 0
end

if abspath(PROGRAM_FILE) == @__FILE__
    exit(harvest(check_only = "--check" in ARGS))
end
