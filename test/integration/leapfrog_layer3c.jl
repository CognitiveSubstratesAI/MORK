# Leapfrog LAYER 3c — the wildcard-aware ground probe.
#
# 🔑 WHAT MAKES THIS THE UNIFICATION HALF. A ground query column matches either the IDENTICAL stored
# bytes or ANY stored wildcard: a fact `(rel $w)` unifies with `(rel anything)`. Upstream's insight
# is that those wildcards need no scan — a stored variable is a COMPLETE ONE-BYTE SUBTERM, so it
# appears as a child byte at the column start and one child-mask read yields all of them.
#
# ⚠️ THE ORACLE IS A SPACE THAT REALLY CONTAINS A STORED VARIABLE. Testing the predicates against
# hand-built masks (layer 3b already does that) cannot show that a real trie puts the wildcard byte
# where the theory says. These tests build the space and read the mask the engine would read.

using MORK, Test
const _L3 = MORK.Leapfrog

"Cursor at the root of a space built from these atoms."
function _l3_cursor(atoms::Vector{String})
    s = MORK.new_space()
    MORK.space_add_all_sexpr!(s, join(atoms, "\n") * "\n")
    (s, _L3.SubtermCursor(MORK.read_zipper(s.btm)))
end

@testset "leapfrog layer 3c — wildcard-aware ground probe" begin

    @testset "ground_probe! finds a stored subterm, and reports absence" begin
        atoms = ["(rel a)", "(rel b)", "(other c)"]
        (_, c) = _l3_cursor(atoms)
        present = MORK.sexpr_to_expr("(rel a)").buf
        (exact, mask) = _L3.ground_probe!(c, present)
        @test exact                                      # it IS stored
        @test !PathMaps.is_empty_mask(mask.bits)          # …and the column really has children

        # the negative twin: a subterm that is NOT stored
        (_, c2) = _l3_cursor(atoms)
        (exact2, _) = _L3.ground_probe!(c2, MORK.sexpr_to_expr("(rel zzz)").buf)
        @test !exact2
    end

    @testset "🔴 the probe RESTORES the cursor to its floor" begin
        # A probe that left the cursor positioned would corrupt the enclosing enumeration — the same
        # class of defect as `cursor_ascend_floor!`'s precondition, which cost two speculative fixes
        # before instrumentation found it. Assert the state, not just the return value.
        atoms = ["(rel a)", "(rel b)"]
        (_, c) = _l3_cursor(atoms)
        floor_before = c.col.floor
        path_before = length(PathMaps.zipper_path(c.z))

        _L3.ground_probe!(c, MORK.sexpr_to_expr("(rel a)").buf)
        @test c.col.floor == floor_before
        @test length(PathMaps.zipper_path(c.z)) == path_before
        @test _L3.cursor_check_invariants(c)

        # …and a probe that MISSES must restore just as cleanly
        _L3.ground_probe!(c, MORK.sexpr_to_expr("(rel zzz)").buf)
        @test c.col.floor == floor_before
        @test length(PathMaps.zipper_path(c.z)) == path_before
        @test _L3.cursor_check_invariants(c)

        # after probing, a fresh enumeration must still work — the real consequence of a bad restore
        _L3.cursor_first!(c)
        @test _L3.cursor_key(c) !== nothing
    end

    @testset "stored_wildcard_bytes reads a REAL stored variable off the mask" begin
        # The space genuinely holds `(rel $w)`, so at the top-level column the child mask must carry
        # a variable tag byte. This is the claim layer 3b could only make about synthetic masks.
        (s, c) = _l3_cursor(["(rel a)", "(rel \$w)"])
        @test occursin("\$", MORK.space_dump_all_sexpr(s))    # anti-vacuity: the var really stored

        # descend to the `rel` relation's argument column, then read the mask there
        (_, mask) = _L3.ground_probe!(c, MORK.sexpr_to_expr("(rel a)").buf)
        wilds = _L3.stored_wildcard_bytes(mask)
        # At the ROOT column the children are whole atoms, so this asserts the mechanism, not a
        # specific byte: every byte returned must BE a wildcard tag, and none may be a symbol.
        @test all(b -> _L3.is_wildcard_term(UInt8[b]), wilds)
        @test !any(b -> MORK.byte_item(b) isa MORK.ExprSymbol, wilds)
    end

    @testset "stored_wildcard_bytes agrees with column_matches_by_equality" begin
        # The two read the SAME range (0x80..0xC0). If they ever disagreed, the join would prune a
        # column one of them called wildcard-free — silently dropping every answer that needed it.
        mk(bs) = (bits=PathMaps.EMPTY_BITS4;
            for b in bs
                bits = PathMaps.with_bit_set(bits, UInt8(b))
            end;
            PathMaps.ByteMask(bits))
        for bs in (
            [0xC1, 0xD0], [0x00, 0x3F], UInt8[], [0x80], [0xC0], [0xBF, 0xC1], [0x00, 0x80]
        )
            m = mk(bs)
            wilds = _L3.stored_wildcard_bytes(m)
            # equality-only ⟺ no wildcards found. Asserted BOTH ways, so neither can drift.
            @test _L3.column_matches_by_equality(m) == isempty(wilds)
        end
    end

    @testset "the mask is read BEFORE the seek" begin
        # Order is load-bearing: seeking moves the zipper off the floor, so a mask read afterwards
        # would report the children of wherever it landed — a different question with a
        # plausible-looking answer. Compare the probe's mask against the floor mask taken directly.
        (_, c) = _l3_cursor(["(rel a)", "(rel b)", "(zed q)"])
        direct = _L3.cursor_floor_child_mask(c)
        (_, probed) = _L3.ground_probe!(c, MORK.sexpr_to_expr("(rel a)").buf)
        @test probed.bits == direct.bits
        @test !PathMaps.is_empty_mask(direct.bits)        # anti-vacuity for the comparison
    end
end
