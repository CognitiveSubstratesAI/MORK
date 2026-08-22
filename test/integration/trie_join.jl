# test/integration/trie_join.jl
#
# ADR-056 Lever A / P1 — assert the empty-tail trie-join (`trie_join_unary`, via `pmeet`)
# is EXACTLY equivalent to the naive ProductZipper route (run here through the exec
# calculus `(, (p $x) (q $x)) → (both $x)`), across overlap / disjoint / subset /
# identical / singleton shapes. The subset & identical cases exercise the `pmeet`
# AlgResIdentity branch (`_trie_meet` resolves it to the smaller-by-val_count input).
using MORK, PathMaps, Test

# head-prefix of a unary relation = common prefix of two atoms with different-length args
# (so the common prefix stops at the relation head, before the argument).
_head_prefix(h) = begin
    a = sexpr_to_expr("($h a)").buf
    b = sexpr_to_expr("($h bb)").buf
    k = 0
    n = min(length(a), length(b))
    while k < n && a[k + 1] == b[k + 1]
        k += 1
    end
    a[1:k]
end

# exec-route reference: result $x bindings of (, (p $x) (q $x)) over the given ranges
function _exec_ref(Pr, Qr)
    s = new_space()
    io = IOBuffer()
    for k in Pr
        print(io, "(p k$k)\n")
    end
    for k in Qr
        print(io, "(q k$k)\n")
    end
    space_add_all_sexpr!(s, String(take!(io)))
    space_add_all_sexpr!(s, "(exec 0 (, (p \$x) (q \$x)) (, (both \$x)))\n")
    space_metta_calculus!(s, 10_000_000)
    Set(m.captures[1] for m in eachmatch(r"\(both (k\d+)\)", space_dump_all_sexpr(s)))
end

# build a space holding just the p/q facts (no exec) for the trie-join path
function _facts(Pr, Qr)
    s = new_space()
    io = IOBuffer()
    for k in Pr
        print(io, "(p k$k)\n")
    end
    for k in Qr
        print(io, "(q k$k)\n")
    end
    space_add_all_sexpr!(s, String(take!(io)))
    s
end

@testset "TrieJoin P1 — empty-tail join ≡ ProductZipper (exec route)" begin
    cases = [("overlap", 0:99, 50:149),
        ("disjoint", 0:49, 100:149),
        ("p⊂q", 0:49, 0:99),     # AlgResIdentity (meet = p)
        ("q⊂p", 0:99, 0:49),     # AlgResIdentity (meet = q)
        ("identical", 0:99, 0:99),     # AlgResIdentity (meet = either)
        ("singleton", 5:5, 5:5)]
    hp_p = _head_prefix("p")
    arg_enc(v) = (e=sexpr_to_expr("(p $v)").buf; e[(length(hp_p) + 1):end])
    for (lbl, Pr, Qr) in cases
        ref = _exec_ref(Pr, Qr)
        j = trie_join_unary(_facts(Pr, Qr).btm, [_head_prefix("p"), _head_prefix("q")])
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
    c = Ref(0)
    space_query_multi(s.btm, pat, (b, cc) -> (c[] += 1; true))
    @test c[] == 3                                  # (1,2,4) (1,2,5) (1,3,4)

    # exec derivation through the calculus → distinct (path2 x z)
    space_add_all_sexpr!(
        s, "(exec 0 (, (edge \$x \$y) (edge \$y \$z)) (, (path2 \$x \$z)))\n"
    )
    space_metta_calculus!(s, 1_000_000)
    p2 = sort([
        strip(l) for
        l in split(space_dump_all_sexpr(s), '\n') if startswith(strip(l), "(path2 ")
    ])
    @test p2 == ["(path2 1 4)", "(path2 1 5)"]

    # different relation heads, shared middle var
    s2 = new_space()
    space_add_all_sexpr!(s2, "(a 1 2)\n(a 3 2)\n(b 2 9)\n")
    c2 = Ref(0)
    space_query_multi(
        s2.btm, sexpr_to_expr("(, (a \$x \$y) (b \$y \$z))"), (b, cc) -> (c2[] += 1; true)
    )
    @test c2[] == 2                                 # (1,2,9) (3,2,9)

    # NO shared variable ⇒ must fall through to ProductZipper (full product), not P2
    c3 = Ref(0)
    space_query_multi(
        s2.btm, sexpr_to_expr("(, (a \$x \$y) (b \$z \$w))"), (b, cc) -> (c3[] += 1; true)
    )
    @test c3[] == 2                                 # 2 a-atoms × 1 b-atom
end

@testset "TrieJoin P3 — n-ary chain join (vs hand-computed truth)" begin
    # 3-chain x→y→z→w over: a→b→{c,d}→e  ⇒  a→b→c→e, a→b→d→e  (2 paths)
    s = new_space()
    space_add_all_sexpr!(s, "(edge a b)\n(edge b c)\n(edge b d)\n(edge c e)\n(edge d e)\n")
    pat = sexpr_to_expr("(, (edge \$x \$y) (edge \$y \$z) (edge \$z \$w))")
    c = Ref(0)
    space_query_multi(s.btm, pat, (b, cc) -> (c[] += 1; true))
    @test c[] == 2

    # exec derivation → distinct (path3 x w)  (a→e via two routes ⇒ one atom)
    space_add_all_sexpr!(
        s, "(exec 0 (, (edge \$x \$y) (edge \$y \$z) (edge \$z \$w)) (, (path3 \$x \$w)))\n"
    )
    space_metta_calculus!(s, 1_000_000)
    p3 = sort([
        strip(l) for
        l in split(space_dump_all_sexpr(s), '\n') if startswith(strip(l), "(path3 ")
    ])
    @test p3 == ["(path3 a e)"]

    # 4-chain on a layered W=2 DAG (L0..L4) ⇒ 2^5 = 32 paths
    s4 = new_space()
    io = IOBuffer()
    for l in 0:3, i in 0:1, j in 0:1
        print(io, "(edge L$(l)n$(i) L$(l+1)n$(j))\n")
    end
    space_add_all_sexpr!(s4, String(take!(io)))
    pat4 = sexpr_to_expr("(, (edge \$a \$b) (edge \$b \$c) (edge \$c \$d) (edge \$d \$e))")
    c4 = Ref(0)
    space_query_multi(s4.btm, pat4, (b, cc) -> (c4[] += 1; true))
    @test c4[] == 32
end

@testset "Projection pushdown (variant A) — set-sink dedup preserves atom set" begin
    # layered L0..L2, W=6: 72 edges. 2-hop join via the exec calculus.
    mkg() = (s=new_space(); io=IOBuffer();
        for l in 0:1, i in 0:5, j in 0:5
            print(io, "(edge L$(l)n$(i) L$(l+1)n$(j))\n")
        end;
        space_add_all_sexpr!(s, String(take!(io))); s)

    # PROJECTING: (reach2 $x $z) drops $y ⇒ W²=36 distinct (the W³=216 paths collapse)
    s = mkg()
    space_add_all_sexpr!(
        s, "(exec 0 (, (edge \$x \$y) (edge \$y \$z)) (, (reach2 \$x \$z)))\n"
    )
    space_metta_calculus!(s, 1_000_000)
    @test count(
        l -> startswith(strip(l), "(reach2 "), split(space_dump_all_sexpr(s), '\n')
    ) == 36

    # NON-PROJECTING: (twohop $x $y $z) keeps all vars ⇒ W³=216 distinct; dedup auto-disables
    s2 = mkg()
    space_add_all_sexpr!(
        s2, "(exec 0 (, (edge \$x \$y) (edge \$y \$z)) (, (twohop \$x \$y \$z)))\n"
    )
    space_metta_calculus!(s2, 1_000_000)
    @test count(
        l -> startswith(strip(l), "(twohop "), split(space_dump_all_sexpr(s2), '\n')
    ) == 216
end

@testset "P4-B projection composition — chain endpoint projection (vs full exec)" begin
    # two disjoint 3-paths: a→m→p→e and a→n→q→e
    edges = "(edge a m)\n(edge a n)\n(edge m p)\n(edge n q)\n(edge p e)\n(edge q e)\n"

    # reach3 projects to endpoints {x,w} ⇒ B fires ⇒ distinct (a,e) = ONE atom
    s = new_space()
    space_add_all_sexpr!(s, edges)
    space_add_all_sexpr!(
        s,
        "(exec 0 (, (edge \$x \$y) (edge \$y \$z) (edge \$z \$w)) (, (reach3 \$x \$w)))\n"
    )
    space_metta_calculus!(s, 1_000_000)
    @test sort([
        strip(l) for
        l in split(space_dump_all_sexpr(s), '\n') if startswith(strip(l), "(reach3 ")
    ]) ==
        ["(reach3 a e)"]

    # template uses the INTERMEDIATE $y ⇒ B must NOT fire (would lose $y) ⇒ both witnesses kept
    s2 = new_space()
    space_add_all_sexpr!(s2, edges)
    space_add_all_sexpr!(
        s2,
        "(exec 0 (, (edge \$x \$y) (edge \$y \$z) (edge \$z \$w)) (, (pathy \$x \$y \$w)))\n"
    )
    space_metta_calculus!(s2, 1_000_000)
    @test sort([
        strip(l) for
        l in split(space_dump_all_sexpr(s2), '\n') if startswith(strip(l), "(pathy ")
    ]) ==
        ["(pathy a m e)", "(pathy a n e)"]
end

@testset "TrieJoin arity-N — ternary relation join (generalized binary P2)" begin
    # ternary `(syn pre post weight)`: 2-hop joins on $b (post of f1 = pre of f2).
    # a→m→p and a→n→q ⇒ exactly 2 two-hops.
    s = new_space()
    space_add_all_sexpr!(s, "(syn a m 5)\n(syn a n 3)\n(syn m p 7)\n(syn n q 2)\n")
    c = Ref(0)
    space_query_multi(
        s.btm,
        sexpr_to_expr("(, (syn \$a \$b \$w) (syn \$b \$c \$w2))"),
        (b, cc) -> (c[] += 1; true)
    )
    @test c[] == 2

    # exec derivation projecting to endpoints ⇒ distinct (twohop a p), (twohop a q)
    space_add_all_sexpr!(
        s, "(exec 0 (, (syn \$a \$b \$w) (syn \$b \$c \$w2)) (, (twohop \$a \$c)))\n"
    )
    space_metta_calculus!(s, 1_000_000)
    @test sort([
        strip(l) for
        l in split(space_dump_all_sexpr(s), '\n') if startswith(strip(l), "(twohop ")
    ]) ==
        ["(twohop a p)", "(twohop a q)"]

    # backward-compat: binary `(edge …)` still classifies + joins (different graph, 1 two-hop)
    s2 = new_space()
    space_add_all_sexpr!(s2, "(edge x y)\n(edge y z)\n")
    c2 = Ref(0)
    space_query_multi(
        s2.btm,
        sexpr_to_expr("(, (edge \$a \$b) (edge \$b \$c))"),
        (b, cc) -> (c2[] += 1; true)
    )
    @test c2[] == 1
end

@testset "TrieJoin P3 arity-N — ternary chain join" begin
    # ternary syn 3-hop: a→m→{p,q}→e ⇒ 2 three-hops (a,m,p,e),(a,m,q,e)
    s = new_space()
    space_add_all_sexpr!(
        s, "(syn a m 1)\n(syn m p 2)\n(syn m q 3)\n(syn p e 4)\n(syn q e 5)\n"
    )
    pat = sexpr_to_expr("(, (syn \$a \$b \$w1) (syn \$b \$c \$w2) (syn \$c \$d \$w3))")
    c = Ref(0)
    space_query_multi(s.btm, pat, (b, cc) -> (c[] += 1; true))
    @test c[] == 2

    # exec endpoint projection ⇒ distinct (r3 a e) (both routes collapse)
    space_add_all_sexpr!(
        s,
        "(exec 0 (, (syn \$a \$b \$w1) (syn \$b \$c \$w2) (syn \$c \$d \$w3)) (, (r3 \$a \$d)))\n"
    )
    space_metta_calculus!(s, 1_000_000)
    @test sort([
        strip(l) for
        l in split(space_dump_all_sexpr(s), '\n') if startswith(strip(l), "(r3 ")
    ]) ==
        ["(r3 a e)"]
end

@testset "TrieJoin P2c — compound-arg (nested shared-var) binary join" begin
    # shared join var $c is NESTED inside the compound first arg (join ($c …)),
    # modeled on going-wide (0 join) case/0. P2's top-level classifier rejects this;
    # P2c navigates into the compound to the key. Assert ≡ forced-ProductZipper baseline.
    import MORK: _TRIE_JOIN_ENABLED, _classify_binary_join_nested
    function _facts_c(N)
        s = new_space()
        io = IOBuffer()
        for k in 1:N
            print(io, "((join (c$k case/0)) a$k)\n")
            print(io, "((join (c$k arg/0)) b$k)\n")
        end
        space_add_all_sexpr!(s, String(take!(io)))
        s
    end
    pat = sexpr_to_expr("(, ((join (\$c case/0)) \$a) ((join (\$c arg/0)) \$b))")

    # classifier fires on the nested shape (and not on a plain binary, which P2 owns)
    let pa = MORK.ExprEnv[]
        MORK.ee_args!(MORK.ExprEnv(UInt8(0), UInt8(0), UInt32(0), pat), pa)
        (ok, _, vp1, _, vp2) = _classify_binary_join_nested(pa[2:end])
        @test ok && vp1 == [1, 2, 1] && vp2 == [1, 2, 1]
    end

    # equivalence: P2c result-set ≡ forced ProductZipper, across sizes
    for N in (1, 2, 50)
        outs(s) = (
            space_add_all_sexpr!(s,
                "(exec 0 (, ((join (\$c case/0)) \$a) ((join (\$c arg/0)) \$b)) (, (out \$c \$a \$b)))\n"
            );
            space_metta_calculus!(s, 1_000_000);
            Set(m.match for m in eachmatch(r"\(out [^\n]*\)", space_dump_all_sexpr(s))))
        _TRIE_JOIN_ENABLED[] = false
        ref = outs(_facts_c(N))
        _TRIE_JOIN_ENABLED[] = true
        got = outs(_facts_c(N))
        @test length(got) == N
        @test got == ref
    end
    _TRIE_JOIN_ENABLED[] = true
end

@testset "TrieJoin P2c — higher-order key bails to ProductZipper (soundness)" begin
    # stored rule (double $x $conv (+ $conv $conv)) has a VARIABLE at the join-key
    # position; exact-byte trie keying can't match it against ground (input 5), so P2c
    # must bail to ProductZipper. Result must equal the forced-ProductZipper baseline.
    import MORK: _TRIE_JOIN_ENABLED
    prog = raw"""
    (double $x $conv (+ $conv $conv))
    (input 5)
    (exec 0 (, (input $x) (double $x (i32_from_string $x) $formula)) (, (macro-expanded $x $formula)))
    """
    outs() = (s=new_space(); space_add_all_sexpr!(s, prog);
        space_metta_calculus!(s, 10);
        Set(
            l for
            l in split(space_dump_all_sexpr(s), '\n') if occursin("macro-expanded", l)
        ))
    _TRIE_JOIN_ENABLED[] = false
    ref = outs()
    _TRIE_JOIN_ENABLED[] = true
    got = outs()
    @test !isempty(got)            # macro-expanded IS derived (the bug was: empty)
    @test got == ref               # P2c bail ≡ ProductZipper
    _TRIE_JOIN_ENABLED[] = true
end

@testset "TrieJoin P5 — pipelined connected join (star + consumer, k≥3)" begin
    # going-wide (0 join) case/2 shape: 3-way STAR on nested $a + eval consumer on ($b $c $d).
    import MORK: _TRIE_JOIN_ENABLED, _classify_connected
    QPAT = "(, ((join (\$a case/2)) \$b) ((join (\$a arg/0)) \$c) ((join (\$a arg/1)) \$d) (eval (\$b \$c \$d) -> \$e))"
    function facts(N)
        s = new_space()
        io = IOBuffer()
        for k in 1:N
            print(io, "((join (c$k case/2)) b$k)\n((join (c$k arg/0)) x$k)\n")
            print(io, "((join (c$k arg/1)) y$k)\n(eval (b$k x$k y$k) -> out$k)\n")
        end
        space_add_all_sexpr!(s, String(take!(io)))
        s
    end
    # classifier: connected, order covers all 4 factors
    let pa = MORK.ExprEnv[]
        MORK.ee_args!(MORK.ExprEnv(UInt8(0), UInt8(0), UInt32(0), sexpr_to_expr(QPAT)), pa)
        (ok, ord, _, _) = _classify_connected(pa[2:end])
        @test ok && sort(ord) == [1, 2, 3, 4]
    end
    # equivalence vs forced ProductZipper (small N so the 4-factor product is cheap)
    outs(s) = (space_add_all_sexpr!(s, "(exec 0 $QPAT (, (res \$a \$e)))\n");
        space_metta_calculus!(s, 1_000_000);
        Set(m.match for m in eachmatch(r"\(res [^\n]*\)", space_dump_all_sexpr(s))))
    for N in (1, 3)
        _TRIE_JOIN_ENABLED[] = false
        ref = outs(facts(N))
        _TRIE_JOIN_ENABLED[] = true
        got = outs(facts(N))
        @test length(got) == N && got == ref
    end
    _TRIE_JOIN_ENABLED[] = true
end

@testset "TrieJoin P5 — disconnected + higher-order conjunctions bail correctly" begin
    import MORK: _TRIE_JOIN_ENABLED
    # disconnected k=3 (no shared var): inherent Cartesian product; P5 bails ≡ ProductZipper
    s = new_space()
    space_add_all_sexpr!(s, "(a 1)\n(a 2)\n(b 7)\n(c 9)\n")
    cnt = Ref(0)
    space_query_multi(
        s.btm, sexpr_to_expr("(, (a \$x) (b \$y) (c \$z))"), (bnd, cc) -> (cnt[] += 1; true)
    )
    @test cnt[] == 2   # 2×1×1 product, all enumerated (bail to ProductZipper)

    # higher-order: a stored rule with a var at a join-key position ⇒ bail, result ≡ ProductZipper
    prog = raw"""
    (rule $k (lhs $k) (rhs $k))
    (fact 5)
    (seed 5)
    (exec 0 (, (fact $k) (seed $k) (rule $k $l $r)) (, (fired $k $l $r)))
    """
    go() = (t=new_space(); space_add_all_sexpr!(t, prog); space_metta_calculus!(t, 10);
        Set(x for x in split(space_dump_all_sexpr(t), '\n') if occursin("fired", x)))
    _TRIE_JOIN_ENABLED[] = false
    ref = go()
    _TRIE_JOIN_ENABLED[] = true
    got = go()
    @test got == ref
    _TRIE_JOIN_ENABLED[] = true
end

@testset "TrieJoin P5 — cardinality reorder preserves results (OFF ≡ ON)" begin
    import MORK: _CARD_REORDER_ENABLED
    # The P5 cardinality-greedy execution reorder (measured 2026-07-10, ~1.3× fewer intermediate
    # allocs on the Nil BFC exec-6 shape) changes ONLY the pipeline's intermediate `tuples` sizes —
    # the result SET must be byte-identical to the connectivity-only source order. Star join on $h:
    # one large `big` relation written FIRST (the near-worst source order) + small functional/filter
    # factors — exactly the shape the reorder helps. Guards against a reorder that drops/duplicates.
    facts() = begin
        s = new_space()
        io = IOBuffer()
        for h in 0:5, t in 1:4
            println(io, "(big h$h t$(h)_$t)")
        end     # 24 tuples over 6 keys
        for h in 0:5
            println(io, "(fa h$h a$h)")
            println(io, "(fb h$h b$h)")
        end
        for h in 0:2
            println(io, "(lt h$h)")
        end                          # filter: h ∈ {0,1,2}
        space_add_all_sexpr!(s, String(take!(io)))
        s
    end
    QPAT = raw"(, (big $h $t) (fa $h $a) (fb $h $b) (lt $h))"               # big first = worst source order
    outs(s) = (space_add_all_sexpr!(s, "(exec 0 $QPAT (, (res \$h \$t)))\n");
        space_metta_calculus!(s, 1_000_000);
        Set(m.match for m in eachmatch(r"\(res [^\n]*\)", space_dump_all_sexpr(s))))
    _CARD_REORDER_ENABLED[] = false
    ref = outs(facts())
    _CARD_REORDER_ENABLED[] = true
    got = outs(facts())
    @test !isempty(ref)
    @test got == ref                     # reorder is result-set-preserving
    @test length(got) == 12              # h ∈ {0,1,2} × t ∈ {1..4} = 12 distinct (res $h $t)
    _CARD_REORDER_ENABLED[] = true
end
