# test/integration/sink_add_remove.jl — ports fn sink_add_remove() in kernel/src/main.rs
# O sink: remove A and add B in one exec step.
using MORK, Test

@testset "sink_add_remove — O sink removes A adds B" begin
    s = new_space()
    space_add_all_sexpr!(s, "A\n(exec a (, A) (O (- A) (+ B)))\n")
    steps = space_metta_calculus!(s, 100_000)
    @test steps < 100_000
    result = space_dump_all_sexpr(s)
    @test !occursin("A\n", result)
    @test occursin("B\n", result)
end
