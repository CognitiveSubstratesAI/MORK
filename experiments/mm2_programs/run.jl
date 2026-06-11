# experiments/mm2_programs/run.jl
# Smoke/robustness test: run each MM2_Structuring_Code program through the Julia port, record
# crash / terminate / cap-hit + output size, and persist a dated result. The step cap bounds
# intentional loops (e.g. Control_07_Recursive is a self-replicating exec).
#
# Warm REPL:
#   cd ~/code/CognitiveSubstratesAI/MORK
#   printf 'include("experiments/mm2_programs/run.jl"); exit()\n' | julia --project=. -i tools/repl.jl

using MORK
using Dates

const PROGDIR = joinpath(@__DIR__, "programs")
const CAP = 10_000

function run_and_save()
    files = sort(filter(f -> endswith(f, ".mm2"), readdir(PROGDIR)))
    rows = Tuple{String,String,Int,Any}[]
    ok = capped = crash = 0
    for fn in files
        print(stderr, "  · ", rpad(fn, 46)); flush(stderr)
        src = read(joinpath(PROGDIR, fn), String)
        try
            s = new_space()
            space_add_all_sexpr!(s, src)
            steps = space_metta_calculus!(s, CAP)
            dump = space_dump_all_sexpr(s)
            nlines = count(==('\n'), dump)
            if steps >= CAP
                capped += 1; println(stderr, "CAP ($steps)")
                push!(rows, (fn, "CAP", steps, nlines))
            else
                ok += 1; println(stderr, "OK ($steps steps, $nlines lines)")
                push!(rows, (fn, "OK", steps, nlines))
            end
        catch e
            crash += 1; msg = first(split(sprint(showerror, e), '\n'))
            println(stderr, "CRASH")
            push!(rows, (fn, "CRASH", 0, msg))
        end
    end
    date = string(Dates.today())
    outdir = joinpath(@__DIR__, "results"); mkpath(outdir)
    outfile = joinpath(outdir, "$(date)_mm2_smoke.md")
    open(outfile, "w") do f
        println(f, "# MM2_Structuring_Code smoke test — $date\n")
        println(f, "Each program run through the port (step cap $CAP). **CAP** = hit the cap",
            " (intentional loops, e.g. `Control_07_Recursive`); **CRASH** = a port error (real gap).\n")
        println(f, "**$ok OK · $capped CAP · $crash CRASH** of $(length(files))\n")
        println(f, "| program | status | detail |")
        println(f, "|---|---|---|")
        for (fn, st, steps, detail) in rows
            d = st == "CRASH" ? "`$detail`" : "$steps steps, $detail out-lines"
            println(f, "| `$fn` | $st | $d |")
        end
    end
    println("MM2_SMOKE: $ok OK  $capped CAP  $crash CRASH  → $outfile")
    for (fn, st, _, d) in rows; st == "CRASH" && println("  CRASH  $fn : $d"); end
end

run_and_save()
