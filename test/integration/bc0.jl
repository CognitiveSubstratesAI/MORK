# test/integration/bc0.jl — ports fn bc0() in kernel/src/main.rs
# Backward chaining: prove C from KB using step/zealous exec strategy.
# Upstream uses 50 steps; we use 10k to account for step-counting differences.
using MORK, Test

@testset "bc0 — backward chaining proof of C" begin
    s = new_space()
    space_add_all_sexpr!(
        s,
        """
((step base)
  (, (goal (: \$proof \$conclusion)) (kb (: \$proof \$conclusion)))
  (, (ev (: \$proof \$conclusion) ) ))

((step abs)
  (, (goal (: \$proof \$conclusion)))
  (, (goal (: \$lhs (-> \$synth \$conclusion)) ) ))

((step rev)
  (, (ev (: \$lhs (-> \$a \$r)))  (goal (: \$k \$r)) )
  (, (goal (: \$rhs \$a) ) ))

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
(kb (: MP (-> (R \$p \$q) (-> \$p \$q))))
(goal (: \$proof C))
"""
    )
    # ⚠️ THIS TEST USED TO HANG THE ENTIRE SUITE. Cause was the BUDGET, not the engine.
    # `(step abs)` is divergent by construction — every goal spawns a strictly LARGER goal
    # ((-> $synth $conclusion), then (-> $s2 (-> $synth $conclusion)), …) — and `(exec zealous …)`
    # re-adds itself, so the program never halts and term size grows without bound. The old budget
    # of 10_000 (raised from upstream's 50 with the note "to account for step-counting differences")
    # therefore asked for 10_000 steps of exponential term growth: it ran >4 min at 100% CPU and
    # silently swallowed THREE whole-suite sweeps before being isolated.
    # Upstream (main.rs:3546 `fn bc0`) uses 50 and asserts the proof atom below.
    steps = space_metta_calculus!(s, 50)
    @test steps == 50                       # consumed the whole budget — non-halting by design
    result = space_dump_all_sexpr(s)
    # UPSTREAM'S ACTUAL ASSERTION (main.rs:3594) — the ground proof term for C.
    @test occursin("(ev (: (@ (@ MP bc) (@ (@ MP ab) a)) C))", result)
end
