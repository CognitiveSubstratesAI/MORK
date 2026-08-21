# Leapfrog `loc` — the SECOND callback argument, compared BYTE FOR BYTE against the stock engine.
#
# 🔴 THIS FILE EXISTS BECAUSE EVERY OTHER LEAPFROG TEST COMPARES COUNTS. `space_query_multi`'s
# contract is `effect(bindings, loc) -> Bool`, where `loc` is the matched stored fact. From layer 5
# (8d02787) until 2026-08-21 the leapfrog returned it TRUNCATED — missing the leading arity byte:
#
#     stock    [0x03, 0xc4 'edge', 0xc2 'n1', 0xc2 'n2']     ← the stored atom
#     leapfrog [      0xc4 'edge', 0xc2 'n1', 0xc2 'n2']     ← what `fact_bytes` returned
#
# `zipper_path` is RELATIVE to the zipper's root, and the cursor is opened AT the factor's prefix,
# so the prefix has to be prepended. A truncated `loc` changes NO ANSWER COUNT, so:
#   · 603 generated differential shapes  — blind to it
#   · 330 generated wiring bodies        — blind to it
#   · the 274/274 conformance corpus, run on this very engine — blind to it
# It surfaced only by accident, while debugging the re-index region walk, which failed LOUDLY on the
# same wrong assumption (`reserved byte: 0x6e` — a symbol payload byte read as a tag).
#
# ⚠️ THE LESSON IS THE ASSERTION SHAPE, NOT THE BUG. Counting answers tests the JOIN; it does not
# test the CONTRACT. Anything the callback receives and the count does not depend on is invisible
# until something asserts on the value itself.
# [[feedback_assert_the_contract_not_the_representation]] · [[feedback_oracle_must_observe_the_defect_class]]

using MORK, Test, Random

_loc_space(src) = (s = MORK.new_space(); MORK.space_add_all_sexpr!(s, src); s)
_loc_raw(loc) = Vector{UInt8}(loc isa MORK.Expr ? loc.buf : loc)

"Every `loc` the stock engine hands back, in order."
function _loc_stock(s, body)
    out = Vector{Vector{UInt8}}()
    MORK.space_query_multi(s.btm, MORK.sexpr_to_expr(body), (_b, l) -> (push!(out, _loc_raw(l)); true))
    out
end

"Every `loc` the leapfrog hands back, or `nothing` if the body is not routable."
function _loc_leap(s, body)
    out = Vector{Vector{UInt8}}()
    r = MORK.space_query_multi_leapfrog(s.btm, MORK.sexpr_to_expr(body),
                                        (_b, l) -> (push!(out, _loc_raw(l)); true))
    r === nothing ? nothing : out
end

@testset "leapfrog loc — byte-identical to the stock engine" begin

    @testset "🔑 the loc bytes ARE the stored atom" begin
        s = _loc_space("(edge n1 n2)\n(edge n2 n3)\n")
        body = "(, (edge \$x \$y))"
        stock = _loc_stock(s, body)
        leap = _loc_leap(s, body)

        @test leap !== nothing
        @test length(stock) == length(leap)
        @test !isempty(stock)                                  # anti-vacuity
        # ORDER may differ between engines — the join visits differently — so compare as SETS.
        @test Set(stock) == Set(leap)
        # …and pin the absolute fact: a loc must BE a stored atom, prefix included.
        @test Set(leap) == Set([MORK.sexpr_to_expr("(edge n1 n2)").buf,
                                MORK.sexpr_to_expr("(edge n2 n3)").buf])
    end

    @testset "multi-factor, ground columns, and a stored wildcard" begin
        for (src, body) in [
            ("(edge a b)\n(edge b c)\n(edge c d)\n",   "(, (edge \$x \$y) (edge \$y \$z))"),
            ("(edge a b)\n(edge \$w b)\n(edge b c)\n", "(, (edge \$x \$y) (edge \$y \$z))"),
            ("(edge a b)\n(link b c)\n",               "(, (edge \$x \$y) (link \$y \$z))"),
            ("(edge (f a) b)\n(edge (f c) d)\n",       "(, (edge (f \$x) \$y))"),
            ("(edge a a)\n(edge a b)\n",               "(, (edge \$x \$x))"),
        ]
            s = _loc_space(src)
            stock = _loc_stock(s, body)
            leap = _loc_leap(s, body)
            @test leap !== nothing
            @test Set(stock) == Set(leap)
        end
    end

    @testset "randomised — shapes nobody chose by hand" begin
        rng = MersenneTwister(0x10c)
        syms = ["a", "b", "c"]
        rels = ["edge", "link"]
        nonempty = 0
        for _ in 1:120
            lines = String[]
            for _ in 1:rand(rng, 2:5)
                r = rand(rng, rels)
                arg() = (t = rand(rng); t < 0.2 ? "\$w" : t < 0.35 ? "(f $(rand(rng, syms)))" :
                                        rand(rng, syms))
                push!(lines, "($r $(arg()) $(arg()))")
            end
            s = _loc_space(join(unique(lines), "\n") * "\n")
            nv = rand(rng, 1:2)
            conj = ["($(rand(rng, rels)) \$v$(rand(rng, 0:(nv-1))) \$v$(rand(rng, 0:(nv-1))))"
                    for _ in 1:rand(rng, 1:2)]
            body = "(, " * join(conj, " ") * ")"
            stock = _loc_stock(s, body)
            leap = _loc_leap(s, body)
            leap === nothing && continue
            !isempty(stock) && (nonempty += 1)
            @test Set(stock) == Set(leap)
        end
        @test nonempty >= 20        # anti-vacuity: empty-answer cases prove nothing
    end
end
