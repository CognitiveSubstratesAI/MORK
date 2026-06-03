# test/integration/basic.jl — ports fn basic() in kernel/src/main.rs
# Transitive closure: Straight edges → Transitive → Line atoms.
using MORK, Test

@testset "basic — transitive closure (100 steps)" begin
    s = new_space()
    space_add_all_sexpr!(
        s,
        """
(Straight 1 2)
(Straight 2 3)
(exec P1 (, (Straight \$x \$y) (Straight \$y \$z)) (, (Transitive \$x \$z)))
    """
    )
    steps = space_metta_calculus!(s, 100)
    @test steps < 100
    result = space_dump_all_sexpr(s)
    @test occursin("(Transitive 1 3)", result)
end
