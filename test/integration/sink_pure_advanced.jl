# sink_pure_advanced.jl — ports of remaining sink_pure_* tests from kernel/src/main.rs
using MORK, Test

all_lines(s) = Set(filter(!isempty, split(space_dump_all_sexpr(s), "\n")))

function mc(src, steps=typemax(Int))
    s = new_space()
    space_add_all_sexpr!(s, src)
    space_metta_calculus!(s, steps)
    s
end

# ── sink_pure_quote_collapse_symbol ──────────────────────────────────
# Mirrors fn sink_pure_quote_collapse_symbol in main.rs.
# (collapse_symbol ('(_ $x _ bar))) with $x=foo → _foo_bar
@testset "sink_pure_quote_collapse_symbol" begin
    s = mc("""
(mysym foo)
(exec 0 (, (mysym \$x))
        (O (pure (myconcat \$i) \$i (collapse_symbol ('(_ \$x _ bar)) )))
)
""")
    lines = all_lines(s)
    @test "(myconcat _foo_bar)" in lines
end

# ── sink_pure_dynamic_subformula ─────────────────────────────────────
# Mirrors fn sink_pure_dynamic_subformula in main.rs.
# normalize rule is matched as a second sub-pattern; the formula $normalized
# is the entire (div_f64 ...) expression evaluated by PureSink.
@testset "sink_pure_dynamic_subformula (f64 normalize rule)" begin
    s = mc(
        """
(inputfile 0 (arg 1390) (arg 0.9257))
(inputfile 1 (arg 3490) (arg 1.2329))

(normalize \$e (div_f64 (sum_f64 (f64_from_string 1.0) \$e) (f64_from_string 10.0)))

(exec 0
  (, (inputfile \$i (arg \$x) (arg \$y))
     (normalize (product_f64 (i64_as_f64 (i64_from_string \$x)) (f64_from_string \$y)) \$normalized))
  (O (pure (result \$i \$res) \$res (f64_to_string \$normalized)))
)
"""
    )
    lines = all_lines(s)
    @test any(contains(l, "result 0") for l in lines)
    @test any(contains(l, "result 1") for l in lines)
end

# ── sink_hash_expr ────────────────────────────────────────────────────
# Mirrors fn sink_hash_expr in main.rs.
# hash_expr produces a deterministic hash; exact value differs from upstream
# (upstream uses gxhash, we use Julia hash). Test that two distinct exprs
# produce distinct base64url results.
@testset "sink_hash_expr (deterministic distinct hashes)" begin
    s = mc("""
(myexpr (foo \$q \$q (bar baz)))
(myexpr symbols)
(exec 0 (, (myexpr \$x))
        (O (pure (result \$i) \$i (encode_base64url (i128_as_i64 (hash_expr (' \$x)))))))
""")
    lines = all_lines(s)
    result_lines = filter(l -> startswith(l, "(result "), lines)
    @test length(result_lines) == 2
    # Two distinct expressions → two distinct hash values
    @test length(Set(result_lines)) == 2
    # UPSTREAM BYTE PARITY (kernel/src/main.rs:1201-1225 asserts exactly these two strings).
    # Reachable since 2026-07-27: `Expr::hash()` is XXH3-128 (NOT gxhash — `#[cfg(gxhash)]` is a bare
    # cfg nothing sets, so the xxh3 stub at expr/src/lib.rs:76 is live), now ported in
    # src/kernel/XXH3.jl. Asserting the VALUES, not just distinctness — "two distinct hashes" passes
    # for any hash function at all and is exactly how a wrong digest would hide here.
    @test sort(String.(result_lines)) == ["(result XoicVnQv2bk)", "(result tspt4QCdRB8)"]
end

# ── sink_pure_dynamic_subformula (ip_sudoku subset) ───────────────────
# Ports the pure-ops arithmetic from ip_sudoku without the full constraint solver.
# Tests that i8 arithmetic ops (sum, product, div, mod) work in PureSink.
@testset "ip_sudoku pure arithmetic (dim=2, box coordinate)" begin
    s = mc(
        """
(dim 2)
(pos 0) (pos 1) (pos 2) (pos 3)
(exec 0 (, (dim \$b) (pos \$c) (pos \$r))
        (O (pure (box \$c \$co) \$co
             (tuple
               (i8_to_string (sum_i8 (product_i8 (i8_from_string \$b) (div_i8 (i8_from_string \$c) (i8_from_string \$b)))
                                     (div_i8 (i8_from_string \$r) (i8_from_string \$b))))
               (i8_to_string (sum_i8 (product_i8 (i8_from_string \$b) (mod_i8 (i8_from_string \$c) (i8_from_string \$b)))
                                     (mod_i8 (i8_from_string \$r) (i8_from_string \$b))))))))
"""
    )
    lines = all_lines(s)
    # box coordinates for (c=0,r=0) with dim=2: (2*(0/2)+0/2, 2*(0%2)+0%2) = (0,0)
    @test any(contains(l, "box 0") for l in lines)
    @test length(filter(l -> startswith(l, "(box "), lines)) > 0
end
