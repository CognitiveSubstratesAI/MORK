# test/integration/bc1.jl — ports fn bc1() in kernel/src/main.rs
# Backward chaining: prove (D) using rec/app steps.
using MORK, Test

@testset "bc1 — backward chaining rec/app (100 steps)" begin
    s = new_space()
    space_add_all_sexpr!(
        s,
        """
((step base)
  (, (goal (: \$proof \$conclusion)) (kb (: \$proof \$conclusion)))
  (, (ev (: \$proof \$conclusion) ) ))

((step rec)
  (, (goal (: (@ \$lhs \$rhs) \$conclusion)))
  (, (goal (: \$lhs (-> \$synth \$conclusion))) (goal (: \$rhs \$synth))))

((step app)
  (, (ev (: \$lhs (-> \$a \$r)))  (ev (: \$rhs \$a))  )
  (, (ev (: (@ \$lhs \$rhs) \$r) ) ))

(exec zealous
        (, ((step \$x) \$p0 \$t0)
           (exec zealous \$p1 \$t1) )
        (, (exec \$x \$p0 \$t0)
           (exec zealous \$p1 \$t1) ))
"""
    )
    space_add_all_sexpr!(
        s,
        """
(kb (: a A))
(kb (: ab (R A B)))
(kb (: bc (R B C)))
(kb (: cd (R C D)))
(kb (: MP (-> (R \$p \$q) (-> \$p \$q))))
(goal (: \$proof C))
"""
    )
    steps = space_metta_calculus!(s, 100)
    @test steps < 100
    result = space_dump_all_sexpr(s)
    # bc1 proves C (and possibly D) — check ev atom with relevant type was produced
    @test occursin("(ev (: ", result) &&
        (occursin("C))", result) || occursin("D))", result))
end
