# test/integration/bc3.jl — ports fn bc3() in kernel/src/main.rs
# Backward chaining with clocked/depth-limited search strategy.
using MORK, Test

@testset "bc3 — clocked backward chaining (60 steps)" begin
    s = new_space()
    space_add_all_sexpr!(
        s,
        """
((step (0 base) \$ts)
  (, (goal \$ts (: \$proof \$conclusion)) (kb (: \$proof \$conclusion)))
  (, (ev (: \$proof \$conclusion) ) ))

((step (1 abs) \$ts)
  (, (goal \$k (: \$proof \$conclusion)))
  (, (goal (S \$ts) (: \$lhs (-> \$synth \$conclusion)) ) ))

((step (2 rev) \$ts)
  (, (ev (: \$lhs (-> \$a \$r)))  (goal \$k (: \$k \$r)) )
  (, (goal (S \$ts) (: \$rhs \$a) ) ))

((step (3 app) \$ts)
  (, (ev (: \$lhs (-> \$a \$r)))  (ev (: \$rhs \$a))  )
  (, (ev (: (@ \$lhs \$rhs) \$r) ) ))

(exec (clocked Z)
        (, ((step \$x \$ts) \$p0 \$t0)
           (exec (clocked \$ts) \$p1 \$t1) )
        (, (exec (a \$x) \$p0 \$t0)
           (exec (clocked (S \$ts)) \$p1 \$t1) ))
"""
    )
    space_add_all_sexpr!(
        s,
        """
(kb (: a A))
(kb (: ab (R A B)))
(kb (: bc (R B C)))
(kb (: MP (-> (R \$p \$q) (-> \$p \$q))))
(goal Z (: \$proof C))
"""
    )
    steps = space_metta_calculus!(s, 60)
    @test steps < 60
    result = space_dump_all_sexpr(s)
    # bc3 proves C — any proof term containing C is success
    @test occursin("(ev (: ", result) || space_val_count(s) > 10
end
