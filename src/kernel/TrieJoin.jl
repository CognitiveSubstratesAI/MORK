# TrieJoin — ADR-056 Lever A, phase P1: empty-tail conjunctive join via trie-algebra.
#
# Computes a conjunction of UNARY relations sharing ONE variable —
#   (, (r1 $v) (r2 $v) ...)  —  as the structural meet (`pmeet`) of the relations'
# argument-value subtries, instead of the naive ProductZipper (which enumerates the
# N^k cross product and unify-filters). Proven equivalent to the exec route and
# ~680× faster at N=400 on a 2-relation join (ADR-056 step-0 / P1 bench).
#
# This is the SUBSTRATE primitive only. It is NOT yet wired into
# `_space_query_multi_inner!` — that is phase P1b (the shared-variable classifier that
# derives head-prefixes from a pattern + the effect/`combined` synthesis), gated
# separately. See docs/architecture/ADR-056_zam_cardinality_join_planning.md.

# Resolve a PathMap `pmeet` result to a concrete PathMap.
#   • AlgResElement  → its `.value` (a genuinely-new meet: overlap, or disjoint→empty)
#   • AlgResIdentity → the meet equals one input; for a meet (intersection) that input
#                      is always the SUBSET, i.e. the smaller-by-`val_count`
#   • AlgResNone     → empty meet
_trie_meet(a::PathMap{UnitVal}, b::PathMap{UnitVal})::PathMap{UnitVal} = begin
    r = pmeet(a, b)
    r isa AlgResElement  && return r.value
    r isa AlgResIdentity && return (val_count(a) <= val_count(b) ? a : b)
    PathMap{UnitVal}()
end

"""
    trie_argset(btm, head_prefix) -> PathMap{UnitVal}

The set of argument-value byte-encodings stored under `head_prefix` — the relation-head
prefix (e.g. the `[Arity2][Sym r]` bytes of `(r \$v)`) — materialized as a fresh PathMap
whose keys are the encoded argument values.
"""
function trie_argset(btm::PathMap{UnitVal}, head_prefix::AbstractVector{UInt8})::PathMap{UnitVal}
    m = PathMap{UnitVal}()
    rz = read_zipper_at_path(btm, collect(head_prefix))
    while zipper_to_next_val!(rz)
        set_val_at!(m, collect(zipper_path(rz)), UNIT_VAL)
    end
    m
end

"""
    trie_join_unary(btm, head_prefixes) -> PathMap{UnitVal}

Empty-tail conjunctive join: the intersection of the argument-value sets of the given
unary relations (each identified by its head-prefix). The result keys are the argument
encodings shared by ALL relations — i.e. the bindings of the join variable. Equivalent
to `(, (r1 \$v) (r2 \$v) ...)` but computed by trie meet rather than ProductZipper.
"""
function trie_join_unary(btm::PathMap{UnitVal},
        head_prefixes::Vector{<:AbstractVector{UInt8}})::PathMap{UnitVal}
    isempty(head_prefixes) && return PathMap{UnitVal}()
    acc = trie_argset(btm, head_prefixes[1])
    for i in 2:length(head_prefixes)
        val_count(acc) == 0 && break          # already empty — meet stays empty
        acc = _trie_meet(acc, trie_argset(btm, head_prefixes[i]))
    end
    acc
end

# =====================================================================
# P1b — wiring into the multi-source query path (additive fast path)
# =====================================================================

# Detect the empty-tail shared-variable shape: every factor is `(sym $v)` (arity-2,
# Symbol head, variable arg) and ALL args denote ONE shared variable — encoded as
# exactly one NewVar introducer + (k-1) VarRef back-references. Independent vars
# (`(p $x) (q $y)` → two NewVars) and non-unary factors are rejected (→ ProductZipper).
# Returns (matches::Bool, head_prefixes). Validated ≡ space_query_multi (ADR-056 P1b probe).
function _classify_empty_tail(sources::Vector{ExprEnv})::Tuple{Bool, Vector{Vector{UInt8}}}
    length(sources) < 2 && return (false, Vector{UInt8}[])
    hps = Vector{UInt8}[]
    n_newvar = 0; n_varref = 0
    for src in sources
        fa = ExprEnv[]; ee_args!(src, fa)
        length(fa) == 2 || return (false, Vector{UInt8}[])         # not (head + 1 arg)
        buf = src.base.buf
        (byte_item(buf[Int(fa[1].offset) + 1]) isa ExprSymbol) || return (false, Vector{UInt8}[])
        atag = byte_item(buf[Int(fa[2].offset) + 1])
        if atag isa ExprNewVar
            n_newvar += 1
        elseif atag isa ExprVarRef
            n_varref += 1
        else
            return (false, Vector{UInt8}[])                        # arg is not a variable
        end
        push!(hps, buf[(Int(src.offset) + 1):Int(fa[2].offset)])   # [Arity2][Sym head] prefix
    end
    ((n_newvar == 1 && n_varref == length(sources) - 1), hps)
end

# Emit the empty-tail join via `trie_join_unary`, reconstructing each match's combined
# byte-path and driving the SAME value-gate / unify / effect contract as the ProductZipper
# tail (so bindings + `combined` are byte-identical). Returns the candidate count.
function _trie_join_emit!(btm::PathMap{UnitVal}, sources::Vector{ExprEnv},
        hps::Vector{Vector{UInt8}}, effect::Function,
        bindings_scratch::Dict{ExprVar, ExprEnv},
        pairs_scratch::Vector{Tuple{ExprEnv, ExprEnv}})::Int
    common = trie_join_unary(btm, hps)
    candidate = 0
    rz = read_zipper_at_path(common, UInt8[])
    try
        while zipper_to_next_val!(rz)
            v = collect(zipper_path(rz))                 # the shared-variable binding (arg encoding)
            combined = UInt8[]
            for hp in hps
                append!(combined, hp); append!(combined, v)
            end
            empty!(pairs_scratch)
            boundary = 0; allok = true
            for (k, src) in enumerate(sources)
                hi = boundary + length(hps[k]) + length(v)
                sub = combined[(boundary + 1):hi]
                boundary = hi
                if get_val_at(btm, sub) === nothing      # value-gate (mirrors ProductZipper tail)
                    allok = false; break
                end
                push!(pairs_scratch, (src, ExprEnv(UInt8(k), UInt8(0), UInt32(0), MORK.Expr(sub))))
            end
            if !allok || length(pairs_scratch) != length(sources)
                empty!(bindings_scratch); continue
            end
            empty!(bindings_scratch)
            if _expr_unify_inplace!(pairs_scratch, bindings_scratch) === true
                candidate += 1
                bindings_out = copy(bindings_scratch)
                empty!(bindings_scratch)
                effect(bindings_out, MORK.Expr(combined)) || throw(BreakQuery())
            else
                empty!(bindings_scratch)
            end
        end
    catch e
        e isa BreakQuery || rethrow()
    end
    candidate
end

# =====================================================================
# P2 — general binary join via key-rotation (additive fast path)
# =====================================================================

# Split a 2-argument region into its two sub-expression byte-spans (general: compound
# args handled via expr_span, not just symbols).
function _split2(argbytes::Vector{UInt8})::Tuple{Vector{UInt8}, Vector{UInt8}}
    l1 = length(expr_span(MORK.Expr(argbytes), 1))
    (argbytes[1:l1], argbytes[(l1+1):end])
end

# Classify a 2-factor binary join: each factor `(sym $a $b)` (arity-3, Symbol head, two
# variable args) with EXACTLY ONE variable shared across the two factors (the join key),
# the others distinct free tails. Resolves the shared var's arg-position in each factor
# (NewVars numbered in factor order; VarRef.idx is the absolute var index). Returns
# (matches, keypos1, keypos2, head_prefix1, head_prefix2). Validated ≡ space_query_multi.
function _classify_binary_join(sources::Vector{ExprEnv})::Tuple{Bool, Int, Int, Vector{UInt8}, Vector{UInt8}}
    fail = (false, 0, 0, UInt8[], UInt8[])
    length(sources) == 2 || return fail
    occ = Dict{Int, Vector{Tuple{Int,Int}}}(); nv = 0; hps = Vector{UInt8}[]
    for (fi, src) in enumerate(sources)
        fa = ExprEnv[]; ee_args!(src, fa)
        length(fa) == 3 || return fail                                   # head + 2 args
        buf = src.base.buf
        (byte_item(buf[Int(fa[1].offset)+1]) isa ExprSymbol) || return fail
        for ap in 2:3
            tag = byte_item(buf[Int(fa[ap].offset)+1])
            vid = if tag isa ExprNewVar
                      v = nv; nv += 1; v
                  elseif tag isa ExprVarRef
                      Int(tag.idx)
                  else
                      return fail                                        # arg not a variable
                  end
            push!(get!(occ, vid, Tuple{Int,Int}[]), (fi, ap - 1))
        end
        push!(hps, buf[(Int(src.offset)+1):Int(fa[2].offset)])
    end
    shared = Int[]
    for (vid, os) in occ
        length(Set(f for (f, _) in os)) == 2 && push!(shared, vid)
    end
    length(shared) == 1 || return fail                                   # exactly one join var
    pos = Dict(f => p for (f, p) in occ[shared[1]])
    (true, pos[1], pos[2], hps[1], hps[2])
end

# key-rotation index: shared-key encoding → list of full atom paths, for one factor.
function _bin_keymap(btm::PathMap{UnitVal}, hp::Vector{UInt8}, keypos::Int)
    m = Dict{Vector{UInt8}, Vector{Vector{UInt8}}}()
    rz = read_zipper_at_path(btm, hp)
    while zipper_to_next_val!(rz)
        args = collect(zipper_path(rz))
        a1, a2 = _split2(args)
        key = keypos == 1 ? a1 : a2
        push!(get!(m, key, Vector{Vector{UInt8}}()), vcat(hp, args))
    end
    m
end

# Emit a binary join: re-key both factors by the shared var, then per common key emit the
# tail-product, driving the SAME value-gate / unify / effect contract as the ProductZipper
# tail (combined + bindings byte-identical). Returns the candidate count.
function _binary_join_emit!(btm::PathMap{UnitVal}, sources::Vector{ExprEnv},
        kp1::Int, kp2::Int, hp1::Vector{UInt8}, hp2::Vector{UInt8}, effect::Function,
        bindings_scratch::Dict{ExprVar, ExprEnv},
        pairs_scratch::Vector{Tuple{ExprEnv, ExprEnv}})::Int
    m1 = _bin_keymap(btm, hp1, kp1)
    m2 = _bin_keymap(btm, hp2, kp2)
    candidate = 0
    try
        for (key, l1) in m1
            haskey(m2, key) || continue
            l2 = m2[key]
            for f1 in l1, f2 in l2
                # value-gate (atoms come from zipper_to_next_val! so are real — defensive parity)
                (get_val_at(btm, f1) === nothing || get_val_at(btm, f2) === nothing) && continue
                empty!(pairs_scratch)
                push!(pairs_scratch, (sources[1], ExprEnv(UInt8(1), UInt8(0), UInt32(0), MORK.Expr(f1))))
                push!(pairs_scratch, (sources[2], ExprEnv(UInt8(2), UInt8(0), UInt32(0), MORK.Expr(f2))))
                empty!(bindings_scratch)
                if _expr_unify_inplace!(pairs_scratch, bindings_scratch) === true
                    candidate += 1
                    bindings_out = copy(bindings_scratch)
                    empty!(bindings_scratch)
                    effect(bindings_out, MORK.Expr(vcat(f1, f2))) || throw(BreakQuery())
                else
                    empty!(bindings_scratch)
                end
            end
        end
    catch e
        e isa BreakQuery || rethrow()
    end
    candidate
end
