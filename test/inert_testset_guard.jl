# test/inert_testset_guard.jl — FAIL THE BUILD ON A TESTSET THAT ASSERTS NOTHING.
#
# WHY (2026-07-23). `Test` reports "N passed, 0 failed" and the eye stops at the 0. It cannot
# distinguish a testset that verified something from one that ran to completion asserting NOTHING —
# and the latter is the more expensive defect, because it reports coverage it does not have while
# everything downstream is trusted on the strength of it. Two instances found the same day:
#   · `upstream_conformance.jl` — our ONLY differential check vs the built Rust binary — erroring on
#     every mandated run because `tools/repl.jl:27` shadows `Base.run`. 15 assertions, 0 executed,
#     suite green (c543841).
#   · a Core suite reporting "0 failures" from a runner script that did not exist; `testsets=0` was
#     the tell, not the 0.
# An `errored` line among 1848 passes reads as noise. A COUNT does not.
#
# RULE: a LEAF testset (no child testsets) that contributes ZERO passing assertions is INERT.
# Skips do not count as coverage — a file whose every branch degraded to `@test_skip` lands here
# exactly as intended (see `_oracle_missing` in integration/upstream_conformance.jl).
using Test

"""
    inert_testsets(ts) -> Vector{Tuple{String,Int}}

Leaf testsets under `ts` that passed 0 assertions, as `(dotted path, n_broken)`. `n_broken > 0`
means the leaf was all-skips — coverage that was PLANNED and then silently dropped.
"""
function inert_testsets(ts::Test.DefaultTestSet, prefix::String = "")
    path  = isempty(prefix) ? ts.description : prefix * " › " * ts.description
    kids  = [r for r in ts.results if r isa Test.DefaultTestSet]
    if isempty(kids)
        broken = count(r -> r isa Test.Broken, ts.results)
        return ts.n_passed == 0 ? [(path, broken)] : Tuple{String,Int}[]
    end
    reduce(vcat, (inert_testsets(k, path) for k in kids); init = Tuple{String,Int}[])
end

"""
    assert_no_inert_testsets(ts)

Throw if any leaf testset asserted nothing. Call on the value of the TOP-LEVEL `@testset`.
"""
function assert_no_inert_testsets(ts::Test.DefaultTestSet)
    bad = inert_testsets(ts)
    isempty(bad) && return nothing
    io = IOBuffer()
    println(io, "INERT TESTSETS — these ran and asserted NOTHING, so the green result overstates ",
                "coverage by exactly their scope:")
    for (p, broken) in bad
        println(io, "  · ", p, broken > 0 ? "   ($broken skipped — coverage planned, then dropped)" :
                                            "   (0 assertions)")
    end
    println(io, "Either make them assert, or DELETE them. A test that cannot run is worse than a ",
                "missing test: the missing one is visibly absent.")
    error(String(take!(io)))
end
