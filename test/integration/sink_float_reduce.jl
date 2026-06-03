# test/integration/sink_float_reduce.jl — ports fn sink_float_reduce() in kernel/src/main.rs
# FloatReductionSink: fsum/fmin/fmax/fprod over matched numeric values.
using MORK, Test

@testset "sink_float_reduce" begin
    s = new_space()
    space_add_all_sexpr!(
        s,
        """
(exec (1)
    (, (n \$x))
    (O
        (fmin (min \$c) \$c \$x)
        (fmax (max \$c) \$c \$x)
        (fsum (sum \$c) \$c \$x)
        (fprod (prod \$c) \$c \$x)
    )
)
(exec (2)
    (, (n \$x))
    (O (- (n \$x) ) )
)
(n 5.8)
(n 9.6)
(n 5.4)
(n 61.0)
    """
    )
    steps = space_metta_calculus!(s, 100_000)
    @test steps < 100_000
    result = space_dump_all_sexpr(s)
    @test occursin("(max 61.0)", result)
    @test occursin("(min 5.4)", result)
    @test occursin("(sum 81.8)", result)
    # prod = 5.8 × 9.6 × 5.4 × 61.0 ≈ 18340.992
    @test occursin("(prod ", result) && occursin("18340", result)
    # Source atoms removed by exec 2
    @test !occursin("(n 5.8)", result)
end
