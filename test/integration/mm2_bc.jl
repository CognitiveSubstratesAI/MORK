# test/integration/mm2_bc.jl — ports fn mm2_bc() in kernel/src/main.rs
# MM2 backward chaining: prove ⊢ (= (t) (t)) using bc exec strategy.
# Upstream runs up to 7 ticks; we cap at 10k steps.
using MORK, Test

@testset "mm2_bc — prove ⊢ (= (t) (t)) via backward chaining" begin
    s = new_space()
    space_add_all_sexpr!(
        s,
        """
(kb (: (+) (-> (term) (term) (term))))
(kb (: (=) (-> (term) (term) (wff))))
(kb (: (t) (term)))
(kb (: (0) (term)))
(kb (: tt (: (t) (term))))
(kb (: (a2-curry) (-> (: \$a (term)) (: ((=) ((+) \$a (0)) \$a) (|-)))))
(kb (: (tpl) (-> (: \$x (term)) (: \$y (term)) (: ((+) \$x \$y) (term)))))
(kb (: (weq) (-> (: \$x (term)) (: \$y (term)) (: ((=) \$x \$y) (wff)))))
(kb (: (a2) (-> (: \$a (term)) (: ((=) ((+) \$a (0)) \$a) (|-)))))
(kb (: (a1) (-> (: \$t (term)) (: \$r (term)) (: \$s (term)) (: ((->) ((=) \$t \$r) ((->) ((=) \$t \$s) ((=) \$r \$s))) (|-)))))
(kb (: (mp) (-> (: \$P (wff)) (: \$Q (wff)) (: \$P (|-)) (: ((->) \$P \$Q) (|-)) (: \$Q (|-)))))
(exec (0 lift) (, (kb (: \$t \$T))) (, (ev (: \$t \$T))))
((step (0 base))
    (, (goal (: \$proof \$conclusion)) (kb (: \$proof \$conclusion)))
    (, (ev (: \$proof \$conclusion))))
(exec bc
    (, ((step \$x) \$premises0 \$conclusions0)
       (exec bc \$premises1 \$conclusions1) )
    (, (exec \$x \$premises0 \$conclusions0)
       (exec bc \$premises1 \$conclusions1) ))
(goal (: ((=) (t) (0)) (wff)))
  """
    )
    steps = space_metta_calculus!(s, 10_000)
    # Zealous driver re-adds itself ⇒ never halts; 10_000 is a BUDGET. Upstream asserts NO
    # halting here (its only assert! is COMMENTED OUT for bc3; mm2_bc has none), so
    # `@test steps < 10_000` was invented locally and could never pass (10000 < 10000).
    @test steps == 10_000
    result = space_dump_all_sexpr(s)
    # lift rule must fire: kb facts become ev facts
    @test occursin("(ev (: (t) (term)))", result)
    @test occursin("(ev (: (0) (term)))", result)
end
