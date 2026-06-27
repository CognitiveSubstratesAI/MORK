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
