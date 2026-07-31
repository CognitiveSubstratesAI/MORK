# pure_operand_width.jl — `consume::<T>` is EXACT (ported 2026-07-31).
#
# Every `op!` arm reads its operands with `expr.consume::<$tx>()`, and that check
# (eval-ffi/src/source.rs:152) is `*e.ptr == item_byte(SymbolSize(size_of::<T>()))` — the operand
# must be a symbol of PRECISELY the type's width. Anything else is `Err("failed to consume <T>")`
# and the atom is skipped: not coerced, not padded, not truncated.
#
# GROUND TRUTH: the four-case program below was run through the upstream release binary
# (`mork run width.mm2 width.raw`). Upstream dumps TWO expressions — `(n 1)` and the correct-width
# `(ok ^A)` — and NOTHING for the three wrong-width cases.
#
# 🔴 WHAT THIS CAUGHT. We rejected too-SHORT operands (the body ran out of bytes) but ACCEPTED
# too-LONG ones, emitting `(long \x01)` where upstream skips the atom. Silent, and it applied to
# every typed op — 276 fixed-arity plus 43 nary.
using MORK, Test

const _WIDTH_PROG = """
(n 1)
(exec 0 (, (n \$x)) (O (pure (ok \$r) \$r (lt_i64 aaaaaaaa bbbbbbbb))))
(exec 0 (, (n \$x)) (O (pure (short1 \$r) \$r (lt_i64 aaaa bbbbbbbb))))
(exec 0 (, (n \$x)) (O (pure (short2 \$r) \$r (lt_i64 aaaaaaaa bbbb))))
(exec 0 (, (n \$x)) (O (pure (long \$r) \$r (lt_i64 aaaaaaaaaaaa bbbbbbbbbbbb))))
"""

@testset "consume::<T> operand width is exact" begin
    s = MORK.new_space()
    MORK.space_add_all_sexpr!(s, _WIDTH_PROG)
    MORK.space_metta_calculus!(s, 2000)
    out = MORK.space_dump_all_sexpr(s)

    # byte-for-byte what the upstream binary produced
    @test out == "(n 1)\n(ok \x01)\n"
    @test occursin("(ok ", out)                 # correct width survives
    for skipped in ("short1", "short2", "long")
        @test !occursin(skipped, out)           # every wrong width is skipped
    end

    # the tables are vendored from the op! invocations; spot-check the widths they must carry
    @test MORK.PURE_OP_OPERAND_WIDTHS["lt_i64"] == [8, 8]
    @test MORK.PURE_OP_OPERAND_WIDTHS["lt_i8"] == [1, 1]
    @test MORK.PURE_OP_OPERAND_WIDTHS["lt_i128"] == [16, 16]
    @test MORK.PURE_OP_OPERAND_WIDTHS["lt_f32"] == [4, 4]
    # nary carries ONE width per ELEMENT — the arm's `$x: $tx`, never the accumulator's `$tt`
    @test MORK.PURE_OP_NARY_WIDTH["max_i64"] == 8
    @test MORK.PURE_OP_NARY_WIDTH["max_i8"] == 1
    @test MORK.PURE_OP_NARY_WIDTH["max_i128"] == 16
    @test MORK.PURE_OP_NARY_WIDTH["max_f32"] == 4
    # every declared width is a real Rust type size, and NOTHING else
    @test sort(unique(values(MORK.PURE_OP_NARY_WIDTH))) == [1, 2, 4, 8, 16]
    @test sort(unique(reduce(vcat, values(MORK.PURE_OP_OPERAND_WIDTHS)))) == [1, 2, 4, 8, 16]
    # coverage: the tables must span the arms the extraction found
    @test length(MORK.PURE_OP_OPERAND_WIDTHS) == 276
    @test length(MORK.PURE_OP_NARY_WIDTH) == 43
end
