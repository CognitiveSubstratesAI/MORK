# coref_pattern_specificity.jl — port of func_type_unification() from
# upstream kernel/src/main.rs (commit e551924).
#
# Tests "decreasing pattern specificity": a pattern in a constant position
# can match a free (NewVar) data variable after the coreferential-transition
# sentinel fix.
using MORK, Test

@testset "coref: decreasing pattern specificity (upstream e551924)" begin

    # Mirrors func_type_unification() in kernel/src/main.rs.
    # Pattern ($f) must match data ($a) where $a is a free NewVar in the trie.
    @testset "func_type_unification" begin
        s = new_space()
        space_add_all_sexpr!(
            s,
            """
(a (: \$a A))
(b (: f (-> A)))
(exec 0 (, (a (: (\$f) A))
           (b (: \$f (-> A))))
        (, (c OK)))
"""
        )
        steps = space_metta_calculus!(s, 10_000)  # bounded: 1 exec fires
        io = IOBuffer()
        space_dump_all_sexpr(s, io)
        res = String(take!(io))
        @test steps >= 1
        @test contains(res, "(c OK)")
    end

end
