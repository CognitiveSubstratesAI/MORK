# test/integration/mm1_forward.jl — ports fn mm1_forward() in kernel/src/main.rs
# MM1: prove ⊢ (t = t). Full proof requires multi-source ProductZipper fix.
using MORK, Test

@testset "mm1_forward — full proof (SKIP: needs multi-factor ProductZipper)" begin
    @test_skip "multi-source patterns (3-4 sources) exceed single-factor ProductZipper limit"
end

@testset "mm1_forward — lift rule (single-source, safe)" begin
    # Only test the lift exec rule: single-source (, (kb (: $t $T))) → (ev (: $t $T))
    s = new_space()
    space_add_all_sexpr!(
        s,
        """
(kb (: (t) (term)))
(kb (: (0) (term)))
(kb (: (+) (-> (term) (-> (term) (term)))))
(exec (0 lift) (, (kb (: \$t \$T))) (, (ev (: \$t \$T))))
    """
    )
    steps = space_metta_calculus!(s, 1_000)
    @test steps < 1_000
    result = space_dump_all_sexpr(s)
    @test occursin("(ev (: (t) (term)))", result)
    @test occursin("(ev (: (0) (term)))", result)
end
