# test/integration/stv_roman.jl — ports fn stv_roman() in kernel/src/main.rs
# STV (Simple Truth Value) computation via metta_calculus + fun facts.
using MORK, Test

@testset "stv_roman — STV multiplication via metta_calculus" begin
    s = new_space()
    space_add_all_sexpr!(
        s,
        """
(exec (step (0 cpu))
  (, (goal (CPU \$f \$arg \$res)) (fun (\$f \$arg (\$b1 \$b2) \$res)) (fun \$b1) (fun \$b2))
  (, (ev \$res)))

(fun (mp-formula ((STV \$sa \$ca) (STV \$sb \$cb)) ((mul (\$sa \$sb) \$so) (mul (\$ca \$cb) \$co)) (STV \$so \$co)))

(goal (CPU mp-formula ((STV 0.5 0.5) (STV 0.5 0.5)) \$res))
"""
    )
    space_add_all_sexpr!(s, "(fun (mul (0.5 0.5) 0.2))\n")
    steps = space_metta_calculus!(s, 10)
    @test steps < 10
    result = space_dump_all_sexpr(s)
    @test occursin("ev", result)   # upstream just prints — no hard assertion
end
