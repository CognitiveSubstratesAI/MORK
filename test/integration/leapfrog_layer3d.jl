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

using MORK, Test, Random
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

    # ═════════════════════════════════════════════════════════════════════════════════════════════
    # 🔑 THE UNDO TRAIL'S DIFFERENTIAL ORACLE (added 2026-08-21, when the trail took the live path).
    #
    # `match_candidate!` no longer calls `unified_bindings`; it solves the ONE new equation against a
    # LIVE map and unwinds by removal. That is only correct if it agrees with a FROM-SCRATCH MGU, and
    # `unified_bindings` IS the from-scratch MGU — so it stops being the implementation and becomes
    # the oracle. This is the reason it is not deleted as dead code.
    #
    # ⚠️ WHY ANSWER-LEVEL TESTS DO NOT COVER THIS. `leapfrog_differential.jl` (603) and
    # `leapfrog_wiring.jl` (330) compare ANSWER COUNTS against the stock engine. An incremental
    # binder that diverged on a binding no answer projects would pass every one of them — the same
    # blindness that let a wrong `loc` survive 1000+ assertions, because a wrong `loc` changes no
    # count. So compare BINDINGS, and compare them BY DEREFERENCE: the solved form's SHAPE may
    # legitimately differ (path compression, which end of a var-var equation survived) while the
    # closure may not. [[feedback_assert_the_contract_not_the_representation]]
    @testset "🔑 UNDO TRAIL == FROM-SCRATCH MGU, by deref (the oracle for `match_candidate!`)" begin
        # ⚠️ A SHALLOW DEREF IS NOT A NORMAL FORM, and a first draft of this testset used one: it
        # followed top-level variable chains and keyed the result BY THE MAP'S OWN KEYS. It reported
        # 11 divergences, all spurious, in the two shapes this comment exists to rule out:
        #
        #   (a) WHICH END OF A VAR-VAR EQUATION SURVIVED — live bound (0,2), the oracle bound (0,0),
        #       both to an unbound variable. Keying by map keys makes that a difference; it is not.
        #   (b) EAGER vs LAZY SUBSTITUTION — `unified_bindings` re-solves everything, so it
        #       substitutes INTO terms and yields `(rel a)`; the trail leaves `(rel $w)` with
        #       `$w -> a` recorded separately. A shallow deref cannot see through the compound.
        #
        # Both are exactly what "compare derefs, not maps" is supposed to permit — so the draft was
        # asserting the representation while its own comment said not to. The normal form must
        # RECURSE INTO COMPOUNDS and rename unbound variables CANONICALLY (by first occurrence over
        # a FIXED probe order), which is the only reading under which the two are comparable at all.
        function _d_norm(b, e, names::Dict{MORK.ExprVar, Int}, fuel::Int)
            fuel <= 0 && return "CYCLE"          # a bound cycle: terminate rather than hang
            v = MORK.ee_var_opt(e)
            if v !== nothing
                nxt = get(b, v, nothing)
                # an UNBOUND variable is a hole; its identity is its FIRST-OCCURRENCE index, so two
                # solutions that differ only in which representative survived compare equal.
                nxt === nothing && return "_" * string(get!(names, v, length(names) + 1))
                return _d_norm(b, nxt, names, fuel - 1)
            end
            # ⚠️ `ee_subsexpr` RETURNS THE REST OF THE BUFFER, not this item's span. A second draft
            # rendered a symbol with it and reported 4 divergences that were the TAIL leaking into
            # the head: `(rel $w)` showed as bytes `[rel 0xC0]` against `(rel a)`'s `[rel a]`, while
            # the arg that actually mattered had already resolved to `a` on BOTH sides. Slice the
            # symbol by its own declared size.
            tag = MORK.byte_item(e.base.buf[Int(e.offset) + 1])
            if !(tag isa MORK.ExprArity)
                tag isa MORK.ExprSymbol || return "TAG:" * string(typeof(tag))
                lo = Int(e.offset) + 1
                return string(Vector{UInt8}(e.base.buf[lo:lo + Int(tag.size)]))
            end
            args = MORK.ExprEnv[]
            MORK.ee_args!(e, args)
            "(" * join([_d_norm(b, a, names, fuel - 1) for a in args], " ") * ")"
        end

        "What the join can OBSERVE: the query variables, normalised, in a fixed order under one
         shared renaming. Not the map."
        _d_closure(b) = (names = Dict{MORK.ExprVar, Int}();
                         String[_d_norm(b, _L4.query_var_env(i), names, 64) for i in 0:3])

        rng   = MersenneTwister(0xB13F)
        terms = ["a", "b", "(rel a)", "(rel \$w)", "(pair a b)", "\$u"]
        eq(r) = rand(r, Bool) ? _L4.query_var_env(rand(r, 0:3)) :
                                _l4_env(rand(r, 1:3), rand(r, terms))

        nbound = 0        # trials where the oracle really bound something
        nfailed = 0       # trials where the two agreed on a CONTRADICTION
        nrestored = 0     # trials where an unwind was exercised

        for _ in 1:300
            oracle = MORK.Bindings()
            live   = MORK.Bindings()
            trail  = MORK.ExprVar[]

            for _ in 1:rand(rng, 1:4)
                lhs, rhs = eq(rng), eq(rng)
                mark = length(trail)
                before = _d_closure(live)

                nb = _L4.unified_bindings(oracle, lhs, rhs)
                r  = MORK.expr_unify_into!(live,
                        Tuple{MORK.ExprEnv, MORK.ExprEnv}[(lhs, rhs)], trail)
                failed = r isa MORK.UnificationFailure

                # 🔴 AGREEMENT ON FAILURE FIRST. An incremental binder that merely failed LESS often
                # would look like an improvement and be a wrong answer.
                @test (nb === nothing) == failed
                if failed
                    nfailed += 1
                    # ⚠️ the map is DIRTY after a failed solve — a contradiction may insert before it
                    # contradicts. Unwinding must restore it exactly, or the NEXT candidate in the
                    # real join is solved against corruption, silently.
                    MORK.expr_unify_unwind!(live, trail, mark)
                    @test _d_closure(live) == before
                    nrestored += 1
                    break
                end
                oracle = nb
                @test _d_closure(live) == _d_closure(oracle)   # ⇐ the property this testset exists for
                length(live) > 0 && (nbound += 1)
            end
        end

        # ⚠️ ANTI-VACUITY. Without these, a generator that only ever produced trivially-equal or
        # instantly-contradictory pairs would satisfy every assertion above while testing nothing.
        @test nbound   > 100
        @test nfailed  > 10
        @test nrestored == nfailed
    end

    # ═════════════════════════════════════════════════════════════════════════════════════════════
    # 🔴 THE FAILURE PATH, WHICH NOTHING REACHED. Added 2026-08-21 after a MUTATION EXPERIMENT:
    # deleting the unwind from `match_candidate!`'s failure branch SURVIVED ALL FOUR trail suites —
    # layer3d, expr_unify_trail, leapfrog_differential, leapfrog_end_to_end — and the full 8153.
    #
    # The reason is not subtle test weakness: instrumenting the join showed `expr_unify_into!`
    # returns a failure ZERO times inside `match_candidate!` on the corpus. The branch is
    # UNREACHABLE there, because candidate enumeration pre-filters by byte prefix — by the time a
    # candidate is unified it already matches. So the mutant was unreachable code, not undetected
    # corruption.
    #
    # ⚠️ WHAT THIS TEST DOES AND DOES NOT ESTABLISH. Attribution over the corpus (2026-08-21): the
    # branch is reached by 2 programs, both via OCCURS violations, which fire BEFORE inserting and so
    # can never be dirty. The repeated-variable shape that WOULD insert-then-fail is abundant in the
    # corpus (591 terms, 269 files) but never reaches the binder — the join settles coreference on
    # the trie descent. So the case below is constructed by calling `match_candidate!` DIRECTLY with
    # a pattern the join would not hand it.
    # ⇒ It is a legitimate UNIT test of this function's documented contract, and it KILLS the mutant.
    #   It is NOT evidence that the join can reach this state, and must not be cited as such.
    #   Unreachable-here remains a property of the CORPUS and of the current column scheduling, not a
    #   guarantee [[feedback_unexplained_behaviour_is_not_a_contract]] — which is why the unwind and
    #   its counters stay.
    @testset "🔴 match_candidate! RESTORES after a candidate that INSERTS then CONTRADICTS" begin
        sp, c = _l4_cursor(["(rel a b)"])
        trail = MORK.ExprVar[]
        b = MORK.Bindings()

        # `(pair $x $x)` against the data `(pair a b)`: unification binds $x := a, then meets $x
        # against b and CONTRADICTS — a failure that has already inserted. This is the shape
        # `expr_unify_trail.jl` pins at the primitive level; here it goes through the join's binder.
        pat  = _l4_env(0, "(pair \$x \$x)")
        data = MORK.sexpr_to_expr("(pair a b)").buf

        seen = Ref(0)
        got = _L4.match_candidate!(c, b, 0, 0x00, pat, data, _ -> (seen[] += 1); trail = trail)

        @test got === nothing            # it really did fail…
        @test seen[] == 0                # …and the continuation never ran
        # ⇐ THE ASSERTIONS THE MUTANT BREAKS: a failed solve may insert before it contradicts, so
        # the binder must unwind on the failure path too, or this map and trail stay dirty.
        @test isempty(trail)
        @test isempty(b)

        # ⚠️ ANTI-VACUITY, TWO WAYS. Without these the test above is satisfied by a binder that
        # simply never binds anything — which is exactly what "unreachable branch" looked like.
        b2 = MORK.Bindings(); trail2 = MORK.ExprVar[]
        inner = Ref(0)
        _L4.match_candidate!(c, b2, 0, 0x00, _l4_env(0, "(pair \$x \$y)"),
                             MORK.sexpr_to_expr("(pair a b)").buf,
                             _ -> (inner[] += 1); trail = trail2)
        @test inner[] == 1               # the SAME shape, non-contradictory, DOES run cont
        @test isempty(trail2)            # …and still restores afterwards

        # and the insert-then-contradict really does insert: solving it against a live map directly
        # (no unwind) must leave the map non-empty, or the failure path had nothing to restore.
        probe = MORK.Bindings(); ptrail = MORK.ExprVar[]
        pr = MORK.expr_unify_into!(probe,
                Tuple{MORK.ExprEnv, MORK.ExprEnv}[(pat,
                    MORK.ExprEnv(UInt8(1), UInt8(0), UInt32(0), MORK.sexpr_to_expr("(pair a b)")))],
                ptrail)
        @test pr isa MORK.UnificationFailure
        @test !isempty(ptrail)           # ⇐ proves the branch has something to unwind
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
