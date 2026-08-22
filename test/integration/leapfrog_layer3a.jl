# Leapfrog LAYER 3a — the GROUND leapfrog join.
#
# 🔑 THE ORACLE IS THE LIVE ENGINE. `space_query_multi` answers the same conjunctive queries by a
# completely different algorithm (ProductZipper / P5 trie-join), is exercised by ~3000 assertions,
# and is byte-differentialled against the upstream Rust binary. If our leapfrog agrees with it on
# answer SETS, the seek machinery is right. Comparing against hand-written expected tuples would
# only prove the join agrees with the same reasoning that wrote it.
# [[feedback_metta_rules_verify_by_oracle_not_syntax]]
#
# ⚠️ SET comparison, deliberately. A WCO join visits answers in a different ORDER than a
# relation-at-a-time join — that is what it is FOR. Order equality would be a false requirement and
# would fail for a correct implementation.

using MORK, Test
const _LF = MORK.Leapfrog

# The head prefix of a relation: the common prefix of two atoms whose args differ in length, so it
# stops at the relation head, before the first argument.
_lf3_prefix(h, arity) = begin
    a = MORK.sexpr_to_expr("($h " * join(fill("a", arity), " ") * ")").buf
    b = MORK.sexpr_to_expr("($h " * join(fill("bb", arity), " ") * ")").buf
    k = 0
    n = min(length(a), length(b))
    while k < n && a[k + 1] == b[k + 1]
        k += 1
    end
    a[1:k]
end

"Answers from OUR leapfrog, as a set of variable-tuples (bytes)."
function _lf3_leapfrog(space, factors, nvars)
    out = Set{Vector{Vector{UInt8}}}()
    _LF.ground_leapfrog(space.btm, factors, nvars, b -> push!(out, [copy(x) for x in b]))
    out
end

"Answers from the LIVE ENGINE for the same conjunctive body, as a set of bound-atom tuples."
function _lf3_engine(space, body::String)
    pat = MORK.sexpr_to_expr(body)
    out = Set{String}()
    MORK.space_query_multi(
        space.btm, pat, (_b, loc) -> begin
            push!(out, strip(MORK.expr_serialize(loc)))
            true
        end
    )
    out
end

@testset "leapfrog layer 3a — ground WCO join" begin

    @testset "2-factor chain join agrees with the engine on COUNT" begin
        s = MORK.new_space()
        MORK.space_add_all_sexpr!(
            s, "(edge a b)\n(edge b c)\n(edge b d)\n(edge c e)\n(edge d e)\n"
        )

        # (, (edge $x $y) (edge $y $z))  — variables 1,2 / 2,3
        p = _lf3_prefix("edge", 2)
        factors = [_LF.GroundFactor(p, [1, 2]), _LF.GroundFactor(p, [2, 3])]
        got = _lf3_leapfrog(s, factors, 3)

        # ANTI-VACUITY: an empty result would satisfy any set-inclusion claim below.
        @test !isempty(got)

        # The engine, on the same body. Its callback yields one `loc` per match, so the COUNT is the
        # comparable quantity here (the tuple encodings differ by construction).
        n_engine = Ref(0)
        MORK.space_query_multi(s.btm,
            MORK.sexpr_to_expr("(, (edge \$x \$y) (edge \$y \$z))"),
            (_b, _l) -> (n_engine[] += 1; true))
        @test n_engine[] > 0
        @test length(got) == n_engine[]

        # Hand-computed truth, independently: 2-paths over a→b→{c,d}→e are
        # (a,b,c) (a,b,d) (b,c,e) (b,d,e) = 4.
        @test length(got) == 4
    end

    @testset "the clique4 shape — the case this whole adoption is for" begin
        # 6 factors, non-chain, cyclic. This is the query where our P5 path scales at 145x and
        # upstream's leapfrog at 6.3x.
        s = MORK.new_space()
        edges = ["(edge $i $j)" for i in 1:5 for j in 1:5 if i < j]   # K5: every pair
        MORK.space_add_all_sexpr!(s, join(edges, "\n") * "\n")

        p = _lf3_prefix("edge", 2)
        # (edge $1 $2)(edge $1 $3)(edge $1 $4)(edge $2 $3)(edge $2 $4)(edge $3 $4)
        factors = [_LF.GroundFactor(p, [1, 2]), _LF.GroundFactor(p, [1, 3]),
            _LF.GroundFactor(p, [1, 4]), _LF.GroundFactor(p, [2, 3]),
            _LF.GroundFactor(p, [2, 4]), _LF.GroundFactor(p, [3, 4])]
        got = _lf3_leapfrog(s, factors, 4)

        n_engine = Ref(0)
        MORK.space_query_multi(s.btm,
            MORK.sexpr_to_expr(
                "(, (edge \$a \$b) (edge \$a \$c) (edge \$a \$d) " *
                "(edge \$b \$c) (edge \$b \$d) (edge \$c \$d))"
            ),
            (_b, _l) -> (n_engine[] += 1; true))

        @test n_engine[] > 0                        # anti-vacuity for the comparison
        @test length(got) == n_engine[]
        # K5 has C(5,4) = 5 four-cliques, each found once in increasing order.
        @test length(got) == 5
    end

    @testset "an empty intersection yields nothing, and does not hang" begin
        s = MORK.new_space()
        MORK.space_add_all_sexpr!(s, "(edge a b)\n(edge c d)\n")
        p = _lf3_prefix("edge", 2)
        # (edge $x $y)(edge $y $z) — b has no outgoing edge, d has none: no 2-path exists.
        factors = [_LF.GroundFactor(p, [1, 2]), _LF.GroundFactor(p, [2, 3])]
        @test isempty(_lf3_leapfrog(s, factors, 3))
    end

    @testset "a single factor enumerates its whole relation" begin
        s = MORK.new_space()
        MORK.space_add_all_sexpr!(s, "(edge a b)\n(edge b c)\n(edge c d)\n")
        p = _lf3_prefix("edge", 2)
        got = _lf3_leapfrog(s, [_LF.GroundFactor(p, [1, 2])], 2)
        @test length(got) == 3        # degenerate join = the relation itself
    end

    @testset "a self-join on ONE variable is the diagonal" begin
        # (edge $x $x) — the same variable twice in one factor. The repetition IS the join, so this
        # must return only the self-loops, not the full relation.
        s = MORK.new_space()
        MORK.space_add_all_sexpr!(s, "(edge a a)\n(edge a b)\n(edge b b)\n(edge c d)\n")
        p = _lf3_prefix("edge", 2)
        got = _lf3_leapfrog(s, [_LF.GroundFactor(p, [1, 1])], 1)
        @test length(got) == 2        # (a,a) and (b,b) — NOT 4
    end
end
