# unit_unify_cycle_safe.jl — `expr_unify_cycle_safe` and `expr_deref`, the two entry points seam 1
# needs (docs/specs/term_model_boundary.md).
#
# WHY THEY EXIST. `expr_unify_method` answers "do these unify?" and THROWS THE BINDINGS AWAY, so a
# consumer that needs them either re-ran the solve or reached for `expr_unify` — which upstream
# states "does not do full occurs check". The two differ by a SAFETY property, and the weaker one has
# the shorter name and is the one appearing in surrounding code, which is precisely how it gets
# picked by mistake. MEASURED cost (USink, 2026-08-03): fixing only the variable scoping gained 3
# conformance probes and REGRESSED `g7_u_occurs`.
#
# ⚠️ THE OCCURS CASE WAS MEANT TO *PROVE* THE ENTRY POINT WAS CHOSEN CORRECTLY, BY SHOWING THE TWO
# DIVERGE. It does not, and that is recorded here rather than quietly dropped: swept 120 pattern/data
# pairs and found ZERO where raw `expr_unify` accepts and the cycle-safe entry rejects, because our
# in-solve `_occurs_check` is deref-aware and already subsumes upstream's post-apply one. So the
# justification for this entry point is DEFENCE IN DEPTH and upstream fidelity, not a demonstrated
# behavioural gap — and the tests below assert the SUBSUMPTION, which turns red if it ever stops
# holding. [[feedback_unexplained_behaviour_is_not_a_contract]]

using MORK, Test
const M = MORK

@testset "expr_unify_cycle_safe + expr_deref" begin
    _f = M.expr_parse_str

    @testset "agrees with expr_unify_method on the yes/no verdict" begin
        # same solve underneath, so any disagreement here is a refactor bug, not a semantic one
        for (xs, ys) in [(raw"[2] f $", raw"[2] f a"), (raw"[2] $ $", raw"[2] a b"),
                         (raw"[2] f a", raw"[2] f b"), (raw"[2] f a", raw"[3] f a b")]
            meth = M.expr_unify_method(_f(xs), _f(ys), M.ExprZipper(M.Expr(zeros(UInt8, 128)), 1))
            safe = M.expr_unify_cycle_safe(_f(xs), _f(ys))
            @test (meth === nothing) == !(safe isa M.UnificationFailure)
        end
    end

    @testset "it RETURNS the bindings — which is the entire point" begin
        r = M.expr_unify_cycle_safe(_f(raw"[3] f $ $"), _f(raw"[3] f a b"))
        @test r isa M.Bindings
        @test length(r) == 2
        # pattern variables are source 0, data source 1 — asserted, because a caller that built both
        # at base 0 would make $x and $y the SAME variable (USink's masked first defect)
        @test all(k -> k[1] == 0x00, keys(r))
    end

    @testset "🔴 OCCURS IS REJECTED — and an honest note about WHERE the check fires" begin
        # `[3] f $ _1` vs `[3] f $ [2] g _1`: a pattern variable shared across both arguments meets a
        # data term built over a data variable. Cyclic; must be rejected.
        x, y = _f(raw"[3] f $ _1"), _f(raw"[3] f $ [2] g _1")
        safe = M.expr_unify_cycle_safe(x, y)
        @test safe isa M.UnificationFailure
        @test M.expr_unifiable(x, y) == false
        # CONTROL, so the assertion above is not just "everything fails": a near-identical
        # NON-cyclic shape must be ACCEPTED.
        @test M.expr_unify_cycle_safe(_f(raw"[3] f $ _1"), _f(raw"[3] f a a")) isa M.Bindings

        # ⚠️ WHAT THIS TESTSET DELIBERATELY DOES *NOT* CLAIM, because it was MEASURED and is FALSE
        # for our port. The expected demonstration was "raw `expr_unify` accepts where the cycle-safe
        # entry rejects" — upstream's reason for keeping the method beside the function. SWEPT 120
        # pattern/data pairs (10 patterns x 12 data shapes): 67 rejected by BOTH, and **ZERO** where
        # raw accepts and cycle-safe rejects. Our in-solve `_occurs_check` is DEREF-AWARE (the
        # 2026-07-25 ADR-057 fix, deliberately stronger than upstream's order-dependent macro), so on
        # this family it SUBSUMES the post-apply check.
        #
        # 🔴 THAT IS NOT A REASON TO USE `expr_unify`. It means the post-apply check is currently a
        # REDUNDANT SAFETY NET rather than the only guard — and a net whose value shows up exactly
        # when the thing it backs up regresses. If anyone "simplifies" `_occurs_check` back toward
        # upstream's order-dependent form, this entry point still rejects the cycle. Keeping the
        # weaker function because the stronger one is currently redundant is how USink lost
        # `g7_u_occurs` (CODEMAP row 197).
        # [[feedback_unexplained_behaviour_is_not_a_contract]]
        for (xs, ys) in [(raw"$", raw"[2] f $"), (raw"[2] $ $", raw"[2] $ [2] f _1"),
                         (raw"[2] $ _1", raw"[2] [2] f $ $"), (raw"[2] f $", raw"[2] f a")]
            a, b = _f(xs), _f(ys)
            rawok = M.expr_unify([(M.ExprEnv(0, a), M.ExprEnv(1, b))]) isa M.Bindings
            safeok = M.expr_unify_cycle_safe(a, b) isa M.Bindings
            @test rawok == safeok      # pins the SUBSUMPTION; a future divergence turns this RED
        end
    end

    @testset "expr_deref resolves a chain, and is a no-op on a free cursor" begin
        r = M.expr_unify_cycle_safe(_f(raw"[3] f $ $"), _f(raw"[3] f a b"))
        @test r isa M.Bindings
        for (k, v) in r
            d = M.expr_deref(r, v)
            @test d isa M.ExprEnv
            # a resolved cursor is no longer a variable — that is what "resolved" means
            @test M.ee_var_opt(d) === nothing || get(r, M.ee_var_opt(d), nothing) === nothing
        end
        # NEGATIVE CONTROL: on an EMPTY map nothing can resolve, so deref must return its input
        empty_b = M.Bindings()
        e = M.ExprEnv(0, _f(raw"$"))
        @test M.expr_deref(empty_b, e) === e
    end

    @testset "var-var: both sides variables still solve and deref" begin
        r = M.expr_unify_cycle_safe(_f(raw"[2] f $"), _f(raw"[2] f $"))
        @test r isa M.Bindings
        for (_, v) in r
            @test M.expr_deref(r, v) isa M.ExprEnv     # must not loop on a var-var equation
        end
    end
end
