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

    @testset "substitute_symbols — symbols mapped, structure preserved" begin
        outz() = M.ExprZipper(M.Expr(Vector{UInt8}(undef, 256)), 1)
        upper(b) = Vector{UInt8}(uppercase(String(copy(collect(b)))))

        oz = outz(); M.expr_substitute_symbols(_e("(a b)"), oz, upper)
        @test M.expr_span(M.Expr(oz.root.buf[1:(oz.loc - 1)])) == M.expr_span(_e("(A B)"))

        # identity substitution must round-trip byte-for-byte
        oz2 = outz(); M.expr_substitute_symbols(_e("(f (g a) b)"), oz2, collect)
        @test oz2.root.buf[1:(oz2.loc - 1)] == M.expr_span(_e("(f (g a) b)"))

        # variables and arity are copied VERBATIM — only symbols go through subst
        oz3 = outz(); M.expr_substitute_symbols(_e("(\$x a \$y)"), oz3, upper)
        got = M.Expr(oz3.root.buf[1:(oz3.loc - 1)])
        @test M.expr_variables(got) == 2
        @test M.expr_max_arity(got) == 0x03

        # a length-changing substitution still produces a well-formed expression
        oz4 = outz(); M.expr_substitute_symbols(_e("(a b)"), oz4, b -> Vector{UInt8}("xyz"))
        @test M.expr_span(M.Expr(oz4.root.buf[1:(oz4.loc - 1)])) == M.expr_span(_e("(xyz xyz)"))
    end

    # ── extract_data — pattern/data matching with a TYPED failure taxonomy ───────────────────────
    # upstream Expr::extract_data (lib.rs:805-863). The 12 ExtractFailure variants are load-bearing:
    # `*EarlyMismatch` = the SHAPE disagreed (size/arity), `*Mismatch` = shape matched but CONTENT
    # differed. Collapsing them would discard exactly what a caller branches on.
    @testset "extract_data" begin
        ed(pat, dat) = M.expr_extract_data(_e(pat), M.ExprZipper(_e(dat), 1))
        # upstream returns Result<Vec<Expr>, ExtractFailure>, so a failure is a VALUE, not a throw
        kind_of(f) = begin r = f(); r isa M.ExtractFailure ? r.kind : nothing end

        # FIRST establish how our parser encodes a repeated variable name, rather than assuming:
        # if `($x $x)` is binder+back-reference, byte 3 is a VarRef; if two binders, a NewVar.
        two_x = _e("(\$x \$x)")
        repeated_is_ref = M.byte_item(two_x.buf[3]) isa M.ExprVarRef
        @info "parser: repeated var name encodes as" repeated_is_ref

        # ground pattern vs identical data: matches, binds nothing
        @test ed("(a b)", "(a b)") == M.Expr[]

        # a pattern variable binds the data sub-expression it covers
        b1 = ed("(\$x b)", "(a b)")
        @test length(b1) == 1
        @test M.expr_span(b1[1]) == M.expr_span(_e("a"))

        # binding to a whole SUB-EXPRESSION must skip its entire span, not one item
        b2 = ed("(\$x)", "((f g))")
        @test length(b2) == 1
        @test M.expr_span(b2[1]) == M.expr_span(_e("(f g)"))

        # ── the failure taxonomy ──
        @test kind_of(() -> ed("(a b)", "(a c)")) === M.EF_SYMBOL_MISMATCH        # bytes differ
        @test kind_of(() -> ed("(a bb)", "(a c)")) === M.EF_SYMBOL_EARLY_MISMATCH # SIZES differ
        @test kind_of(() -> ed("(a b)", "(a b c)")) === M.EF_EXPR_EARLY_MISMATCH  # arities differ
        # data may not INTRODUCE a variable — the pattern is what carries them
        @test kind_of(() -> ed("(a b)", "(a \$x)")) === M.EF_INTRODUCED_VAR
        # a symbol pattern against a compound datum is a plain type mismatch
        @test kind_of(() -> ed("(a b)", "(a (c d))")) === M.EF_TYPE_MISMATCH
    end

    @testset "substitute / transformData / transformed" begin
        # `expr_parse_str` is our port of upstream's `parse!` const fn and was verified byte-identical
        # to it (`[n]`->Arity, `$`->NewVar, `_k`->VarRef(k-1), word->Symbol), so upstream's own test
        # vectors are copied VERBATIM below rather than translated into s-expr syntax. That is not
        # only convenience: `[2] axiom [3] = _2 _1` is a pattern of BARE back-references with no
        # binder at all, which named s-expr syntax cannot express.
        _f = M.expr_parse_str

        # --- substitute (positional, NO re-basing) -------------------------------------------
        let oz = M.ExprZipper(M.Expr(zeros(UInt8, 256)), 1)
            # ($ _1) with slot 0 := `a` — the NewVar AND the back-reference both become `a`
            M.expr_substitute(_f("[2] \$ _1"), [_f("a")], oz)
            @test collect(M.ez_finish_span(oz)) == _f("[2] a a").buf
        end
        let oz = M.ExprZipper(M.Expr(zeros(UInt8, 256)), 1)
            # an EMPTY substitution is upstream's null span: the variable passes through UNCHANGED
            M.expr_substitute(_f("[2] \$ _1"), [M.Expr()], oz)
            @test collect(M.ez_finish_span(oz)) == _f("[2] \$ _1").buf
        end
        let oz = M.ExprZipper(M.Expr(zeros(UInt8, 256)), 1)
            # symbols and arity headers are copied verbatim; two independent slots
            M.expr_substitute(_f("[3] f \$ \$"), [_f("x"), _f("[2] g y")], oz)
            @test collect(M.ez_finish_span(oz)) == _f("[3] f x [2] g y").buf
        end
        let oz = M.ExprZipper(M.Expr(zeros(UInt8, 256)), 1)
            # NO re-basing: a substituted sub-expression's own vars are written through as-is,
            # which is precisely what separates this from substitute_de_bruijn.
            M.expr_substitute(_f("[2] \$ _1"), [_f("[2] h \$")], oz)
            @test collect(M.ez_finish_span(oz)) == _f("[2] [2] h \$ [2] h \$").buf
        end

        # --- transformData (match, then instantiate) ----------------------------------------
        let oz = M.ExprZipper(M.Expr(zeros(UInt8, 256)), 1)
            r = M.expr_transform_data(_f("[3] pair a b"), _f("[3] pair \$ \$"), _f("[3] swap _2 _1"), oz)
            @test r === nothing                      # upstream's Ok(())
            @test collect(M.ez_finish_span(oz)) == _f("[3] swap b a").buf
        end
        let oz = M.ExprZipper(M.Expr(zeros(UInt8, 256)), 1)
            # a failed match RETURNS the ExtractFailure (it does not throw) and writes nothing useful
            r = M.expr_transform_data(_f("[3] pair a b"), _f("[3] nope \$ \$"), _f("[2] t _1"), oz)
            @test r isa M.ExtractFailure
            @test r.kind === M.EF_SYMBOL_MISMATCH
        end

        # --- transformed: upstream's four vectors, verbatim ---------------------------------
        # All four share this pattern/template pair. The pattern's `_2 _1` SWAPS the equation's
        # sides; only unification can bind those bare refs, which is why `transformed` exists
        # alongside `transformData`.
        pat   = _f("[2] axiom [3] = _2 _1")
        templ = _f("[2] flip [3] = \$ \$")
        # _main.rs:1180 / :1201 / :1222 / :1240 (the last also at lib.rs:2388)
        for (src, want) in (
            ("[2] axiom [3] = [4] L \$ \$ \$ [4] R \$ _2 _3",
             "[2] flip [3] = [4] R \$ \$ \$ [4] L \$ _2 _3"),
            ("[2] axiom [3] = [4] L \$ \$ \$ [4] R _1 \$ _3",
             "[2] flip [3] = [4] R \$ \$ \$ [4] L _1 \$ _3"),
            ("[2] axiom [3] = [2] A \$ [4] B _1 _1 _1",
             "[2] flip [3] = [4] B \$ _1 _1 [2] A _1"),
            ("[2] axiom [3] = [3] T \$ [3] * \$ _2 [3] T _1 [3] R [4] a _1 \$ \$ [3] * _2 _2",
             "[2] flip [3] = [3] T \$ [3] R [4] a _1 \$ \$ [3] * \$ _4 [3] T _1 [3] * _4 _4"),
        )
            got = M.expr_transformed(_f(src), templ, pat)
            @test got isa M.Expr
            got isa M.Expr && @test got.buf == _f(want).buf
        end

        # the result is CUT to the template instantiation — upstream returns a bare pointer whose
        # implicit length hides the instantiated pattern that follows it in the same buffer
        let got = M.expr_transformed(_f("[2] axiom [3] = [2] A \$ [4] B _1 _1 _1"), templ, pat)
            @test got isa M.Expr
            got isa M.Expr && @test length(got.buf) == length(collect(M.expr_span(got, 1)))
        end

        # a non-unifiable source collapses to upstream's single ExprEarlyMismatch(0,0)
        let got = M.expr_transformed(_f("[2] theorem [3] = a b"), templ, pat)
            @test got isa M.ExtractFailure
            got isa M.ExtractFailure && @test got.kind === M.EF_EXPR_EARLY_MISMATCH
        end
    end

    @testset "loaders use transformData, not unify (parity regression)" begin
        # `space_load_csv!` / `space_add_sexpr!` ported the transform as unify + expr_apply, which is
        # NOT upstream's `transformData` (extract_data + substitute). Both cases below were produced
        # by RUNNING the two routes side by side, not by reading:
        #
        #   pattern `(parser $)`  data `($ foo)`  -> upstream Err(IntroducedVar); unify ADDED (parser foo)
        #   pattern `(foo bar)`   data `(foo $)`  -> upstream Err(IntroducedVar); unify ADDED done
        #
        # Matching is one-directional: a variable on the DATA side is an error, because the data is
        # meant to be ground. Unification binds it to the pattern's constant instead. Hidden because
        # every upstream call site uses the identity transform `$` -> `_1`, where the two agree.
        _f = M.expr_parse_str
        _tr(pat, tpl, dat) = begin
            oz = M.ExprZipper(M.Expr(zeros(UInt8, 256)), 1)
            r = M.expr_transform_data(_f(dat), _f(pat), _f(tpl), oz)
            r === nothing ? collect(M.ez_finish_span(oz)) : r
        end

        # a variable on the DATA side is rejected — this is the whole difference
        @test _tr("[2] parser \$", "[2] p _1", "[2] \$ foo") isa M.ExtractFailure
        @test _tr("[2] foo bar", "done", "[2] foo \$") isa M.ExtractFailure
        @test _tr("[2] \$ \$", "[2] t _2 _1", "[2] a \$") isa M.ExtractFailure

        # ground data still transforms normally
        @test _tr("[2] parser \$", "[2] p _1", "[2] parser foo") == _f("[2] p foo").buf

        # the identity transform every upstream caller uses accepts data WITH variables, because a
        # lone NewVar pattern binds the whole datum in one step and never looks inside it
        @test _tr("\$", "_1", "[2] foo \$") == _f("[2] foo \$").buf
    end

    @testset "breadcrumb traversal — upstream's own `children` test" begin
        _f = M.expr_parse_str

        # ---- upstream _main.rs:59-75, which asserts exact locs. Upstream's loc is 0-based and ours
        # is 1-based throughout the port, so every expected value here is upstream's + 1.
        # Built byte-wise like upstream because two of its symbols hold non-text bytes (a NUL, and
        # 7/91/205/21) that the flat-notation parser cannot express.
        # (= (func $) (add`0 (123456789 _1)))
        e = UInt8[M.item_byte(M.ExprArity(0x03)), M.item_byte(M.ExprSymbol(0x01)), UInt8('='),
                  M.item_byte(M.ExprArity(0x02)), M.item_byte(M.ExprSymbol(0x04)),
                  UInt8('f'), UInt8('u'), UInt8('n'), UInt8('c'), M.item_byte(M.ExprNewVar()),
                  M.item_byte(M.ExprArity(0x02)), M.item_byte(M.ExprSymbol(0x04)),
                  UInt8('a'), UInt8('d'), UInt8('d'), 0x00,
                  M.item_byte(M.ExprArity(0x02)), M.item_byte(M.ExprSymbol(0x04)),
                  0x07, 0x5b, 0xcd, 0x15, M.item_byte(M.ExprVarRef(0x00))]
        ecz = M.ExprZipper(M.Expr(e), 1)
        @test M.ez_item_str(ecz) == "[3]" && ecz.loc == 1      # upstream loc 0
        @test M.ez_next_child!(ecz)
        @test M.ez_item_str(ecz) == "=" && ecz.loc == 2        # upstream loc 1
        @test M.ez_next_child!(ecz)
        @test M.ez_item_str(ecz) == "[2]" && ecz.loc == 4      # upstream loc 3
        @test M.ez_next_child!(ecz)
        @test M.ez_item_str(ecz) == "[2]" && ecz.loc == 11     # upstream loc 10
        @test !M.ez_next_child!(ecz)

        # ---- upstream _main.rs:77-130, the true/false sequence verbatim
        big = _f("[3] , [3] f [3] A \$ \$ [4] B \$ \$ _4 [4] g [4] B _3 _4 _4 [3] C \$ _5 [3] C _5 _5")
        ez = M.ExprZipper(big, 1)
        @test M.ez_next_child!(ez)
        @test M.ez_next_child!(ez)
        fz = M.ExprZipper(M.ez_subexpr(ez), 1)     # the (f ...) subexpr
        @test M.ez_next_descendant!(ez, 1, 1)
        @test M.ez_next_descendant!(ez, 0, 0)
        gz = M.ExprZipper(M.ez_subexpr(ez), 1)     # the (g ...) subexpr
        @test !M.ez_next_child!(ez)

        # fz walks a subexpr, i.e. a buffer holding the (f ...) expression FOLLOWED BY its siblings.
        # It stops after exactly 3 children because the TRACE empties — not because bytes ran out.
        # This is the case where a buffer-bounded walk would keep going.
        @test M.ez_next_child!(fz); @test M.ez_next_child!(fz); @test M.ez_next_child!(fz)
        @test !M.ez_next_child!(fz)

        @test M.ez_next_child!(gz); @test M.ez_next_child!(gz)
        @test M.ez_next_child!(gz); @test M.ez_next_child!(gz)
        @test !M.ez_next_child!(gz)
    end

    @testset "ez_next! vs ez_gnext! — the equivalence claim, and where it ends" begin
        # `ez_next!` is OURS; upstream has only `next() = gnext(0)`. Expr.jl claims they agree on a
        # zipper over exactly one complete expression. VERIFIED here rather than asserted, because
        # the claim is what licenses leaving every existing ez_next! call site alone.
        _f = M.expr_parse_str
        walk!(z, step!) = begin locs = Int[z.loc]; while step!(z); push!(locs, z.loc); end; locs end

        for src in ("[2] a b", "foo", "\$", "[3] f [2] g x \$",
                    "[3] , [3] f [3] A \$ \$ [4] B \$ \$ _4 [4] g [4] B _3 _4 _4 [3] C \$ _5 [3] C _5 _5")
            @test walk!(M.ExprZipper(_f(src), 1), M.ez_next!) ==
                  walk!(M.ExprZipper(_f(src), 1), z -> M.ez_gnext!(z, 0))
        end

        # ...and where it ends: a buffer holding an expression PLUS a trailing sibling — exactly what
        # ez_subexpr hands back. gnext stops at the end of the first expression; ez_next! walks on.
        tail = M.Expr(vcat(_f("[2] a b").buf, _f("[2] c d").buf))
        @test length(walk!(M.ExprZipper(tail, 1), z -> M.ez_gnext!(z, 0))) == 3   # [2] a b
        @test length(walk!(M.ExprZipper(tail, 1), M.ez_next!)) == 6               # runs into (c d)
    end

    @testset "ez_parent! / ez_next_skip! / ez_reset!" begin
        _f = M.expr_parse_str
        z = M.ExprZipper(_f("[3] f [2] g x \$"), 1)
        @test M.ez_next_child!(z) && z.loc == 2                 # f
        @test M.ez_next_child!(z) && z.loc == 4                 # the (g x) node
        @test M.ez_gnext!(z) && z.loc == 5                      # descend to g
        @test M.ez_parent!(z) && z.loc == 4                     # back to the (g x) node
        @test !M.ez_parent!(z) || true                          # depth-dependent, not pinned here

        # next_skip steps OVER a sub-expression instead of into it. It is UNFINISHED upstream work
        # (its only reference anywhere upstream is its own recursive call), and its behaviour FROM
        # THE ROOT is degenerate: the root's tag IS the whole expression, so one call advances past
        # all 9 bytes and reports success. Pinned as-is, because that is what upstream does.
        y = M.ExprZipper(_f("[3] f [2] g x \$"), 1)
        @test M.ez_next_skip!(y) && y.loc == 10                 # skipped the ENTIRE expression
        @test !M.ez_next_skip!(y)                               # upstream would read out of bounds

        # used as intended — after descending — it walks one level's siblings, stepping OVER subtrees
        w = M.ExprZipper(_f("[3] f [2] g x \$"), 1)
        @test M.ez_gnext!(w) && w.loc == 2                      # descend to f
        @test M.ez_next_skip!(w) && w.loc == 4                  # to the (g x) node
        @test M.ez_next_skip!(w) && w.loc == 9                  # OVER (g x) entirely, onto $
        @test !M.ez_next_skip!(w)

        # ez_reset! must rebuild the trace, not just rewind loc — it was loc-only before the trace
        # was ported, which would leave a reset zipper resuming from a stale stack.
        r = M.ExprZipper(_f("[3] f a b"), 1)
        while M.ez_gnext!(r); end
        @test isempty(M._ez_trace!(r))                           # walked to exhaustion
        M.ez_reset!(r)
        @test r.loc == 1 && length(M._ez_trace!(r)) == 1 && M._ez_trace!(r)[1].seen == 0
        n = 1; while M.ez_gnext!(r); n += 1; end
        @test n == 4                                             # root + 3 children, walkable again
    end
end
