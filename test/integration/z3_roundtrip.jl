# test/integration/z3_roundtrip.jl — real Z3Sink + Z3Source round-trip (CeTTa borrow; port of Rust Z3Source/Z3Sink,
# space.rs:1051-1078). The sink streams SMT-LIB assertions to a named z3 subprocess; the source sends
# (check-sat)+(get-model) and injects the solved model back into the space so a downstream exec can consume it.
# GUARDED on z3_available() — z3 is an OPTIONAL external dep, so this skips cleanly wherever z3 isn't installed.
using MORK, Test

@testset "z3 sink/source round-trip (SMT-guarded rewrite)" begin
    if !z3_available()
        @info "z3 binary not on PATH — skipping Z3 integration test (optional external dep)"
        @test_skip true
    else
        z3_reset!()
        s = new_space()
        # declares (priority 0) → asserts (priority 1) → read model (priority 2); priority ordering guarantees
        # z3 sees (declare-const a Int) before the (assert …)s (else z3 errors "unknown constant a").
        space_add_all_sexpr!(s, """
(decl (declare-const a Int))
(asrt (assert (> a 5)))
(asrt (assert (< a 8)))
(exec 0 (, (decl \$d)) (O (z3 rt \$d)))
(exec 1 (, (asrt \$a)) (O (z3 rt \$a)))
(exec 2 (I (z3 rt \$m)) (, (result \$m)))
""")
        space_metta_calculus!(s, 200)
        out = space_dump_all_sexpr(s)
        z3_reset!()
        # z3 solves 5 < a < 8 ⇒ a = 6; the source injects the model, the exec emits (result (define-fun a () Int 6))
        @test occursin("result", out)
        @test occursin("(define-fun a () Int", out)
    end
end
