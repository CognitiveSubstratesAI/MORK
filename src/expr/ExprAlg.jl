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
# Exports
# =====================================================================

export expr_traverseh, ee_args!
export UnificationFailureKind, UNIF_OCCURS, UNIF_DIFFERENCE, UNIF_MAX_ITER
export UnificationFailure, expr_unify, _expr_unify_inplace!
export expr_apply, ee_show
