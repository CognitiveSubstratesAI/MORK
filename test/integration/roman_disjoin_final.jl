# test/integration/roman_disjoin_final.jl — ports fn roman_disjoin_final() in kernel/src/main.rs
# Set disjointness: remove (disjoint a b) when sets share an element.
using MORK, Test

@testset "roman_disjoin_final — set disjointness (10M steps)" begin
    s = new_space()
    space_add_all_sexpr!(
        s,
        """
(set 1 a) (set 1 b) (set 1 c)
(set 2 d) (set 2 e) (set 2 f)
(set 3 a) (set 3 b)
(lt 1 2) (lt 1 3) (lt 2 3)
(exec 0 (, (set \$a \$ea)) (, (elementOf \$ea \$a)))
(exec 0 (, (set \$a \$ea)) (, (sets \$a)))
(exec 0 (, (lt \$a \$b)) (, (disjoint \$a \$b)))
(exec 0 (, (elementOf \$ea \$a) (elementOf \$ea \$b)) (O (- (disjoint \$a \$b))))
    """
    )
    steps = space_metta_calculus!(s, 100_000)
    # must be < the CAP passed above: a run that hits the cap did not halt.
    # (was `< 10_000_000` against a 100_000 cap — vacuous, could never fail.)
    @test steps < 100_000
    result = space_dump_all_sexpr(s)
    @test occursin("(disjoint 1 2)", result)
    @test occursin("(disjoint 2 3)", result)
    @test !occursin("(disjoint 1 3)", result)
end
