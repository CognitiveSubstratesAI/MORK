# test/integration/run_all.jl — runs all integration tests
# Mirrors the fn main() call sequence in kernel/src/main.rs.
# Each file corresponds to one upstream test function.
#
# Usage (from warm REPL):
#   include("test/integration/run_all.jl")

const INTEGRATION_DIR = @__DIR__

pass = 0;
fail = 0;
err = 0
for f in sort(readdir(INTEGRATION_DIR))
    f == "run_all.jl" && continue
    endswith(f, ".jl") || continue
    t0 = time()
    try
        include(joinpath(INTEGRATION_DIR, f))
        println("PASS  $f  ($(round(time()-t0,digits=1))s)")
        global pass += 1
    catch e
        if e isa Test.TestSetException
            println("FAIL  $f  ($(round(time()-t0,digits=1))s)")
            global fail += 1
        else
            println("ERROR $f: $(typeof(e)): $(sprint(showerror, e))")
            global err += 1
        end
    end
end
println("\n=== Integration tests: $pass passed  $fail failed  $err errors ===")
