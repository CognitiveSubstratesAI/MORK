"""
ExprAlg — port of the algorithmic half of `mork/expr/src/lib.rs`.

Provides:
  - `expr_traverseh`   : generic catamorphism over flat byte expressions
  - `ee_args!`         : push child ExprEnvs of a compound onto a stack
  - `UnificationFailure` / `expr_unify`  : most-general unifier
  - `expr_apply`       : variable substitution

Julia translation notes
========================
  - Rust `traverseh!` macro (SmallVec stack) → Julia function + Vector stack
  - Rust `BTreeMap<ExprVar, ExprEnv>` → Julia `Dict{ExprVar, ExprEnv}`
  - Rust `gxhash::HashSet<(ExprEnv, ExprEnv)>` → Julia `Set{...}` (skipped for simplicity)
  - 0-based byte offsets preserved; 1-based buf indexing via `buf[j+1]`
"""

# =====================================================================
# expr_traverseh — generic tree fold over a flat Expr (ports traverseh!)
# =====================================================================

"""
    expr_traverseh(h0, x, j0, new_var_cb, var_ref_cb, symbol_cb, zero_cb, add_cb, finalize_cb)
          → (h, value, j_end)

Generic catamorphism over the flat byte encoding of expression `x`
starting at byte offset `j0` (0-based, same convention as Rust upstream).

Each callback receives the current `h` state and returns `(new_h, result)`:
  - `new_var_cb(h, offset)            → (new_h, value)`
  - `var_ref_cb(h, offset, idx)       → (new_h, value)`
  - `symbol_cb(h, offset, slice)      → (new_h, value)`
  - `zero_cb(h, offset, arity)        → (new_h, acc)`   (at arity node, before children)
  - `add_cb(h, offset, acc, sub)      → (new_h, new_acc)` (fold each child into acc)
  - `finalize_cb(h, offset, acc)      → (new_h, value)`  (after last child)

Returns `(h_final, final_value, j_end)` where `j_end` is the 0-based offset just
past the last consumed byte.  Mirrors the return of `traverseh!` in mork_expr.
"""
function expr_traverseh(h0, x::MORK.Expr, j0::Int,
    new_var_cb, var_ref_cb, symbol_cb, zero_cb, add_cb, finalize_cb)
    h = h0
    # Lazy stack: only allocated on the first Arity node with arity > 0.
    # Leaf-only and single-symbol expressions (the common case in unification)
    # never touch this variable, eliminating the ~180 byte/call Vector allocation.
    stack = nothing   # Union{Nothing, Vector{Tuple{UInt8,Any}}}
    j = j0

    while true
        b = x.buf[j + 1]    # j is 0-based; buf is 1-based
        tag = byte_item(b)

        local value
        if tag isa ExprNewVar
            j += 1
            h, value = new_var_cb(h, j - 1)
        elseif tag isa ExprVarRef
            j += 1
            h, value = var_ref_cb(h, j - 1, tag.idx)
        elseif tag isa ExprSymbol
            s = Int(tag.size)
            sl = view(x.buf, (j + 2):(j + 1 + s))
            h, value = symbol_cb(h, j, sl)
            j += s + 1
        elseif tag isa ExprArity
            h, acc = zero_cb(h, j, tag.arity)
            j += 1
            if tag.arity == 0
                h, value = finalize_cb(h, j, acc)
            else
                # First compound node seen: allocate stack now
                if stack === nothing
                    stack = Tuple{UInt8, Any}[(tag.arity, acc)]
                else
                    push!(stack, (tag.arity, acc))
                end
                continue
            end
        else
            error("unknown tag byte 0x$(string(b, base=16))")
        end

        # Popping loop: fold value into parent stack frame
        while true
            (stack === nothing || isempty(stack)) && return (h, value, j)
            k, acc = stack[end]
            h, new_acc = add_cb(h, j, acc, value)
            k -= UInt8(1)
            if k == 0
                pop!(stack)
                h, value = finalize_cb(h, j, new_acc)
            else
                stack[end] = (k, new_acc)
                break
            end
        end
    end
end

# Convenience: traverse over the sub-expression of an ExprEnv
function _ee_traverseh(
    h0, ee::ExprEnv, new_var_cb, var_ref_cb, symbol_cb, zero_cb, add_cb, finalize_cb
)
    expr_traverseh(
        h0,
        ee.base,
        Int(ee.offset),
        new_var_cb,
        var_ref_cb,
        symbol_cb,
        zero_cb,
        add_cb,
        finalize_cb
    )
end

# =====================================================================
# ee_args! — push child ExprEnvs of a compound onto `dest`
# =====================================================================

"""
    ee_args!(ee, dest)

Push the immediate child `ExprEnv`s of compound `ee` onto `dest`.
No-op for atoms (NewVar, VarRef, Symbol).
Mirrors `ExprEnv::args` in mork_expr.
"""
function ee_args!(ee::ExprEnv, dest::Vector{ExprEnv})
    tag = byte_item(ee.base.buf[Int(ee.offset) + 1])
    tag isa ExprArity || return nothing
    k = Int(tag.arity)
    env = ExprEnv(ee.n, ee.v, ee.offset + UInt32(1), ee.base)
    for _ in 1:k
        start_j = Int(env.offset)
        # Measure byte span + new-var count using traverseh
        (new_var_count, _, j_end) = _ee_traverseh(
            UInt8(0), env,
            (h, o) -> (h + UInt8(1), nothing),  # new_var: count it
            (h, o, r) -> (h, nothing),              # var_ref: noop
            (h, o, sl) -> (h, nothing),              # symbol:  noop
            (h, o, a) -> (h, nothing),              # zero:    noop
            (h, o, x, y) -> (h, nothing),              # add:     noop
            (h, o, acc) -> (h, acc))                  # finalize: identity
        push!(dest, ExprEnv(ee.n, env.v, env.offset, ee.base))
        span = j_end - start_j    # number of bytes this sub-expression occupies
        env = ExprEnv(env.n, env.v + new_var_count, env.offset + UInt32(span), env.base)
    end
end

# =====================================================================
# UnificationFailure
# =====================================================================

"""
    UnificationFailure

Reason for unification failure.  Mirrors `UnificationFailure` in mork_expr.
"""
@enum UnificationFailureKind begin
    UNIF_OCCURS
    UNIF_DIFFERENCE
    UNIF_MAX_ITER
end

struct UnificationFailure
    kind::UnificationFailureKind
    lhs::ExprEnv
    rhs::ExprEnv
    var::ExprVar
    iters::Int
end

const _EMPTY_EE = ExprEnv(UInt8(0), UInt8(0), UInt32(0), MORK.Expr(UInt8[]))

UnificationFailure(::Val{:occurs}, var::ExprVar, rhs::ExprEnv) =
    UnificationFailure(UNIF_OCCURS, _EMPTY_EE, rhs, var, 0)
UnificationFailure(::Val{:difference}, lhs::ExprEnv, rhs::ExprEnv) =
    UnificationFailure(UNIF_DIFFERENCE, lhs, rhs, (UInt8(0), UInt8(0)), 0)
UnificationFailure(::Val{:max_iter}, n::Int) =
    UnificationFailure(UNIF_MAX_ITER, _EMPTY_EE, _EMPTY_EE, (UInt8(0), UInt8(0)), n)

# =====================================================================
# expr_unify — Robinson unification
# =====================================================================

const MAX_UNIFY_ITER = 1000

"""
    _expr_unify_inplace!(pairs, bindings) → Union{Bool, UnificationFailure}

Internal scratch-Dict variant: clears `bindings`, fills it in-place, returns
`true` on success or a `UnificationFailure`.  Caller must NOT retain the Dict
across calls — use `copy(bindings)` before passing to user code.

Used by `_space_query_multi_inner!` to eliminate per-call Dict allocation.
Public callers use `expr_unify` which allocates a fresh Dict.
"""
function _expr_unify_inplace!(pairs::Vector{Tuple{ExprEnv, ExprEnv}},
    bindings::Dict{ExprVar, ExprEnv})::Union{Bool, UnificationFailure}
    empty!(bindings)
    result = _expr_unify_core!(pairs, bindings)
    result isa UnificationFailure ? result : true
end

"""
    expr_unify(stack) → Union{Dict{ExprVar,ExprEnv}, UnificationFailure}

Unify pairs of `ExprEnv`s. Returns a fresh bindings map on success or a failure.
Public API — always allocates a new Dict; safe to retain the result.
Mirrors `unify` in mork_expr.
"""
function expr_unify(
    stack::Vector{Tuple{ExprEnv, ExprEnv}}
)::Union{Dict{ExprVar, ExprEnv}, UnificationFailure}
    bindings = Dict{ExprVar, ExprEnv}()
    result = _expr_unify_core!(stack, bindings)
    result isa UnificationFailure ? result : bindings
end

# Shared implementation: fills `bindings` (which must already be empty/cleared).
# Returns `bindings` on success or `UnificationFailure`.
function _expr_unify_core!(stack::Vector{Tuple{ExprEnv, ExprEnv}},
    bindings::Dict{ExprVar, ExprEnv})::Union{Dict{ExprVar, ExprEnv}, UnificationFailure}
    iters = 0
    # encountered: deduplicates structural child pairs to break cyclic chains.
    # Mirrors the `encountered` HashSet<(ExprEnv,ExprEnv)> in the Rust `unify`.
    # Key = (base_id1, offset1, n1, v1, base_id2, offset2, n2, v2)
    encountered = Set{NTuple{8, UInt64}}()

    # deref: follow chain of bindings
    function _deref(t::ExprEnv)::ExprEnv
        while true
            vo = ee_var_opt(t)
            vo === nothing && return t
            bound = get(bindings, vo, nothing)
            bound === nothing && return t
            t = bound
        end
    end

    # occurs check: does var xvar appear in the fully-RESOLVED form of e (deref'd via bindings)?
    #
    # DEREF-AWARE (fix 2026-07-25, ADR-057 BFC over-generation). Upstream's `occurs` macro
    # (expr/src/lib.rs) is NOT deref-aware — it short-circuits on `x.0 != e.n` and only scans e's
    # OWN-namespace var indices. Upstream nonetheless catches cross-namespace cycles because its
    # `match2`-based pair generation binds in an ORDER where the offending var is eventually
    # unified in its own namespace (e.g. binds `W := (> $s $p)` first, then meets `$s` against
    # W's binding and tries `$s := (> $s $p)` — same namespace → occurs fires). OUR pair generation
    # (recursive `ee_args!` child-pairing) binds in a DIFFERENT order (`$s := W` first, then
    # `W := (> $s $p)` — cross-namespace → the old short-circuit MISSED the cycle), so the
    # order-dependent occurs check was unsound for us. The BFC `exec(3 3)` firing exploited exactly
    # this: it accepted `W := (> _2 _1)` (a data var bound to a term containing itself), producing
    # a malformed proof upstream rejects (verified: upstream returns `Occurs((0,1),…)` at the same
    # firing). Making the check deref-aware catches the cycle regardless of binding order — the
    # standard correct occurs check, order-independent, so it matches upstream's OUTCOME without
    # depending on replicating its exact pair-generation order. A depth guard treats an
    # already-cyclic chain as "occurs" (safety; bindings are acyclic before the checked insert).
    function _occurs_check(xvar::ExprVar, e::ExprEnv, depth::Int=0)::Bool
        depth > MAX_UNIFY_ITER && return true
        ev = ee_var_opt(e)
        if ev !== nothing
            ev == xvar && return true
            bound = get(bindings, ev, nothing)
            bound === nothing && return false
            return _occurs_check(xvar, bound, depth + 1)
        end
        tag = byte_item(e.base.buf[Int(e.offset) + 1])
        if tag isa ExprArity
            children = ExprEnv[]
            ee_args!(e, children)
            for c in children
                _occurs_check(xvar, c, depth + 1) && return true
            end
        end
        return false
    end

    # is_unbound: follow variable chain, true if ultimately unbound
    function _is_unbound(v::ExprVar)::Bool
        vv = v
        while true
            bound = get(bindings, vv, nothing)
            bound === nothing && return true
            vo = ee_var_opt(bound)
            vo === nothing && return false
            vv = vo
        end
    end

    while !isempty(stack)
        iters > MAX_UNIFY_ITER && return UnificationFailure(Val(:max_iter), iters)
        iters += 1

        xpop, ypop = pop!(stack)
        dt1 = _deref(xpop)
        dt2 = _deref(ypop)

        vx = ee_var_opt(dt1)
        vy = ee_var_opt(dt2)

        if vx === nothing && vy === nothing
            # Both ground — must match structurally
            # Push pairs of children
            b1 = dt1.base.buf[Int(dt1.offset) + 1]
            b2 = dt2.base.buf[Int(dt2.offset) + 1]
            tag1, tag2 = byte_item(b1), byte_item(b2)
            if typeof(tag1) != typeof(tag2)
                return UnificationFailure(Val(:difference), dt1, dt2)
            end
            if tag1 isa ExprSymbol
                tag2 = tag2::ExprSymbol
                s1 = Int(tag1.size);
                s2 = Int(tag2.size)
                if s1 != s2
                    ;
                    return UnificationFailure(Val(:difference), dt1, dt2);
                end
                o1 = Int(dt1.offset);
                o2 = Int(dt2.offset)
                if dt1.base.buf[(o1 + 2):(o1 + 1 + s1)] !=
                    dt2.base.buf[(o2 + 2):(o2 + 1 + s2)]
                    return UnificationFailure(Val(:difference), dt1, dt2)
                end
            elseif tag1 isa ExprArity
                tag2 = tag2::ExprArity
                if tag1.arity != tag2.arity
                    return UnificationFailure(Val(:difference), dt1, dt2)
                end
                # push child pairs with deduplication (mirrors Rust encountered set)
                children1 = ExprEnv[];
                ee_args!(dt1, children1)
                children2 = ExprEnv[];
                ee_args!(dt2, children2)
                for i in length(children1):-1:1
                    c1 = children1[i];
                    c2 = children2[i]
                    v1 = ee_var_opt(c1);
                    v2 = ee_var_opt(c2)
                    # Always push unbound-variable pairs (mirrors Rust special case)
                    if v1 !== nothing && v2 !== nothing && _is_unbound(v1) &&
                        _is_unbound(v2)
                        push!(stack, (c1, c2))
                    else
                        # Deduplicate: skip pair already in encountered
                        key = (UInt64(objectid(c1.base.buf)), UInt64(c1.offset),
                            UInt64(c1.n), UInt64(c1.v),
                            UInt64(objectid(c2.base.buf)), UInt64(c2.offset),
                            UInt64(c2.n), UInt64(c2.v))
                        if key ∉ encountered
                            push!(encountered, key)
                            push!(stack, (c1, c2))
                        end
                    end
                end
            end
            # NewVar/VarRef pairs handled below; symbol/arity matched above
        elseif vx !== nothing
            vx == vy && continue   # same var — skip
            _occurs_check(vx, dt2) && return UnificationFailure(Val(:occurs), vx, dt2)
            bindings[vx] = dt2
        else  # vy !== nothing
            vy == vx && continue
            _occurs_check(vy, dt1) && return UnificationFailure(Val(:occurs), vy, dt1)
            bindings[vy] = dt1
        end
    end

    bindings   # success: return the filled Dict
end

# =====================================================================
# expr_apply — substitution (ports apply in mork_expr)
# =====================================================================

# MORK "Rule of 64" design boundaries (from upstream expr/src/lib.rs)
# These are not arbitrary — they fall directly from the 6-bit fields in the
# byte tag encoding (Arity/VarRef/SymbolSize all capped at 63).
const MAX_EXPR_ARITY = 63   # max children per expression node
const MAX_SYMBOL_SIZE = 63   # max bytes in a symbol name
const MAX_VAR_REFS = 63   # max variable back-references per expression
const MAX_SOURCES = 63   # max sources in a multi-source pattern
const APPLY_DEPTH = 64   # max recursion depth in expr_apply

"""
    expr_apply(n, original_intros, new_intros, ez, bindings, oz, cycled, stack, assignments)
          → (original_intros, new_intros)

Apply variable bindings to the expression at `ez`, writing the result to `oz`.
Mirrors `apply` in mork_expr.
"""
function expr_apply(n::UInt8, original_intros::UInt8, new_intros::UInt8,
    ez::ExprZipper,
    bindings::Dict{ExprVar, ExprEnv},
    oz::ExprZipper,
    cycled::Dict{ExprVar, UInt8},
    stack::Vector{ExprVar},
    assignments::Vector{ExprVar})::Tuple{UInt8, UInt8}

    length(stack) > APPLY_DEPTH && error("expr_apply depth > $APPLY_DEPTH: n=$n")

    while true
        ez.loc > length(ez.root) && return (original_intros, new_intros)
        _loc_before = ez.loc          # invariant: must advance each iteration
        b = ez.root.buf[ez.loc]
        tag = byte_item(b)

        if tag isa ExprNewVar
            key = (n, original_intros)
            bound = get(bindings, key, nothing)
            if bound === nothing
                pos = findfirst(==(key), assignments)
                if pos !== nothing
                    ez_write_var_ref!(oz, UInt8(pos - 1))
                else
                    ez_write_new_var!(oz)
                    new_intros += UInt8(1)
                    push!(assignments, key)
                end
                original_intros += UInt8(1)
            else
                if haskey(cycled, key)
                    ez_write_var_ref!(oz, cycled[key])
                elseif key in stack
                    cycled[key] = new_intros
                    ez_write_new_var!(oz)
                    new_intros += UInt8(1)
                else
                    push!(stack, key)
                    sub_span = expr_span(bound.base, Int(bound.offset) + 1)
                    sub_ez = ExprZipper(MORK.Expr(Vector{UInt8}(sub_span)), 1)
                    _, new_intros = expr_apply(
                        bound.n,
                        bound.v,
                        new_intros,
                        sub_ez,
                        bindings,
                        oz,
                        cycled,
                        stack,
                        assignments
                    )
                    pop!(stack)
                end
                original_intros += UInt8(1)
            end
            ez.loc += 1

        elseif tag isa ExprVarRef
            idx = tag.idx
            key = (n, idx)
            bound = get(bindings, key, nothing)
            if bound === nothing
                pos = findfirst(==(key), assignments)
                if pos !== nothing
                    ez_write_var_ref!(oz, UInt8(pos - 1))
                else
                    ez_write_new_var!(oz)
                    new_intros += UInt8(1)
                    push!(assignments, key)
                end
            else
                if haskey(cycled, key)
                    ez_write_var_ref!(oz, cycled[key])
                elseif key in stack
                    cycled[key] = new_intros
                    ez_write_new_var!(oz)
                    new_intros += UInt8(1)
                else
                    push!(stack, key)
                    sub_span = expr_span(bound.base, Int(bound.offset) + 1)
                    sub_ez = ExprZipper(MORK.Expr(Vector{UInt8}(sub_span)), 1)
                    _, new_intros = expr_apply(
                        bound.n,
                        bound.v,
                        new_intros,
                        sub_ez,
                        bindings,
                        oz,
                        cycled,
                        stack,
                        assignments
                    )
                    pop!(stack)
                end
            end
            ez.loc += 1

        elseif tag isa ExprSymbol
            n_sym = Int(tag.size)
            sym_bytes = view(ez.root.buf, (ez.loc + 1):(ez.loc + n_sym))
            ez_write_symbol!(oz, sym_bytes)
            ez.loc += 1 + n_sym
            _check = ez.loc <= length(ez.root)
            _check || return (original_intros, new_intros)
            continue

        elseif tag isa ExprArity
            ez_write_arity!(oz, tag.arity)
            ez.loc += 1
        end

        ez.loc <= length(ez.root) || return (original_intros, new_intros)
        # advance to next byte
        # (symbol advances manually above; other tags advance in the conditionals)
        if !(tag isa ExprSymbol)
            ez.loc <= length(ez.root) || return (original_intros, new_intros)
        end
        @assert ez.loc > _loc_before "expr_apply: ez.loc did not advance for tag $(typeof(tag)) at byte 0x$(string(b, base=16))"
    end
end

# Convenience wrapper
function expr_apply(ez::ExprZipper, bindings::Dict{ExprVar, ExprEnv}, oz::ExprZipper)
    expr_apply(UInt8(0), UInt8(0), UInt8(0), ez, bindings, oz,
        Dict{ExprVar, UInt8}(), ExprVar[], ExprVar[])
end

# =====================================================================
# substitute_de_bruijn — de-Bruijn variable substitution with re-basing
# (ports Expr::substitute_de_bruijn / substitute_one_de_bruijn / shift / bind
#  from upstream expr/src/lib.rs:571/539/620/598)
# =====================================================================
#
# Unlike `expr_apply` (which substitutes NAMED (n,idx) bindings), this substitutes BY DE-BRUIJN
# POSITION: the k-th NewVar of the input is replaced by substitutions[k], and every other var's
# index is RE-BASED so the result stays a well-formed de-Bruijn expression. The `additions` offset
# array is the re-basing mechanism (upstream lib.rs:571): each substitution may introduce a
# different number of vars than the single var it replaces, and subsequent references shift by the
# accumulated delta. The PureSink needs this to substitute its output slot (a ground computed value,
# 0 vars) for one NewVar while correctly decrementing the trailing VarRefs — the naive
# byte-copy substitution left them dangling (the ip_sudoku meta-rule respawn +1-shift bug, 2026-07-25).

# Count NewVars in buf[from:to]. Ports Expr::newvars (lib.rs:331).
function _expr_newvars(buf::AbstractVector{UInt8}, from::Int, to::Int)::Int
    c = 0; i = from
    @inbounds while i <= to
        t = byte_item(buf[i])
        if t isa ExprNewVar; c += 1; i += 1
        elseif t isa ExprVarRef; i += 1
        elseif t isa ExprSymbol; i += 1 + Int(t.size)
        else; i += 1   # Arity
        end
    end
    c
end

# Write `sub` to `out` with every VarRef index incremented by `n` (NewVars unchanged). Returns the
# number of NewVars written. Ports Expr::shift (lib.rs:620).
function _expr_shift!(sub::AbstractVector{UInt8}, n::Int, out::Vector{UInt8})::Int
    nvar = 0; i = 1
    @inbounds while i <= length(sub)
        t = byte_item(sub[i])
        if t isa ExprNewVar
            push!(out, item_byte(ExprNewVar())); i += 1; nvar += 1
        elseif t isa ExprVarRef
            push!(out, item_byte(ExprVarRef(UInt8(Int(t.idx) + n)))); i += 1
        elseif t isa ExprSymbol
            m = Int(t.size); append!(out, @view sub[i:(i + m)]); i += m + 1
        else  # Arity
            push!(out, sub[i]); i += 1
        end
    end
    nvar
end

# Write `sub` to `out` with NewVar → VarRef(n + running-newvar-count) and VarRef(i) → VarRef(n + i).
# Ports Expr::bind (lib.rs:598).
function _expr_bind!(sub::AbstractVector{UInt8}, n::Int, out::Vector{UInt8})
    var_count = 0; i = 1
    @inbounds while i <= length(sub)
        t = byte_item(sub[i])
        if t isa ExprNewVar
            push!(out, item_byte(ExprVarRef(UInt8(n + var_count)))); i += 1; var_count += 1
        elseif t isa ExprVarRef
            push!(out, item_byte(ExprVarRef(UInt8(n + Int(t.idx))))); i += 1
        elseif t isa ExprSymbol
            m = Int(t.size); append!(out, @view sub[i:(i + m)]); i += m + 1
        else  # Arity
            push!(out, sub[i]); i += 1
        end
    end
end

# Substitute the k-th NewVar of buf[from:to] with substitutions[k+1] (0-based k), re-basing all
# other vars. Ports Expr::substitute_de_bruijn (lib.rs:571).
function _expr_substitute_de_bruijn(buf::AbstractVector{UInt8}, from::Int, to::Int,
        substitutions::Vector{<:AbstractVector{UInt8}})::Vector{UInt8}
    out = UInt8[]
    additions = zeros(Int, length(substitutions))
    var_count = 0; i = from
    @inbounds while i <= to
        t = byte_item(buf[i])
        if t isa ExprNewVar
            nvars = _expr_shift!(substitutions[var_count + 1], additions[var_count + 1], out)
            var_count += 1
            for j in (var_count + 1):length(additions); additions[j] += nvars; end
            i += 1
        elseif t isa ExprVarRef
            r = Int(t.idx)
            _expr_bind!(substitutions[r + 1], additions[r + 1], out)
            i += 1
        elseif t isa ExprSymbol
            m = Int(t.size); append!(out, @view buf[i:(i + m)]); i += m + 1
        else  # Arity
            push!(out, buf[i]); i += 1
        end
    end
    out
end

# Substitute the single NewVar at de-Bruijn index `idx` with `substitution` (a complete sub-expr),
# keeping every other var (identity) but re-based. Ports Expr::substitute_one_de_bruijn (lib.rs:539).
function _expr_substitute_one_de_bruijn(buf::AbstractVector{UInt8}, from::Int, to::Int,
        idx::Int, substitution::AbstractVector{UInt8})::Vector{UInt8}
    nvs = _expr_newvars(buf, from, to)   # upstream: self.newvars(); vars[idx] indexes it (panics if idx>=nvs)
    subs = Vector{Vector{UInt8}}(undef, nvs)
    nv = UInt8[item_byte(ExprNewVar())]
    for k in 1:nvs; subs[k] = nv; end
    subs[idx + 1] = Vector{UInt8}(substitution)
    _expr_substitute_de_bruijn(buf, from, to, subs)
end

# =====================================================================
# ee_show — debug string for ExprEnv
# =====================================================================

"""Show the expression in ExprEnv with variable labels like <n,idx>."""
function ee_show(ee::ExprEnv)::String
    io = IOBuffer()
    _ee_show_impl(io, ee.base, Int(ee.offset), Int(ee.v), Int(ee.n))
    String(take!(io))
end

function _ee_show_impl(io::IO, x::MORK.Expr, off::Int, var_cnt::Int, n::Int)::Int
    b = x.buf[off + 1]
    tag = byte_item(b)
    if tag isa ExprNewVar
        print(io, "<$(n),$(var_cnt)>")
        return var_cnt + 1
    elseif tag isa ExprVarRef
        print(io, "<$(n),$(Int(tag.idx))>")
        return var_cnt
    elseif tag isa ExprSymbol
        s = Int(tag.size)
        write(io, x.buf[(off + 2):(off + 1 + s)])
        return var_cnt
    elseif tag isa ExprArity
        a = Int(tag.arity)
        print(io, "(")
        off2 = off + 1
        for i in 1:a
            i > 1 && print(io, " ")
            var_cnt = _ee_show_impl(io, x, off2, var_cnt, n)
            # advance off2 by the span of the child
            (_, _, j_end) = expr_traverseh(
                0, x, off2,
                (h, o) -> h, (h, o, r) -> h, (h, o, sl) -> h,
                (h, o, a2) -> h, (h, o, x2, y) -> h, (h, o, acc) -> acc)
            off2 = j_end
        end
        print(io, ")")
        return var_cnt
    end
    var_cnt
end

# =====================================================================
# Structural queries — upstream `expr/src/lib.rs` (ported 2026-07-30)
# =====================================================================
#
# Six `impl Expr` methods that were genuinely absent. Sized with three filters FIRST, because three
# headline absence counts dissolved under reading today:
#   * cfg-gates — none here (unlike space.rs, where 3 of 16 were `#[cfg(feature="neo4j")]`)
#   * renames   — `subsexpr`->`ee_subsexpr`, `var_opt`->`ee_var_opt`, `_unify`->`expr_unify` were
#                 ALREADY PORTED and must not be re-ported
#   * definition-site check — a plain grep counts a name appearing in a COMMENT as "present"
#
# ⚠️ `is_ground` is on record as a gap the inventory once MASKED, by matching it against the
# unrelated `is_grounded`. It is real, and it is three lines.

"""
    expr_variables(x, [j0]) → Int

upstream `Expr::variables` (lib.rs:344-346) — count of variable ITEMS: every `NewVar` **and** every
`VarRef`. Not the same as `_expr_newvars`, which counts only the binders.
"""
expr_variables(x::MORK.Expr, j0::Int = 0)::Int =
    expr_traverseh(nothing, x, j0,
                   (h, o) -> (h, 1), (h, o, r) -> (h, 1), (h, o, sl) -> (h, 0),
                   (h, o, a) -> (h, 0), (h, o, acc, sub) -> (h, acc + sub),
                   (h, o, acc) -> (h, acc))[2]

"""
    expr_is_ground(x) → Bool

upstream `Expr::is_ground` (lib.rs:913-915) — `self.variables() == 0`, i.e. no vars and no refs.
"""
expr_is_ground(x::MORK.Expr)::Bool = expr_variables(x) == 0

"""
    expr_max_arity(x) → Union{Nothing, UInt8}

upstream `Expr::max_arity` (lib.rs:348-350). The accumulator is the arity of the node being folded
and leaves contribute `None`, so a leaf-only expression yields `nothing` rather than 0 — that
distinction is upstream's `Option<u8>` and is preserved here.
"""
function expr_max_arity(x::MORK.Expr)::Union{Nothing, UInt8}
    expr_traverseh(nothing, x, 0,
                   (h, o) -> (h, nothing), (h, o, r) -> (h, nothing), (h, o, sl) -> (h, nothing),
                   (h, o, a) -> (h, a),
                   (h, o, acc, sub) -> (h, max(acc, sub === nothing ? UInt8(0) : sub)),
                   (h, o, acc) -> (h, acc))[2]
end

"""
    expr_has_unbound(x) → Bool

upstream `Expr::has_unbound` (lib.rs:352-360) — true when some `VarRef(r)` names an index at or
beyond the number of `NewVar` binders seen SO FAR, i.e. a reference with nothing to bind to.

The carried state is that binder count: `|c, _| { *c += 1; false }` on a binder,
`|c, _, r| r >= *c` on a reference.
"""
function expr_has_unbound(x::MORK.Expr)::Bool
    expr_traverseh(UInt8(0), x, 0,
                   (c, o) -> (c + UInt8(1), false),
                   (c, o, r) -> (c, r >= c),
                   (c, o, sl) -> (c, false), (c, o, a) -> (c, false),
                   (c, o, acc, sub) -> (c, acc || sub), (c, o, acc) -> (c, acc))[2]
end

"""
    expr_forward_references(x, at) → Int

upstream `Expr::forward_references` (lib.rs:339-342) — how many distinct variables are referenced
before being bound, given `at` already-bound variables on entry.

The carried state is a 64-bit occupancy mask seeded to the low `at` bits. A binder claims the lowest
free bit (`1 << trailing_ones(c)`); a reference counts 1 only the FIRST time its bit is unset, then
sets it — so repeated forward references to the same variable count once.
"""
function expr_forward_references(x::MORK.Expr, at::Integer = 0)::Int
    seed = at > 0 ? (typemax(UInt64) >> (64 - at)) : UInt64(0)
    expr_traverseh(seed, x, 0,
                   (c, o) -> (c | (UInt64(1) << trailing_ones(c)), 0),
                   (c, o, r) -> ((UInt64(1) << r) & c == 0 ? (c | (UInt64(1) << r), 1) : (c, 0)),
                   (c, o, sl) -> (c, 0), (c, o, a) -> (c, 0),
                   (c, o, acc, sub) -> (c, acc + sub), (c, o, acc) -> (c, acc))[2]
end

"""
    expr_difference_under(x, other) → Union{Nothing, Int}

upstream `Expr::difference_under` (lib.rs:378-391) — the 0-based offset of the first item at which
the two expressions differ, or `nothing` when `x` is exhausted with no difference.

⚠️ UPSTREAM'S `under: F` CLOSURE IS UNUSED. It appears in the signature and never in the body, which
compares `ez.item() != oz.item()` outright. It is omitted here rather than reproduced as a parameter
that does nothing — the same shape as `load_json_`'s unused `pattern`, which we DID keep because it
is positional in a public loader API. Do not "implement" a comparison hook upstream does not have.
"""
function expr_difference_under(x::MORK.Expr, other::MORK.Expr)::Union{Nothing, Int}
    i = 1
    j = 1
    while true
        i > length(x.buf) && return nothing
        j > length(other.buf) && return i - 1
        tx = byte_item(x.buf[i])
        ty = byte_item(other.buf[j])
        # An item is its tag byte plus, for a symbol, its payload — compare both.
        if x.buf[i] != other.buf[j]
            return i - 1
        end
        if tx isa ExprSymbol
            n = Int(tx.size)
            (i + n > length(x.buf) || j + n > length(other.buf)) && return i - 1
            view(x.buf, (i + 1):(i + n)) == view(other.buf, (j + 1):(j + n)) || return i - 1
            i += n + 1
            j += n + 1
        else
            i += 1
            j += 1
        end
    end
end

# =====================================================================
# Variable equating / unbinding — upstream `impl Expr` (ported 2026-07-30)
# =====================================================================
#
# 🔴 VERIFICATION LEVEL — WEAKEST IN THIS FILE. Read this before trusting these four.
# Upstream has only THREE `#[test]` fns in expr/src/lib.rs and NONE of them covers `unbind` or the
# `equate_var*` family, and none of these functions is reachable from the `mork` CLI. So unlike the
# pure ops (byte-exact against the running binary at 2792 input points) or the MM2 sinks (249
# conformance probes), these are verified as:
#
#     read the upstream body line by line -> port 1:1 -> test MY UNDERSTANDING of it
#
# That is strictly weaker, and it is labelled here rather than left to read as differential
# verification. What the cross-check DID catch, none of which survives inference alone:
#   * upstream's `write_var_ref`/`write_new_var` do NOT advance `loc`; ours do
#   * `equate_var` asserts `new_var > refer_to`, `equate_var_inplace` asserts `>=` — really different
#   * `equate_vars_inplace`'s `refers` is an OUT-param, not just an input
#   * the `bound[i]` sentinel path — read first, then SETTLED BY EXECUTION (see `expr_unbind`)
#
# ⇒ If any of these ever gains a consumer, get a real oracle first: either expose it through a probe
#    the binary can run, or lift upstream's own test vectors the way `anti_unify` does.
#
# ⚠️ WRITER SEMANTICS DIFFER FROM UPSTREAM, and getting this wrong corrupts the traversal.
# Upstream's `ExprZipper::write_var_ref`/`write_new_var` write at `loc` WITHOUT advancing — every
# call site that wants to move does `oz.loc += 1` explicitly. OUR `ez_write_var_ref!` /
# `ez_write_new_var!` write AND advance.
#   * OUT-OF-PLACE (`equate_var`, `unbind`): upstream writes then advances, so our advancing writer
#     is exactly right — one call.
#   * IN-PLACE (`equate_var_inplace`, `equate_vars_inplace`): upstream deliberately does NOT advance,
#     because `ez.next()` does the walking. Using our writer there would double-advance and desync
#     the cursor, so those write the byte DIRECTLY.

"""
    expr_unbind(x, oz) → SubArray{UInt8}

upstream `Expr::unbind` (lib.rs:644-663) — copy `x` into `oz`, turning every variable REFERENCE that
has no binder yet into a fresh binder, and remapping later references to it.

⚠️ SUSPECTED UPSTREAM BUG, ported faithfully and flagged rather than silently "fixed". `bound` is
initialised to the sentinel `255` and is written ONLY in the `else` arm. The first arm fires when
`i < nvars || bound[i] != 255`, so for `(\$ _1)` — binder then a valid back-reference — `i=0 < nvars=1`
takes the FIRST arm and writes `write_var_ref(bound[0])`, i.e. `VarRef(255)`, the sentinel itself.
Upstream's `debug_assert!(i < 64)` would catch that in a debug build; a release build masks it to
`255 & 0x3f = 63`. Our `item_byte` asserts, so we RAISE where upstream release emits `VarRef(63)` —
the same shape as the D8/D9 aborts, where upstream wraps and we refuse.
**Not yet confirmed by execution** (`unbind` has no CLI exposure); the test below pins what we do.
"""
function expr_unbind(x::MORK.Expr, oz::ExprZipper)
    ez = ExprZipper(x, 1)
    bound = fill(0xff, 64)
    nvars = 0
    while true
        t = byte_item(ez.root.buf[ez.loc])
        if t isa ExprNewVar
            ez_write_new_var!(oz)
            nvars += 1
        elseif t isa ExprVarRef
            i = Int(t.idx)
            if i < nvars || bound[i + 1] != 0xff
                ez_write_var_ref!(oz, bound[i + 1])      # may be the 255 sentinel — see above
            else
                ez_write_new_var!(oz)
                bound[i + 1] = UInt8(nvars)
                nvars += 1
            end
        elseif t isa ExprSymbol
            n = Int(t.size)
            ez_write_move!(oz, view(ez.root.buf, ez.loc:(ez.loc + n)))
        else
            ez_write_arity!(oz, (t::ExprArity).arity)
        end
        ez_next!(ez) || return expr_span(x)
    end
end

"""
    expr_equate_var(x, new_var, refer_to, oz) → SubArray{UInt8}

upstream `Expr::equate_var` (lib.rs:439-473) — copy `x` into `oz` with binder `new_var` replaced by a
reference to `refer_to`. Because one binder disappears, every reference ABOVE `new_var` shifts down
by one (`r > new_var => VarRef(r-1)`).

Upstream asserts `new_var > refer_to` (strict), unlike `equate_var_inplace` which allows equality.
"""
function expr_equate_var(x::MORK.Expr, new_var::UInt8, refer_to::UInt8, oz::ExprZipper)
    new_var > refer_to || throw(ArgumentError("equate_var: new_var ($new_var) must exceed refer_to ($refer_to)"))
    ez = ExprZipper(x, 1)
    var_count = 0
    while true
        t = byte_item(ez.root.buf[ez.loc])
        if t isa ExprNewVar
            new_var == var_count ? ez_write_var_ref!(oz, refer_to) : ez_write_new_var!(oz)
            var_count += 1
        elseif t isa ExprVarRef
            r = t.idx
            if new_var == r
                ez_write_var_ref!(oz, refer_to)
            elseif r > new_var
                ez_write_var_ref!(oz, r - UInt8(1))
            else
                ez_write_var_ref!(oz, r)
            end
        elseif t isa ExprSymbol
            n = Int(t.size)
            ez_write_move!(oz, view(ez.root.buf, ez.loc:(ez.loc + n)))
        else
            ez_write_arity!(oz, (t::ExprArity).arity)
        end
        ez_next!(ez) || return expr_span(x)
    end
end

"""
    expr_equate_var_inplace!(x, new_var, refer_to) → SubArray{UInt8}

upstream `Expr::equate_var_inplace` (lib.rs:477-503) — the same rewrite applied IN PLACE. Symbols and
arity nodes are left untouched (upstream's arms are empty), and only variable bytes are overwritten.

The precondition is `new_var >= refer_to` here — WEAKER than `equate_var`'s strict `>`.
"""
function expr_equate_var_inplace!(x::MORK.Expr, new_var::UInt8, refer_to::UInt8)
    new_var >= refer_to || throw(ArgumentError("equate_var_inplace: new_var ($new_var) < refer_to ($refer_to)"))
    ez = ExprZipper(x, 1)
    var_count = 0
    while true
        t = byte_item(ez.root.buf[ez.loc])
        if t isa ExprNewVar
            # direct write, NO advance — upstream does not advance here (see the note above)
            new_var == var_count && (ez.root.buf[ez.loc] = item_byte(ExprVarRef(refer_to)))
            var_count += 1
        elseif t isa ExprVarRef
            r = t.idx
            if new_var == r
                ez.root.buf[ez.loc] = item_byte(ExprVarRef(refer_to))
            elseif r > new_var
                ez.root.buf[ez.loc] = item_byte(ExprVarRef(r - UInt8(1)))
            end
        end
        ez_next!(ez) || return expr_span(x)
    end
end

"""
    expr_equate_vars_inplace!(x, refers)

upstream `Expr::equate_vars_inplace` (lib.rs:506-538) — bulk in-place equating driven by `refers`,
which is BOTH an input and an output: `0xff` means "this variable stays a binder", and the function
writes back its NEW index (`var_count - bound`) so later references can be renumbered.

`refers` is mutated in place, exactly as upstream's `&mut [u8]`.
"""
function expr_equate_vars_inplace!(x::MORK.Expr, refers::Vector{UInt8})
    ez = ExprZipper(x, 1)
    var_count = 0
    bound = 0
    while true
        t = byte_item(ez.root.buf[ez.loc])
        if t isa ExprNewVar
            if refers[var_count + 1] != 0xff
                ez.root.buf[ez.loc] = item_byte(ExprVarRef(refers[var_count + 1]))
                bound += 1
            else
                refers[var_count + 1] = UInt8(var_count - bound)
            end
            var_count += 1
        elseif t isa ExprVarRef
            r = Int(t.idx)
            # upstream's else arm is a commented-out `unreachable!()` — an unmapped ref is left alone
            refers[r + 1] != 0xff && (ez.root.buf[ez.loc] = item_byte(ExprVarRef(refers[r + 1])))
        end
        ez_next!(ez) || return nothing
    end
end

# =====================================================================
# Anti-unification (least general generalization) — upstream expr/src/lib.rs:669, 2121-2320
# =====================================================================
#
# ✅ VERIFIED AGAINST UPSTREAM'S OWN TEST VECTORS (`test_anti_unify`, lib.rs:2625-2700) — the only
# function in this file with a real oracle. Upstream has just THREE `#[test]` fns and this is one.
#
# 🔴 THE MEMO KEY IS THE WHOLE DIFFICULTY, and a plausible shortcut is WRONG. Keying the memo on the
# raw serialized spans of the two subterms passes vectors 1-3 and FAILS vector 4:
#     `[2] a a` vs `[2] $ _1`  must generalize to `[2] $ _1`
# because `$` (a binder) and `_1` (a reference to it) have different BYTES but are the SAME VARIABLE
# IDENTITY. Upstream says so in its own comment on `RelExprEnv`: "Hash/Eq compares subexpressions
# using *absolute* vars (so NewVar occurrences and VarRef occurrences compare as the same variable
# identity)". Caught by working the oracle's vectors BY HAND before writing any code.
#
# WHY A CANONICAL KEY INSTEAD OF A TRANSLITERATED `==`/`hash` PAIR. Upstream needs both, and its
# `Hash` (lib.rs:2180-2192) is already a CANONICAL SERIALIZATION:
#     NewVar   -> (0, v) with v incrementing from `ee.v`     <- binder at absolute index v
#     VarRef r -> (0, r)                                     <- and a reference to it: IDENTICAL
#     Symbol s -> (1, s...)
#     Arity  a -> (2, a)
# Its lockstep `PartialEq` (:2138-2176) agrees with that form exactly. So emitting the canonical
# token vector and using it directly as the Dict key gives the same equivalence with ONE function
# defining it — and sidesteps Julia's requirement that `a == b => hash(a) == hash(b)`, which a
# hand-written pair could silently violate, making the memo miss and vectors 3-4 regress.

"Upstream `AntiUnificationFailure` (lib.rs:2121-2124)."
@enum AntiUnifyFailureKind AU_TOO_MANY_VARS AU_MAX_DEPTH

struct AntiUnificationFailure <: Exception
    kind::AntiUnifyFailureKind
    depth::Int
end
Base.showerror(io::IO, e::AntiUnificationFailure) =
    print(io, "AntiUnificationFailure: ",
          e.kind === AU_TOO_MANY_VARS ? "> 64 distinct disagreement classes" :
          "max depth exceeded ($(e.depth))")

const AU_MAX_DEPTH_LIMIT = 1000        # upstream `const AU_MAX_DEPTH` (lib.rs:2206)

"""
    _au_relkey(ee) → Vector{UInt8}

The canonical variable-identity key — upstream `RelExprEnv`'s `Hash` (lib.rs:2180-2192) IS this
form, and its `PartialEq` agrees with it. A binder and a reference to that binder both emit
`(0, absolute_index)`, which is what makes them the same identity.
"""
function _au_relkey(ee::ExprEnv)::Vector{UInt8}
    out = UInt8[]
    v = Ref(ee.v)
    _ee_traverseh(nothing, ee,
                  (h, o) -> (push!(out, 0x00); push!(out, v[]); v[] += UInt8(1); (h, nothing)),
                  (h, o, r) -> (push!(out, 0x00); push!(out, r); (h, nothing)),
                  (h, o, s) -> (push!(out, 0x01); append!(out, s); (h, nothing)),
                  (h, o, a) -> (push!(out, 0x02); push!(out, a); (h, nothing)),
                  (h, o, x, y) -> (h, nothing),
                  (h, o, acc) -> (h, acc))
    out
end

"""
    _au_decomposable(lhs, rhs) → Bool

upstream `decomposable` (lib.rs:2209-2225). Variables are treated as ATOMS — a variable on either
side is a disagreement, never a decomposition — so repetition is handled purely by memoizing the
disagreement pair.
"""
function _au_decomposable(lhs::ExprEnv, rhs::ExprEnv)::Bool
    (ee_var_opt(lhs) !== nothing || ee_var_opt(rhs) !== nothing) && return false
    lt = byte_item(lhs.base.buf[Int(lhs.offset) + 1])
    rt = byte_item(rhs.base.buf[Int(rhs.offset) + 1])
    if lt isa ExprSymbol && rt isa ExprSymbol
        lt.size == rt.size || return false
        n = Int(lt.size)
        lo = Int(lhs.offset) + 1
        ro = Int(rhs.offset) + 1
        return view(lhs.base.buf, (lo + 1):(lo + n)) == view(rhs.base.buf, (ro + 1):(ro + n))
    elseif lt isa ExprArity && rt isa ExprArity
        return lt.arity == rt.arity
    end
    false
end

"""
    expr_anti_unify(x, other, oz) → (left, right)

upstream `Expr::anti_unify` (lib.rs:669-679) — first-order syntactic anti-unification (least general
generalization). Writes the generalization into `oz` and returns the substitution maps taking each
introduced variable back to the original left/right subterms.

Upstream's worklist pushes children REVERSED so they pop in preorder; the depth guard fires on the
stack length AFTER the pop, both mirrored here.
"""
function expr_anti_unify(x::MORK.Expr, other::MORK.Expr, oz::ExprZipper)
    memo = Dict{Tuple{Vector{UInt8}, Vector{UInt8}}, UInt8}()
    left = Dict{UInt8, ExprEnv}()
    right = Dict{UInt8, ExprEnv}()
    next_var = Ref(UInt8(0))

    stack = Tuple{ExprEnv, ExprEnv}[(ExprEnv(0, x), ExprEnv(1, other))]
    largs = ExprEnv[]
    rargs = ExprEnv[]

    while !isempty(stack)
        lhs, rhs = pop!(stack)
        length(stack) > AU_MAX_DEPTH_LIMIT &&
            throw(AntiUnificationFailure(AU_MAX_DEPTH, length(stack)))

        if _au_decomposable(lhs, rhs)
            t = byte_item(lhs.base.buf[Int(lhs.offset) + 1])
            if t isa ExprArity
                ez_write_arity!(oz, t.arity)
                empty!(largs)
                empty!(rargs)
                ee_args!(lhs, largs)
                ee_args!(rhs, rargs)
                for i in length(largs):-1:1          # reversed => children pop in order
                    push!(stack, (largs[i], rargs[i]))
                end
            else
                n = Int((t::ExprSymbol).size)
                lo = Int(lhs.offset) + 1
                ez_write_move!(oz, view(lhs.base.buf, lo:(lo + n)))
            end
        else
            # Disagreement: introduce OR REUSE a generalization variable. The reuse is what makes
            # `[2] a a` vs `[2] b b` produce `[2] $ _1` rather than `[2] $ $`.
            key = (_au_relkey(lhs), _au_relkey(rhs))
            v = get(memo, key, nothing)
            if v !== nothing
                ez_write_var_ref!(oz, v)
            else
                next_var[] >= 0x40 && throw(AntiUnificationFailure(AU_TOO_MANY_VARS, 0))
                nv = next_var[]
                next_var[] += UInt8(1)
                memo[key] = nv
                left[nv] = lhs
                right[nv] = rhs
                ez_write_new_var!(oz)
            end
        end
    end
    (left, right)
end

"""
    expr_prefix_non_proper(x) → SubArray{UInt8}

upstream `Expr::prefix_non_proper` (lib.rs:393-401) — the constant prefix before the first VARIABLE
item, and when there is no variable at all, the WHOLE expression rather than an error:

    Break(offset)    => slice_from_raw_parts(self.ptr, offset)      // proper prefix
    Continue(offset) => slice_from_raw_parts(self.ptr, offset - 1)  // full expr

That second arm is the whole point of the `_non_proper` name: `prefix()` has no answer for a ground
expression, this one returns the expression itself.
"""
function expr_prefix_non_proper(x::MORK.Expr)
    i = 1
    n = length(x.buf)
    while i <= n
        t = byte_item(x.buf[i])
        if t isa ExprNewVar || t isa ExprVarRef
            return view(x.buf, 1:(i - 1))          # proper prefix: everything before the variable
        elseif t isa ExprSymbol
            i += 1 + Int(t.size)
        else
            i += 1                                  # Arity
        end
    end
    view(x.buf, 1:n)                                # no variable anywhere => the full expression
end

"""
    ez_subexpr(z) → Expr

upstream `ExprZipper::subexpr` (lib.rs:1251) — `Expr { ptr: self.root.ptr.byte_add(self.loc) }`,
the sub-expression rooted at the zipper's current location. Upstream offsets a pointer; we take the
tail of the buffer, which is the same expression.
"""
ez_subexpr(z::ExprZipper)::MORK.Expr = MORK.Expr(z.root.buf[z.loc:end])

# =====================================================================
# Exports
# =====================================================================

export expr_variables, expr_is_ground, expr_max_arity, expr_has_unbound
export expr_forward_references, expr_difference_under, ez_subexpr, expr_prefix_non_proper
export expr_unbind, expr_equate_var, expr_equate_var_inplace!, expr_equate_vars_inplace!
export expr_anti_unify, AntiUnificationFailure, AntiUnifyFailureKind, AU_TOO_MANY_VARS, AU_MAX_DEPTH
export expr_traverseh, ee_args!
export UnificationFailureKind, UNIF_OCCURS, UNIF_DIFFERENCE, UNIF_MAX_ITER
export UnificationFailure, expr_unify, _expr_unify_inplace!
export expr_apply, ee_show
