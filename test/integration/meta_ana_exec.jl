# meta_ana_exec.jl — port of meta_ana_exec from kernel/src/main.rs
using MORK, Test

@testset "meta_ana_exec (coalgebra tree traversal via exec)" begin
    s = new_space()

    # Use a 2-leaf tree so the test is fast and avoids depth limitations
    space_add_all_sexpr!(s, "(tree-example (branch (leaf 1) (leaf 2)))")

    space_add_all_sexpr!(
        s,
        """
T
(tree-to-space (ctx (branch \$left \$right) \$path) (ctx \$left  (cons \$path L)))
(tree-to-space (ctx (branch \$left \$right) \$path) (ctx \$right (cons \$path R)))
(ana (tree-example \$tree) (ctx \$tree nil) \$p (tree-to-space \$p \$t) \$t (ctx (leaf \$value) \$path) (space-example (value \$path \$value)))
(exec 0
  (, (ana \$cx \$x \$p \$cpt \$t \$y \$cy) \$cx \$cpt)
  (, (exec 0 (, (lookup \$x \$px \$tx)) (, (exec (0 \$x) \$px \$tx)))
     (lookup \$p (, (lookup \$t \$px \$tx)) (, (exec (0 \$t) \$px \$tx)))
     (lookup \$y (, T) (, \$cy))))
"""
    )

    space_metta_calculus!(s)

    res = space_dump_all_sexpr(s)
    @test contains(res, "(space-example (value (cons nil L) 1))")
    @test contains(res, "(space-example (value (cons nil R) 2))")
end
