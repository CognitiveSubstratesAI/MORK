# tools/threeway_differential.jl — re-derive the conformance picture TRUSTING NOTHING.
#
# The gate (`test/integration/conformance_gate.jl`) compares our engine against the VENDORED
# `.expected` fixtures. That is fast and right for CI, but it cannot tell you whether the fixtures
# themselves still describe the upstream binary. On 2026-08-03 seven of them did not — they held
# U+FFFD where digest bytes belong, so no implementation could ever match them, and a real defect
# (`g2_and_compound_value`) sat unnoticed behind a probe that was failing for the wrong reason.
#
# This answers the question the gate cannot, by running BOTH engines fresh:
#
#     A = OUR engine          (run now)
#     B = the UPSTREAM BINARY (run now)
#     C = the VENDORED .expected fixture
#
#   ours_vs_live  A != B   the TRUE divergence count, independent of every fixture
#   fixture_rot   C != B   vendored fixtures that no longer describe the binary
#   CONTROL       in EXPECTED_PASS.txt but A != B      <-- MUST BE 0
#
# The control is the load-bearing line: it asserts that every probe the gate CLAIMS we match, we
# actually match against the binary. A non-zero control means the baseline is lying and every
# conformance number derived from it is worthless.
#
# Usage (from the MORK repo root):
#     julia --project=. tools/threeway_differential.jl
#     MORK_BIN=/path/to/mork julia --project=. tools/threeway_differential.jl
#
# The binary must be built from the VENDORED upstream pin; a mismatched build makes B meaningless.
using MORK

const BIN = get(ENV, "MORK_BIN", expanduser("~/dev-zone/MORK/target/release/mork"))
const CONF = joinpath(@__DIR__, "..", "test", "conformance")

include(joinpath(CONF, "run_conformance.jl"))

function main()
    isfile(BIN) || (@error "upstream binary not found — set MORK_BIN" BIN; return 2)
    out = mktempdir()
    baseline = Set{String}(
        strip(l) for
        l in eachline(joinpath(CONF, "EXPECTED_PASS.txt")) if !isempty(strip(l))
    )

    ours_vs_live = String[]
    fixture_rot = String[]
    control = String[]
    total = 0
    for g in ("sinks", "space")
        dir = joinpath(CONF, g)
        isdir(dir) || continue
        mkpath(joinpath(out, g))
        for f in sort(readdir(dir))
            endswith(f, ".mm2") || continue
            stem = f[1:(end - 4)]
            name = g * "/" * stem
            expf = joinpath(dir, stem * ".expected")
            isfile(expf) || continue
            total += 1
            live = joinpath(out, g, stem * ".up")
            # NEVER pipe the binary — a `| head` SIGPIPEs it mid-write and silently truncates,
            # which cost an hour on 2026-08-03 chasing a "missing" output file.
            run(
                pipeline(
                    `$BIN run $(joinpath(dir, f)) $live`; stdout=devnull, stderr=devnull
                )
            )
            A = _conf_run_probe(joinpath(dir, f))
            A = A === nothing ? String[] : A
            B = isfile(live) ? _conf_expected(live) : String[]
            C = _conf_expected(expf)
            A != B && push!(ours_vs_live, name)
            C != B && push!(fixture_rot, name)
            (name in baseline) && A != B && push!(control, name)
        end
    end

    println("\n=== three-way differential ===")
    println("  probes                     ", total)
    println(
        "  ours != LIVE BINARY        ", length(ours_vs_live), "   <- true divergence count"
    )
    println(
        "  fixture != LIVE BINARY     ",
        length(fixture_rot),
        "   <- fixtures no longer describing the binary"
    )
    println("  baseline (EXPECTED_PASS)   ", length(baseline))
    println("  CONTROL: baselined but ours != binary  ", length(control), "   <- MUST BE 0")
    isempty(fixture_rot) ||
        (println("\n  fixture rot:"); foreach(n -> println("    ", n), fixture_rot))
    isempty(control) || (
        println("\n  !! CONTROL VIOLATIONS — the baseline is lying:");
        foreach(n -> println("    ", n), control)
    )
    println("\n  live binary outputs kept at: ", out)
    isempty(control) ? 0 : 1
end

if abspath(PROGRAM_FILE) == @__FILE__
    exit(main())
end
