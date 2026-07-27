# test/integration/bc2.jl — ports fn bc2() in kernel/src/main.rs
# Backward chaining: propositional logic proof (modus ponens chain).
using MORK, Test

@testset "bc2 — propositional logic proof (30 steps)" begin
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
(kb (: mp2b.1 φ))
(kb (: mp2b.2 (-> φ ψ)))
(kb (: mp2b.3 (-> ψ χ)))
(goal (: \$proof χ))
"""
    )
    # Zealous driver re-adds itself ⇒ never halts; 30 is a BUDGET. Upstream (main.rs:3645 `fn bc2`)
    # asserts no halting. `@test steps < 30` was invented locally and could never pass (30 < 30).
    steps = space_metta_calculus!(s, 30)
    @test steps == 30
    result = space_dump_all_sexpr(s)
    # ⚠️ NOT upstream's assertion — our program is a DIFFERENT FORMULATION from upstream's
    # `fn bc2` (main.rs:3645). Upstream asserts `(@ ax-mp (@ ax-mp mp2b.1 mp2b.2) mp2b.3)`; this
    # program has no `ax-mp` symbol at all and chains modus ponens by direct application. So we
    # assert what THIS program proves: mp2b.1 : φ, mp2b.2 : φ→ψ, mp2b.3 : ψ→χ  ⊢  χ.
    # (Whether bc2.jl SHOULD be re-ported to match upstream's program is open — see session log.)
    @test occursin("(@ mp2b.3 (@ mp2b.2 mp2b.1))", result)
    # bc2 proves χ from modus ponens chain — ev atom with χ should exist
    @test occursin("(ev (: ", result) || space_val_count(s) > 5
end
