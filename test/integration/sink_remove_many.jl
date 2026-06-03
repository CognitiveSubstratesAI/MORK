# test/integration/sink_remove_many.jl — ports fn sink_remove_many() in kernel/src/main.rs
# Remove multiple atom types matching a pattern via O sink.
using MORK, Test

@testset "sink_remove_many — remove multiple patterns via O sink" begin
    s = new_space()
    space_add_all_sexpr!(
        s,
        """
(row 1 2 3)
(col 3 4 5)
(remove (col \$x \$y \$z))
(exec 0 (, (remove \$x) \$x) (O (- \$x)))
    """
    )
    steps = space_metta_calculus!(s, 100_000)
    @test steps < 100_000
    result = space_dump_all_sexpr(s)
    # col should be removed (matched remove pattern), row should remain
    @test occursin("(row 1 2 3)", result)
    @test !occursin("(col 3 4 5)", result)
end
