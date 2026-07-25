# bfc_occurs_check.jl — regression for the coreferential-join OCCURS-CHECK gap (fix 2026-07-25).
#
# Nil Geisweiller's backward-via-forward chaining (BFC) proof search, ported from upstream
# `fn bfc(size)` (MORK/kernel/src/main.rs). Size 13 ("jarr") is the smallest that exercises the bug.
#
# THE BUG: our unify's occurs check was DEREF-UNAWARE — it short-circuited on `xvar[1] != e.n`
# (different var namespace ⇒ assume no occurrence) WITHOUT dereferencing bound intermediate vars.
# Upstream's occurs macro has the same short-circuit but its `match2`-based pair generation binds
# in an ORDER where the offending var is caught in its own namespace; OUR recursive child-pairing
# binds in a different order, so the order-dependent check MISSED cross-namespace cycles. The BFC
# `exec(3 3)` (discharge axiom 3) firing exploited exactly this: it accepted a binding of a data
# var to a term containing itself, producing a spurious proof (an extra `(final …)`) that upstream
# rejects (verified: upstream returns `Occurs((0,1),…)` at the identical firing). The fix made the
# occurs check deref-aware (order-independent, standard correct occurs).
#
# GOLDEN (freshly-rebuilt upstream `mork run` on the identical program): size 13 → 393 steps,
# 9938 dumped atoms, exactly 2 `(final …)` proofs. Pre-fix ours produced 3 finals / 10975 atoms.
# Requires _USE_COREF_JOIN=true (the source-join path; the default ProductZipper wedges on BFC).
using MORK, Test

const _BFC_FIXTURE = joinpath(@__DIR__, "..", "fixtures", "mm2", "bfc_axioms_exec.mm2")

function _bfc13_program()
    off1 = join(("(dec $x $(x-1))\n(inc $(x-1) $x)\n" for x in 1:26))
    cmp  = join(("(lte $y $x)\n(gte $x $y)\n" for x in 0:26 for y in 0:x))
    "(target 13 (C (> (> (> p s) x) (> s x)) \$x))\n" * off1 * cmp * read(_BFC_FIXTURE, String)
end

@testset "BFC size-13 occurs-check regression (coref join, fix 2026-07-25)" begin
    prev = MORK._USE_COREF_JOIN[]
    MORK._USE_COREF_JOIN[] = true
    try
        s = MORK.new_space()
        MORK.space_add_all_sexpr!(s, _bfc13_program())
        steps = MORK.space_metta_calculus!(s, 5_000_000)
        atoms = [strip(l) for l in split(MORK.space_dump_all_sexpr(s), '\n') if !isempty(strip(l))]
        data = filter(l -> !startswith(l, "(exec"), atoms)
        finals = filter(l -> startswith(l, "(final "), data)

        @test steps == 393                 # exact vs freshly-rebuilt upstream binary
        @test length(data) == 9938          # pre-fix over-generated to 10975
        @test length(finals) == 2           # pre-fix produced a spurious 3rd (occurs-violating) proof
        # The two upstream-confirmed proofs of the "jarr" theorem (exact dump rendering).
        # `length(finals) == 2` above is the load-bearing guard: pre-fix a spurious 3rd
        # (occurs-violating) proof appeared. These pin WHICH two survive.
        want1 = "(final 0 0 (C (> (> (> p s) x) (> s x)) (1 (1 (1 (M (2 (2 (M (M (1 (M (2 (M (M I)))))))))))))))"
        want2 = "(final 0 0 (C (> (> (> p s) x) (> s x)) (1 (1 (M (1 (2 (1 (M (2 (M (M (2 (M (M I)))))))))))))))"
        @test want1 in finals
        @test want2 in finals
    finally
        MORK._USE_COREF_JOIN[] = prev
    end
end
