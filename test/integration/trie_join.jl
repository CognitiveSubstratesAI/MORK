# test/integration/trie_join.jl
#
# ADR-056 Lever A / P1 — assert the empty-tail trie-join (`trie_join_unary`, via `pmeet`)
# is EXACTLY equivalent to the naive ProductZipper route (run here through the exec
# calculus `(, (p $x) (q $x)) → (both $x)`), across overlap / disjoint / subset /
# identical / singleton shapes. The subset & identical cases exercise the `pmeet`
# AlgResIdentity branch (`_trie_meet` resolves it to the smaller-by-val_count input).
using MORK, PathMap, Test

# head-prefix of a unary relation = common prefix of two atoms with different-length args
# (so the common prefix stops at the relation head, before the argument).
_head_prefix(h) = begin
    a = sexpr_to_expr("($h a)").buf; b = sexpr_to_expr("($h bb)").buf
    k = 0; n = min(length(a), length(b))
    while k < n && a[k+1] == b[k+1]; k += 1; end
    a[1:k]
end

# exec-route reference: result $x bindings of (, (p $x) (q $x)) over the given ranges
function _exec_ref(Pr, Qr)
    s = new_space(); io = IOBuffer()
    for k in Pr; print(io, "(p k$k)\n"); end
    for k in Qr; print(io, "(q k$k)\n"); end
    space_add_all_sexpr!(s, String(take!(io)))
    space_add_all_sexpr!(s, "(exec 0 (, (p \$x) (q \$x)) (, (both \$x)))\n")
    space_metta_calculus!(s, 10_000_000)
    Set(m.captures[1] for m in eachmatch(r"\(both (k\d+)\)", space_dump_all_sexpr(s)))
end

# build a space holding just the p/q facts (no exec) for the trie-join path
function _facts(Pr, Qr)
    s = new_space(); io = IOBuffer()
    for k in Pr; print(io, "(p k$k)\n"); end
    for k in Qr; print(io, "(q k$k)\n"); end
    space_add_all_sexpr!(s, String(take!(io))); s
end

@testset "TrieJoin P1 — empty-tail join ≡ ProductZipper (exec route)" begin
    cases = [("overlap",   0:99, 50:149),
             ("disjoint",  0:49, 100:149),
             ("p⊂q",       0:49, 0:99),     # AlgResIdentity (meet = p)
             ("q⊂p",       0:99, 0:49),     # AlgResIdentity (meet = q)
             ("identical", 0:99, 0:99),     # AlgResIdentity (meet = either)
             ("singleton", 5:5,  5:5)]
    hp_p = _head_prefix("p")
    arg_enc(v) = (e = sexpr_to_expr("(p $v)").buf; e[length(hp_p)+1:end])
    for (lbl, Pr, Qr) in cases
        ref = _exec_ref(Pr, Qr)
        j   = trie_join_unary(_facts(Pr, Qr).btm, [_head_prefix("p"), _head_prefix("q")])
        @testset "$lbl" begin
            @test val_count(j) == length(ref)                          # same cardinality
            @test all(v -> get_val_at(j, arg_enc(v)) !== nothing, ref) # every ref binding present
        end
    end

    # commutativity + the n-ary path (3 relations) for good measure
    @testset "three-way + order independence" begin
        s = new_space()
        space_add_all_sexpr!(s, join(["(p k$k)" for k in 0:99], "\n") * "\n")
        space_add_all_sexpr!(s, join(["(q k$k)" for k in 50:149], "\n") * "\n")
        space_add_all_sexpr!(s, join(["(r k$k)" for k in 60:120], "\n") * "\n")  # ∩ = 60..99 = 40
        hp = _head_prefix
        @test val_count(trie_join_unary(s.btm, [hp("p"), hp("q"), hp("r")])) == 40
        @test val_count(trie_join_unary(s.btm, [hp("r"), hp("q"), hp("p")])) == 40
    end
end

@testset "TrieJoin P2 — binary key-rotation join (vs hand-computed truth)" begin
    # graph: 2-paths x→y→z over these edges.  via y=2: 1→{4,5}; via y=3: 1→{4} ⇒ 3 triples
    s = new_space()
    space_add_all_sexpr!(s, "(edge 1 2)\n(edge 1 3)\n(edge 2 4)\n(edge 3 4)\n(edge 2 5)\n")
    pat = sexpr_to_expr("(, (edge \$x \$y) (edge \$y \$z))")
    c = Ref(0); space_query_multi(s.btm, pat, (b, cc) -> (c[] += 1; true))
    @test c[] == 3                                  # (1,2,4) (1,2,5) (1,3,4)

    # exec derivation through the calculus → distinct (path2 x z)
    space_add_all_sexpr!(s, "(exec 0 (, (edge \$x \$y) (edge \$y \$z)) (, (path2 \$x \$z)))\n")
    space_metta_calculus!(s, 1_000_000)
    p2 = sort([strip(l) for l in split(space_dump_all_sexpr(s), '\n') if startswith(strip(l), "(path2 ")])
    @test p2 == ["(path2 1 4)", "(path2 1 5)"]

    # different relation heads, shared middle var
    s2 = new_space(); space_add_all_sexpr!(s2, "(a 1 2)\n(a 3 2)\n(b 2 9)\n")
    c2 = Ref(0); space_query_multi(s2.btm, sexpr_to_expr("(, (a \$x \$y) (b \$y \$z))"), (b, cc) -> (c2[] += 1; true))
    @test c2[] == 2                                 # (1,2,9) (3,2,9)

    # NO shared variable ⇒ must fall through to ProductZipper (full product), not P2
    c3 = Ref(0); space_query_multi(s2.btm, sexpr_to_expr("(, (a \$x \$y) (b \$z \$w))"), (b, cc) -> (c3[] += 1; true))
    @test c3[] == 2                                 # 2 a-atoms × 1 b-atom
end

@testset "TrieJoin P3 — n-ary chain join (vs hand-computed truth)" begin
    # 3-chain x→y→z→w over: a→b→{c,d}→e  ⇒  a→b→c→e, a→b→d→e  (2 paths)
    s = new_space()
    space_add_all_sexpr!(s, "(edge a b)\n(edge b c)\n(edge b d)\n(edge c e)\n(edge d e)\n")
    pat = sexpr_to_expr("(, (edge \$x \$y) (edge \$y \$z) (edge \$z \$w))")
    c = Ref(0); space_query_multi(s.btm, pat, (b, cc) -> (c[] += 1; true))
    @test c[] == 2

    # exec derivation → distinct (path3 x w)  (a→e via two routes ⇒ one atom)
    space_add_all_sexpr!(s, "(exec 0 (, (edge \$x \$y) (edge \$y \$z) (edge \$z \$w)) (, (path3 \$x \$w)))\n")
    space_metta_calculus!(s, 1_000_000)
    p3 = sort([strip(l) for l in split(space_dump_all_sexpr(s), '\n') if startswith(strip(l), "(path3 ")])
    @test p3 == ["(path3 a e)"]

    # 4-chain on a layered W=2 DAG (L0..L4) ⇒ 2^5 = 32 paths
    s4 = new_space(); io = IOBuffer()
    for l in 0:3, i in 0:1, j in 0:1; print(io, "(edge L$(l)n$(i) L$(l+1)n$(j))\n"); end
    space_add_all_sexpr!(s4, String(take!(io)))
    pat4 = sexpr_to_expr("(, (edge \$a \$b) (edge \$b \$c) (edge \$c \$d) (edge \$d \$e))")
    c4 = Ref(0); space_query_multi(s4.btm, pat4, (b, cc) -> (c4[] += 1; true))
    @test c4[] == 32
end

@testset "Projection pushdown (variant A) — set-sink dedup preserves atom set" begin
    # layered L0..L2, W=6: 72 edges. 2-hop join via the exec calculus.
    mkg() = (s = new_space(); io = IOBuffer();
             for l in 0:1, i in 0:5, j in 0:5; print(io, "(edge L$(l)n$(i) L$(l+1)n$(j))\n"); end;
             space_add_all_sexpr!(s, String(take!(io))); s)

    # PROJECTING: (reach2 $x $z) drops $y ⇒ W²=36 distinct (the W³=216 paths collapse)
    s = mkg()
    space_add_all_sexpr!(s, "(exec 0 (, (edge \$x \$y) (edge \$y \$z)) (, (reach2 \$x \$z)))\n")
    space_metta_calculus!(s, 1_000_000)
    @test count(l -> startswith(strip(l), "(reach2 "), split(space_dump_all_sexpr(s), '\n')) == 36

    # NON-PROJECTING: (twohop $x $y $z) keeps all vars ⇒ W³=216 distinct; dedup auto-disables
    s2 = mkg()
    space_add_all_sexpr!(s2, "(exec 0 (, (edge \$x \$y) (edge \$y \$z)) (, (twohop \$x \$y \$z)))\n")
    space_metta_calculus!(s2, 1_000_000)
    @test count(l -> startswith(strip(l), "(twohop "), split(space_dump_all_sexpr(s2), '\n')) == 216
end
