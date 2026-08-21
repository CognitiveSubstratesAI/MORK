# Leapfrog PRODUCTION WIRING — the parse, and the engine-facing entry point.
#
# 🔑 THIS FILE WAS WRITTEN BEFORE THE CODE IT TESTS. That is the whole point. The previous round of
# this port produced three layers and 77 assertions over code nothing called, because the pieces were
# tested as they were written and the assembled thing was never run against an oracle. The oracle
# here is the same one that exposed that: `space_query_multi`, full unification, already
# byte-differentialled against the upstream Rust binary.
#
# What is being wired: upstream `parse_body_factors` + `scan_subterm` (leapfrog.rs:1183-1298) turn a
# query BODY into factors and a variable count — the thing `leapfrog_differential.jl` hand-builds —
# and `query_multi_leapfrog` (leapfrog.rs:1319) streams the join's answers through the stock
# callback contract. Until both exist, a MeTTa query cannot reach the join at all.
#
# ⚠️ THE PARSE IS WHERE A WRONG ANSWER HIDES, not the join. The join is now differentialled over 603
# generated shapes, but every one of those hand-built its factors — so a parse that numbers a
# variable wrong, or picks the wrong prefix, produces a WELL-FORMED join of the WRONG QUESTION and
# every assertion downstream still passes. That is why these tests compare against the engine given
# the SAME BODY TEXT, and never against hand-built factors.
# [[feedback_verify_the_correspondence_not_just_the_code]] · [[feedback_parses_is_not_fires]]

using MORK, Test, Random
const _W = MORK.Leapfrog

_w_space(src) = (s = MORK.new_space(); MORK.space_add_all_sexpr!(s, src); s)

"Engine answers — the oracle."
function _w_engine(s, body::AbstractString)
    n = Ref(0)
    MORK.space_query_multi(s.btm, MORK.sexpr_to_expr(body), (_b, _l) -> (n[] += 1; true))
    n[]
end

"Leapfrog answers through the engine-facing entry, or `nothing` when the body is not routable."
function _w_leapfrog(s, body::AbstractString)
    n = Ref(0)
    r = MORK.space_query_multi_leapfrog(s.btm, MORK.sexpr_to_expr(body), (_b, _l) -> (n[] += 1; true))
    r === nothing ? nothing : n[]
end

@testset "leapfrog production wiring" begin

    @testset "the entry point exists and is reachable from MORK" begin
        # The assertion `leapfrog_end_to_end.jl` had to fail for this work to be done.
        @test isdefined(MORK, :space_query_multi_leapfrog)
        @test isdefined(_W, :parse_body_factors)
    end

    @testset "parse_body_factors: shapes that must ROUTE, and shapes that must NOT" begin
        # A well-formed conjunction routes; anything that is not one returns `nothing` so the caller
        # falls back to the ProductZipper rather than silently answering the wrong question.
        for body in ["(, (edge \$x \$y))", "(, (edge \$x \$y) (edge \$y \$z))",
                     "(, (edge a b))", "(, \$x)", "(, (edge \$x \$x))"]
            @test _W.parse_body_factors(MORK.sexpr_to_expr(body)) !== nothing
        end
        # 🔴 A BARE COMPOUND IS A CONJUNCTION TO THIS ENGINE, AND THE HEAD IS NEVER CHECKED FOR `,`.
        # `(edge $x $y)` parses as head `edge` with conjuncts `$x` and `$y` — each matching every
        # atom — so on a 3-atom space it answers 9, not 1. Upstream's parse does the same (any
        # `Tag::Arity` routes; nothing tests the head), so ROUTING IT IS CORRECT and the assertion
        # that once stood here — that it must NOT route — was the mistake.
        #
        # ⚠️ THIS COST ME TWICE IN ONE SESSION. The same misreading made the differential's oracle
        # report 64 false divergences, and then made this assertion wrong. Verified by execution,
        # not by reading: engine 9 == leapfrog 9. [[feedback_unexplained_behaviour_is_not_a_contract]]
        let s = _w_space("(edge a b)\n(edge b c)\n(link c d)\n"), b = "(edge \$x \$y)"
            @test _W.parse_body_factors(MORK.sexpr_to_expr(b)) !== nothing
            @test _w_engine(s, b) == 9              # pin the engine's reading, so it cannot drift
            @test _w_leapfrog(s, b) == _w_engine(s, b)
        end

        # NOT Arity nodes, so not routable. The stock path does not merely disagree here — it
        # THROWS ("pat_expr must be an Arity node"), so `nothing` is the only safe answer and a
        # fallback caller must not hand these on.
        for body in ["edge", "\$x"]
            @test _W.parse_body_factors(MORK.sexpr_to_expr(body)) === nothing
        end
    end

    @testset "parse_body_factors numbers variables BODY-GLOBALLY" begin
        # 🔴 THE DEFECT THIS CATCHES: a per-conjunct variable counter makes `$y` in the second
        # conjunct a DIFFERENT variable from `$y` in the first, so the join stops joining and
        # answers a cross product. It would still be a well-formed join, and every structural
        # assertion would pass.
        (fs, nv) = _W.parse_body_factors(MORK.sexpr_to_expr("(, (edge \$x \$y) (edge \$y \$z))"))
        @test length(fs) == 2
        @test nv == 3                       # $x $y $z — THREE, not two-per-conjunct
        # …and the shared variable is literally the same id in both factors.
        st1 = _W.factor_steps(fs[1]); st2 = _W.factor_steps(fs[2])
        v1 = [s.v for s in st1 if s.kind == _W.STEP_VAR]
        v2 = [s.v for s in st2 if s.kind == _W.STEP_VAR]
        @test v1 == [0, 1]
        @test v2 == [1, 2]                  # `$y` is id 1 on BOTH sides — that IS the join
    end

    @testset "🔑 ENGINE PARITY on hand-picked shapes" begin
        for (src, body) in [
            ("(edge a b)\n(edge b c)\n(edge c d)\n",              "(, (edge \$x \$y) (edge \$y \$z))"),
            ("(edge a b)\n(edge \$w b)\n(edge b c)\n",            "(, (edge \$x \$y) (edge \$y \$z))"),
            ("(edge a a)\n(edge a b)\n",                          "(, (edge \$x \$x))"),
            ("(edge (f a) b)\n(edge (f c) d)\n",                  "(, (edge (f \$x) \$y))"),
            ("(edge a b)\n(link b c)\n",                          "(, (edge \$x \$y) (link \$y \$z))"),
            ("(edge a b)\n",                                      "(, (edge a b))"),
            ("(edge a b)\n",                                      "(, (edge a zzz))"),
        ]
            s = _w_space(src)
            @test _w_leapfrog(s, body) == _w_engine(s, body)
        end
    end

    @testset "🔴 KNOWN DIVERGENCE: a TOP-LEVEL VARIABLE fact is invisible to the join" begin
        # A fact that is NOTHING BUT A VARIABLE sits at the trie root under no arity prefix. It
        # unifies with every conjunct of every query, and the join — which opens each factor's
        # cursor AT a prefix — cannot see it. Upstream states this and does NOT fix it; it emits a
        # warning instead (`Space::warn_top_level_variable`, space.rs:938):
        #
        #   "it unifies with every conjunct of every query, and the leapfrog join cannot see it,
        #    so the two engines will not agree on this space."
        #
        # MEASURED HERE 2026-08-21: engine 3, leapfrog 2. Ours diverges the same way upstream's does.
        #
        # ⚠️ NEITHER DIFFERENTIAL CAN SEE THIS. `leapfrog_differential.jl` and the generated-body
        # testset below both build spaces from `(rel arg arg)` lines, so a bare-variable atom is
        # structurally impossible in them. A gap a generator cannot reach needs a hand-written
        # case, or it is not covered — it is merely unobserved.
        # [[feedback_oracle_must_observe_the_defect_class]] · [[feedback_found_a_defect_is_not_a_scope_change]]
        #
        # 🔴 THIS IS A BLOCKER FOR ANY DISPATCH. The moment `space_query_multi` routes to the join,
        # such a space silently answers differently. Porting `warn_top_level_variable` (an O(1) root
        # child-mask probe) belongs WITH that change, not after it.
        control = _w_space("(edge a b)\n(edge b c)\n")
        @test _w_leapfrog(control, "(, (edge \$x \$y))") == _w_engine(control, "(, (edge \$x \$y))")

        loose = _w_space("(edge a b)\n(edge b c)\n\$loose\n")
        @test occursin("\$", MORK.space_dump_all_sexpr(loose))   # anti-vacuity: it really is stored
        eng = _w_engine(loose, "(, (edge \$x \$y))")
        ours = _w_leapfrog(loose, "(, (edge \$x \$y))")
        @test eng == 3                     # the engine sees the loose variable as a third match
        @test ours == 2                    # the join cannot; pinned so a silent change is visible
        @test ours != eng                  # ⇐ the divergence itself, asserted rather than implied
    end

    @testset "ENGINE PARITY on generated bodies — the parse included" begin
        rng = MersenneTwister(0x21ce)
        syms = ["a", "b", "c"]
        rels = ["edge", "link"]
        nonempty = 0
        routed   = 0

        for _ in 1:300
            lines = String[]
            for _ in 1:rand(rng, 2:5)
                r = rand(rng, rels)
                arg() = (t = rand(rng);
                         t < 0.20 ? "\$w" : t < 0.35 ? "(f $(rand(rng, syms)))" : rand(rng, syms))
                push!(lines, "($r $(arg()) $(arg()))")
            end
            s = _w_space(join(unique(lines), "\n") * "\n")

            nv = rand(rng, 1:3)
            conj = String[]
            for _ in 1:rand(rng, 1:3)
                r = rand(rng, rels)
                a() = (t = rand(rng);
                       t < 0.60 ? "\$v$(rand(rng, 0:(nv - 1)))" :
                       t < 0.78 ? "(f \$v$(rand(rng, 0:(nv - 1))))" : rand(rng, syms))
                push!(conj, "($r $(a()) $(a()))")
            end
            body = "(, " * join(conj, " ") * ")"

            eng  = _w_engine(s, body)
            ours = _w_leapfrog(s, body)
            eng > 0 && (nonempty += 1)
            ours === nothing || (routed += 1)
            ours === nothing || ours == eng ||
                println("  🔴 body=", body, "  engine=", eng, " ours=", ours,
                        "\n     space: ", replace(MORK.space_dump_all_sexpr(s), "\n" => " | "))
            @test ours !== nothing && ours == eng
        end

        # ⚠️ THIS PARITY IS SCOPED TO SPACES WITHOUT A TOP-LEVEL VARIABLE FACT — the generator
        # builds only `(rel arg arg)` lines, so it cannot produce one. See the known-divergence
        # testset above for the case it structurally cannot reach.
        # Anti-vacuity, both directions: the generator must produce real answers, and the parse must
        # actually route them rather than falling back to `nothing` and trivially "agreeing".
        @test nonempty >= 40
        @test routed == 300
    end
end
