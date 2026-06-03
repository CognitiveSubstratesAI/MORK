# test/integration/sink_add_remove_var.jl — ports fn sink_add_remove_var() in kernel/src/main.rs
# O sink with variable substitution: remove (foo $x) add (bar $x).
using MORK, Test

@testset "sink_add_remove_var — O sink with variable substitution" begin
    s = new_space()
    space_add_all_sexpr!(
        s,
        """
(foo a)
(exec 0
  (, (foo \$x))
  (O (- (foo \$x))
     (+ (bar \$x))))
    """
    )
    steps = space_metta_calculus!(s, 100_000)
    @test steps < 100_000
    result = space_dump_all_sexpr(s)
    @test !occursin("(foo a)", result)
    @test occursin("(bar a)", result)
end
