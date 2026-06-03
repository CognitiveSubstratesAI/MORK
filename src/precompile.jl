# precompile.jl — PrecompileTools workload for MORK
#
# Covers the hot paths exercised by typical MORK usage.
# Julia executes this block during `Pkg.precompile()` and caches the
# compiled method instances, eliminating JIT latency on first use.

using PrecompileTools

@compile_workload begin
    # ── Space creation and population ─────────────────────────────────
    s = new_space()
    space_add_all_sexpr!(s, "(isa dog animal)\n(isa cat animal)\n(isa frog amphibian)")
    space_val_count(s)
    space_dump_all_sexpr(s)

    # ── Calculus: simple rule ─────────────────────────────────────────
    s2 = new_space()
    space_add_all_sexpr!(
        s2,
        """
    (fact a)
    (fact b)
    (exec 0 (, (fact \$x)) (O (processed \$x)))
    (exec 1 (, (fact \$x)) (O (- (fact \$x))))
"""
    )
    space_metta_calculus!(s2, 1_000)
    space_dump_all_sexpr(s2)

    # ── Calculus: two-source match ────────────────────────────────────
    s3 = new_space()
    space_add_all_sexpr!(s3, "(A foo)\n(B foo)\n(exec 0 (, (A \$x) (B \$x)) (O (C \$x)))")
    space_metta_calculus!(s3, 1_000)

    # ── Calculus: float reduction sinks ──────────────────────────────
    s4 = new_space()
    space_add_all_sexpr!(
        s4,
        """
    (n 1.0)
    (n 2.0)
    (n 3.0)
    (exec 0
        (, (n \$x))
        (O
            (fsum  (total \$c) \$c \$x)
            (fmax  (peak  \$c) \$c \$x)
        )
    )
    (exec 1 (, (n \$x)) (O (- (n \$x))))
"""
    )
    space_metta_calculus!(s4, 10_000)

    # ── Expression conversion ─────────────────────────────────────────
    e = sexpr_to_expr("(isa alice human)")
    expr_serialize(e.buf)
end
