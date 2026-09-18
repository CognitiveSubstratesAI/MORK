# unit_serialize_roundtrip.jl — MORK owns this property: `expr_serialize2` round-trips VARIABLE
# STRUCTURE; `expr_serialize` does not, and that is not a bug in either.
#
# ─── WHY THE ASSERTIONS COMPARE TAGS AND NEVER STRINGS ───────────────────────────────────────────
# `expr_serialize` is a FAITHFUL port of upstream's `serialize` (`NewVar => "$"`,
# `VarRef(r) => "_{r+1}"`, expr/src/lib.rs:1387-1388). By the MeTTa grammar a bare `$` is
# ungrammatical and `_1` matches `WORD -> SYMBOL`, so re-parsing its output turns a VarRef into a
# ground symbol. Upstream's own dump paths use `serialize2` for exactly this reason
# (space.rs:903/952), and `expr_varname` ignores the `intro` flag on purpose so a binder and every
# back-reference print the SAME name — Expr.jl:722-726, "which is what makes the output re-readable".
#
# 🔴 A STRING COMPARISON CANNOT SEE THE CORRUPTION. MEASURED 2026-09-18: `(g _1)` parses to
# `Sym("_1")` and serializes back to `"(g _1)"` — string-identical, structurally wrong. Only the TAG
# SEQUENCE distinguishes a VarRef from a symbol that prints like one.
#
# The corpus deliberately includes `NewVar NewVar VarRef(0)` — the three-variable shape. It is the
# one that exposed the worst case: `(p $x $y $x)` through `expr_serialize` comes back as
# `NewVar VarRef(0) Sym("_1")`, i.e. the two DISTINCT variables MERGED (both bare `$`, and MORK's
# frontend de-Bruijns by name) and the genuine back-reference became ground. Name loss is the
# advertised behaviour; silently merging distinct variables is what makes it unusable for round trips.

using MORK, Test

@testset "expr_serialize2 round-trips variable structure (expr_serialize does not)" begin
    # Structural tag walk. ⚠️ A Symbol's payload bytes are DATA — walking them as tags dies on
    # "reserved byte: 0x67" (the letter `g`). An earlier probe did exactly that.
    function tagwalk(e::MORK.Expr)
        out = String[]
        i = 1
        while i <= length(e.buf)
            t = byte_item(e.buf[i])
            if t isa ExprSymbol
                push!(out, "Sym(" * String(e.buf[(i + 1):(i + Int(t.size))]) * ")")
                i += 1 + Int(t.size)
            else
                push!(out, t isa ExprNewVar ? "NewVar" :
                           t isa ExprVarRef ? "VarRef$(Int(t.idx))" :
                           t isa ExprArity  ? "Arity$(Int(t.arity))" : "?")
                i += 1
            end
        end
        out
    end

    CORPUS = [
        "(f a b)",                    # ground — both serializers must agree
        "(g \$a)",                    # one binder
        "(g \$a \$a)",                # binder + back-reference
        "(p \$x \$y \$x)",            # 🔴 NewVar NewVar VarRef(0) — the merge case
        "(= (f \$x) \$x)",            # a rule, the shape the migration stores
        "(q \$a \$b \$c \$a \$c)",    # three binders, two back-references
        "(nest (in \$x) (out \$x))",  # co-reference ACROSS sibling subterms
    ]

    @testset "serialize2 is structure-preserving" begin
        for s in CORPUS
            e = sexpr_to_expr(s)
            rt = sexpr_to_expr(String(strip(expr_serialize2(e.buf))))
            @test tagwalk(rt) == tagwalk(e)
        end
    end

    @testset "serialize is NOT, for variable-bearing terms — pinned, not lamented" begin
        # Ground terms survive either way: the divergence is exactly the variables.
        g = sexpr_to_expr("(f a b)")
        @test tagwalk(sexpr_to_expr(String(strip(expr_serialize(g.buf))))) == tagwalk(g)

        # Every variable-bearing case loses structure. If a future change makes one of these
        # round-trip, that is NEWS — update the test rather than deleting it.
        for s in ("(g \$a \$a)", "(p \$x \$y \$x)", "(= (f \$x) \$x)")
            e = sexpr_to_expr(s)
            rt = sexpr_to_expr(String(strip(expr_serialize(e.buf))))
            @test tagwalk(rt) != tagwalk(e)
        end

        # …and specifically HOW it loses it, so the failure mode stays documented in code:
        e = sexpr_to_expr("(p \$x \$y \$x)")
        @test tagwalk(e) == ["Arity4", "Sym(p)", "NewVar", "NewVar", "VarRef0"]
        rt = sexpr_to_expr(String(strip(expr_serialize(e.buf))))
        @test tagwalk(rt) == ["Arity4", "Sym(p)", "NewVar", "VarRef0", "Sym(_1)"]
        #                                          ^^ $x and $y MERGED    ^^ back-ref went GROUND
    end

    @testset "a string comparison would MISS it — why these assertions use tags" begin
        # `_1` is the trap: it re-parses as a SYMBOL, and prints back identically.
        e = sexpr_to_expr("(g _1)")
        @test tagwalk(e) == ["Arity2", "Sym(g)", "Sym(_1)"]          # a SYMBOL, not a VarRef
        @test strip(expr_serialize(e.buf)) == "(g _1)"               # string round-trips…
        @test tagwalk(sexpr_to_expr("(g _1)")) == tagwalk(e)         # …and so the string test passes
    end
end
