# Leapfrog RE-INDEXING — the pure column-permutation transform.
#
# 🔑 THE ROUND-TRIP IS THE ORACLE. `split -> items -> emit` under the IDENTITY permutation must
# reproduce the ORIGINAL BYTES EXACTLY. That single property exercises every part of the pipeline —
# span lengths, tag decoding, symbol payloads, the fact-global variable counter, and the renumbering
# — and it needs no hand-computed expected value, so it cannot be tuned to pass.
#
# ⚠️ WHY THIS LAYER IS TESTED APART FROM THE JOIN. A permutation bug does NOT error; it produces a
# well-formed key for the wrong fact, and the join then returns wrong answers with no complaint.
# The differential would catch it eventually, over shapes it happens to generate. This catches it at
# the transform, where the failure is legible. [[feedback_assert_the_contract_not_the_representation]]

using MORK, Test, Random
const _RI = MORK.Leapfrog

"The column bytes of `sexpr` — everything after the leading arity byte."
function _ri_colbytes(sexpr::AbstractString)
    buf = MORK.sexpr_to_expr(sexpr).buf
    @assert MORK.byte_item(buf[1]) isa MORK.ExprArity
    (buf[2:end], Int((MORK.byte_item(buf[1])::MORK.ExprArity).arity))
end

@testset "leapfrog re-indexing — the column permutation" begin

    @testset "🔑 IDENTITY permutation round-trips the bytes EXACTLY" begin
        for sx in ["(edge a b)", "(edge \$x \$y)", "(edge \$u \$u)", "(rel a \$x b)",
            "(rel (f a) \$y)", "(rel (f \$x) (g \$x))", "(e \$a \$b \$a)",
            "(deep (f (g \$x)) c)", "(sym-only x)"]
            (bytes, ncols) = _ri_colbytes(sx)
            cols = _RI.ri_split_columns(bytes, ncols)
            # the split must partition the bytes with nothing left over — a wrong span length would
            # silently shift every later column
            @test first(cols[1]) == 1
            @test last(cols[end]) == length(bytes)
            items = _RI.ri_columns_to_items(bytes, cols)
            out = _RI.ri_emit_reordered(items, collect(1:ncols))
            @test out == bytes                       # ⇐ the property this file exists for
        end
    end

    @testset "span lengths partition the fact, with no gaps or overlaps" begin
        for sx in ["(rel (f a) \$y c)", "(rel \$x (g (h b)) \$x)"]
            (bytes, ncols) = _ri_colbytes(sx)
            cols = _RI.ri_split_columns(bytes, ncols)
            @test length(cols) == ncols
            for k in 2:ncols                          # contiguous, in order
                @test first(cols[k]) == last(cols[k - 1]) + 1
            end
            @test sum(length, cols) == length(bytes)  # exhaustive
        end
    end

    @testset "🔴 COREFERENCE SURVIVES A PERMUTATION — `(e \$a \$b \$a)`" begin
        # A stored fact is numbered canonically IN COLUMN ORDER, so moving columns changes which
        # occurrence is the binder. Re-emitting the ORIGINAL bytes in a new order would leave the
        # repeated variable a VarRef to an id that no longer precedes it — a well-formed key for a
        # DIFFERENT fact, and no error anywhere.
        (bytes, ncols) = _ri_colbytes("(e \$a \$b \$a)")
        cols = _RI.ri_split_columns(bytes, ncols)
        items = _RI.ri_columns_to_items(bytes, cols)

        # cols are [e, $a, $b, $a]; the two `$a` columns must carry the SAME original id, and `$b`
        # a different one. That is the fact-global counter doing its job — a per-column counter
        # would make every column's first variable id 0.
        vars_of(c) = [it.var for it in items[c] if it.is_var]
        @test vars_of(2) == vars_of(4)                # both `$a`
        @test vars_of(2) != vars_of(3)                # `$b` is not `$a`
        @test length(vars_of(3)) == 1

        # …and after ANY permutation the emitted key is a VALID canonical encoding: the first
        # occurrence of each id is a NewVar, later ones VarRefs BACKWARD to an already-bound index.
        for order in ([1, 2, 3, 4], [1, 4, 3, 2], [1, 3, 2, 4], [1, 4, 2, 3])
            out = _RI.ri_emit_reordered(items, order)
            seen = 0
            for b in out
                t = MORK.maybe_byte_item(b)
                if t isa MORK.ExprNewVar
                    seen += 1
                elseif t isa MORK.ExprVarRef
                    @test Int(t.idx) < seen            # never a forward/dangling reference
                end
            end
            @test seen >= 1
        end
    end

    @testset "is_inverted flags exactly the out-of-schedule-order factors" begin
        # `var_pos[v+1]` = the level at which variable v is scheduled; ids run 0,1,2 in body order.
        var_pos = [1, 2, 3]
        v(i) = _RI.unify_var_col(i)
        head = _RI.unify_term_col(MORK.sexpr_to_expr("edge"))
        ground = _RI.unify_term_col(MORK.sexpr_to_expr("c"))

        @test _RI.is_inverted(_RI.UnifyFactor(UInt8[], [head, v(0), v(1)]), var_pos) ==
            false
        @test _RI.is_inverted(_RI.UnifyFactor(UInt8[], [head, v(2), v(0)]), var_pos) == true
        @test _RI.is_inverted(_RI.UnifyFactor(UInt8[], [head, v(0), v(0)]), var_pos) ==
            false
        # a GROUND column constrains nothing about ordering and must be skipped, not treated as 0
        @test _RI.is_inverted(_RI.UnifyFactor(UInt8[], [head, ground, v(1)]), var_pos) ==
            false
        @test _RI.is_inverted(
            _RI.UnifyFactor(UInt8[], [head, v(1), ground, v(0)]), var_pos
        ) == true
    end

    @testset "randomised round-trip — shapes nobody chose by hand" begin
        rng = MersenneTwister(0x21c0)
        syms = ["a", "b", "c"]
        for _ in 1:200
            arg() = (t=rand(rng);
                if t < 0.30
                    "\$v$(rand(rng, 0:2))"
                elseif t < 0.45
                    "(f \$v$(rand(rng, 0:1)))"
                elseif t < 0.60
                    "(g $(rand(rng, syms)))"
                else
                    rand(rng, syms)
                end)
            sx = "(rel " * join([arg() for _ in 1:rand(rng, 1:3)], " ") * ")"
            (bytes, ncols) = _ri_colbytes(sx)
            cols = _RI.ri_split_columns(bytes, ncols)
            items = _RI.ri_columns_to_items(bytes, cols)
            @test _RI.ri_emit_reordered(items, collect(1:ncols)) == bytes
        end
    end
end
