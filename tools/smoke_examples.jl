#!/usr/bin/env julia
# tools/smoke_examples.jl — smoke test all examples/
#
# Run from warm REPL:  include("tools/smoke_examples.jl")
# Run from CLI:        julia --project=. tools/smoke_examples.jl

try
    ; using Revise;
catch
    ;
end
using MORK

println("=== examples/ smoke test ===\n");
flush(stdout)

base = dirname(dirname(@__FILE__))  # packages/MORK/
examples = [
    "transitive_closure",
    "aggregation",
    "backward_chaining",
    "hexlife",
    "reachability",
    "ctl_model_checking",
    "counter_machine"
]

n_pass = 0;
n_fail = 0
for name in examples
    path = joinpath(base, "examples", "$name.jl")
    print("[$name] ... ");
    flush(stdout)
    try
        elapsed = @elapsed include(path)
        println("OK ($(round(elapsed, digits=1))s)");
        flush(stdout)
        global n_pass += 1
    catch e
        println("FAIL: $e");
        flush(stdout)
        global n_fail += 1
    end
    println();
    flush(stdout)
end

println("="^50)
println("Results: $n_pass passed, $n_fail failed out of $(n_pass+n_fail) examples")
flush(stdout)
