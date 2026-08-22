# test_morkl_algebra_identity.jl — MorkL's binary space ops must handle `Identity` correctly.
#
# `AlgebraicResult::Identity(mask)` means "the answer IS one of the operands" — SELF_IDENT the
# first, COUNTER_IDENT the second. It does NOT mean "no answer". `_binary_space_op!` used to map
# every non-Element result to a fresh empty PathMap, so any op whose answer happened to equal an
# input produced an EMPTY SPACE. Four of the five shapes below were wrong.
#
# WHY THE SUITE MISSED IT: every MorkL test drove ops whose result DIFFERS from both inputs, which
# is the one case the old code got right. The bug needs a *degenerate* pair — disjoint operands for
# subtract, a subset for union, equal operands for intersect, a superset for restrict. Those are
# exactly the pairs a hand-written test tends not to bother with, and exactly the ones a real query
# hits constantly.
#
# ⚠️ NOT A PORTED BUG — upstream has a DIFFERENT one in the same place, and the two are
# complementary. Upstream (server branch 2d6730b, experiments/morkl_interpreter/src/lib.rs:306-311)
# writes `let out = space_reg[arg_0].clone(); out.$OP(&space_reg[arg_1]); space_reg[pc] = out;`
# but those ops are `&self -> Self` (pathmap trie_map.rs:523-559), so the result is DISCARDED and
# every op returns `arg_0` untouched. Upstream is right exactly where we were wrong (Identity) and
# wrong where we were right (Element). Do not "restore parity" toward it.
using MORK, PathMaps, Test

_b(s) = Vector{UInt8}(codeunits(s))

function _mk(keys::Vector{String})
    m = PathMaps.PathMap{PathMaps.UnitVal}()
    for k in keys
        PathMaps.set_val_at!(m, _b(k), PathMaps.UnitVal())
    end
    m
end

function _paths(m::PathMaps.PathMap{PathMaps.UnitVal})
    z = PathMaps.read_zipper(m)
    out = String[]
    while PathMaps.zipper_to_next_val!(z)
        push!(out, String(copy(PathMaps.zipper_path(z))))
    end
    sort(out)
end

"Run one binary space op through the real interpreter helper and return the result register."
function _op(a::Vector{String}, b::Vector{String}, op::Symbol)
    reg = PathMaps.PathMap{PathMaps.UnitVal}[_mk(a), _mk(b), _mk(String[])]
    MORK._binary_space_op!(reg, 2, 0, 1, op)
    _paths(reg[3])
end

@testset "MorkL binary space ops — Identity is an operand, not emptiness" begin

    @testset "the four degenerate pairs that used to return an EMPTY space" begin
        # a - b where b is disjoint: nothing to remove, so the answer IS a.
        @test _op(["a", "b"], ["c", "d"], :subtraction) == ["a", "b"]
        # a | b where b ⊆ a: the union IS a.
        @test _op(["a", "b"], ["a"], :union) == ["a", "b"]
        # a & b where a == b: the intersection IS a.
        @test _op(["a", "b"], ["a", "b"], :intersection) == ["a", "b"]
        # a restricted to a superset: everything survives, so the answer IS a.
        @test _op(["a", "b"], ["a", "b", "c"], :restriction) == ["a", "b"]
    end

    @testset "controls — Element and None were always correct, and must stay so" begin
        @test _op(["a", "b"], ["b"], :subtraction) == ["a"]        # Element
        @test _op(["a", "b"], ["b", "c"], :intersection) == ["b"]    # Element
        @test _op(["a"], ["b"], :union) == ["a", "b"]   # Element
        @test _op(["a"], ["a"], :subtraction) == String[]     # None — genuinely empty
    end

    @testset "COUNTER_IDENT — the answer is the SECOND operand" begin
        # a | b where a ⊆ b: the union IS b, so the mask is COUNTER_IDENT, not SELF_IDENT.
        # A fix that returned `a` on any Identity would pass every test above and fail this one.
        @test _op(["a"], ["a", "b"], :union) == ["a", "b"]
        @test _op(["a", "b"], ["a"], :intersection) == ["a"]
    end
end
