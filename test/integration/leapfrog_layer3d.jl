# Leapfrog LAYER 3d — the descent: bind a candidate, unify, recurse, restore.
#
# 🔑 THE CLAIM THAT MATTERS is not "it unifies" — layer 3b/3c already rest on `expr_unify`, which
# carries ~3000 assertions of its own. It is that `unified_bindings` produces a genuine MGU over the
# WHOLE system: every existing binding is re-stated as an equation, so a new pair can force an
# EXISTING binding to refine. An incremental `setindex!` would miss that, silently, and produce
# answers that satisfy the last equation while violating an earlier one.
#
# ⚠️ AND THE RESTORE. Upstream's descent is straight-line Rust; ours can throw. A `cont` that raises
# must still leave the cursor where it found it, or every enclosing column stays descended and the
# next enumeration reads a key from the wrong floor — the failure mode that cost two speculative
# fixes on `cursor_ascend_floor!` and surfaced three frames from its cause.

using MORK, Test
const _L4 = MORK.Leapfrog

_l4_expr(s::AbstractString) = MORK.sexpr_to_expr(s)
_l4_env(n::Integer, s::AbstractString) = MORK.ExprEnv(UInt8(n), UInt8(0), UInt32(0), _l4_expr(s))

function _l4_cursor(atoms::Vector{String})
    sp = MORK.new_space()
    MORK.space_add_all_sexpr!(sp, join(atoms, "\n") * "\n")
    (sp, _L4.SubtermCursor(MORK.read_zipper(sp.btm)))
end

@testset "leapfrog layer 3d — candidate descent" begin

    @testset "namespaces: query is 0, factor f is 1+f" begin
        @test _L4.QUERY_NS == 0x00
        @test _L4.factor_namespace(0) == 0x01
        @test _L4.factor_namespace(3) == 0x04
        # 🔴 NO FACTOR MAY LAND IN THE QUERY NAMESPACE, or a data variable would alias a query
        # variable and unification would silently conflate them.
        @test all(_L4.factor_namespace(f) != _L4.QUERY_NS for f in 0:63)
    end

    @testset "unified_bindings re-solves EXISTING bindings, not just the new pair" begin
        # $x already bound to `a`. Now unify $y against $x. A correct MGU must give $y -> a;
        # an incremental extension that only looked at the new pair would leave $y unresolved.
        b0 = MORK.Bindings()
        b1 = _L4.unified_bindings(b0, _L4.query_var_env(0), _l4_env(1, "a"))
        @test b1 !== nothing
        @test length(b1) >= 1

        b2 = _L4.unified_bindings(b1, _L4.query_var_env(1), _L4.query_var_env(0))
        @test b2 !== nothing
        @test length(b2) >= length(b1)          # the earlier binding survived the re-solve

        # 🔴 THE REFUTATION: a pair that contradicts an existing binding must FAIL, not overwrite.
        # $x is bound to `a`; unifying $x against `b` is unsatisfiable.
        @test _L4.unified_bindings(b1, _L4.query_var_env(0), _l4_env(1, "b")) === nothing
    end

    @testset "a ground/ground mismatch does not unify; a match does" begin
        b = MORK.Bindings()
        @test _L4.unified_bindings(b, _l4_env(0, "a"), _l4_env(1, "a")) !== nothing
        @test _L4.unified_bindings(b, _l4_env(0, "a"), _l4_env(1, "b")) === nothing
        # …and a stored WILDCARD unifies with a ground query term — the whole point of layer 3c
        @test _L4.unified_bindings(b, _l4_env(0, "(rel a)"), _l4_env(1, "\$w")) !== nothing
    end

    @testset "🔴 with_bound_bytes! restores the cursor — even when cont THROWS" begin
        (_, c) = _l4_cursor(["(rel a)", "(rel b)"])
        floor0 = c.col.floor
        path0  = length(PathMap.zipper_path(c.z))

        ran = Ref(false)
        _L4.with_bound_bytes!(c, UInt8[0xC1], () -> (ran[] = true))
        @test ran[]                                            # anti-vacuity: cont actually ran
        @test c.col.floor == floor0
        @test length(PathMap.zipper_path(c.z)) == path0

        # THE LOAD-BEARING CASE. Upstream is straight-line Rust and cannot throw here; ours can.
        # Without the `finally`, the cursor stays descended and every enclosing column is corrupt.
        @test_throws ErrorException _L4.with_bound_bytes!(c, UInt8[0xC1], () -> error("boom"))
        @test c.col.floor == floor0
        @test length(PathMap.zipper_path(c.z)) == path0
        @test _L4.cursor_check_invariants(c)
    end

    @testset "match_candidate! runs cont on a hit, and leaves the caller's bindings alone" begin
        (_, c) = _l4_cursor(["(rel a)", "(rel b)"])
        caller = MORK.Bindings()
        caller_len = length(caller)

        seen = Ref(0)
        got = _L4.match_candidate!(c, caller, 0, 0x00,
                                   _L4.query_var_env(0), MORK.sexpr_to_expr("(rel a)").buf,
                                   nb -> (seen[] += 1))
        @test got !== nothing                                  # it unified
        @test seen[] == 1                                      # …and the continuation ran
        # ⚠️ The CALLER's bindings must be untouched — upstream saves/restores; we return instead.
        @test length(caller) == caller_len

        # a candidate that cannot unify: no continuation, nothing returned
        caller2 = MORK.Bindings()
        b1 = _L4.unified_bindings(caller2, _L4.query_var_env(0), _l4_env(1, "zzz"))
        @test b1 !== nothing
        seen2 = Ref(0)
        got2 = _L4.match_candidate!(c, b1, 0, 0x00,
                                    _L4.query_var_env(0), MORK.sexpr_to_expr("(rel a)").buf,
                                    nb -> (seen2[] += 1))
        @test got2 === nothing
        @test seen2[] == 0                                     # cont must NOT run on a miss
    end

    @testset "candidate_intro_delta counts the candidate's OWN NewVars" begin
        # A stored wildcard introduces one variable; a ground term none. Getting this wrong lets a
        # later candidate in the same factor collide with variables an earlier one introduced.
        @test _L4.candidate_intro_delta(UInt8[0xC0]) == 0x01            # a bare NewVar
        @test _L4.candidate_intro_delta(MORK.sexpr_to_expr("a").buf) == 0x00
        @test _L4.candidate_intro_delta(MORK.sexpr_to_expr("(rel a)").buf) == 0x00
        @test _L4.candidate_intro_delta(MORK.sexpr_to_expr("(rel \$w)").buf) == 0x01
        @test _L4.candidate_intro_delta(MORK.sexpr_to_expr("(rel \$u \$v)").buf) == 0x02
    end
end
