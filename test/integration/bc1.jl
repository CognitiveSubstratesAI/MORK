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
    # `(exec zealous …)` RE-ADDS ITSELF, so this program NEVER halts by design — 100 is a BUDGET,
    # not a halting expectation. Upstream (main.rs:3597 `fn bc1`) asserts NO halting: it runs
    # metta_calculus(100), prints the count, and asserts the proof atom below.
    # The old `@test steps < 100` was invented locally and could NEVER pass (it evaluated 100 < 100).
    steps = space_metta_calculus!(s, 100)
    @test steps == 100                      # consumed the whole budget — non-halting driver
    result = space_dump_all_sexpr(s)
    # UPSTREAM'S ACTUAL ASSERTION (main.rs:3642) — the full proof of D by modus-ponens chaining.
    # Far stronger than the previous `occursin("(ev (: ")` + "C))"/"D))" substring disjunction.
    @test occursin("(ev (: (@ (@ MP cd) (@ (@ MP bc) (@ (@ MP ab) a))) D))", result)
end
