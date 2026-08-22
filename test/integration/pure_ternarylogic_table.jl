# pure_ternarylogic_table.jl — the 256-arm `ternary_table` LUT3, proven for EVERY selector.
#
# Upstream `kernel/src/pure.rs:113-370` is a `match s` with 256 arms, one hand-written boolean
# expression per selector, consumed by `u{8,16,32,64,128}_ternarylogic` (:391/:412/:434/:455/:476).
# Our port does NOT transcribe the table — `Pure.jl` `_ternarylogic` COMPUTES it from the 8 minterms.
# That is the right call (a 256-arm transcription is 256 chances to typo), but it moves the burden of
# proof onto an equivalence argument, and the comment there previously claimed only five selectors
# (s = 0,1,2,4,6) had ever been checked. 251 were not.
#
# THE METHOD — bit-slicing, which collapses the whole table into a single identity.
# Feed x = 0xF0…, y = 0xCC…, z = 0xAA… (repeated per byte). Then bit j of the operand triple encodes
# exactly the input combination (x<<2)|(y<<1)|z == j:
#
#     j        7   6   5   4   3   2   1   0
#     x 0xF0   1   1   1   1   0   0   0   0
#     y 0xCC   1   1   0   0   1   1   0   0
#     z 0xAA   1   0   1   0   1   0   1   0
#
# By the definition of a 3-input LUT, the result bit at position j is bit j of the selector. So under
# these inputs a CORRECT implementation of selector `s` must return exactly `s`. One identity,
# 256 selectors, no vendored expected-value table to drift.
#
# UPSTREAM'S HALF OF THE PROOF was run against `pure.rs` itself (2026-07-30): all 256 arms were
# extracted and evaluated under the same bit-sliced inputs, and every arm evaluated to its own index
# — 0 mismatches, 256/256 selectors present, none missing. That half cannot live in this suite
# because it needs the Rust source, which is outside this repo; it is reproducible with:
#
#     python3 - <<'PY'   # over ~/JuliaAGI/dev-zone/MORK/kernel/src/pure.rs
#     ... eval each `N => <expr>,` arm with X,Y,Z = 0xF0,0xCC,0xAA, `!`->`~`, mask &0xFF; assert == N
#     PY
#
# This file is the OUR-SIDE half: the same identity, through the real dispatch path, at all five
# widths. Together they establish pointwise agreement over the entire selector domain.
using MORK, Test

# Replicate a byte pattern across all bytes of T, so every byte position independently exercises the
# identity (a width bug that only corrupts the high bytes cannot hide).
_tt_rep(::Type{T}, b::UInt8) where {T <: Unsigned} =
    foldl((acc, i) -> acc | (T(b) << (8 * i)), 0:(sizeof(T) - 1); init=zero(T))

@testset "ternary_table — computed LUT3 == upstream's 256 arms" begin
    @testset "identity holds for all 256 selectors ($nm)" for (T, nm) in
                                                              ((UInt8, "u8"),
        (UInt16, "u16"),
        (UInt32, "u32"), (UInt64, "u64"),
        (UInt128, "u128"))
        x, y, z = _tt_rep(T, 0xF0), _tt_rep(T, 0xCC), _tt_rep(T, 0xAA)

        # (a) the helper itself
        bad_fn = [s for s in 0x00:0xff if MORK._ternarylogic(x, y, z, s) != _tt_rep(T, s)]
        @test isempty(bad_fn)

        # (b) the REAL dispatch path — PURE_OPS through pure_apply, big-endian in and out. This is
        # what a `(pure …)` sink actually calls, and it also pins the RESULT WIDTH: the macro writes
        # `($e).to_be_bytes()`, so the width is the operand width, not the selector's.
        bad_op = Tuple{UInt8, Vector{UInt8}, Vector{UInt8}}[]
        for s in 0x00:0xff
            got = MORK.pure_apply("$(nm)_ternarylogic",
                [MORK._be_bytes(x), MORK._be_bytes(y), MORK._be_bytes(z),
                    UInt8[s]])
            want = MORK._be_bytes(_tt_rep(T, s))
            got == want || push!(bad_op, (s, got, want))
        end
        @test isempty(bad_op)
        @test length(
            MORK.pure_apply("$(nm)_ternarylogic",
                [MORK._be_bytes(x), MORK._be_bytes(y), MORK._be_bytes(z),
                    UInt8[0x96]])
        ) == sizeof(T)
    end

    # Spot-check three arms by their upstream TEXT, independently of the identity above, so a
    # misreading of the bit order (x<->z) could not pass by symmetry of the pattern.
    #   s=1   -> !((x|y)|z)     : true only where x=y=z=0
    #   s=16  -> x & !(y|z)     : true only where x=1, y=z=0   (16 = 1<<4, i.e. j=4 == 0b100)
    #   s=170 -> z              : the identity-on-z selector
    @testset "bit order, read from the upstream arms" begin
        x, y, z = 0xF0, 0xCC, 0xAA
        @test MORK._ternarylogic(x, y, z, 0x01) == ~(x | y | z) == 0x01
        @test MORK._ternarylogic(x, y, z, 0x10) == (x & ~(y | z)) == 0x10
        @test MORK._ternarylogic(x, y, z, 0xaa) == z
        @test MORK._ternarylogic(x, y, z, 0xf0) == x
        @test MORK._ternarylogic(x, y, z, 0xcc) == y
        @test MORK._ternarylogic(x, y, z, 0x00) == 0x00
        @test MORK._ternarylogic(x, y, z, 0xff) == 0xff
    end
end
