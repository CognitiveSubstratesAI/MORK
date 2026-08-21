# Leapfrog END-TO-END — does the join we ACTUALLY HAVE give the right answers?
#
# 🔴 WHY THIS FILE EXISTS, AND WHY IT SHOULD HAVE BEEN THE FIRST ONE WRITTEN.
# The port reached 259 assertions across six layers before this file existed. Every layer passed.
# Exactly ONE of them (`ground_leapfrog`) ran end to end; layers 3b/3c/3d — 77 assertions — appeared
# only in `export` lines and their own definitions. NOTHING CALLED THEM. Tested in isolation,
# correct in isolation, unreachable. Then a twelve-line probe against the live engine asked the only
# question that matters, and `ground_leapfrog` answered 2 where the engine answered 5.
#
# The assembly (`unify_leapfrog`, layer 4) is what closed it. This file is its acceptance criterion,
# and the ordering is the lesson: the oracle was available from the first commit.
# [[feedback_parses_is_not_fires]] · [[feedback_green_suite_hides_unwired_correct_code]]
#
# ⚠️ AND THE ORACLE ITSELF NEEDED VERIFYING FIRST. The randomized differential's first run reported
# 64 divergences — every one of them this harness passing a BARE conjunct where the engine expects a
# `(, …)` conjunction, so `(link $a $b)` was read as a conjunction over `$a` and `$b` and a 4-atom
# space answered 16. The join was right and the oracle was wrong.
# [[feedback_verify_the_oracle_runs]] · [[feedback_verify_oracle_against_upstream_not_assume_canonical]]

using MORK, Test
const _E2E = MORK.Leapfrog
const _E2E_ARITY3 = MORK.item_byte(MORK.ExprArity(0x03))

"The head prefix of a binary relation — the common prefix of two atoms whose args differ in length."
function _e2e_prefix(h::AbstractString)
    a = MORK.sexpr_to_expr("($h a a)").buf
    b = MORK.sexpr_to_expr("($h bb bb)").buf
    k = 0; n = min(length(a), length(b))
    while k < n && a[k + 1] == b[k + 1]; k += 1; end
    a[1:k]
end

"Answers from the LIVE ENGINE — full unification, the oracle. The body MUST be a `(, …)` conjunction."
function _e2e_engine(s, body::AbstractString)
    n = Ref(0)
    MORK.space_query_multi(s.btm, MORK.sexpr_to_expr(body), (_b, _l) -> (n[] += 1; true))
    n[]
end

"Answers from the GROUND join — equality-only, by contract."
function _e2e_ground(s, factors, nvars)
    out = Set{Vector{Vector{UInt8}}}()
    _E2E.ground_leapfrog(s.btm, factors, nvars, b -> push!(out, [copy(x) for x in b]))
    length(out)
end

"Answers from the ASSEMBLED UNIFY join — layer 4."
function _e2e_unify(s, factors, nvars)
    n = Ref(0)
    _E2E.unify_leapfrog(s.btm, factors, nvars, (_b, _st) -> (n[] += 1; true))
    n[]
end

"The two-hop chain `(, (edge \$x \$y) (edge \$y \$z))` as unify-join factors."
function _e2e_chain()
    head = _E2E.unify_term_col(MORK.sexpr_to_expr("edge"))
    [ _E2E.UnifyFactor(UInt8[_E2E_ARITY3], [head, _E2E.unify_var_col(0), _E2E.unify_var_col(1)]),
      _E2E.UnifyFactor(UInt8[_E2E_ARITY3], [head, _E2E.unify_var_col(1), _E2E.unify_var_col(2)]) ]
end

_e2e_space(src) = (s = MORK.new_space(); MORK.space_add_all_sexpr!(s, src); s)
const _E2E_CHAIN_BODY = "(, (edge \$x \$y) (edge \$y \$z))"

@testset "leapfrog end-to-end vs the live engine" begin

    @testset "GROUND data — both joins agree with the engine" begin
        s = _e2e_space("(edge a b)\n(edge b c)\n(edge b d)\n(edge c e)\n(edge d e)\n")
        p = _e2e_prefix("edge")
        gf = [_E2E.GroundFactor(p, [1, 2]), _E2E.GroundFactor(p, [2, 3])]
        eng = _e2e_engine(s, _E2E_CHAIN_BODY)
        @test eng > 0                                    # anti-vacuity
        @test _e2e_ground(s, gf, 3) == eng
        @test _e2e_unify(s, _e2e_chain(), 3) == eng
    end

    @testset "🔑 STORED WILDCARD — the case that separates the two joins" begin
        # `(edge $a b)` unifies with `(edge ANYTHING b)`, so equality-only matching drops answers.
        s = _e2e_space("(edge a b)\n(edge \$w b)\n(edge b c)\n")
        @test occursin("\$", MORK.space_dump_all_sexpr(s))     # the wildcard really is stored

        p = _e2e_prefix("edge")
        gf = [_E2E.GroundFactor(p, [1, 2]), _E2E.GroundFactor(p, [2, 3])]
        eng = _e2e_engine(s, _E2E_CHAIN_BODY)

        @test eng == 5                                   # pin the oracle, not just the agreement
        @test _e2e_unify(s, _e2e_chain(), 3) == eng      # ⇐ THE ASSERTION THIS FILE EXISTS FOR
        # The ground join is NOT broken here — it is ground-only BY CONTRACT, and this pins the
        # difference so nobody later "fixes" it into a slower unify join.
        @test _e2e_ground(s, gf, 3) == 2
        @test _e2e_ground(s, gf, 3) < eng
    end

    @testset "wildcards in BOTH columns, and the degenerate spaces" begin
        for (src, nv) in [("(edge a b)\n(edge \$u \$v)\n(edge b c)\n", 3),
                          ("(edge a b)\n", 3),
                          ("(zzz q)\n", 3)]
            s = _e2e_space(src)
            @test _e2e_unify(s, _e2e_chain(), nv) == _e2e_engine(s, _E2E_CHAIN_BODY)
        end
    end

    @testset "🔑 CYCLIC CAPTURE yields no answer — and why that is free TODAY but not tomorrow" begin
        # A stored wildcard can be captured by two columns at once, forcing  $x = (f $x)  — an
        # occurs violation that arrives through a CHAIN of columns, not through any single equation.
        # Upstream names this exactly ("the join-propagated capture builds x0 = (k (k x0))") and
        # drops such a row at emit with an explicit `cycled` check.
        #
        # 🔴 WE HAVE NO SUCH CHECK AND STILL AGREE — because `unified_bindings` re-states EVERY
        # existing binding as an equation and re-solves from scratch per candidate, so the occurs
        # check sees the whole chain. That is a property of the SLOW path we deliberately ported.
        # ⇒ WHEN THE INCREMENTAL UNDO TRAIL IS ADOPTED (upstream `cfa8abf`), THAT PROPERTY IS LOST
        # AND THE `cycled` CHECK BECOMES MANDATORY. These cases are what will catch it: they pass
        # now, and they are the reason the trail is not a drop-in swap.
        mk(rel, c1, c2) = _E2E.UnifyFactor(UInt8[_E2E_ARITY3],
            [_E2E.unify_term_col(MORK.sexpr_to_expr(rel)),
             c1 isa Int ? _E2E.unify_var_col(c1) : _E2E.unify_term_col(MORK.sexpr_to_expr(c1[1]), c1[2]),
             c2 isa Int ? _E2E.unify_var_col(c2) : _E2E.unify_term_col(MORK.sexpr_to_expr(c2[1]), c2[2])])

        cyc = [mk("edge", 0, ("(f \$x)", 0))]
        s1 = _e2e_space("(edge \$w \$w)\n")
        @test _e2e_engine(s1, "(, (edge \$x (f \$x)))") == 0        # the oracle rejects it
        @test _e2e_unify(s1, cyc, 1) == 0                          # …and so must we

        # ⚠️ ANTI-VACUITY: the same query on a space that DOES satisfy it must still answer, or the
        # assertion above would be satisfied by a join that simply never emits.
        s2 = _e2e_space("(edge \$w \$w)\n(edge (f a) (f (f a)))\n")
        @test _e2e_engine(s2, "(, (edge \$x (f \$x)))") == 1
        @test _e2e_unify(s2, cyc, 1) == 1

        # …and across TWO factors, where the cycle closes only when both are combined.
        two = [mk("edge", 0, 1), mk("link", 1, ("(f \$x)", 0))]
        s3 = _e2e_space("(edge \$w \$w)\n(link \$u \$u)\n")
        @test _e2e_engine(s3, "(, (edge \$x \$y) (link \$y (f \$x)))") == 0
        @test _e2e_unify(s3, two, 2) == 0

        # 🔴 THE SHAPES THE CURRENT DESIGN MAKES UNREACHABLE — added 2026-08-21 after a STUB
        # EXPERIMENT. Weakening `unified_bindings` to state only the LOCAL edge (exactly what a
        # trail's occurs check sees) made all three assertions above fail, so they DO exercise
        # chain-visibility. But every one of them closes its cycle across ADJACENT columns. The
        # dangerous case for a trail is a cycle closing through a variable bound TWO OR MORE COLUMNS
        # BACK: the local edge looks innocent, and only the accumulated chain is contradictory.
        #
        # ⚠️ THESE ARE NOT REACHABLE BY EITHER GENERATOR. `leapfrog_differential.jl` and
        # `leapfrog_wiring.jl` build spaces from `(rel arg arg)` lines and bodies from two-column
        # conjuncts; neither can produce a three-hop capture. Hand-written or unobserved.
        three = [mk("edge", 0, 1), mk("link", 1, 2), mk("rel", 2, ("(f \$x)", 0))]
        s4 = _e2e_space("(edge \$w \$w)\n(link \$u \$u)\n(rel \$v \$v)\n")
        b4 = "(, (edge \$x \$y) (link \$y \$z) (rel \$z (f \$x)))"
        @test _e2e_engine(s4, b4) == 0            # the oracle rejects the three-hop capture
        @test _e2e_unify(s4, three, 3) == 0       # …and so must we, with `$x` bound TWO levels back

        # ANTI-VACUITY for the three-hop shape: a space that genuinely satisfies it must answer,
        # or the assertion above is satisfied by a join that never emits at depth 3.
        s5 = _e2e_space("(edge a b)\n(link b c)\n(rel c (f a))\n")
        @test _e2e_engine(s5, b4) == 1
        @test _e2e_unify(s5, three, 3) == 1
    end

    @testset "the layers the assembly made reachable are now CALLED" begin
        # This replaces a testset that asserted the OPPOSITE — that nothing called them. Keeping it
        # as a test rather than a comment is what made the change visible.
        #
        # ⚠️ COMMENT LINES ARE STRIPPED FIRST. The version before this one matched raw file text and
        # so counted a name MENTIONED IN THE HEADER PROSE as a call — it reported
        # `column_matches_by_equality` reachable when layer 4 never calls it. A test that a comment
        # can satisfy is not a test. [[feedback_verify_code_body_not_comments]]
        src = read(joinpath(@__DIR__, "..", "..", "src", "kernel", "Leapfrog.jl"), String)
        layer4 = src[findfirst("LAYER 4 — THE ASSEMBLY", src).start:end]
        code = join([l for l in split(layer4, '\n') if !startswith(strip(l), "#")], '\n')

        for f in ("ground_probe!", "stored_wildcard_bytes", "match_candidate!",
                  "with_bound_bytes!", "cursor_var_counts", "cursor_floor_child_mask")
            @test occursin(f * "(", code)          # genuinely called from layer 4's body
        end

        # 🔑 THE SOUNDNESS GUARDS ARE NOW CALLED — this pair has flipped FOUR times, which is the
        # entire reason it is a test and not a comment:
        #   v1 nothing called the layers · v2 only LeapfrogEntry did · v3 Space.jl routes (gated)
        #   v4 (here) the WCO layer landed, so the PRUNING guards are live.
        # They gate `fill_lead_candidates!`'s mutual seek: pruning is legal only where unifiability
        # IS equality, and these two are what establish that.
        for f in ("column_matches_by_equality", "is_symbol_head", "fill_lead_candidates!",
                  "partition_restrictors!", "rank_parts!")
            @test occursin(f * "(", code)
        end

        # 🔴 THE LAST DOCUMENTED OMISSION, still absent: RE-INDEXING. Upstream's `is_inverted`
        # detects a factor mentioning variables OUT OF SCHEDULE ORDER — `(, (edge $x $y) (edge $z
        # $x))` — and permutes its columns into a private map so it can still be SOUGHT rather than
        # enumerated. Costs speed, not answers, and `scan_subterm`'s variable mask is DISCARDED
        # rather than stored precisely so a dead field cannot read as the feature being half-present.
        # When it lands this line fails and must flip, like the four before it.
        # v5 (2026-08-21): the PURE TRANSFORM layer landed — `is_inverted` and the column
        # permutation exist and are round-trip tested (`leapfrog_reindex.jl`, 253 assertions).
        @test occursin("function is_inverted", code)
        @test occursin("function ri_emit_reordered", code)
        # ✅ v6 — THE WIRING LANDED, and this pin flipped for the SIXTH time. The sequence is the
        # whole argument for writing reachability as a test rather than a comment:
        #   v1 nothing called the layers · v2 only LeapfrogEntry · v3 Space.jl routes (gated)
        #   v4 the pruning guards went live · v5 the transform existed, unused · v6 the join uses it
        # Measured effect: an inverted factor went 90 600 -> 897 candidates (100.7x -> 1.0x).
        @test occursin("build_reindex(", code)
        @test occursin("is_inverted(", code)

        # 🔴 NOTHING DOCUMENTED REMAINS UNWIRED. Every deliberate omission named in the layer
        # headers — rank_parts, fill_lead_candidates, re-indexing — is now called from the join.
        # If a future omission is added, pin it HERE, the way these six were.
    end

    @testset "🔴 REACHABLE from an entry point, but NOT on the default query path" begin
        # This testset previously asserted `isempty(callers)` — that NOTHING in src/ called the
        # join. Wiring `LeapfrogEntry.jl` made it fail, which is exactly what it was written to do,
        # and this is its rewrite. The remaining gap is narrower and must stay just as visible.
        srcdir = joinpath(@__DIR__, "..", "..", "src")
        callers = String[]
        for (root, _, files) in walkdir(srcdir), fn in files
            endswith(fn, ".jl") || continue
            fn == "Leapfrog.jl" && continue
            occursin("unify_leapfrog(", read(joinpath(root, fn), String)) && push!(callers, fn)
        end
        @test callers == ["LeapfrogEntry.jl"]        # reachable, from exactly one place

        # …and the parse that makes a BODY routable now exists.
        lf = read(joinpath(srcdir, "kernel", "Leapfrog.jl"), String)
        code2 = join([l for l in split(lf, '\n') if !startswith(strip(l), "#")], '\n')
        @test occursin("function parse_body_factors", code2)

        # 🔴 THE GAP THAT REMAINS: `space_query_multi` — what a MeTTa query actually calls — does
        # NOT consult the leapfrog. There is no dispatch, so the join answers only a caller who
        # asks for it by name. When a dispatch lands this line fails and must be rewritten again.
        #
        # ⚠️ AND A DISPATCH IS NOT A SWAP. Our own P5 measurement says a wrong gate makes queries
        # SLOWER, not merely different, so the gate has to be earned on measured shapes — which is
        # why wiring the entry point and choosing when to use it are deliberately separate commits.
        # 🔑 THIS ASSERTION PAIR HAS NOW FLIPPED TWICE, WHICH IS THE POINT OF WRITING IT AS A TEST.
        # v1: nothing in src/ called the join.        v2: only LeapfrogEntry.jl did.
        # v3 (here): `Space.jl`'s `,`-source transform ROUTES to it — but only behind a flag that is
        # OFF by default, so the stock engine still answers unless a caller opts in.
        sp = read(joinpath(srcdir, "kernel", "Space.jl"), String)
        spcode = join([l for l in split(sp, '\n') if !startswith(strip(l), "#")], '\n')
        @test occursin("space_query_multi_leapfrog", spcode)       # the route exists…
        @test occursin("LEAPFROG_DISPATCH", spcode)                # …and it is gated
        # …and the gate is SHUT BY DEFAULT — asserted against the SOURCE, not the runtime value.
        # ⚠️ This read `MORK.LEAPFROG_DISPATCH[] == false` and FAILED under
        # `MORK_LEAPFROG_DISPATCH=1 tools/run_tests.sh` — the very run that compares the join against
        # the upstream binary. A test that breaks when you exercise the thing it guards is testing
        # the harness, not the invariant. The invariant is what SHIPS.
        dispatch_src = read(joinpath(srcdir, "kernel", "LeapfrogDispatch.jl"), String)
        @test occursin("const LEAPFROG_DISPATCH = Ref(false)", dispatch_src)

        # The divergence warning is wired to the same place upstream puts it — the serialization
        # entry point — rather than merely defined. Three layers of this port were defined and
        # called by nothing; that is what this line is guarding against.
        @test occursin("warn_top_level_variable(s)", spcode)
    end
end
