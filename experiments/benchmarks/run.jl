# experiments/benchmarks/run.jl
# Time core MORK operations and persist a dated result file under results/ for perf tracing.
#
# Warm REPL (the only sanctioned way):
#   cd ~/code/CognitiveSubstratesAI/MORK
#   printf 'include("experiments/benchmarks/run.jl"); exit()\n' | julia --project=. -i tools/repl.jl

using MORK
using Dates

# min-of-n wall time after a warmup call
function _bench(f; n::Int=5)
    f()
    minimum(@elapsed(f()) for _ in 1:n)
end

function run_and_save()
    sample = join(["(rel s$(i) s$(i + 1))" for i in 1:1000], "\n") * "\n"
    prog = sample * "(exec 0 (, (rel \$a \$b)) (, (out \$a \$b)))\n"

    rows = Tuple{String, Float64}[]
    push!(
        rows,
        ("parse 1k atoms (sexpr_to_expr)",
            _bench(() -> for ln in split(strip(sample), '\n')
                MORK.sexpr_to_expr(ln)
            end))
    )
    push!(
        rows,
        ("add 1k atoms (space_add_all_sexpr!)",
            _bench(() -> (s=new_space(); space_add_all_sexpr!(s, sample))))
    )
    push!(
        rows,
        ("metta_calculus: 1k-rel exec rewrite",
            _bench(
                () -> (
                    s=new_space();
                    space_add_all_sexpr!(s, prog);
                    space_metta_calculus!(s, 100_000)
                )
            ))
    )

    date = string(Dates.today())
    outdir = joinpath(@__DIR__, "results")
    mkpath(outdir)
    outfile = joinpath(outdir, "$(date)_bench.md")
    open(outfile, "w") do f
        println(f, "# MORK benchmarks — $date")
        println(f, "")
        println(f, "min-of-5 wall time, warm process (`tools/repl.jl`).")
        println(f, "")
        println(f, "| workload | min time |")
        println(f, "|---|---|")
        for (name, t) in rows
            println(f, "| $name | $(round(t * 1000; digits = 2)) ms |")
        end
    end
    println("BENCH_RESULT saved → $outfile")
    for (name, t) in rows
        println("  $(rpad(name, 40)) $(round(t * 1000; digits = 2)) ms")
    end
end

run_and_save()
