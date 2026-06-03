# test/integration/sink_two_bipolar_equal_crossed.jl — ports fn sink_two_bipolar_equal_crossed()
# Two-source match via comma, result added via O+(+) sink.
using MORK, Test

@testset "sink_two_bipolar_equal_crossed — O+ sink with two-source match" begin
    s = new_space()
    space_add_all_sexpr!(
        s,
        """
(exec 0 (, (Something \$x \$y) (Else \$x \$y)) (O (+ (MATCHED \$x \$y))))
(Something (foo \$x) (foo \$x))
(Else (\$x bar) (\$x bar))
    """
    )
    steps = space_metta_calculus!(s, 100_000)
    @test steps < 100_000
    result = space_dump_all_sexpr(s)
    @test occursin("(MATCHED (foo bar) (foo bar))", result)
end
