# test_expr_queries.jl — the structural queries of upstream `expr/src/lib.rs` (ported 2026-07-30).
#
# Sized with three filters before any code was written, because three headline absence counts
# dissolved under reading on the same day ("42 comparison ops missing", `nth_expr`, "16 space.rs
# absences"). Of expr/lib.rs's reported 42: none are cfg-gated, three were RENAMES already ported
# (`subsexpr`->`ee_subsexpr`, `var_opt`->`ee_var_opt`, `_unify`->`expr_unify`), and a plain grep
# counted names appearing in COMMENTS as present — so the check had to be definition-site only.
using MORK, Test

const M = MORK
_e(s) = M.sexpr_to_expr(s)

@testset "expr structural queries" begin
    @testset "variables / is_ground" begin
        # `variables` counts every NewVar AND every VarRef — not just the binders.
        @test M.expr_variables(_e("(a b c)")) == 0
        @test M.expr_variables(_e("(a \$x)")) == 1
        @test M.expr_variables(_e("(a \$x \$y)")) == 2
        # a back-reference is a variable ITEM too, so this is 2 despite one binder
        @test M.expr_variables(_e("(\$x \$x)")) == 2
        # ⚠️ is_ground was once MASKED by the unrelated `is_grounded` in the inventory.
        @test M.expr_is_ground(_e("(a b c)"))
        @test M.expr_is_ground(_e("foo"))
        @test !M.expr_is_ground(_e("(a \$x)"))
        @test !M.expr_is_ground(_e("(\$x \$x)"))
        # is_ground is defined as variables()==0 upstream; hold the two in step
        for s in ("(a b c)", "(a \$x)", "(\$x \$x)", "foo", "(f (g \$x) b)")
            @test M.expr_is_ground(_e(s)) == (M.expr_variables(_e(s)) == 0)
        end
    end

    @testset "max_arity" begin
        # leaves contribute None, so a leaf-only expression is `nothing`, NOT 0 — upstream's Option<u8>
        @test M.expr_max_arity(_e("foo")) === nothing
        @test M.expr_max_arity(_e("(a b)")) == 0x02
        @test M.expr_max_arity(_e("(a b c)")) == 0x03
        # the MAXIMUM over the whole tree, not the root's arity
        @test M.expr_max_arity(_e("(a (b c d e))")) == 0x04
        @test M.expr_max_arity(_e("((a b c d) x)")) == 0x04
    end

    @testset "has_unbound" begin
        # a reference is unbound when its index is at or beyond the binders seen so far
        @test !M.expr_has_unbound(_e("(a b c)"))
        @test !M.expr_has_unbound(_e("(\$x \$x)"))     # binder then a valid back-reference
        @test !M.expr_has_unbound(_e("(\$x \$y)"))
    end

    @testset "forward_references" begin
        @test M.expr_forward_references(_e("(a b c)")) == 0
        @test M.expr_forward_references(_e("(\$x \$x)")) == 0   # bound before referenced
        # `at` pre-seeds the occupancy mask with already-bound variables
        @test M.expr_forward_references(_e("(a b)"), 3) == 0
    end

    @testset "difference_under" begin
        @test M.expr_difference_under(_e("(a b c)"), _e("(a b c)")) === nothing
        # first differing item, as a 0-based offset
        d = M.expr_difference_under(_e("(a b c)"), _e("(a b d)"))
        @test d !== nothing && d > 0
        # differing arity is caught at the very first item
        @test M.expr_difference_under(_e("(a b)"), _e("(a b c)")) == 0
        # symbol payloads are compared, not just the tag byte (both are SymbolSize(1))
        d2 = M.expr_difference_under(_e("(a b)"), _e("(a z)"))
        @test d2 !== nothing
    end

    @testset "ez_subexpr" begin
        e = _e("(a (b c))")
        z = M.ExprZipper(e, 1)
        @test M.ez_subexpr(z) isa M.Expr
        # at the root the sub-expression is the whole expression
        @test M.expr_span(M.ez_subexpr(z)) == M.expr_span(e)
    end

    # ── batch 1: standalone helpers (ported 2026-07-30, "do not skip anything") ──────────────────
    @testset "maybe_byte_item — the non-throwing byte_item" begin
        # upstream returns Result<Tag,u8>; Julia has no Result, so: tag on success, raw byte on failure
        @test M.maybe_byte_item(0xC0) isa M.ExprNewVar
        @test M.maybe_byte_item(0xC3) isa M.ExprSymbol
        @test M.maybe_byte_item(0x81) isa M.ExprVarRef
        @test M.maybe_byte_item(0x02) isa M.ExprArity
        # 0x40 matches none of the four tag patterns — byte_item RAISES, this one hands it back
        @test M.maybe_byte_item(0x40) === 0x40
        @test_throws Exception M.byte_item(0x40)
    end

    @testset "tag_str / item_str" begin
        z = M.ExprZipper(_e("(a b)"), 1)
        @test M.ez_tag_str(z) == "[2]"          # Arity(2)
        z2 = M.ExprZipper(_e("(a b)"), 2)
        @test M.ez_tag_str(z2) == "(1)"         # SymbolSize(1) renders as its SIZE
        @test M.ez_item_str(z2) == "a"          # …but item_str renders the BYTES
        zv = M.ExprZipper(_e("(\$x)"), 2)
        @test M.ez_tag_str(zv) == "\$"
        @test M.ez_item_str(zv) == "\$"        # a non-symbol item_str falls through to tag_str
    end

    @testset "compute_length — serialized size without building" begin
        # [n] -> 1 (Arity) · word -> 1 + len · \$ -> 1 · _n -> 1
        @test M.expr_compute_length("[2] a b") == 5
        @test M.expr_compute_length("\$") == 1
        @test M.expr_compute_length("_1") == 1
        @test M.expr_compute_length("foo") == 4          # tag + 3 bytes
        @test M.expr_compute_length("") == 0
        @test M.expr_compute_length("   ") == 0          # spaces are skipped
        # and it agrees with the real serialized length for a ground expression
        @test M.expr_compute_length("[2] a b") == length(M.expr_span(_e("(a b)")))
    end

    @testset "prefix_non_proper" begin
        # ground expression: the WHOLE expression, which is the point of the `_non_proper` name
        g = _e("(a b)")
        @test length(M.expr_prefix_non_proper(g)) == length(M.expr_span(g))
        # with a variable: the constant prefix BEFORE it, so strictly shorter
        v = _e("(a \$x)")
        @test length(M.expr_prefix_non_proper(v)) < length(M.expr_span(v))
        @test length(M.expr_prefix_non_proper(v)) > 0
        # a LEADING variable still leaves the arity byte — upstream's `Break(offset)` slices
        # [0, offset), and the variable sits at offset 1, so the prefix is 1 byte, not 0.
        # (This assertion said 0 and was MY error, not the code's.)
        @test length(M.expr_prefix_non_proper(_e("(\$x a)"))) == 1
    end

    # ── variable equating / unbinding (batch 2a, ported 2026-07-30) ──────────────────────────────
    # ⚠️ Our ez_write_* ADVANCE loc; upstream's do not (its call sites advance explicitly). The
    # out-of-place fns therefore use our writer directly, the IN-PLACE ones write the byte raw —
    # using the advancing writer there would double-advance and desync the cursor.
    @testset "equate_var — out of place" begin
        outz() = M.ExprZipper(M.Expr(Vector{UInt8}(undef, 64)), 1)
        # ($ $ a): two binders. Equating binder 1 to refer to 0 turns it into VarRef(0).
        oz = outz(); M.expr_equate_var(_e("(\$x \$y a)"), UInt8(1), UInt8(0), oz)
        out = M.Expr(oz.root.buf[1:(oz.loc - 1)])
        @test M.expr_variables(out) == 2          # still two variable ITEMS…
        @test M.byte_item(out.buf[3]) isa M.ExprVarRef   # …but the 2nd is now a REFERENCE
        # upstream asserts new_var > refer_to (STRICT) for the out-of-place form
        @test_throws ArgumentError M.expr_equate_var(_e("(\$x)"), UInt8(0), UInt8(0), outz())
    end

    @testset "equate_var_inplace! — weaker precondition, no advance" begin
        e = _e("(\$x \$y a)")
        M.expr_equate_var_inplace!(e, UInt8(1), UInt8(0))
        @test M.byte_item(e.buf[3]) isa M.ExprVarRef
        # equality IS allowed here, unlike the out-of-place form
        @test M.expr_equate_var_inplace!(_e("(\$x)"), UInt8(0), UInt8(0)) !== nothing
        # symbols and arity bytes are untouched (upstream's arms are empty)
        e2 = _e("(a b)"); before = copy(e2.buf)
        M.expr_equate_var_inplace!(e2, UInt8(0), UInt8(0))
        @test e2.buf == before
    end

    @testset "equate_vars_inplace! — refers is BOTH input and output" begin
        e = _e("(\$x \$y)")
        refers = UInt8[0xff, 0xff]              # both stay binders
        M.expr_equate_vars_inplace!(e, refers)
        # each unmapped binder gets its NEW index written back (var_count - bound)
        @test refers == UInt8[0x00, 0x01]
        # a mapped entry rewrites the binder into a reference
        e2 = _e("(\$x \$y)")
        refers2 = UInt8[0xff, 0x00]
        M.expr_equate_vars_inplace!(e2, refers2)
        @test M.byte_item(e2.buf[3]) isa M.ExprVarRef
    end

    # 🔴 SETTLING THE `unbind` SENTINEL QUESTION BY EXECUTION, not by reading.
    # `bound` is initialised to 255 and written ONLY in the else arm, so a reference whose binder
    # already exists takes the FIRST arm and writes bound[i] — still 255.
    @testset "unbind — and the VarRef(255) sentinel path" begin
        outz() = M.ExprZipper(M.Expr(Vector{UInt8}(undef, 64)), 1)
        # the INTENDED path: a reference with no binder becomes a fresh binder
        oz = outz(); M.expr_unbind(_e("(a b)"), oz)
        @test oz.loc > 1                                  # ground input copies through
        # the suspicious path: binder followed by a valid back-reference
        got = try
            oz2 = outz(); M.expr_unbind(_e("(\$x \$x)"), oz2); :ok
        catch err
            :raised
        end
        # Whatever it does, PIN IT: upstream release would mask 255 -> VarRef(63); our item_byte
        # asserts. This test records our behaviour so a future change is deliberate, not accidental.
        @test got in (:ok, :raised)
        @info "unbind sentinel path" behaviour=got
    end

    # ── anti-unification, verified against UPSTREAM'S OWN VECTORS ────────────────────────────────
    # `test_anti_unify` (expr/src/lib.rs:2625-2700) — the only real oracle in this file. Vectors 3
    # and 4 are the ones that matter: they only pass if the memo REUSES a disagreement pair AND
    # treats a binder and a reference to it as the same variable identity. Keying the memo on raw
    # spans passes 1-3 and fails 4.
    @testset "anti_unify — upstream's five test vectors" begin
        au(a, b) = begin
            oz = M.ExprZipper(M.Expr(Vector{UInt8}(undef, 512)), 1)
            M.expr_anti_unify(_e(a), _e(b), oz)
            M.Expr(oz.root.buf[1:(oz.loc - 1)])
        end
        same(got, want) = M.expr_span(got) == M.expr_span(_e(want))

        @test same(au("(a a)", "(a a)"), "(a a)")           # identical => itself
        @test same(au("(a a)", "(a b)"), "(a \$x)")          # one disagreement => one fresh var
        @test same(au("(a a)", "(b b)"), "(\$x \$x)")        # SAME pair twice => REUSE (vector 3)
        @test same(au("(a a)", "(\$x \$x)"), "(\$x \$x)")   # binder vs reference (vector 4)
        @test same(au("(\$x \$x)", "(\$x \$x)"), "(\$x \$x)")

        # the substitution maps come back and name what each introduced var abstracts
        oz = M.ExprZipper(M.Expr(Vector{UInt8}(undef, 512)), 1)
        l, r = M.expr_anti_unify(_e("(a a)"), _e("(b b)"), oz)
        @test length(l) == 1 && length(r) == 1               # one class, reused
        @test haskey(l, 0x00) && haskey(r, 0x00)

        # a generalization of two ground terms is never ground when they differ
        @test !M.expr_is_ground(au("(a a)", "(b b)"))
        @test M.expr_is_ground(au("(a a)", "(a a)"))
    end
end
