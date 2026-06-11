# experiments/upstream_diff/run_asserts.jl
# The CORRECT port-vs-upstream differential: checks upstream's OWN
# `assert!(res.contains(...))` from kernel/src/main.rs — NOT the self-recorded full-dump
# fixtures (which only detect regressions vs the port's own earlier output).
#
# Warm REPL:
#   cd ~/code/CognitiveSubstratesAI/MORK
#   printf 'include("experiments/upstream_diff/run_asserts.jl"); exit()\n' | julia --project=. -i tools/repl.jl

using MORK
using Dates
include(joinpath(@__DIR__, "..", "..", "tools", "diff_upstream.jl"))  # run_julia, UPSTREAM_INPUTS

# upstream main.rs `assert!(res.contains(...))` substrings (the real spec).
const UPSTREAM_ASSERTS = Dict{String,Vector{String}}(
    "lookup" => ["MATCHED\n"], "positive" => ["MATCHED\n"], "positive_equal" => ["MATCHED\n"],
    "negative" => ["MATCHED\n"], "negative_equal" => ["MATCHED\n"], "bipolar" => ["MATCHED\n"],
    "two_positive_equal" => ["MATCHED\n"], "two_positive_equal_crossed" => ["MATCHED\n"],
    "two_bipolar_equal_crossed" => ["(MATCHED (foo bar) (foo bar))\n"],
    "func_type_unification" => ["(c OK)\n"],
    # upstream COMMENTS THESE OUT in main() — variable-priority exec is WIP everywhere:
    "variable_priority" => ["(B Z)\n"], "variables_in_priority" => ["(B Z)\n"],
)
const _WIP = Set(["variable_priority", "variables_in_priority"])

# extra inputs not in the 14 (bipolar source/sink variants — assert only the GROUND match)
const EXTRA = [
    ("source_space_two_bipolar_equal_crossed",
     "(exec 0 (I (BTM (Something \$x \$y)) (BTM (Else \$x \$y))) (, (MATCHED \$x \$y) ))\n(Something (foo \$x) (foo \$x))\n(Else (\$x bar) (\$x bar))\n",
     ["(MATCHED (foo bar) (foo bar))\n"]),
    ("sink_two_bipolar_equal_crossed",
     "(exec 0 (, (Something \$x \$y) (Else \$x \$y)) (O (+ (MATCHED \$x \$y))))\n(Something (foo \$x) (foo \$x))\n(Else (\$x bar) (\$x bar))\n",
     ["(MATCHED (foo bar) (foo bar))\n"]),
]

const CASES = vcat(
    [(n, src, UPSTREAM_ASSERTS[n]) for (n, src) in UPSTREAM_INPUTS if haskey(UPSTREAM_ASSERTS, n)],
    EXTRA)

function run_and_save()
    rows = Tuple{String,String,Vector{String}}[]
    pass = fail = wipfail = crash = 0
    for (name, src, asserts) in CASES
        try
            r = run_julia(src)
            missing = [a for a in asserts if !occursin(a, r.result)]
            if isempty(missing)
                pass += 1; push!(rows, (name, "PASS", String[]))
            elseif name in _WIP
                wipfail += 1; push!(rows, (name, "FAIL(wip)", missing))
            else
                fail += 1; push!(rows, (name, "FAIL", missing))
            end
        catch e
            crash += 1; push!(rows, (name, "CRASH", [sprint(showerror, e)]))
        end
    end
    date = string(Dates.today())
    outdir = joinpath(@__DIR__, "results"); mkpath(outdir)
    outfile = joinpath(outdir, "$(date)_upstream_asserts.md")
    open(outfile, "w") do f
        println(f, "# Upstream-ASSERT differential — $date\n")
        println(f, "Checks upstream `main.rs` `assert!(res.contains(...))` (the real spec), not self-recorded dumps.\n")
        println(f, "**$pass PASS · $fail FAIL · $wipfail FAIL(wip, upstream-disabled) · $crash CRASH** of $(length(CASES))\n")
        println(f, "| case | status | missing |")
        println(f, "|---|---|---|")
        for (n, s, miss) in rows
            println(f, "| `$n` | $s | $(isempty(miss) ? "" : "`" * join(miss, "`, `") * "`") |")
        end
    end
    println("ASSERT_RESULT: $pass PASS  $fail FAIL  $wipfail FAIL(wip)  $crash CRASH  → $outfile")
    for (n, s, _) in rows; s == "PASS" || println("  $s  $n"); end
end

run_and_save()
