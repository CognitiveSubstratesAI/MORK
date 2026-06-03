# test/integration/roman_disjoin_initial.jl — ports fn roman_disjoin_initial() in kernel/src/main.rs
# Set intersection via 4-source pattern + O remove sink.
using MORK, Test

@testset "roman_disjoin_initial — set intersections via 4-source match" begin
    s = new_space()
    space_add_all_sexpr!(
        s,
        """
(set 1 a) (set 1 b) (set 1 c)
(set 2 d) (set 2 e) (set 2 f)
(set 3 a) (set 3 b)
(neq 1 2) (neq 1 3) (neq 2 3)
(neq Nil a) (neq a Nil)
(neq Nil b) (neq b Nil)
(neq Nil c) (neq c Nil)
(neq Nil d) (neq d Nil)
(neq Nil e) (neq e Nil)
(neq Nil f) (neq f Nil)
(mcmp \$e \$e \$e)
(mcmp \$e \$f Nil)
(exec 0
    (, (set \$a \$ae) (set \$b \$be) (neq \$a \$b) (mcmp \$ae \$be \$e))
    (, (intersection \$a \$b \$e) ) )
(exec 2
    (, (intersection \$a \$b Nil) (neq Nil \$e2) (intersection \$a \$b \$e2)  )
    (O (- (intersection \$a \$b Nil) ) ) )
    """
    )
    steps = space_metta_calculus!(s, 100_000)
    @test steps < 100_000
    result = space_dump_all_sexpr(s)
    # Upstream asserts these four intersection atoms (mirrors assert in main.rs):
    @test occursin("(intersection 1 2 Nil)", result)
    @test occursin("(intersection 1 3 a)", result)
    @test occursin("(intersection 1 3 b)", result)
    @test occursin("(intersection 2 3 Nil)", result)
end
