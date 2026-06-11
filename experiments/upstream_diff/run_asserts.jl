# experiments/upstream_diff/run_asserts.jl
# The CORRECT port-vs-upstream differential: checks upstream's OWN
# `assert!(res.contains(...))` from kernel/src/main.rs (extracted into main_rs_fixtures.jl) —
# NOT the self-recorded full-dump fixtures (which only detect regressions vs the port's own output).
#
# Warm REPL:
#   cd ~/code/CognitiveSubstratesAI/MORK
#   printf 'include("experiments/upstream_diff/run_asserts.jl"); exit()\n' | julia --project=. -i tools/repl.jl
#
# Regenerate fixtures from upstream:  python3 /tmp/extract_fixtures.py experiments/upstream_diff/main_rs_fixtures.jl

using MORK
using Dates
include(joinpath(@__DIR__, "..", "..", "tools", "diff_upstream.jl"))   # run_julia
include(joinpath(@__DIR__, "main_rs_fixtures.jl"))                     # MAIN_RS_FIXTURES

function run_and_save()
    rows = Tuple{String,String,Vector{String}}[]
    pass = fail = wipfail = wippass = crash = 0
    for fx in MAIN_RS_FIXTURES
        print(stderr, "  · ", rpad(fx.name, 42)); flush(stderr)
        try
            r = run_julia(fx.input, 50_000)   # conformance tests terminate in <100 steps; cap bounds runaways
            println(stderr, "done")
            missing = [a for a in fx.asserts if !occursin(a, r.result)]
            if isempty(missing)
                fx.wip ? (wippass += 1; push!(rows, (fx.name, "PASS(wip)", String[]))) :
                         (pass += 1;    push!(rows, (fx.name, "PASS", String[])))
            elseif fx.wip
                wipfail += 1; push!(rows, (fx.name, "FAIL(wip)", missing))
            else
                fail += 1;    push!(rows, (fx.name, "FAIL", missing))
            end
        catch e
            crash += 1; push!(rows, (fx.name, "CRASH", [first(split(sprint(showerror, e), '\n'))]))
        end
    end

    date = string(Dates.today())
    outdir = joinpath(@__DIR__, "results"); mkpath(outdir)
    outfile = joinpath(outdir, "$(date)_upstream_asserts.md")
    open(outfile, "w") do f
        println(f, "# Upstream-ASSERT differential — $date\n")
        println(f, "Checks upstream `main.rs` `assert!(res.contains(...))` (the real spec). `(wip)` = upstream",
            " comments the test out in its own `main()` (WIP/known-faulty), not a port regression.\n")
        println(f, "**$pass PASS · $fail FAIL · $crash CRASH** (real)  +  $wippass PASS(wip) · $wipfail FAIL(wip)",
            "  of $(length(MAIN_RS_FIXTURES))\n")
        println(f, "| case | status | missing assert |")
        println(f, "|---|---|---|")
        for (n, s, miss) in rows
            println(f, "| `$n` | $s | $(isempty(miss) ? "" : "`" * join(miss, "`, `") * "`") |")
        end
    end
    println("ASSERT_RESULT: $pass PASS  $fail FAIL  $crash CRASH  (+ $wippass/$wipfail wip pass/fail)  → $outfile")
    for (n, s, _) in rows; (s == "PASS" || s == "PASS(wip)") || println("  $s  $n"); end
end

run_and_save()
