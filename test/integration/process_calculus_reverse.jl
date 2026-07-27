# test/integration/process_calculus_reverse.jl — ports fn process_calculus_reverse() in kernel/src/main.rs
# Petri net process calculus: compute 2+2=4 via π-calculus encoding.
# Uses IC (interleaving counter) with 10 steps of Peano arithmetic.
using MORK, Test

@testset "process_calculus_reverse — petri net 2+2=4" begin
    s = new_space()
    space_add_all_sexpr!(
        s,
        """
(exec (IC 0 1 (S (S (S (S (S (S (S (S (S (S Z)))))))))))
             (, (exec (IC \$x \$y (S \$c)) \$sp \$st) ((exec \$x) \$p \$t))
             (, (exec (IC \$y \$x \$c) \$sp \$st) (exec (R \$x) \$p \$t)))
((exec 0)
      (, (petri (! \$channel \$payload)) (petri (? \$channel \$payload \$body)))
      (, (petri \$body)))
((exec 1)
      (, (petri (| \$lprocess \$rprocess)))
      (, (petri \$lprocess) (petri \$rprocess)))
(petri (? (add \$ret) ((S \$x) \$y) (| (! (add (PN \$x \$y)) (\$x \$y))
                                    (? (PN \$x \$y) \$z (! \$ret (S \$z))))))
(petri (? (add \$ret) (Z \$y) (! \$ret \$y)))
(petri (! (add result) ((S (S Z)) (S (S Z)))))
    """
    )
    steps = space_metta_calculus!(s, 100_000)
    # must be < the CAP passed above: a run that hits the cap did not halt.
    # (was `< 1_000_000_000` against a 100_000 cap — vacuous, could never fail.)
    @test steps < 100_000
    result = space_dump_all_sexpr(s)
    # 2+2=4: result should contain (S (S (S (S Z)))) i.e. Peano 4
    @test occursin("(S (S (S (S Z))))", result)
end
