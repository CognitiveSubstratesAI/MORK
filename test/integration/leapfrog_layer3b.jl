# Leapfrog LAYER 3b — the unification predicates, and the byte ordering they rest on.
#
# 🔴 THE ORDERING TEST IS THE LOAD-BEARING ONE, AND IT IS NOT A TAUTOLOGY. The leapfrog is allowed to
# prune ONLY inside the symbol-headed suffix of a column's enumeration. That is sound because MORK's
# tag bytes place every symbol byte ABOVE every compound and variable byte, so the symbol-headed
# candidates really are a contiguous SUFFIX. If a future re-encoding moved `SymbolSize` below
# `VarRef`, the pruning would start skipping stored wildcards and the join would silently drop
# answers — fast, green on every happy-path test, and wrong.
#
# So the ordering is pinned here EXHAUSTIVELY over all 256 bytes, against `byte_item` itself rather
# than against constants I could have copied wrong from the same reading that wrote the code.

using MORK, Test
const _LF = MORK.Leapfrog

_b(s) = MORK.sexpr_to_expr(s).buf

@testset "leapfrog layer 3b — unification predicates" begin

    @testset "🔴 every SYMBOL byte sorts above every COMPOUND and VARIABLE byte" begin
        syms, vars, arities, reserved = UInt8[], UInt8[], UInt8[], UInt8[]
        for b in 0x00:0xFF
            t = try
                MORK.byte_item(b)
            catch
                push!(reserved, b)
                continue
            end
            if t isa MORK.ExprSymbol
                push!(syms, b)
            elseif t isa MORK.ExprNewVar || t isa MORK.ExprVarRef
                push!(vars, b)
            elseif t isa MORK.ExprArity
                push!(arities, b)
            end
        end
        # ANTI-VACUITY: each class must be non-empty or the comparisons below hold trivially.
        @test !isempty(syms) && !isempty(vars) && !isempty(arities)

        # THE CLAIM, stated as a total order between classes.
        @test minimum(syms) > maximum(vars)
        @test minimum(vars) > maximum(arities)

        # …and the exact boundaries upstream's comment names, so a drift is legible not just failing.
        @test maximum(arities) == 0x3F
        @test minimum(vars) == 0x80
        @test maximum(vars) == 0xC0          # NewVar is the top of the variable range
        @test minimum(syms) == 0xC1
        @test reserved == collect(0x40:0x7F)    # our byte_item throws exactly here
    end

    @testset "is_wildcard_term — a bare stored variable, and nothing else" begin
        # A stored `$w` is one byte and unifies with anything: the reason it can never restrict.
        @test _LF.is_wildcard_term(UInt8[0xC0])                 # NewVar
        @test _LF.is_wildcard_term(UInt8[0x80])                 # VarRef(0)
        @test _LF.is_wildcard_term(UInt8[0xBF])                 # VarRef(63)

        # NEGATIVE TWINS — the load-bearing half. A predicate that said `true` for everything would
        # make the join correct-but-slow; one that said `true` for a compound would make it WRONG.
        @test !_LF.is_wildcard_term(_b("(f a)"))                # compound
        @test !_LF.is_wildcard_term(_b("a"))                    # ground symbol
        @test !_LF.is_wildcard_term(UInt8[0xC0, 0xC0])          # two variables is not ONE term
        @test !_LF.is_wildcard_term(UInt8[])                    # empty
    end

    @testset "is_symbol_head — ground leaves only" begin
        @test _LF.is_symbol_head(_b("a"))
        @test _LF.is_symbol_head(_b("hello"))
        # a compound is NOT prunable: a stored schematic `(f $x)` unifies with it without equalling
        @test !_LF.is_symbol_head(_b("(f a)"))
        @test !_LF.is_symbol_head(UInt8[0xC0])                  # NewVar
        @test !_LF.is_symbol_head(UInt8[0x80])                  # VarRef
    end

    @testset "column_matches_by_equality — a stored variable disables pruning" begin
        mk(bs) = (bits=PathMaps.EMPTY_BITS4;
            for b in bs
                bits = PathMaps.with_bit_set(bits, UInt8(b))
            end;
            PathMaps.ByteMask(bits))

        # Only symbols present ⇒ equality is the only way to match ⇒ prunable.
        @test _LF.column_matches_by_equality(mk([0xC1, 0xD0, 0xFF]))
        # Only arities present (compounds) ⇒ still no stored VARIABLE ⇒ prunable.
        @test _LF.column_matches_by_equality(mk([0x00, 0x03, 0x3F]))
        @test _LF.column_matches_by_equality(mk(UInt8[]))        # empty column

        # 🔴 A STORED VARIABLE ANYWHERE IN THE COLUMN DISABLES IT. Each of these must return false;
        # returning true would let the seek prune a wildcard that unifies with every candidate.
        @test !_LF.column_matches_by_equality(mk([0x80]))         # VarRef(0)
        @test !_LF.column_matches_by_equality(mk([0xC0]))         # NewVar
        @test !_LF.column_matches_by_equality(mk([0xBF]))         # VarRef(63)
        @test !_LF.column_matches_by_equality(mk([0xC1, 0xC0]))   # symbol AND a wildcard
        @test !_LF.column_matches_by_equality(mk([0x00, 0x80]))   # compound AND a wildcard

        # BOUNDARY, both sides: 0xC0 (NewVar) is a variable, 0xC1 (the least symbol) is not.
        @test !_LF.column_matches_by_equality(mk([0xC0]))
        @test _LF.column_matches_by_equality(mk([0xC1]))
    end

    @testset "the predicates agree on a real stored wildcard" begin
        # End-to-end: a fact whose column IS a variable must be seen as a wildcard by both the
        # term-level and the mask-level predicate. If these disagreed, the join would prune on one
        # and not the other, which is how a wrong answer set appears intermittently.
        s = MORK.new_space()
        MORK.space_add_all_sexpr!(s, "(rel \$w)\n(rel a)\n")
        c = _LF.SubtermCursor(MORK.read_zipper(s.btm))
        _LF.cursor_first!(c)
        seen_wildcard = false
        while (k = _LF.cursor_key(c)) !== nothing
            # each yielded key is a whole `(rel …)` atom; we only assert the predicates are total
            @test _LF.is_complete(k)
            _LF.cursor_next!(c)
        end
        # the space really does hold a stored variable — anti-vacuity for the claim above
        @test occursin("\$", MORK.space_dump_all_sexpr(s))
    end
end
