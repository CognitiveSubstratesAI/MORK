# experiments/upstream_diff/run.jl
# Run the upstream differential fixtures through the Julia port and persist a dated result
# file under results/ for traceability. Reuses the harness in tools/diff_upstream.jl.
#
# Warm REPL (the only sanctioned way — never cold-start):
#   cd ~/code/CognitiveSubstratesAI/MORK
#   printf 'include("experiments/upstream_diff/run.jl"); exit()\n' | julia --project=. -i tools/repl.jl

using MORK
using Dates

# tools/diff_upstream.jl defines run_julia(src) + UPSTREAM_INPUTS and, on include, runs its
# default diff (which loads UPSTREAM_FIXTURES from tools/upstream_fixtures.jl into scope).
const _TOOLS = joinpath(@__DIR__, "..", "..", "tools")
include(joinpath(_TOOLS, "diff_upstream.jl"))       # run_julia, UPSTREAM_INPUTS, UPSTREAM_FIXTURES

# Optionally fold in extra fixture sets (Data-in-MORK wiki, etc.) if present.
const _EXTRA = joinpath(@__DIR__, "data_in_mork.jl")
isfile(_EXTRA) && include(_EXTRA)   # may append to UPSTREAM_INPUTS / UPSTREAM_FIXTURES

function run_and_save()
    rows = Tuple{String, String, Any, Any}[]
    pass = fail = crash = miss = 0
    for (name, src) in UPSTREAM_INPUTS
        try
            r = run_julia(src)
            expected = get(UPSTREAM_FIXTURES, name, nothing)
            status =
                expected === nothing ? "MISS" :
                (r.result == expected ? "PASS" : "FAIL")
            status == "PASS" && (pass += 1)
            status == "FAIL" && (fail += 1)
            status == "MISS" && (miss += 1)
            push!(rows, (name, status, expected, r.result))
        catch e
            crash += 1
            push!(rows, (name, "CRASH", nothing, sprint(showerror, e)))
        end
    end

    date = string(Dates.today())
    outdir = joinpath(@__DIR__, "results")
    mkpath(outdir)
    outfile = joinpath(outdir, "$(date)_upstream_diff.md")
    open(outfile, "w") do f
        println(f, "# Upstream differential test — $date")
        println(f, "")
        println(f,
            "Fixtures: `tools/diff_upstream.jl` UPSTREAM_INPUTS (upstream `kernel/src/main.rs`)",
            isfile(_EXTRA) ? " + `experiments/upstream_diff/data_in_mork.jl`" : "")
        println(f, "")
        println(
            f,
            "**$pass PASS · $fail FAIL · $crash CRASH · $miss MISS** of $(length(UPSTREAM_INPUTS)) fixtures"
        )
        println(f, "")
        println(f, "| fixture | status |")
        println(f, "|---|---|")
        for (name, status, _, _) in rows
            println(f, "| `$name` | $status |")
        end
        for (name, status, expected, got) in rows
            status in ("FAIL", "CRASH") || continue
            println(f, "\n## $status — `$name`\n")
            status == "FAIL" && println(f, "- expected: `", repr(expected), "`")
            println(f, "- got:      `", repr(got), "`")
        end
    end
    println(
        "UPSTREAM_DIFF_RESULT: $pass PASS  $fail FAIL  $crash CRASH  $miss MISS  →  $outfile"
    )
    (; pass, fail, crash, miss, outfile)
end

run_and_save()
