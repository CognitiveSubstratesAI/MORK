# pure_comparison_ops.jl — the `lt/gt/lte/gte/eq/ne` pure-op family (ported 2026-07-26).
#
# A name-level diff of our PURE_OPS table against upstream's `op!` macro invocations in
# kernel/src/pure.rs found 371 upstream ops, ALL present on our side except one family: the 42
# comparisons `{lt,gt,lte,gte,eq,ne} × {i8,i16,i32,i64,i128,f32,f64}`. Every one of them simply
# errored as an unknown op.
#
# That gap was not cosmetic. MM2's JOIN layer has no ordering whatsoever (`<`/`<=` panic as sources);
# the documented capability story is that ordering is DERIVABLE in the PURE-SINK layer from these
# comparisons plus `ifnz`. Without them, that was false for every type.
#
# Upstream shape (pure.rs:556-561 ints, :676-681 floats):
#     op!(num binary lt_i32(x: i32, y: i32) => (x < y) as i8);
# so the result is a 1-BYTE SIGNED int — 0 or 1 — NOT the operand width. Our space dump escapes those
# raw bytes as `\x01` / `\x00`.
#
# Upstream defines NO unsigned comparisons (there is no `lt_u8`), so neither do we — asserted below.
#
# GROUND TRUTH: every expectation was produced by running this exact program through the upstream
# release binary (`mork run`), which emitted `(lt32 ^A)`, `(gt32 ^@)`, … i.e. 0x01 / 0x00.
using MORK, Test

const _CMP_PROGRAM = raw"""
(p 1)
(exec 0 (, (p $_)) (O
  (pure (lt32 $r) $r (lt_i32 (i32_from_string 3) (i32_from_string 5)))
  (pure (gt32 $r) $r (gt_i32 (i32_from_string 3) (i32_from_string 5)))
  (pure (lte32 $r) $r (lte_i32 (i32_from_string 5) (i32_from_string 5)))
  (pure (gte32 $r) $r (gte_i32 (i32_from_string 4) (i32_from_string 5)))
  (pure (eq32 $r) $r (eq_i32 (i32_from_string 5) (i32_from_string 5)))
  (pure (ne32 $r) $r (ne_i32 (i32_from_string 5) (i32_from_string 5)))
  (pure (ltf $r) $r (lt_f64 (f64_from_string 1.5) (f64_from_string 2.5)))
  (pure (eqf $r) $r (eq_f64 (f64_from_string 2.5) (f64_from_string 2.5)))
  (pure (neg $r) $r (lt_i8 (i8_from_string -3) (i8_from_string 2)))
))
"""

# (atom-head, expected raw byte) — exactly as the upstream binary produced them.
const _CMP_EXPECTED = [
    ("lt32",  0x01),   # 3 <  5
    ("gt32",  0x00),   # 3 >  5
    ("lte32", 0x01),   # 5 <= 5
    ("gte32", 0x00),   # 4 >= 5
    ("eq32",  0x01),   # 5 == 5
    ("ne32",  0x00),   # 5 != 5
    ("ltf",   0x01),   # 1.5 <  2.5   (f64)
    ("eqf",   0x01),   # 2.5 == 2.5   (f64)
    ("neg",   0x01),   # -3  <  2     (i8, signed)
]

@testset "pure comparison ops (vs upstream binary)" begin
    @testset "table completeness — all 42 present, no unsigned variants" begin
        for suffix in ("i8", "i16", "i32", "i64", "i128", "f32", "f64"),
            name in ("lt", "gt", "lte", "gte", "eq", "ne")
            @test haskey(MORK.PURE_OPS, "$(name)_$(suffix)")
        end
        # Upstream defines no unsigned comparisons; adding them would be invention, not porting.
        for suffix in ("u8", "u16", "u32", "u64", "u128"), name in ("lt", "gt", "lte", "gte", "ne")
            @test !haskey(MORK.PURE_OPS, "$(name)_$(suffix)")
        end
    end

    @testset "end-to-end values through a pure sink" begin
        s = MORK.new_space()
        MORK.space_add_all_sexpr!(s, _CMP_PROGRAM)
        MORK.space_metta_calculus!(s, 1000)
        atoms = [strip(l) for l in split(MORK.space_dump_all_sexpr(s), '\n') if !isempty(strip(l))]

        for (head, byte) in _CMP_EXPECTED
            # The dump escapes the raw result byte, e.g. `(lt32 \x01)`.
            want = "($head \\x" * string(byte; base = 16, pad = 2) * ")"
            @test want in atoms
        end
    end

    @testset "results are ONE byte (i8), not the operand width" begin
        # Regression guard for the class of bug that bit the bit-count ops (which must return u32
        # for every input width): a comparison must be 1 byte regardless of operand size.
        @test MORK.pure_apply("lt_i64", [MORK._be_bytes(Int64(1)), MORK._be_bytes(Int64(2))]) == UInt8[0x01]
        @test MORK.pure_apply("gt_i64", [MORK._be_bytes(Int64(1)), MORK._be_bytes(Int64(2))]) == UInt8[0x00]
        @test MORK.pure_apply("eq_f32", [MORK._be_bytes(Float32(1.5)), MORK._be_bytes(Float32(1.5))]) == UInt8[0x01]
    end
end
