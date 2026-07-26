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

# Runtime toggle for ALL trie-join fast paths (P1/P1b/P2/P2c/P3) in
# `_space_query_multi_inner!`. Default on; flip to `false` to force the naive
# ProductZipper route — used by equivalence tests / benchmarks to A/B the join
# engine without code changes. Not const-wedge-prone (a Ref, not a recompiled const).
const _TRIE_JOIN_ENABLED = Ref(true)

# Runtime toggle for the P5 cardinality-greedy execution reorder in `_connected_join_emit!`
# (measured 2026-07-10). Default on; flip to `false` to force the connectivity-only source
# order `_classify_connected` picks — used to A/B the reorder win without code changes.
const _CARD_REORDER_ENABLED = Ref(true)

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

# byte-span of the sub-expression at 1-based arg position `pos` — generalizes _split2 to
# arity-N factors (walk `pos` sub-expressions; no need to know the total arity). Lets the
# binary join handle higher-arity relations like `(syn $a $b $w)` joining at any position.
function _arg_at(argbytes::Vector{UInt8}, pos::Int)::Vector{UInt8}
    p = 1; sp = UInt8[]
    for _ in 1:pos
        sp = Vector{UInt8}(expr_span(MORK.Expr(argbytes[p:end]), 1))
        p += length(sp)
    end
    sp
end

# Classify a 2-factor join over ARITY-N relations: each factor `(sym $a₁ … $aₙ)` (≥2 var
# args) with EXACTLY ONE variable shared across the two factors (the join key), the others
# distinct free tails — e.g. binary `(edge $x $y)(edge $y $z)` OR ternary
# `(syn $a $b $w)(syn $b $c $w2)`. Resolves the shared var's arg-position in each factor
# (NewVars numbered in factor order; VarRef.idx is the absolute var index). Returns
# (matches, keypos1, keypos2, head_prefix1, head_prefix2). Validated ≡ space_query_multi.
function _classify_binary_join(sources::Vector{ExprEnv})::Tuple{Bool, Int, Int, Vector{UInt8}, Vector{UInt8}}
    fail = (false, 0, 0, UInt8[], UInt8[])
    length(sources) == 2 || return fail
    occ = Dict{Int, Vector{Tuple{Int,Int}}}(); nv = 0; hps = Vector{UInt8}[]
    for (fi, src) in enumerate(sources)
        fa = ExprEnv[]; ee_args!(src, fa)
        length(fa) >= 3 || return fail                                   # head + ≥2 args
        buf = src.base.buf
        (byte_item(buf[Int(fa[1].offset)+1]) isa ExprSymbol) || return fail
        for ap in 2:length(fa)
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
        key = _arg_at(args, keypos)        # join-key arg at `keypos` (any arity/position)
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

# =====================================================================
# P2c — compound-arg (NESTED shared-var) binary join (additive fast path)
# =====================================================================
#
# Generalizes P2 to the case where the shared join variable sits at a NESTED
# position inside a COMPOUND argument, e.g.
#   (, ((join ($ctx case/0)) $a) (eval ($a) -> $b))         # going-wide (0 join) case/0
#   (, ((rel ($x foo)) $a)       ((rel ($x bar)) $b))       # nested shared $x
# whereas P2's `_classify_binary_join` only handles a shared var at a TOP-LEVEL
# arg position (and rejects compound/ground args). Blessed-faithful to Zippy's
# "navigate (unwrap) to the key position, then key on it" model (Zippy README):
# we walk the ground SKELETON to reach the var, anchor the trie read at the
# leading ground prefix, and extract the key by structural navigation. NOT a port
# of upstream MORK `query_multi` (which is a naive Cartesian product + post-unify).
# Tried only AFTER P2 fails, so the top-level all-var fast path is unchanged.

# Walk a factor's flat byte tree, assigning ABSOLUTE variable ids (NewVar #j →
# src.v + j; VarRef → tag.idx, already absolute) and recording, per var id, the
# child-index PATH from the factor root to its FIRST occurrence. Also returns the
# leading ground prefix (bytes before the first variable byte at any depth) — a
# valid trie prefix to anchor the read. Returns (occ, leading_prefix).
function _scan_factor_vars(src::ExprEnv)::Tuple{Dict{Int,Vector{Int}}, Vector{UInt8}}
    buf = src.base.buf
    occ = Dict{Int,Vector{Int}}()
    base_v = Int(src.v)
    localnv = Ref(0)
    firstvar = Ref(0)   # 1-based buf index of first var byte; 0 = none yet
    function walk(off::Int, path::Vector{Int})::Int       # off = 1-based buf index
        tag = byte_item(buf[off])
        if tag isa ExprNewVar
            vid = base_v + localnv[]; localnv[] += 1
            haskey(occ, vid) || (occ[vid] = path)
            firstvar[] == 0 && (firstvar[] = off)
            return off + 1
        elseif tag isa ExprVarRef
            vid = Int(tag.idx)
            haskey(occ, vid) || (occ[vid] = path)
            firstvar[] == 0 && (firstvar[] = off)
            return off + 1
        elseif tag isa ExprSymbol
            return off + 1 + Int(tag.size)
        elseif tag isa ExprArity
            o = off + 1
            for c in 1:Int(tag.arity)
                o = walk(o, vcat(path, c))
            end
            return o
        else
            return off + 1
        end
    end
    walk(Int(src.offset) + 1, Int[])
    lp = firstvar[] == 0 ? UInt8[] : buf[(Int(src.offset)+1):(firstvar[]-1)]
    (occ, lp)
end

# Classify a 2-factor join where EXACTLY ONE variable is shared across the factors,
# the var allowed at any nesting depth. Returns (matches, lp1, varpath1, lp2, varpath2)
# where lp_i = factor i's leading ground prefix and varpath_i = child-path to the
# shared var's first occurrence in factor i.
function _classify_binary_join_nested(sources::Vector{ExprEnv})
    fail = (false, UInt8[], Int[], UInt8[], Int[])
    length(sources) == 2 || return fail
    (occ1, lp1) = _scan_factor_vars(sources[1])
    (occ2, lp2) = _scan_factor_vars(sources[2])
    (isempty(occ1) || isempty(occ2)) && return fail
    shared = collect(intersect(keys(occ1), keys(occ2)))
    length(shared) == 1 || return fail                       # exactly one join var
    svid = shared[1]
    (true, lp1, occ1[svid], lp2, occ2[svid])
end

# Navigate `atom` by a child-index path (descend into Arity nodes), returning the
# byte-span of the sub-expression at the target position. Variable-length leaves are
# walked dynamically via `expr_span`, so the same structural path resolves across all
# atoms matching the factor's arity tree. Returns nothing on a structural mismatch.
"""
    _navigate_path(atom, path) -> Nothing | :hov | Vector{UInt8}

Walk `atom` down `path` (a sequence of 1-based child indices), mirroring the descent
`_scan_factor_vars` used to record where a shared variable sits in the PATTERN. Three
outcomes, NOT two — this used to collapse the last two into a single `nothing`, which
broke the P5/P2c soundness contract (found 2026-07-24 investigating a DTL query that
silently returned zero matches instead of falling back to ProductZipper):
  - `nothing` — genuine structural mismatch (wrong arity/symbol at this depth): the
    stored atom does not belong to this relation at all, safe to skip.
  - `:hov`    — the stored atom has a VARIABLE at a position where the pattern expects
    to descend FURTHER (e.g. pattern position holds `(i32_from_string \$y)`, a 2-node
    compound, but the stored fact — a type-relation like `(total_gini_impurity (->
    (\$yes_no_l \$yes_no_r) ...))` — has a bare variable there instead). This is NOT "no
    match": a free variable unifies with ANY value, so the caller cannot decide via
    positional trie-keying and MUST bail to the full unification path (ProductZipper).
  - `Vector{UInt8}` — the value found at `path`.
Callers (`_atom_varvals`, `_nested_keymap`) already handle the SEPARATE case where the
FINAL extracted value itself contains a variable (via `_expr_has_var`); this function
only needs to flag variables hit while descending TOWARD that final position.
"""
function _navigate_path(atom::Vector{UInt8}, path::Vector{Int})::Union{Nothing, Symbol, Vector{UInt8}}
    e = MORK.Expr(atom); off = 1
    for ci in path
        off <= length(atom) || return nothing
        tag = byte_item(atom[off])
        (tag isa ExprNewVar || tag isa ExprVarRef) && return :hov
        tag isa ExprArity || return nothing
        off += 1
        for _ in 1:(ci - 1)
            off <= length(atom) || return nothing
            off += length(expr_span(e, off))
        end
    end
    off <= length(atom) || return nothing
    collect(expr_span(e, off))
end

# True if a sub-expression's bytes contain ANY variable (NewVar/VarRef) — i.e. the
# stored atom is a (partial) RULE/higher-order pattern, not ground data.
function _expr_has_var(bytes::Vector{UInt8})::Bool
    i = 1
    while i <= length(bytes)
        t = byte_item(bytes[i])
        (t isa ExprNewVar || t isa ExprVarRef) && return true
        i += t isa ExprSymbol ? 1 + Int(t.size) : 1
    end
    false
end

"""
    _relation_has_var_atom(btm, head_prefix) → Bool

True if ANY atom stored under `head_prefix` carries a variable — i.e. the relation holds a
(partial) RULE / higher-order pattern rather than pure ground data.

**Every trie-join fast path MUST bail to ProductZipper when this holds.** Upstream matches a
query against such an atom by UNIFICATION: its coreferential DFS descends into data-side
variable bytes and keeps going (the `vs!` macro, space.rs:94-111, invoked at :133/:183/:188/:197),
so a stored `(p \$x)` behaves as a WILDCARD that matches every `(p …)` query. Exact-byte trie
keying cannot express that — a meet/keymap compares bytes, so a var byte simply fails to match
any ground key and the join SILENTLY UNDER-GENERATES.

Found 2026-07-26 by differential probes: with the fast paths on, `(, (p \$a) (q \$a))` over a
space containing `(p \$x)` dropped the `(out a)` result upstream produces, and
`(, (f \$x) (g \$x))` over `(f \$)` produced NOTHING at all. Disabling `_TRIE_JOIN_ENABLED`
took the space.rs probe corpus from 33/41 to 40/41 byte-exact — all seven recovered probes were
this one cause, across all five fast paths (P1b/P2/P2c/P3/P5).

This is the SECOND instance of this defect class in the trie-join lever: the P5 connected join
previously reported "0 matches, handled" instead of bailing when a stored relation's shape
diverged from the query's ground prefix. The lesson is the same — an exact-byte optimization must
DECLINE on var-bearing data, never silently return fewer rows.

Cost: one subtrie scan per factor, the same order as the keymap/argset build the fast path
performs anyway, and it runs only when a fast path has already matched the query SHAPE.
"""
function _relation_has_var_atom(btm::PathMap{UnitVal}, head_prefix::AbstractVector{UInt8})::Bool
    rz = read_zipper_at_path(btm, collect(head_prefix))
    while zipper_to_next_val!(rz)
        _expr_has_var(collect(zipper_path(rz))) && return true
    end
    false
end

# True if ANY of the given relations holds a var-bearing atom (see above).
_any_relation_has_var_atom(btm::PathMap{UnitVal}, hps) =
    any(hp -> _relation_has_var_atom(btm, hp), hps)

"""
    _factor_head_prefix(src) → Vector{UInt8} | nothing

The `[Arity][Symbol-head]` prefix of a query factor — the RELATION it reads, with no argument bytes.
`nothing` when the head is not a plain symbol (compound or variable head), which callers must treat
as UNSAFE for exact-byte keying.

Why the head, and not the classify's leading prefix: upstream calls `vs!` at the **SymbolSize** branch
too (space.rs:187-188) — BEFORE attempting the exact byte match — so a data-side variable is absorbed
at ANY argument position where the query holds a ground byte. A fast path that anchors at a longer
ground prefix (factor `(s a \$x)` anchors at `(s a`) therefore cannot see a var atom stored as
`(s \$z 9)`, which lives under `(s \$…` — yet upstream matches it, because `\$z` unifies with `a`.
Scanning from the relation head is what makes such atoms visible.

(Found 2026-07-26: guarding on the leading prefix recovered 5 of 7 probes and left exactly the two
whose var atom hid behind a ground argument — s2_p2c_hidden_varatom, s2_p5_hidden_varatom.)
"""
function _factor_head_prefix(src::ExprEnv)::Union{Nothing, Vector{UInt8}}
    fa = ExprEnv[]; ee_args!(src, fa)
    length(fa) >= 2 || return nothing
    buf = src.base.buf
    byte_item(buf[Int(fa[1].offset) + 1]) isa ExprSymbol || return nothing   # compound/variable head
    Vector{UInt8}(buf[(Int(src.offset) + 1):Int(fa[2].offset)])
end

# True if ANY query factor reads a relation holding a var-bearing atom — the soundness condition for
# every trie-join fast path. A factor whose head is not a plain symbol cannot be bounded this cheaply,
# so it counts as unsafe (conservative: the query falls through to the coref DFS, which is correct).
_any_factor_relation_has_var_atom(btm::PathMap{UnitVal}, sources::Vector{ExprEnv}) =
    any(sources) do src
        hp = _factor_head_prefix(src)
        hp === nothing ? true : _relation_has_var_atom(btm, hp)
    end

# Index a factor's stored atoms by the shared-var value reached via `varpath`,
# anchoring the read at `leading_prefix`. Returns (keymap, sound). `sound` is false
# if any stored atom carries a VARIABLE at the join-key position (a stored rule /
# higher-order pattern): exact-byte trie keying cannot match a var key against a
# ground key, so the join must fall back to ProductZipper's full unification. The
# caller bails BEFORE emitting any effect, so no partial results escape.
function _nested_keymap(btm::PathMap{UnitVal}, leading_prefix::Vector{UInt8}, varpath::Vector{Int})
    m = Dict{Vector{UInt8}, Vector{Vector{UInt8}}}()
    rz = read_zipper_at_path(btm, leading_prefix)
    sound = true
    while zipper_to_next_val!(rz)
        full = vcat(leading_prefix, collect(zipper_path(rz)))
        key = _navigate_path(full, varpath)
        key === nothing && continue
        key === :hov && (sound = false; break)          # var hit while descending → higher-order, bail
        _expr_has_var(key) && (sound = false; break)   # higher-order key → bail to ProductZipper
        push!(get!(m, key, Vector{Vector{UInt8}}()), full)
    end
    (m, sound)
end

# Emit a nested-key binary join: re-key both factors by the shared (nested) var, then
# per common key emit the tail-product, driving the SAME value-gate / unify / effect
# contract as the ProductZipper tail (combined + bindings byte-identical). Returns
# (handled, count): handled=false means a stored higher-order key was found and the
# caller must fall through to ProductZipper (NO effect has fired yet in that case).
function _nested_binary_join_emit!(btm::PathMap{UnitVal}, sources::Vector{ExprEnv},
        lp1::Vector{UInt8}, vp1::Vector{Int}, lp2::Vector{UInt8}, vp2::Vector{Int},
        effect::Function, bindings_scratch::Dict{ExprVar, ExprEnv},
        pairs_scratch::Vector{Tuple{ExprEnv, ExprEnv}})::Tuple{Bool, Int}
    (m1, s1) = _nested_keymap(btm, lp1, vp1)
    s1 || return (false, 0)
    (m2, s2) = _nested_keymap(btm, lp2, vp2)
    s2 || return (false, 0)
    candidate = 0
    try
        for (key, l1) in m1
            haskey(m2, key) || continue
            l2 = m2[key]
            for f1 in l1, f2 in l2
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
    (true, candidate)
end

# =====================================================================
# P3 — n-ary strict-chain join via recursive streaming (additive fast path)
# =====================================================================

const _NO_ATOMS = Vector{Vector{UInt8}}()

# Classify a strict left-chain of k>=3 binary factors:
#   (rel1 $x0 $x1)(rel2 $x1 $x2)...(relk $x_{k-1} $xk)
# factor1 = (NewVar, NewVar); factor i>=2 = (VarRef→factor(i-1)'s 2nd-arg var, NewVar).
# i.e. each factor's FIRST arg = the previous factor's SECOND arg (a path query).
# Returns (matches, head_prefixes). Non-chain k>=3 shapes (star, unlinked) are rejected.
function _classify_chain(sources::Vector{ExprEnv})::Tuple{Bool, Vector{Vector{UInt8}}}
    length(sources) >= 3 || return (false, Vector{UInt8}[])
    hps = Vector{UInt8}[]; nv = 0; prev = -1
    for (fi, src) in enumerate(sources)
        fa = ExprEnv[]; ee_args!(src, fa)
        length(fa) >= 3 || return (false, Vector{UInt8}[])               # head + ≥2 args
        buf = src.base.buf
        (byte_item(buf[Int(fa[1].offset)+1]) isa ExprSymbol) || return (false, Vector{UInt8}[])
        t1 = byte_item(buf[Int(fa[2].offset)+1]); t2 = byte_item(buf[Int(fa[3].offset)+1])
        (t2 isa ExprNewVar) || return (false, Vector{UInt8}[])           # arg2 (out-link) introduces a var
        if fi == 1
            (t1 isa ExprNewVar) || return (false, Vector{UInt8}[])       # 1st factor: arg1 also new
            nv += 1                                                       # account arg1's var
        else
            (t1 isa ExprVarRef && Int(t1.idx) == prev) || return (false, Vector{UInt8}[])  # chain link arg1↔prev arg2
        end
        prev = nv; nv += 1                                               # arg2 introduces the next link var
        for ap in 4:length(fa)                                          # arity-N tails (pos ≥3): fresh NewVars
            (byte_item(buf[Int(fa[ap].offset)+1]) isa ExprNewVar) || return (false, Vector{UInt8}[])
            nv += 1
        end
        push!(hps, buf[(Int(src.offset)+1):Int(fa[2].offset)])
    end
    (true, hps)
end

# Recursive depth-first streaming chain join: factor i>=2 indexed by its 1st arg; at each
# depth bind the factor's atoms whose 1st arg == the prior factor's 2nd arg, recurse, and at
# the leaf reconstruct the combined path + drive the unify/effect contract. Returns the count.
function _chain_join_emit!(btm::PathMap{UnitVal}, sources::Vector{ExprEnv},
        hps::Vector{Vector{UInt8}}, effect::Function,
        bindings_scratch::Dict{ExprVar, ExprEnv},
        pairs_scratch::Vector{Tuple{ExprEnv, ExprEnv}})::Int
    k = length(sources)
    kms = [Dict{Vector{UInt8}, Vector{Vector{UInt8}}}() for _ in 1:k]   # factor i>=2 keyed by 1st arg
    f1 = Vector{Vector{UInt8}}()
    for fi in 1:k
        rz = read_zipper_at_path(btm, hps[fi])
        while zipper_to_next_val!(rz)
            args = collect(zipper_path(rz)); a1 = _arg_at(args, 1); full = vcat(hps[fi], args)
            fi == 1 ? push!(f1, full) : push!(get!(kms[fi], a1, Vector{Vector{UInt8}}()), full)
        end
    end
    stack = Vector{Vector{UInt8}}(undef, k)
    candidate = Ref(0)
    # atoms are sourced from zipper_to_next_val! → always real stored values, so no value-gate.
    function rec(depth::Int, joinkey::Vector{UInt8})::Bool
        if depth > k
            empty!(pairs_scratch)
            for i in 1:k
                push!(pairs_scratch, (sources[i], ExprEnv(UInt8(i), UInt8(0), UInt32(0), MORK.Expr(stack[i]))))
            end
            empty!(bindings_scratch)
            if _expr_unify_inplace!(pairs_scratch, bindings_scratch) === true
                candidate[] += 1
                bindings_out = copy(bindings_scratch); empty!(bindings_scratch)
                return effect(bindings_out, MORK.Expr(reduce(vcat, stack)))
            end
            return true
        end
        atoms = depth == 1 ? f1 : get(kms[depth], joinkey, _NO_ATOMS)
        for atom in atoms
            a2 = _arg_at(atom[(length(hps[depth])+1):end], 2)   # out-link key = arg2 (any arity)
            stack[depth] = atom
            rec(depth + 1, a2) || return false
        end
        true
    end
    rec(1, UInt8[])
    candidate[]
end

# =====================================================================
# P5 — pipelined multi-way hash join for CONNECTED conjunctions (k≥3)
# =====================================================================
#
# Generalizes P2/P2c/P3 to any CONNECTED k≥3 conjunction the chain classifier
# rejects — notably the going-wide (0 join) case/2 query, a k-way STAR on a nested
# hub var plus a consumer factor on the produced vars:
#   (, ((join ($a case/2)) $b) ((join ($a arg/0)) $c) ((join ($a arg/1)) $d)
#      (eval ($b $c $d) -> $e))
# Instead of the naive ProductZipper N^k cross-product, we pick a connected join
# order and pipeline: each factor is hash-indexed by the values of the variables it
# shares with the already-bound set (multi-key, nested positions via P2c machinery),
# extending partial tuples. The streaming-native conjunction decomposition the ADR
# describes; blessed-faithful to Zippy (iterate + restrict), NOT a port of upstream
# MORK query_multi (naive Cartesian). Soundness: keying is valid only over GROUND
# data, so if any stored atom carries a VARIABLE at a join position the whole path
# BAILS to ProductZipper before any effect fires.

# Greedily order factors so each (after the first) shares ≥1 var with the running
# bound-var set. Returns (matches, order, occ_per_source, lp_per_source). Disconnected
# conjunctions (an independent factor) are rejected → ProductZipper.
function _classify_connected(sources::Vector{ExprEnv})
    fail = (false, Int[], Dict{Int,Vector{Int}}[], Vector{UInt8}[])
    k = length(sources)
    k >= 3 || return fail
    occ = Dict{Int,Vector{Int}}[]; lps = Vector{UInt8}[]
    for src in sources
        (o, lp) = _scan_factor_vars(src)
        isempty(o) && return fail                 # a ground factor can't join — bail
        push!(occ, o); push!(lps, lp)
    end
    order = [1]; bound = Set{Int}(keys(occ[1]))
    used = falses(k); used[1] = true
    for _ in 2:k
        nxt = 0
        for j in 1:k
            used[j] && continue
            isempty(intersect(keys(occ[j]), bound)) && continue
            nxt = j; break
        end
        nxt == 0 && return fail                   # disconnected component
        used[nxt] = true; push!(order, nxt); union!(bound, keys(occ[nxt]))
    end
    (true, order, occ, lps)
end

# Extract every var's value-bytes from one atom (keyed by absolute var id). Returns
# nothing on structural mismatch, or :hov if any value carries a variable (higher-order
# stored atom → caller must bail to ProductZipper).
"""
    _outer_head_prefix(lp) -> Nothing | Vector{UInt8}

Truncate a factor's (possibly deep) ground prefix `lp` down to just its OUTERMOST
arity tag + head symbol — e.g. for `(total_gini_impurity (-> ((i32_from_string`, this
returns `(total_gini_impurity` alone, one hop deep. Used as a soundness cross-check
(2026-07-24): if a factor's full ground-prefix scan finds nothing, that alone doesn't
prove the relation has no data — the relation could be a stored RULE whose own shape
diverges from the query's assumed literal continuation (e.g. `(total_gini_impurity (->
(\$yes_no_l \$yes_no_r) ...))` has a bare variable exactly where the query pattern's
deeper ground prefix expects to keep matching literal `i32_from_string` bytes, so the
deep-prefix scan never finds it at all). Checking existence at this shallow anchor lets
the caller detect that divergence and bail to ProductZipper instead of silently
reporting zero matches. Returns `nothing` if `lp` doesn't even start with a well-formed
arity+symbol pair (nothing to check).
"""
function _outer_head_prefix(lp::Vector{UInt8})::Union{Nothing, Vector{UInt8}}
    isempty(lp) && return nothing
    (byte_item(lp[1]) isa ExprArity) || return nothing
    length(lp) < 2 && return nothing
    (byte_item(lp[2]) isa ExprSymbol) || return nothing
    e = MORK.Expr(lp)
    vcat(lp[1], expr_span(e, 2))
end

function _atom_varvals(atom::Vector{UInt8}, occ::Dict{Int,Vector{Int}})
    d = Dict{Int,Vector{UInt8}}()
    for (vid, path) in occ
        v = _navigate_path(atom, path)
        v === nothing && return nothing
        v === :hov && return :hov
        _expr_has_var(v) && return :hov
        d[vid] = v::Vector{UInt8}
    end
    d
end

# Multi-key: concatenate the (sorted) shared vars' bound values into one Dict key.
_join_key(vals::Dict{Int,Vector{UInt8}}, shared::Vector{Int}) = begin
    out = UInt8[]; for v in shared; append!(out, vals[v]); end; out
end

# Pipelined hash join. Returns (handled, count); handled=false ⇒ a higher-order key was
# found and NO effect fired ⇒ caller falls through to ProductZipper.
function _connected_join_emit!(btm::PathMap{UnitVal}, sources::Vector{ExprEnv},
        order::Vector{Int}, occ::Vector{Dict{Int,Vector{Int}}}, lps::Vector{Vector{UInt8}},
        effect::Function, bindings_scratch::Dict{ExprVar, ExprEnv},
        pairs_scratch::Vector{Tuple{ExprEnv, ExprEnv}})::Tuple{Bool, Int}
    k = length(sources)
    # Load + index each factor's atoms once; bail on any higher-order (var-bearing) atom.
    atoms = Vector{Vector{Tuple{Vector{UInt8}, Dict{Int,Vector{UInt8}}}}}(undef, k)
    for fi in 1:k
        lst = Tuple{Vector{UInt8}, Dict{Int,Vector{UInt8}}}[]
        rz = read_zipper_at_path(btm, lps[fi])
        _n_scanned = 0
        while zipper_to_next_val!(rz)
            _n_scanned += 1
            full = vcat(lps[fi], collect(zipper_path(rz)))
            vv = _atom_varvals(full, occ[fi])
            vv === nothing && continue            # structural non-match → not in this relation
            vv === :hov && return (false, 0)      # higher-order key → bail
            push!(lst, (full, vv::Dict{Int,Vector{UInt8}}))
        end
        # Soundness cross-check (2026-07-24): a deep ground-prefix scan finding NOTHING is
        # not proof this relation has no data — it could be a stored higher-order RULE whose
        # shape diverges from the query's literal continuation before our prefix even ends
        # (see _outer_head_prefix docstring). Only trust "0 matches" once we've confirmed the
        # relation is ALSO absent at its shallow, outermost anchor.
        if _n_scanned == 0
            shallow = _outer_head_prefix(lps[fi])
            if shallow !== nothing && length(shallow) < length(lps[fi])
                rz2 = read_zipper_at_path(btm, shallow)
                if zipper_to_next_val!(rz2)
                    return (false, 0)
                end
            end
        end
        atoms[fi] = lst
    end

    # Cardinality-greedy execution order (measured 2026-07-10). The `order` handed in by
    # `_classify_connected` is connectivity-only, tie-broken by SOURCE order — so a program
    # that writes a large relation first (e.g. Nil BFC's `sol` in exec-6) drives a near-worst
    # plan (measured rank ~23/24 of 24 orderings; ~1.2–1.6× slower than optimal). Upstream MORK
    # `query_multi_raw` (space.rs:1216) has NO join planning at all — a fixed-order coreferential
    # ProductZipper — so there is no upstream ordering contract to preserve; this is a pure
    # MORK-side optimization on our own P5 path. We already loaded every factor's atoms above, so
    # the EXACT per-factor cardinality is in hand at ZERO extra scan: re-seed with the smallest
    # factor and repeatedly append the smallest-cardinality factor sharing ≥1 var with the bound
    # set. The join is commutative/associative ⇒ the result SET is byte-identical; only the
    # intermediate `tuples` sizes shrink. Connectivity is a whole-graph property the classifier
    # already proved, so a different seed still reaches every factor — the `best == 0` branch is
    # defensive only (a Cartesian step stays CORRECT, just slower).
    if _CARD_REORDER_ENABLED[]
        card = Int[length(atoms[fi]) for fi in 1:k]
        neworder = Int[]; usedp = falses(k)
        seed = argmin(card); push!(neworder, seed); usedp[seed] = true
        boundc = Set{Int}(keys(occ[seed]))
        for _ in 2:k
            best = 0; bestc = typemax(Int)
            for j in 1:k
                usedp[j] && continue
                isempty(intersect(keys(occ[j]), boundc)) && continue
                if card[j] < bestc
                    bestc = card[j]; best = j
                end
            end
            best == 0 && (best = something(findfirst(!, usedp)))   # defensive: connected ⇒ unused-connected exists
            push!(neworder, best); usedp[best] = true; union!(boundc, keys(occ[best]))
        end
        order = neworder     # rebinds the function arg (plain if-scope, no let shadow)
    end

    # Pipeline. A partial tuple = (slot atoms by SOURCE index, merged bound values).
    f0 = order[1]
    tuples = Tuple{Vector{Union{Nothing,Vector{UInt8}}}, Dict{Int,Vector{UInt8}}}[]
    for (a, vv) in atoms[f0]
        slot = Vector{Union{Nothing,Vector{UInt8}}}(nothing, k); slot[f0] = a
        push!(tuples, (slot, copy(vv)))
    end
    boundvars = Set{Int}(keys(occ[f0]))
    for step in 2:k
        fi = order[step]
        shared = sort(collect(intersect(keys(occ[fi]), boundvars)))
        idx = Dict{Vector{UInt8}, Vector{Tuple{Vector{UInt8}, Dict{Int,Vector{UInt8}}}}}()
        for t in atoms[fi]
            push!(get!(idx, _join_key(t[2], shared), valtype(idx)()), t)
        end
        nxt = Tuple{Vector{Union{Nothing,Vector{UInt8}}}, Dict{Int,Vector{UInt8}}}[]
        for (slot, bnd) in tuples
            cands = get(idx, _join_key(bnd, shared), nothing)
            cands === nothing && continue
            for (a, vv) in cands
                ns = copy(slot); ns[fi] = a
                nb = copy(bnd); for (vid, val) in vv; nb[vid] = val; end
                push!(nxt, (ns, nb))
            end
        end
        tuples = nxt
        union!(boundvars, keys(occ[fi]))
        isempty(tuples) && break
    end

    candidate = 0
    try
        for (slot, _) in tuples
            any(s -> s === nothing, slot) && continue
            empty!(pairs_scratch); ok = true
            for i in 1:k
                get_val_at(btm, slot[i]) === nothing && (ok = false; break)   # value gate
                push!(pairs_scratch, (sources[i], ExprEnv(UInt8(i), UInt8(0), UInt32(0), MORK.Expr(slot[i]))))
            end
            ok || continue
            empty!(bindings_scratch)
            if _expr_unify_inplace!(pairs_scratch, bindings_scratch) === true
                candidate += 1
                bindings_out = copy(bindings_scratch); empty!(bindings_scratch)
                combined = UInt8[]; for i in 1:k; append!(combined, slot[i]); end   # SOURCE order
                effect(bindings_out, MORK.Expr(combined)) || throw(BreakQuery())
            else
                empty!(bindings_scratch)
            end
        end
    catch e
        e isa BreakQuery || rethrow()
    end
    (true, candidate)
end

# =====================================================================
# P4-B — projection pushdown via composition (chain + endpoint projection)
# =====================================================================
# For a set-sink exec whose pattern is a strict chain and whose template(s) reference ONLY
# the chain endpoints (x0, xk) — e.g. `(reach3 $x $w)` over `(edge $x $y)(edge $y $z)(edge
# $z $w)` — compute the DISTINCT endpoint pairs by relational composition (W² result / ~W³
# work) instead of enumerating every path (W⁴), and apply the template once per pair.
# Validated ≡ the full exec (ADR-056 P4-B probe).

# True iff every template references (via VarRef) only the endpoint pattern vars {0, xk_idx}
# (template-introduced NewVars are fine). A template using an intermediate var ⇒ composition
# would lose it ⇒ NOT eligible.
function _chain_projection_ok(template_ees::Vector{ExprEnv}, oi::Int, xk_idx::Int)::Bool
    okref = Ref(true)
    for ee in template_ees
        _ee_traverseh(UInt8(0), ee,
            (h, o) -> (h, nothing),
            (h, o, r) -> (begin ri = Int(r); (ri < oi && ri != 0 && ri != xk_idx) && (okref[] = false) end; (h, nothing)),
            (h, o, sl) -> (h, nothing), (h, o, a) -> (h, nothing),
            (h, o, x, y) -> (h, nothing), (h, o, acc) -> (h, acc))
        okref[] || return false
    end
    true
end

# Relational composition along the chain: returns Dict x0 → Set{xk} of DISTINCT endpoint pairs.
function _chain_compose(btm::PathMap{UnitVal}, hps::Vector{Vector{UInt8}})
    reach = Dict{Vector{UInt8}, Set{Vector{UInt8}}}()
    rz = read_zipper_at_path(btm, hps[1])                          # factor 1 → (x0, x1)
    while zipper_to_next_val!(rz)
        a1, a2 = _split2(collect(zipper_path(rz)))
        push!(get!(reach, a1, Set{Vector{UInt8}}()), a2)
    end
    for i in 2:length(hps)                                         # compose factor i (dedup each hop)
        si = Dict{Vector{UInt8}, Vector{Vector{UInt8}}}()
        rzi = read_zipper_at_path(btm, hps[i])
        while zipper_to_next_val!(rzi)
            a1, a2 = _split2(collect(zipper_path(rzi)))
            push!(get!(si, a1, Vector{Vector{UInt8}}()), a2)
        end
        nr = Dict{Vector{UInt8}, Set{Vector{UInt8}}}()
        for (x0, mids) in reach, m in mids
            haskey(si, m) && for nx in si[m]
                push!(get!(nr, x0, Set{Vector{UInt8}}()), nx)
            end
        end
        reach = nr
    end
    reach
end

# Apply the template(s) once per distinct (x0, xk) endpoint pair → set_val_at!. Returns
# (count, any_new). Constructs the minimal bindings {endpoint vars → values} the template needs.
function _chain_proj_emit!(s, hps::Vector{Vector{UInt8}}, template_ees::Vector{ExprEnv},
        oi::Int, xk_idx::Int)::Tuple{Int, Bool}
    reach = _chain_compose(s.btm, hps)
    cnt = 0; any_new = false
    obuf = Vector{UInt8}(undef, 1 << 16)
    tspans = [Vector{UInt8}(expr_span(ee.base, Int(ee.offset) + 1)) for ee in template_ees]
    for (x0, xks) in reach, xk in xks
        bind = Dict{ExprVar, ExprEnv}()
        bind[(UInt8(0), UInt8(0))]      = ExprEnv(UInt8(0), UInt8(0), UInt32(0), MORK.Expr(x0))
        bind[(UInt8(0), UInt8(xk_idx))] = ExprEnv(UInt8(0), UInt8(0), UInt32(0), MORK.Expr(xk))
        for tsp in tspans
            ez = ExprZipper(MORK.Expr(tsp), 1)
            oz = ExprZipper(MORK.Expr(obuf), 1)
            expr_apply(UInt8(0), UInt8(oi), UInt8(0), ez, bind, oz,
                Dict{ExprVar, UInt8}(), ExprVar[], ExprVar[])
            out = obuf[1:(oz.loc - 1)]
            old = get_val_at(s.btm, out)
            set_val_at!(s.btm, out, UNIT_VAL)
            old === nothing && (any_new = true)
            cnt += 1
        end
    end
    (cnt, any_new)
end

# Orchestrator: fire P4-B iff pat is a strict chain (k>=3) and all templates project to the
# endpoints. Returns (count, any_new) when it fires, else `nothing` (caller falls through).
function _try_chain_projection!(s, pat_expr::MORK.Expr, pat_v::UInt8,
        template_ees::Vector{ExprEnv})::Union{Nothing, Tuple{Int, Bool}}
    pa = ExprEnv[]; ee_args!(ExprEnv(UInt8(0), pat_v, UInt32(0), pat_expr), pa)
    length(pa) < 4 && return nothing                              # need (, f1 f2 f3...) k>=3
    sources = pa[2:end]
    (ch_ok, hps) = _classify_chain(sources)
    ch_ok || return nothing
    (pat_nv, _, _) = _ee_traverseh(UInt8(0), ExprEnv(UInt8(0), pat_v, UInt32(0), pat_expr),
        (h, o) -> (h + UInt8(1), nothing), (h, o, r) -> (h, nothing), (h, o, sl) -> (h, nothing),
        (h, o, a) -> (h, nothing), (h, o, x, y) -> (h, nothing), (h, o, acc) -> (h, acc))
    oi = Int(pat_v) + Int(pat_nv); xk_idx = oi - 1
    _chain_projection_ok(template_ees, oi, xk_idx) || return nothing
    _chain_proj_emit!(s, hps, template_ees, oi, xk_idx)
end
