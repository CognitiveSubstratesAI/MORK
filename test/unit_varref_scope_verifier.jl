# unit_varref_scope_verifier.jl — the VarRef scope invariant, and proof the checker can SEE a breach.
#
# THE INVARIANT (BLOCKER 2 step 4's safety net, docs/specs/blocker2_variable_identity_design_2026-09-18.md §5):
#
#     every VarRef(k) must satisfy  k < (number of NewVar binders to its LEFT)
#
# It is the same thing `MORK.wiki/Data-in-MORK.md` states as a syntax rule — "`[2] &0 $` would be a
# syntax error, as the reference is before the binding" — and the same thing the splice invariant
# needs: a subterm carrying `VarRef(k)` spliced into a destination with a different binder count
# produces a reference to the WRONG binder, or to none.
#
# 🔴 THIS FUNCTION ALREADY EXISTED. `expr_has_unbound` (ExprAlg.jl:1261, exported, a port of
# upstream's `Expr::has_unbound`) carries the binder count and flags `r >= c` — exactly the
# invariant. It was nearly re-implemented under a new name. The check is therefore a WIRING job for
# step 4, not new machinery, and this file pins the behaviour step 4 will rely on.
#
# ⚠️ A CHECKER THAT NEVER FIRES IS NOT A CHECKER. Every assertion below is paired: a well-scoped case
# that must pass AND a planted breach that must be caught. On today's tree the breaches can only be
# built BY HAND, because `atom_to_expr` assigns levels correctly — which is the point of landing this
# before the representation changes: green today means "it runs and does not fire spuriously", so a
# red after the change is signal rather than ambiguity.

using MORK, Test

@testset "VarRef scope invariant — expr_has_unbound is the step-4 verifier" begin
    # helper: build a buffer from tags directly, so a BREACH can be constructed (no encoder will)
    nv() = item_byte(ExprNewVar())
    vr(k) = item_byte(ExprVarRef(UInt8(k)))
    ar(n) = item_byte(ExprArity(UInt8(n)))
    sym(s) = vcat(item_byte(ExprSymbol(UInt8(length(s)))), Vector{UInt8}(s))
    E(parts...) = MORK.Expr(reduce(vcat, parts))

    @testset "WELL-SCOPED — must NOT fire" begin
        @test !expr_has_unbound(E(ar(3), sym("g"), nv(), nv()))          # two independent binders
        @test !expr_has_unbound(E(ar(3), sym("g"), nv(), vr(0)))         # binder then back-reference
        @test !expr_has_unbound(E(ar(4), sym("p"), nv(), nv(), vr(0)))   # refers to the FIRST binder
        @test !expr_has_unbound(E(ar(4), sym("p"), nv(), nv(), vr(1)))   # refers to the SECOND
        @test !expr_has_unbound(E(ar(3), sym("k"), sym("1"), sym("2")))  # ground
        # nested: the binder is in a SIBLING subterm but still to the LEFT — levels are ABSOLUTE
        @test !expr_has_unbound(E(ar(3), sym("q"), nv(), ar(3), sym("path"), vr(0), nv()))
    end

    @testset "🔴 BREACHES — the checker MUST catch each one" begin
        # reference with NO binder to its left — the wiki's `[2] &0 $` syntax error
        @test expr_has_unbound(E(ar(2), sym("g"), vr(0)))
        # one binder, but the reference names level 1
        @test expr_has_unbound(E(ar(3), sym("g"), nv(), vr(1)))
        # two binders, reference names level 2 — the OFF-BY-ONE a rebase error produces
        @test expr_has_unbound(E(ar(4), sym("p"), nv(), nv(), vr(2)))
        # THE SPLICE FAILURE, exactly: `(g $a $a)` = [Arity3 Sym NewVar VarRef0] copied VERBATIM into
        # a destination with 2 binders to its left. Correct is VarRef2; the verbatim copy keeps
        # VarRef0 — which is IN SCOPE and therefore NOT caught here, and that is the honest limit of
        # this checker (see below). The catchable case is the reverse direction: a subterm rebased
        # UPWARD and then spliced somewhere shallower.
        @test expr_has_unbound(E(ar(3), sym("g"), nv(), vr(5)))
    end

    @testset "THE LIMIT OF THIS CHECKER, pinned so it is not over-trusted" begin
        # A `VarRef(k)` that is IN RANGE but points at the WRONG binder is INVISIBLE here: both the
        # correct and the incorrect encoding satisfy `k < binders_to_left`. Splicing `(g $a $a)` into
        # a 2-binder destination yields `VarRef0` where `VarRef2` was meant — well-scoped, wrong.
        wrong_but_in_scope = E(ar(4), sym("p"), nv(), nv(), ar(3), sym("g"), nv(), vr(0))
        @test !expr_has_unbound(wrong_but_in_scope)   # 🔴 NOT caught — by construction
        # ⇒ the verifier bounds the damage (no dangling reference, no 6-bit wraparound) but does NOT
        # prove a splice was rebased correctly. THAT is what the differential oracle in 4b is for:
        # `match_atoms` vs `expr_unify` on the same terms. Recording the gap here so step 4 does not
        # mistake a green verifier for a correct rebase.
    end
end
