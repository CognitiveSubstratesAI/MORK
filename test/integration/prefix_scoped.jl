# test/integration/prefix_scoped.jl
#
# Prefix-scoped (byte-region) multi-space primitives — PRIMUS-original
# (upstream MORK scopes by thread-id, not byte-prefix region).
#
#   space_query_multi_at(btm, prefix, pat, effect)   — region-anchored query
#   space_metta_calculus_in_prefix!(s, prefix, n)    — region-scoped exec (Stage A:
#                                                       comma/comma form)
#
# Both must isolate to their prefix region and never leak the raw prefix bytes
# into expression decoding (the bug the anchored PathMap ProductZipper fixed).

using MORK, Test
using PathMaps: UNIT_VAL, set_val_at!, read_zipper_at_path, zipper_to_next_val!, zipper_path
using MORK: new_space, sexpr_to_expr, expr_serialize,
    space_query_multi_at, space_metta_calculus_in_prefix!

# Store `sexpr` at  prefix ++ encoded(sexpr)  (the Core multi-space convention).
_addp(btm, prefix, sexpr) =
    set_val_at!(btm, vcat(Vector{UInt8}(prefix), sexpr_to_expr(sexpr).buf), UNIT_VAL)

# Serialize the anchor-relative atoms under `prefix` (space_dump_all_sexpr can't
# be used — it walks root and chokes on the raw prefix bytes).
function _dump_prefix(btm, prefix)
    out = String[]
    rz = read_zipper_at_path(btm, Vector{UInt8}(prefix))
    while zipper_to_next_val!(rz)
        push!(out, expr_serialize(collect(zipper_path(rz))))
    end
    sort!(out)
end

@testset "prefix-scoped query — region isolation, no prefix-byte leak" begin
    s = new_space()
    _addp(s.btm, "a/", "(foo 1)")
    _addp(s.btm, "a/", "(bar 1)")
    _addp(s.btm, "b/", "(foo 2)")
    _addp(s.btm, "b/", "(bar 2)")
    pat = sexpr_to_expr("(, (foo \$x) (bar \$x))")

    function joins(prefix)
        out = String[]
        space_query_multi_at(
            s.btm,
            Vector{UInt8}(prefix),
            pat,
            (b, path) -> begin
                buf = path isa MORK.Expr ? path.buf : collect(UInt8, path)
                push!(out, expr_serialize(buf))
                true
            end
        )
        sort!(out)
    end

    @test joins("a/") == ["(foo 1) (bar 1)"]   # only region a, x=1
    @test joins("b/") == ["(foo 2) (bar 2)"]   # only region b, x=2
    # no result carries the raw prefix byte 'a'/'b'
    @test !any(r -> occursin(r"^[ab]/", r), joins("a/"))
end

@testset "prefix-scoped calculus (Stage A comma/comma) — exec stays in region" begin
    s = new_space()
    _addp(s.btm, "a/", "(item x)")
    _addp(s.btm, "a/", "(item y)")
    _addp(s.btm, "a/", "(exec 0 (, (item \$v)) (, (seen \$v)))")
    _addp(s.btm, "b/", "(item z)")   # other region — must be untouched

    n = space_metta_calculus_in_prefix!(s, Vector{UInt8}("a/"), 1000)
    @test n == 1                                            # the exec atom ran
    a_after = _dump_prefix(s.btm, "a/")
    @test "(seen x)" in a_after                             # result written in-region
    @test "(seen y)" in a_after
    @test _dump_prefix(s.btm, "b/") == ["(item z)"]         # region b isolated
end

@testset "prefix-scoped calculus (Stage B O-sink) — CountSink stays in region" begin
    # An O-sink (CountSink) exec under "c/" must count only c/ atoms and write
    # its result under "c/", via the PrefixBtm wrapper — region "d/" untouched.
    s = new_space()
    _addp(s.btm, "c/", "(item x)")
    _addp(s.btm, "c/", "(item y)")
    _addp(s.btm, "c/", "(item z)")
    _addp(s.btm, "c/", "(exec 0 (, (item \$v)) (O (count (n \$k) \$k \$v)))")
    _addp(s.btm, "d/", "(item p)")   # other region — must be untouched + not counted

    n = space_metta_calculus_in_prefix!(s, Vector{UInt8}("c/"), 1000)
    @test n == 1
    c_after = _dump_prefix(s.btm, "c/")
    @test "(n 3)" in c_after                          # counted x,y,z = 3 (only region c)
    @test _dump_prefix(s.btm, "d/") == ["(item p)"]   # region d isolated, uncounted
end

@testset "prefix-scoped calculus — empty prefix == root calculus" begin
    # Sanity: empty prefix delegates to space_metta_calculus! (root path).
    s = new_space()
    space_add_all_sexpr!(
        s,
        """
(item p) (item q)
(exec 0 (, (item \$v)) (, (seen \$v)))
"""
    )
    n = space_metta_calculus_in_prefix!(s, UInt8[], 1000)
    @test n >= 1
    out = space_dump_all_sexpr(s)
    @test occursin("(seen p)", out) && occursin("(seen q)", out)
end
