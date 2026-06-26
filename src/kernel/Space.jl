"""
Space — port of `mork/kernel/src/space.rs`.

The `Space` struct is the central data structure of the MORK kernel: a
`PathMap{UnitVal}` (set-trie of flat byte-encoded expressions) coupled with
a `SharedMappingHandle` for symbol interning.

Julia translation notes
========================
  - `PathMap<()>` → `PathMap{UnitVal}` (unit-value set-trie)
  - `#[cfg(feature="interning")]` path → raw-bytes (no-interning) variant
    (symbols stored as raw UTF-8 truncated to 63 bytes, matching the
    `#[cfg(not(feature="interning"))]` code path in upstream)
  - `coreferential_transition` (DFS) → IMPLEMENTED (`_coreferential_transition!` +
    `space_query_coref`, single- and multi-source; ports upstream e551924). `query_multi`
    additionally has the `#[cfg(feature="no_search")]` ProductZipper + unify fast path.
    (SP-4 fix 2026-06-04: header previously called the coref DFS "deferred" — stale.)
  - `setjmp`/`longjmp` early-exit → Julia `throw`/`catch` (BreakQuery)
  - `subprocess::Popen` (Z3 integration) → stubbed
  - `memmap2::Mmap` (ACT memory-mapped files) → stubbed
"""

# =====================================================================
# Bitmask constants (mirrors SIZES/ARITIES/VARS in space.rs)
# =====================================================================

"""
Byte → category bitmask mapping for expression byte tags.
`SPACE_SIZES[((b & 0xC0) >> 6) + 1]` has bit `(b & 0x3F)` set iff `b` encodes
a SymbolSize tag.  Same structure for SPACE_ARITIES and SPACE_VARS.
"""
function _build_space_mask(predicate::Function)
    result = zeros(UInt64, 4)
    for b_int in 0:255
        b = UInt8(b_int)
        tag = try
            byte_item(b)
        catch
            ;
            continue
        end   # skip reserved bytes
        if predicate(tag)
            bucket = Int((b & 0xC0) >> 6) + 1
            bit = Int(b & 0x3F)
            result[bucket] |= UInt64(1) << bit
        end
    end
    NTuple{4, UInt64}(result)
end

const SPACE_SIZES = _build_space_mask(t -> t isa ExprSymbol)
const SPACE_ARITIES = _build_space_mask(t -> t isa ExprArity)
const SPACE_VARS = _build_space_mask(t -> t isa ExprNewVar || t isa ExprVarRef)

# =====================================================================
# Fix 3: task-local ReadZipperCore pool — eliminates per-query heap alloc
# =====================================================================
#
# Each call to _space_query_multi_inner! previously allocated fresh
# ReadZipperCore objects for secondary factors via read_zipper_at_path.
# The pool stores up to 8 reusable zippers per task.  On checkout the
# zipper is reinitialized from the current btm root; on return it is
# handed back to the pool (no reset needed — reinit is always full).
#
# Uses Julia's built-in task_local_storage so it is task-safe by
# construction and does not require any external packages.

const _ZIPPER_POOL_KEY = :_mork_zipper_pool

@inline function _zipper_pool_get!()::Vector{Any}
    get!(task_local_storage(), _ZIPPER_POOL_KEY, Any[])::Vector{Any}
end

@inline function _pool_checkout!(pool::Vector{Any})
    isempty(pool) ? nothing : pop!(pool)
end

@inline function _pool_return!(pool::Vector{Any}, z)
    length(pool) < 8 && push!(pool, z)
    nothing
end

"""
    _reinit_zipper_from_btm!(z, btm::PathMap{UnitVal})

Reset a pooled ReadZipperCore to point at the root of `btm`.
Reuses the existing prefix_buf and ancestors vectors (just resizes them)
so the only allocation is the node reference update — no heap alloc.
"""
@inline function _reinit_zipper_from_btm!(z, btm::PathMap{UnitVal})
    _ensure_root!(btm)   # exported from PathMap, in scope via `using PathMap`
    root_rc = btm.root::TrieNodeODRc{UnitVal, GlobalAlloc}
    z.root_node = root_rc
    z.root_val = btm.root_val
    z.alloc = btm.alloc
    z.root_key_start = 0
    z.origin_path_len = 0
    resize!(z.prefix_buf, 0)
    empty!(z.ancestors)
    z.focus_node = root_rc.node
    z.focus_iter_token = NODE_ITER_INVALID   # exported from PathMap
    nothing
end

# =====================================================================
# SpaceParser — tokenizer without interning (mirrors ParDataParser, no-intern)
# =====================================================================

"""
    SpaceParser

`MorkParser` whose `fe_tokenizer` truncates symbols to 63 bytes.
Mirrors `ParDataParser` with `cfg(not(feature="interning"))` in space.rs.
"""
struct SpaceParser <: MorkParser
    count::Ref{Int}
    SpaceParser() = new(Ref(0))
end

function fe_tokenizer(p::SpaceParser, s::AbstractVector{UInt8})::Vector{UInt8}
    p.count[] += 1
    n = min(length(s), 63)
    Vector{UInt8}(s[1:n])
end

# =====================================================================
# Space struct
# =====================================================================

"""
    Space

Central MORK data structure: a `PathMap{UnitVal}` set-trie of flat byte-encoded
expressions plus a symbol intern table.
Mirrors `Space` in mork/kernel/src/space.rs.
"""
mutable struct Space
    btm::PathMap{UnitVal, GlobalAlloc}
    sm::SharedMappingHandle
    timing::Bool
    mmaps::Dict{String, ArenaCompactTree}   # ACT file cache (mirrors mmaps in Space)
end

"""    new_space() → Space

Create an empty Space.  Mirrors `Space::new`.
"""
new_space() = Space(
    PathMap{UnitVal}(), SharedMappingHandle(), false, Dict{String, ArenaCompactTree}()
)

# Prevent Julia's default struct show from dumping raw PathMap bytes to stdout.
# Upstream equivalent: Space::statistics() prints "val count N".
Base.show(io::IO, s::Space) =
    print(io, "Space($(space_val_count(s)) atoms)")

"""    space_val_count(s) → Int

Return the number of expressions stored in the Space.
"""
space_val_count(s::Space) = val_count(s.btm)

"""    space_statistics(s)

Print basic statistics.  Mirrors `Space::statistics`.
"""
function space_statistics(s::Space)
    println("val count ", space_val_count(s))
end

# =====================================================================
# space_add_all_sexpr! / space_remove_all_sexpr! / load_all_sexpr_impl!
# =====================================================================

"""
    space_add_all_sexpr!(s, src) → Int

Parse multiple whitespace-separated s-expressions from `src` and add each
to the Space.  Mirrors `Space::add_all_sexpr`.
"""
space_add_all_sexpr!(s::Space, src) = _space_load_all_sexpr_impl!(s, src, true)

"""
    space_remove_all_sexpr!(s, src) → Int

Remove each parsed s-expression from the Space.
Mirrors `Space::remove_all_sexpr`.
"""
space_remove_all_sexpr!(s::Space, src) = _space_load_all_sexpr_impl!(s, src, false)

function _space_load_all_sexpr_impl!(s::Space, src, add::Bool)::Int
    bv = src isa Vector{UInt8} ? src : Vector{UInt8}(src)
    ctx = SexprContext(bv)
    parser = SpaceParser()
    i = 0
    while true
        # Fresh buffer per expression (mirrors stack[] in Rust)
        buf = Vector{UInt8}(undef, max(length(bv) * 2, 64))
        z = ExprZipper(MORK.Expr(buf), 1)
        try
            sexpr_parse!(parser, ctx, z)
        catch e
            if e isa SexprException && e.err == SERR_INPUT_FINISHED
                break
            end
            rethrow()
        end
        data = z.root.buf[1:(z.loc - 1)]
        if add
            set_val_at!(s.btm, data, UNIT_VAL)
        else
            remove_val_at!(s.btm, data)
        end
        empty!(ctx.variables)   # clear variable bindings between expressions
        i += 1
    end
    i
end

# =====================================================================
# space_dump_all_sexpr
# =====================================================================

"""
    space_dump_all_sexpr(s, io) → Int

Write all stored expressions to `io`, one per line, in s-expression text form.
Mirrors `Space::dump_all_sexpr` (no-interning path).
"""
function space_dump_all_sexpr(s::Space, io::IO)::Int
    rz = read_zipper(s.btm)
    i = 0
    while zipper_to_next_val!(rz)
        path = collect(zipper_path(rz))
        println(io, expr_serialize(path))
        i += 1
    end
    i
end

space_dump_all_sexpr(s::Space) =
    (io=IOBuffer(); space_dump_all_sexpr(s, io); String(take!(io)))

# =====================================================================
# space_load_json! — JSON → PathMap (mirrors Space::load_json)
# =====================================================================

"""
    SpaceTranscriber

`JSONTranscriber` that writes parsed JSON tokens into a `WriteZipperCore`.
Mirrors `SpaceTranscriber` in space.rs.
"""
mutable struct SpaceTranscriber <: JSONTranscriber
    count::Int
    wz::WriteZipperCore
    parser::SpaceParser
end

function SpaceTranscriber(wz::WriteZipperCore)
    SpaceTranscriber(0, wz, SpaceParser())
end

function _st_write!(t::SpaceTranscriber, bytes::AbstractVector{UInt8})
    tok = fe_tokenizer(t.parser, bytes)
    path = vcat(UInt8[item_byte(ExprSymbol(UInt8(length(tok))))], tok)
    wz_descend_to!(t.wz, path)
    wz_set_val!(t.wz, UNIT_VAL)
    wz_ascend!(t.wz, length(path))
    t.count += 1
end

jt_begin!(t::SpaceTranscriber) = nothing
jt_end!(t::SpaceTranscriber) = nothing
jt_write_empty_array!(t::SpaceTranscriber) = _st_write!(t, Vector{UInt8}("[]"))
jt_write_empty_object!(t::SpaceTranscriber) = _st_write!(t, Vector{UInt8}("{}"))
jt_write_true!(t::SpaceTranscriber) = _st_write!(t, Vector{UInt8}("true"))
jt_write_false!(t::SpaceTranscriber) = _st_write!(t, Vector{UInt8}("false"))
jt_write_null!(t::SpaceTranscriber) = _st_write!(t, Vector{UInt8}("null"))
jt_write_string!(t::SpaceTranscriber, s::String) = _st_write!(t, Vector{UInt8}(s))

function jt_write_number!(t::SpaceTranscriber, neg::Bool, m::UInt64, e::Int16)
    s = neg ? "-$(m)" : "$(m)"
    e != 0 && (s *= "e$(e)")
    _st_write!(t, Vector{UInt8}(s))
end

function jt_descend_index!(t::SpaceTranscriber, i::Int, first::Bool)
    first && wz_descend_to!(t.wz, UInt8[item_byte(ExprArity(UInt8(2)))])
    tok = fe_tokenizer(t.parser, Vector{UInt8}(string(i)))
    path = vcat(UInt8[item_byte(ExprSymbol(UInt8(length(tok))))], tok)
    wz_descend_to!(t.wz, path)
end

function jt_ascend_index!(t::SpaceTranscriber, i::Int, last::Bool)
    tok = fe_tokenizer(t.parser, Vector{UInt8}(string(i)))
    wz_ascend!(t.wz, length(tok) + 1)
    last && wz_ascend!(t.wz, 1)
end

function jt_descend_key!(t::SpaceTranscriber, k::String, first::Bool)
    first && wz_descend_to!(t.wz, UInt8[item_byte(ExprArity(UInt8(2)))])
    tok = fe_tokenizer(t.parser, Vector{UInt8}(k))
    path = vcat(UInt8[item_byte(ExprSymbol(UInt8(length(tok))))], tok)
    wz_descend_to!(t.wz, path)
end

function jt_ascend_key!(t::SpaceTranscriber, k::String, last::Bool)
    tok = fe_tokenizer(t.parser, Vector{UInt8}(k))
    wz_ascend!(t.wz, length(tok) + 1)
    last && wz_ascend!(t.wz, 1)
end

"""
    space_load_json!(s, src) → Int

Parse JSON `src` and insert the resulting expression tree into the Space.
Mirrors `Space::load_json`.
"""
function space_load_json!(s::Space, src)::Int
    bv = src isa Vector{UInt8} ? src : Vector{UInt8}(src)
    wz = write_zipper(s.btm)
    st = SpaceTranscriber(wz)
    p = JSONParser(bv)
    json_parse!(p, st)
    st.count
end

# =====================================================================
# space_query_multi — pattern matching (no_search / ProductZipper + unify)
# =====================================================================

"""
    BreakQuery

Exception used to implement early termination of a query (mirrors `longjmp`
in the Rust implementation).
"""
struct BreakQuery <: Exception end

"""
    space_query_multi(btm, pat_expr, effect) → Int

Iterate all expressions in `btm` that unify with the pattern encoded in
`pat_expr`, calling `effect(bindings, expr_bytes) -> Bool` on each match.
Return the total number of candidates examined.

`pat_expr` must be an arity node: first child is the "add" expression,
remaining children are the sources (patterns to unify against).
Matches iterate via `ProductZipper` (the `#[cfg(feature="no_search")]` path).

The `bindings` Dict passed to `effect` is a fresh allocation per match — safe
to retain across calls.  (Internal path uses a scratch Dict + copy-on-yield to
eliminate per-failed-unify allocations while preserving this contract.)

Mirrors `Space::query_multi` in space.rs.
"""
function space_query_multi(btm::PathMap{UnitVal}, pat_expr::MORK.Expr,
    pat_v::UInt8, effect::Function)::Int
    pat_tag = byte_item(pat_expr.buf[1])
    pat_tag isa ExprArity || error("pat_expr must be an Arity node")
    n_factors = Int(pat_tag.arity)
    n_factors > 0 || error("pat_expr arity must be > 0")

    if n_factors == 1
        effect(Dict{ExprVar, ExprEnv}(), pat_expr.buf)
        return 1
    end

    _bindings_scratch = Dict{ExprVar, ExprEnv}()
    _pairs_scratch = Tuple{ExprEnv, ExprEnv}[]

    _space_query_multi_inner!(btm, pat_expr, pat_v, n_factors, effect,
        _bindings_scratch, _pairs_scratch)
end

# Compat wrapper with pat_v=0
space_query_multi(btm::PathMap{UnitVal}, pat_expr::MORK.Expr, effect::Function) =
    space_query_multi(btm, pat_expr, UInt8(0), effect)

"""
    space_query_multi_at(btm, prefix, pat_expr, [pat_v], effect) → Int

Prefix-anchored variant of `space_query_multi`.  All factor zippers anchor
at `prefix` (rather than root), so the query operates on the subtrie under
`prefix`.  The combined path passed to `effect` is the FULL path including
`prefix` — callers that want path bytes relative to the prefix should strip
the leading `length(prefix)` bytes themselves.

Use case: Core's "spaces as prefixes" model (Stage 1 of single-node
convergence) where `common:/`, `app/games:/`, etc. are sibling byte-regions
in one shared trie.  Routing a query under one space's prefix limits its
results to that space without scanning the whole trie.

Upstream parity note: upstream MORK has commented-out experiments at this
shape (kernel/src/space.rs:1883, 2117) but no shipped public API.  This
function is the Julia kernel filling that gap — follows the existing `_at!`
pattern from `space_metta_calculus_at!`.
"""
function space_query_multi_at(btm::PathMap{UnitVal}, prefix::Vector{UInt8},
    pat_expr::MORK.Expr, pat_v::UInt8, effect::Function)::Int
    isempty(prefix) && return space_query_multi(btm, pat_expr, pat_v, effect)

    pat_tag = byte_item(pat_expr.buf[1])
    pat_tag isa ExprArity || error("pat_expr must be an Arity node")
    n_factors = Int(pat_tag.arity)
    n_factors > 0 || error("pat_expr arity must be > 0")

    if n_factors == 1
        effect(Dict{ExprVar, ExprEnv}(), pat_expr.buf)
        return 1
    end

    _bindings_scratch = Dict{ExprVar, ExprEnv}()
    _pairs_scratch = Tuple{ExprEnv, ExprEnv}[]

    _space_query_multi_inner!(btm, pat_expr, pat_v, n_factors, effect,
        _bindings_scratch, _pairs_scratch; prefix=prefix)
end

space_query_multi_at(btm::PathMap{UnitVal}, prefix::Vector{UInt8},
    pat_expr::MORK.Expr, effect::Function) =
    space_query_multi_at(btm, prefix, pat_expr, UInt8(0), effect)

# =====================================================================
# space_query_multi_i — I-pattern query using ASource dispatch
# Mirrors Space::query_multi_i (no_source=false path) in space.rs.
#
# For each argument of the I-pattern, calls asource_new() to dispatch:
#   CompatSource / BTMSource → plain read zipper (same as comma pattern)
#   CmpSource (== / !=)      → PrefixZipper<DependentZipper> via source_factor
#
# All factors are combined in a ProductZipperG, then iterated like
# query_multi_raw: focus must be on the last factor before yielding.
# origin_path (including any prefix from CmpSource) is used as the
# expression for unification, with factor_paths adjusted by prefix length.
# =====================================================================

function space_query_multi_i(btm::PathMap{UnitVal}, pat_expr::MORK.Expr,
    pat_v::UInt8, effect::Function;
    mmaps::Dict{String, ArenaCompactTree}=Dict{String, ArenaCompactTree}())::Int
    pat_tag = byte_item(pat_expr.buf[1])
    pat_tag isa ExprArity || return 0
    n_factors = Int(pat_tag.arity)
    n_factors > 0 || return 0

    if n_factors == 1
        effect(Dict{ExprVar, ExprEnv}(), pat_expr.buf)
        return 1
    end

    pat_args = ExprEnv[]
    ee_args!(ExprEnv(UInt8(0), pat_v, UInt32(0), pat_expr), pat_args)
    sources = pat_args[2:end]   # ExprEnv for each sub-pattern

    # Separate grounded sources from trie sources.
    # GroundedSources are evaluated AFTER trie sources match, using bound variables.
    src_types = ASource[]
    trie_idxs = Int[]    # indices into sources[] of trie (non-grounded) sources
    grnd_idxs = Int[]    # indices into sources[] of grounded sources
    for (k, ee) in enumerate(sources)
        span = expr_span(ee.base, Int(ee.offset) + 1)
        sub = MORK.Expr(Vector{UInt8}(span))
        src = asource_new(sub)
        push!(src_types, src)
        src isa GroundedSource ? push!(grnd_idxs, k) : push!(trie_idxs, k)
    end

    candidate = 0
    bindings_scratch = Dict{ExprVar, ExprEnv}()
    pairs_scratch = Tuple{ExprEnv, ExprEnv}[]

    # ── Case 1: all sources are grounded (no trie query needed) ──────
    if isempty(trie_idxs)
        for k in grnd_idxs
            src = src_types[k]::GroundedSource
            results = _grounded_call_no_args(src)
            for path in results
                candidate += 1
                effect(Dict{ExprVar, ExprEnv}(), path) || return candidate
            end
        end
        return candidate
    end

    # ── Case 2: mixed or trie-only — build ProductZipperG for trie sources ──
    trie_ees = sources[trie_idxs]
    trie_srcs = src_types[trie_idxs]
    factors = Any[]
    for (src, ee) in zip(trie_srcs, trie_ees)
        factor =
            src isa ACTSource ? source_factor(src, btm, mmaps) : source_factor(src, btm)
        push!(factors, factor)
    end

    primary = popfirst!(factors)
    prz = ProductZipperG(primary, factors)
    prefix_len = pzg_root_prefix_len(prz)

    while pzg_to_next_val!(prz)
        pzg_focus_factor(prz) != pzg_factor_count(prz) - 1 && continue

        combined = collect(pzg_origin_path(prz))
        fps = pzg_factor_paths(prz)
        boundaries = vcat(0, [fp + prefix_len for fp in fps], length(combined))

        empty!(pairs_scratch)
        all_sliced = true
        for (i, ee) in enumerate(trie_ees)
            lo = boundaries[i] + 1
            hi = boundaries[i + 1]
            if lo > hi || lo > length(combined)
                all_sliced = false;
                break
            end
            expr = MORK.Expr(combined[lo:hi])
            push!(pairs_scratch, (ee, ExprEnv(UInt8(i), UInt8(0), UInt32(0), expr)))
        end
        all_sliced || continue

        pzg_child_count(prz) != 0 && (empty!(bindings_scratch); continue)

        # SP-1 fix (audit 2026-06-04): was `try …unify… catch; nothing end`, which
        # swallowed EVERY exception as a benign no-match. `_expr_unify_inplace!` returns
        # its failure as a VALUE (≠ true) on genuine non-unification and only THROWS on a
        # real bug (malformed expr / BoundsError) — so the catch could only hide bugs.
        # The root paths (`_space_query_multi_inner!`) call it directly; match them.
        result = _expr_unify_inplace!(pairs_scratch, bindings_scratch)
        if result !== true
            empty!(bindings_scratch)
            continue
        end

        # Apply bindings to each grounded source and call the function
        trie_bindings = copy(bindings_scratch)
        empty!(bindings_scratch)

        if isempty(grnd_idxs)
            # No grounded sources — emit directly
            candidate += 1
            effect(trie_bindings, combined) || break
        else
            # For each grounded source: substitute bound variables, call, emit per result
            emit = true
            for k in grnd_idxs
                src = src_types[k]::GroundedSource
                result_paths = _grounded_call_with_bindings(src, trie_bindings)
                isempty(result_paths) && (emit=false; break)
                for rpath in result_paths
                    candidate += 1
                    merged = vcat(combined, rpath)
                    effect(trie_bindings, merged) || return candidate
                end
                emit = false  # already emitted above
            end
        end
    end

    candidate
end

# ── Grounded call helpers ─────────────────────────────────────────────

"""Call a GroundedSource with no variable arguments (all-grounded case)."""
function _grounded_call_no_args(src::GroundedSource)::Vector{Vector{UInt8}}
    f = get(GROUNDED_REGISTRY, src.name, nothing)
    f === nothing && return Vector{UInt8}[]
    args = _grounded_decode_args(src.expr)
    raw = try
        f(args)
    catch e
        ;
        @warn "GroundedSource $(src.name): $e";
        nothing
    end
    _grounded_encode_results(raw)
end

"""Call a GroundedSource after substituting trie-matched variable bindings."""
function _grounded_call_with_bindings(src::GroundedSource,
    bindings::Dict{ExprVar, ExprEnv})::Vector{Vector{UInt8}}
    f = get(GROUNDED_REGISTRY, src.name, nothing)
    f === nothing && return Vector{UInt8}[]
    # Apply bindings to each argument before decoding
    raw_args = _grounded_decode_args(src.expr)
    bound_args = map(raw_args) do a
        # Re-encode the arg string, apply bindings, re-decode
        try
            e = sexpr_to_expr(a)
            applied = _expr_apply_bindings(e, bindings)
            expr_serialize(applied.buf)
        catch
            a  # fallback: pass as-is
        end
    end
    raw = try
        f(bound_args)
    catch e
        ;
        @warn "GroundedSource $(src.name): $e";
        nothing
    end
    _grounded_encode_results(raw)
end

"""Apply variable bindings to an Expr, returning a new Expr with variables replaced."""
function _expr_apply_bindings(e::MORK.Expr, bindings::Dict{ExprVar, ExprEnv})::MORK.Expr
    isempty(bindings) && return e
    # Walk bytes and substitute NewVar/VarRef bytes with bound expression bytes
    out = UInt8[]
    buf = e.buf
    i = 1
    var_idx = UInt8(0)
    while i <= length(buf)
        b = buf[i]
        t = byte_item(b)
        if t isa ExprNewVar
            binding = get(bindings, ExprVar(var_idx, UInt8(0)), nothing)
            if binding !== nothing
                span = expr_span(binding.base, Int(binding.offset) + 1)
                append!(out, span)
            else
                push!(out, b)
            end
            var_idx += UInt8(1)
            i += 1
        elseif t isa ExprVarRef
            binding = get(bindings, ExprVar(UInt8(0), t.index), nothing)
            if binding !== nothing
                span = expr_span(binding.base, Int(binding.offset) + 1)
                append!(out, span)
            else
                push!(out, b)
            end
            i += 1
        elseif t isa ExprSymbol
            n = Int(t.size)
            append!(out, buf[i:(i + n)])
            i += n + 1
        elseif t isa ExprArity
            push!(out, b)
            i += 1
        else
            push!(out, b);
            i += 1
        end
    end
    MORK.Expr(out)
end

space_query_multi_i(btm::PathMap{UnitVal}, pat_expr::MORK.Expr, effect::Function) =
    space_query_multi_i(btm, pat_expr, UInt8(0), effect)

# Internal hot path — takes pre-allocated scratch buffers so the
# per-unify-attempt Dict allocation is eliminated.
#
# `prefix` kwarg (default empty = root) anchors all factor zippers at the
# given byte-prefix.  Empty prefix preserves the original root-anchored
# behavior — no overhead for the common case.
function _space_query_multi_inner!(btm::PathMap{UnitVal},
    pat_expr::MORK.Expr,
    pat_v::UInt8,
    n_factors::Int,
    effect::Function,
    bindings_scratch::Dict{ExprVar, ExprEnv},
    pairs_scratch::Vector{Tuple{ExprEnv, ExprEnv}};
    prefix::Vector{UInt8}=UInt8[])::Int
    # Rule of 64: warn if pattern exceeds practical source limit.
    # ProductZipper with N>2 factors iterates N^M paths (M=trie depth) and
    # becomes intractable beyond 2 secondary factors in practice.
    n_factors > 4 &&
        @warn "query_multi: $(n_factors) sources (>4) may be slow — Rule of 64 boundary"

    pat_args = ExprEnv[]
    ee0 = ExprEnv(UInt8(0), pat_v, UInt32(0), pat_expr)
    ee_args!(ee0, pat_args)
    sources = pat_args[2:end]

    candidate = 0
    # Fix 3: checkout secondary zippers from the task-local pool instead of
    # allocating fresh ReadZipperCore objects on every call.  The primary is
    # still freshly allocated (ProductZipper mutates it as its cursor).
    # Pooled zippers are reinitialized from btm before use and returned after
    # ProductZipper is constructed (constructor only reads root_node/root_val/alloc).
    n_secondaries = n_factors - 2
    # Build the product zipper.  Two anchoring regimes:
    #   • empty prefix (root query, the hot path): pooled secondary zippers,
    #     unchanged from the original implementation.
    #   • non-empty prefix: the anchored ProductZipper(btm, prefix, k) which
    #     roots ALL k = n_factors-1 factors at the prefix-subtrie node (a true
    #     O(subtrie) view).  This replaces the old read_zipper_at_path(btm,
    #     prefix) approach, whose anchor the base ProductZipper discarded —
    #     producing absolute paths whose raw prefix bytes crashed expr decode.
    prz = if isempty(prefix)
        pool = _zipper_pool_get!()
        secondaries_pooled = Vector{Any}(undef, n_secondaries)
        primary = read_zipper_at_path(btm, prefix)
        for i in 1:n_secondaries
            z = _pool_checkout!(pool)
            if z === nothing
                z = read_zipper_at_path(btm, prefix)
            else
                _reinit_zipper_from_btm!(z, btm)
            end
            secondaries_pooled[i] = z
        end
        p = ProductZipper(primary, secondaries_pooled)
        for i in 1:n_secondaries
            _pool_return!(pool, secondaries_pooled[i])   # ProductZipper extracted root refs
        end
        p
    else
        ProductZipper(btm, prefix, n_factors - 1)
    end

    try
        while pz_to_next_val!(prz)
            pz_focus_factor(prz) != pz_factor_count(prz) - 1 && continue

            # The ProductZipper encodes ALL factor paths in ONE combined path
            # via pz.z (the primary zipper). factor_paths[i] marks the byte
            # boundary where factor i ends / factor i+1 begins.
            #
            # For k sources: factor_paths has k-1 entries.
            #   source 1 expression: combined[1 : factor_paths[1]]
            #   source i expression: combined[factor_paths[i-1]+1 : factor_paths[i]]
            #   last source:         combined[factor_paths[end]+1 : end]
            # For single source: factor_paths is empty, use full path.
            combined = collect(pz_path(prz))
            fps = prz.factor_paths   # path-length boundaries, 1-based

            empty!(pairs_scratch)
            # Slice the combined path for each source
            boundaries = vcat(0, fps, length(combined))
            all_valued = true
            for (k, src) in enumerate(sources)
                lo = boundaries[k] + 1
                hi = boundaries[k + 1]
                (lo > hi || lo > length(combined)) && break
                subpath = combined[lo:hi]
                # Value gate: the matched factor must be a REAL stored atom (a value
                # at its path), not a dangling path-node left behind by a non-pruning
                # remove_val_at! (e.g. RemoveSink / the `-` O-sink). The ProductZipper
                # can land on such a valueless path; without this check a removed atom
                # keeps matching, and Control_08_Halts_on_fail never terminates. This
                # restores the value-presence invariant upstream's path_exists()-gated
                # query_multi relies on. See experiments/mm2_programs.
                lookup = isempty(prefix) ? subpath : vcat(prefix, subpath)
                if get_val_at(btm, lookup) === nothing
                    all_valued = false
                    break
                end
                expr = MORK.Expr(subpath)
                push!(pairs_scratch,
                    (src, ExprEnv(UInt8(k), UInt8(0), UInt32(0), expr)))
            end

            # Skip spurious enrollment-only yields (secondary path empty) or a match
            # that touched a value-removed dangling path.
            if !all_valued || length(pairs_scratch) < length(sources)
                empty!(bindings_scratch)
                continue
            end

            # Unify into scratch Dict (zero alloc on failure)
            result = _expr_unify_inplace!(pairs_scratch, bindings_scratch)
            if result === true
                candidate += 1
                # Copy scratch → fresh Dict before yielding to user (Option A).
                # This preserves the public contract: effect may retain bindings.
                bindings_out = copy(bindings_scratch)
                empty!(bindings_scratch)
                if !effect(bindings_out, MORK.Expr(combined))
                    throw(BreakQuery())
                end
            else
                empty!(bindings_scratch)   # failed — clear for next attempt
            end
        end
    catch e
        e isa BreakQuery || rethrow()
    end

    candidate
end

space_query_multi(s::Space, pat::MORK.Expr, f::Function) =
    space_query_multi(s.btm, pat, f)

# =====================================================================
# coreferential_transition — DFS query (the no_search=false path)
# =====================================================================
#
# Mirrors `coreferential_transition` in space.rs (lines 92–212).
#
# This is the alternative to ProductZipper for multi-source queries.
# Instead of generating the full Cartesian product then filtering via
# unify, this DFS tracks variable bindings DURING trie traversal:
#
#   ProductZipper (current):  O(K^N) candidates → filter → O(M) matches
#   Coreferential DFS:        O(M × depth) — explores only consistent paths
#
# When the same variable appears in multiple sources, the DFS records
# the trie path length at first binding (references[i]) and on VarRef
# descends directly to that sub-path — skipping all inconsistent branches.
#
# Algorithm (mirrors Rust recursive DFS):
#   stack  — remaining ExprEnv items to match (popped LIFO)
#   references — path-length offsets for De Bruijn NewVar bindings
#   When stack is empty, f(loc) is called (a match has been found).

# ── Zipper-type-agnostic helpers for _coreferential_transition! ───────────────
# These dispatch on both ReadZipperCore (single-source) and ProductZipper
# (multi-source), allowing one DFS implementation for both paths.

@inline _coref_child_mask(loc::ReadZipperCore) = zipper_child_mask(loc)
@inline _coref_child_mask(loc::ProductZipper) = pz_child_mask(loc)

@inline _coref_path(loc::ReadZipperCore) = zipper_path(loc)
@inline _coref_path(loc::ProductZipper) = pz_path(loc)

@inline _coref_descend_byte!(loc::ReadZipperCore, b::UInt8) =
    zipper_descend_to_byte!(loc, b)
@inline _coref_descend_byte!(loc::ProductZipper, b::UInt8) = pz_descend_to_byte!(loc, b)

@inline _coref_ascend_byte!(loc::ReadZipperCore) = zipper_ascend_byte!(loc)
@inline _coref_ascend_byte!(loc::ProductZipper) = pz_ascend_byte!(loc)

@inline _coref_ascend!(loc::ReadZipperCore, n::Int) = zipper_ascend!(loc, n)
@inline _coref_ascend!(loc::ProductZipper, n::Int) = pz_ascend!(loc, n)

@inline function _coref_descend_to_existing_byte!(loc::ReadZipperCore, b::UInt8)
    zipper_descend_to_existing_byte!(loc, b)
end
@inline function _coref_descend_to_existing_byte!(loc::ProductZipper, b::UInt8)
    pz_descend_to_existing_byte!(loc, b)
end

@inline function _coref_descend_to_check!(loc::ReadZipperCore, bytes)
    zipper_descend_to_check!(loc, bytes)
end
@inline function _coref_descend_to_check!(loc::ProductZipper, bytes)
    pz_descend_to_check!(loc, bytes)
end

@inline function _coref_descend_first_k_path!(loc::ReadZipperCore, k::Int)
    zipper_descend_first_k_path!(loc, k)
end
@inline function _coref_descend_first_k_path!(loc::ProductZipper, k::Int)
    pz_descend_first_k_path!(loc, k)
end

@inline function _coref_to_next_k_path!(loc::ReadZipperCore, k::Int)
    zipper_to_next_k_path!(loc, k)
end
@inline function _coref_to_next_k_path!(loc::ProductZipper, k::Int)
    pz_to_next_k_path!(loc, k)
end

# Filtered child lists using precomputed bitmasks — avoids calling byte_item on
# content bytes (0x40-0x7F are reserved and throw; e.g. 'e' = 0x65 from "edge").
# SPACE_VARS/SIZES/ARITIES are NTuple{4,UInt64}: bucket = (b>>6)+1, bit = b&0x3F.
@inline _in_mask(mask::NTuple{4, UInt64}, b::UInt8) =
    ((mask[Int(b >> 6) + 1] >> Int(b & 0x3F)) & UInt64(1)) != UInt64(0)

@inline _var_children(loc) =
    Iterators.filter(b -> _in_mask(SPACE_VARS, b), _coref_child_mask(loc))
@inline _size_children(loc) =
    Iterators.filter(b -> _in_mask(SPACE_SIZES, b), _coref_child_mask(loc))
@inline _arity_children(loc) =
    Iterators.filter(b -> _in_mask(SPACE_ARITIES, b), _coref_child_mask(loc))

"""
    _coreferential_transition!(loc, stack, references, f)

Recursive DFS that explores the trie `loc` matching `stack` of ExprEnvs.
Calls `f(loc)` for each complete match (empty stack).
Mirrors `coreferential_transition` in space.rs.
"""
function _coreferential_transition!(loc,   # ReadZipperCore (single) or ProductZipper (multi)
    stack::Vector{ExprEnv},
    references::Vector{Int},
    f::Function)
    if isempty(stack)
        f(loc)
        return nothing
    end

    e = pop!(stack)
    e_byte = e.base.buf[Int(e.offset) + 1]

    tag = byte_item(e_byte)

    if tag isa ExprNewVar
        if e.n == 0
            push!(references, length(_coref_path(loc)))
        end

        m_vars = _var_children(loc)
        for b in m_vars
            _coref_descend_byte!(loc, b)
            _coreferential_transition!(loc, stack, references, f)
            _coref_ascend_byte!(loc)
        end

        m_sizes = _size_children(loc)
        for b in m_sizes
            tag_s = byte_item(b)
            tag_s isa ExprSymbol || continue
            size = Int(tag_s.size)
            _coref_descend_byte!(loc, b)
            if _coref_descend_first_k_path!(loc, size)
                while true
                    _coreferential_transition!(loc, stack, references, f)
                    _coref_to_next_k_path!(loc, size) || break
                end
            end
            _coref_ascend_byte!(loc)
        end

        m_arities = _arity_children(loc)
        static_nv = item_byte(ExprNewVar())
        for b in m_arities
            tag_a = byte_item(b)
            tag_a isa ExprArity || continue
            arity = Int(tag_a.arity)
            _coref_descend_byte!(loc, b)
            ol = length(stack)
            nv_expr = MORK.Expr([static_nv])
            for _ in 1:arity
                push!(stack, ExprEnv(UInt8(255), UInt8(0), UInt32(0), nv_expr))
            end
            _coreferential_transition!(loc, stack, references, f)
            resize!(stack, ol)
            _coref_ascend_byte!(loc)
        end

        e.n == 0 && pop!(references)

    elseif tag isa ExprVarRef
        i = Int(tag.idx)   # 0-based De Bruijn index (kept raw; `references` access shifts +1)
        # Upstream HEAD = the REVERT of e551924 (`4807e2f`, kernel/src/space.rs:166-188):
        # NO typemax sentinel guard. An out-of-range coreference (the referenced var is
        # not yet bound on this path) ABORTS this branch via a bounds-check early-return;
        # an in-range one (e.n==0) resolves to the recorded path offset. `references`
        # holds only real 0-based path offsets (push on entering a NewVar, pop on exit).
        if e.n == 0 && i >= length(references)
            push!(stack, e)        # restore the popped element, then abandon this branch
            return
        end
        new_ee = if e.n == 0
            ref_off = references[i + 1]
            path = _coref_path(loc)
            resolved_buf = Vector{UInt8}(path[(ref_off + 1):end])
            ExprEnv(UInt8(254), UInt8(0), UInt32(0), MORK.Expr(resolved_buf))
        else
            static_nv = item_byte(ExprNewVar())
            ExprEnv(UInt8(255), UInt8(0), UInt32(0), MORK.Expr([static_nv]))
        end

        # vs!(e, false) — match stored variable children. No sentinel push: the e551924
        # NewVar-sentinel block is commented out in upstream HEAD (space.rs:104-108).
        push!(stack, new_ee)
        m_vars = _var_children(loc)
        for b in m_vars
            _coref_descend_byte!(loc, b)
            _coreferential_transition!(loc, stack, references, f)
            _coref_ascend_byte!(loc)
        end
        _coreferential_transition!(loc, stack, references, f)
        pop!(stack)

    elseif tag isa ExprSymbol
        size = Int(tag.size)
        # vs!(e, false) — match stored variable children; upstream HEAD (revert of e551924)
        # pushes NO typemax sentinel here (that block is commented out in space.rs:104-108).
        m_vars = _var_children(loc)
        for b in m_vars
            _coref_descend_byte!(loc, b)
            _coreferential_transition!(loc, stack, references, f)
            _coref_ascend_byte!(loc)
        end
        if _coref_descend_to_existing_byte!(loc, e_byte)
            sym_bytes = e.base.buf[(Int(e.offset) + 2):(Int(e.offset) + 1 + size)]
            if _coref_descend_to_check!(loc, sym_bytes)
                _coreferential_transition!(loc, stack, references, f)
            end
            _coref_ascend!(loc, size + 1)
        end

    elseif tag isa ExprArity
        arity = Int(tag.arity)
        # vs!(e, false) — match stored variable children; no typemax sentinel
        # (upstream HEAD = revert of e551924; space.rs:104-108 commented out).
        m_vars = _var_children(loc)
        for b in m_vars
            _coref_descend_byte!(loc, b)
            _coreferential_transition!(loc, stack, references, f)
            _coref_ascend_byte!(loc)
        end
        if _coref_descend_to_existing_byte!(loc, e_byte)
            ol = length(stack)
            ee_args!(e, stack)
            reverse!(view(stack, (ol + 1):length(stack)))
            _coreferential_transition!(loc, stack, references, f)
            resize!(stack, ol)
            _coref_ascend_byte!(loc)
        end
    end

    push!(stack, e)
end

"""
    space_query_coref(btm, pat_expr, pat_v, effect) → Int

DFS coreferential query — mirrors `query_multi_raw` in space.rs.

For all N sources: uses `_coreferential_transition!` DFS on a ProductZipper.
The DFS tracks variable bindings during product-trie traversal, pruning
inconsistent branches.  At each leaf, runs unification to produce bindings.

This is more efficient than ProductZipper + post-filter when variables are
shared across sources (e.g. `(edge \$x \$y)(edge \$y \$z)` — binding `\$y`
from source 1 constrains which paths source 2 explores).

Mirrors `query_multi_raw` DFS path (space.rs:1207–1270).
"""
function space_query_coref(btm::PathMap{UnitVal},
    pat_expr::MORK.Expr,
    pat_v::UInt8,
    effect::Function)::Int
    pat_tag = byte_item(pat_expr.buf[1])
    pat_tag isa ExprArity || return 0
    n_factors = Int(pat_tag.arity)
    n_factors > 0 || return 0

    if n_factors == 1
        effect(nothing)
        return 1
    end

    pat_args = ExprEnv[]
    ee_args!(ExprEnv(UInt8(0), pat_v, UInt32(0), pat_expr), pat_args)
    sources = pat_args[2:end]   # one ExprEnv per source pattern

    n_src = length(sources)

    if n_src == 1
        # Single source: plain ReadZipperCore DFS
        stack = [sources[1]]
        references = Int[]
        count = Ref(0)
        loc = read_zipper(btm)
        _coreferential_transition!(loc, stack, references, function (z)
            count[] += 1
            effect(z)
        end)
        return count[]
    end

    # Multi-source: ProductZipper DFS — mirrors query_multi_raw(prz, sources, f)
    # Build ProductZipper: primary = btm, secondaries = (n_src-1) copies of btm
    primary = read_zipper_at_path(btm, UInt8[])
    secondaries = [read_zipper_at_path(btm, UInt8[]) for _ in 2:n_src]
    prz = ProductZipper(primary, secondaries)

    # Stack: sources in reverse (LIFO — first source on top)
    stack = reverse(collect(sources))
    references = Int[]
    count = Ref(0)
    pairs_scratch = Tuple{ExprEnv, ExprEnv}[]
    bindings_scratch = Dict{ExprVar, ExprEnv}()

    _coreferential_transition!(
        prz,
        stack,
        references,
        function (loc)
            # Reconstruct source expressions from the combined path + factor boundaries
            combined = collect(pz_path(loc))
            fps = loc.factor_paths   # path-length boundaries between factors

            empty!(pairs_scratch)
            boundaries = vcat(0, fps, length(combined))
            for (k, src) in enumerate(sources)
                lo = boundaries[k] + 1
                hi = boundaries[k + 1]
                (lo > hi || lo > length(combined)) && break
                expr = MORK.Expr(combined[lo:hi])
                push!(pairs_scratch, (src, ExprEnv(UInt8(k), UInt8(0), UInt32(0), expr)))
            end

            length(pairs_scratch) < n_src && return nothing   # incomplete match

            result = _expr_unify_inplace!(pairs_scratch, bindings_scratch)
            if result === true
                count[] += 1
                # SP-2 fix (audit 2026-06-04): removed a dead `bindings_out = copy(...)`
                # per match — the coref effect contract is `effect(loc)` (it takes the
                # zipper, not bindings), so the copy was pure per-match allocation waste.
                empty!(bindings_scratch)
                effect(loc)
            else
                empty!(bindings_scratch)
            end
        end
    )

    count[]
end

space_query_coref(btm::PathMap{UnitVal}, pat::MORK.Expr, f::Function) =
    space_query_coref(btm, pat, UInt8(0), f)

space_query_coref(s::Space, pat::MORK.Expr, f::Function) =
    space_query_coref(s.btm, pat, UInt8(0), f)

# Space-level overloads that pass mmaps for ACT file caching
space_query_multi_i(s::Space, pat::MORK.Expr, f::Function) =
    space_query_multi_i(s.btm, pat, UInt8(0), f; mmaps=s.mmaps)
space_query_multi_i(s::Space, pat::MORK.Expr, pat_v::UInt8, f::Function) =
    space_query_multi_i(s.btm, pat, pat_v, f; mmaps=s.mmaps)

# =====================================================================
# _pat_overlaps_exec_prefix — prefix-overlap guard for pjoin skip
# =====================================================================
#
# Returns true iff any structural position in pat_expr's byte buffer starts
# with _EXEC_PREFIX.  Uses the same structural walk as `_const_prefix` in
# space_acquire_transform_permissions: advances by tag-correct amounts
# (skipping symbol payloads), checking only at expression-start positions.
# This avoids false negatives from non-structural byte coincidences that a
# flat substring scan could misidentify.
#
# Safe direction: errs toward true (falls through to pjoin) when uncertain.
# _EXEC_PREFIX = [ExprArity(4), ExprSymbol(4), 'e','x','e','c'] — 6 bytes.
@inline function _pat_overlaps_exec_prefix(pat_expr::MORK.Expr)::Bool
    buf = pat_expr.buf
    ep = _EXEC_PREFIX
    ep_len = length(ep)
    n = length(buf)
    i = 1
    @inbounds while i <= n
        # Check if position i starts with _EXEC_PREFIX (expression-start only)
        if i + ep_len - 1 <= n
            match = true
            for j in 1:ep_len
                buf[i + j - 1] != ep[j] && (match=false; break)
            end
            match && return true
        end
        # Advance structurally — same logic as _const_prefix
        t = byte_item(buf[i])
        if t isa ExprArity
            i += 1          # descend into expression
        elseif t isa ExprSymbol
            i += 1 + Int(t.size)   # skip sym-header + payload bytes
        elseif t isa ExprNewVar || t isa ExprVarRef
            i += 1
        else
            i += 1
        end
    end
    false
end

# =====================================================================
# space_transform_multi_multi! — rewrite rule application
# =====================================================================

"""
    space_transform_multi_multi!(s, pat_expr, tpl_expr, add_expr) → (touched, any_new)

For each match of `pat_expr` in the Space, apply `tpl_expr` to produce new
expressions and insert them.  `add_expr` is also inserted unconditionally.

Simplified port of `Space::transform_multi_multi_` — uses our `expr_apply`
instead of `apply_e`.

Returns `(touched, any_new)` where `touched` is match count and `any_new`
indicates whether at least one new expression was added.
"""
# Returns true if the O-template raw bytes indicate an accumulating sink.
# Accumulating sinks must be created ONCE before the query and finalized ONCE after.
# Recognized: AU, count, fsum, fmin, fmax, fprod, sum, head, tail
# NB head/tail keep the top/bottom-N across ALL matches — they MUST accumulate;
# treated as immediate (fresh-per-match) they never cap (HeadSink's old test was
# vacuous, kept 0/N). Added with TailSink (mirrors upstream HeadTailSink).
function _is_accumulating_sink(raw_bytes::Vector{UInt8})::Bool
    length(raw_bytes) < 4 && return false
    t1 = byte_item(raw_bytes[1])
    t1 isa ExprArity || return false
    t2 = byte_item(raw_bytes[2])
    t2 isa ExprSymbol || return false
    sz = Int(t2.size)
    3 + sz > length(raw_bytes) && return false
    name = String(raw_bytes[3:(3 + sz - 1)])
    name in ("AU", "count", "fsum", "fmin", "fmax", "fprod", "sum", "head", "tail") && return true
    # "-" (RemoveSink) MUST also accumulate. In an O-sink the removes have to be
    # collected across ALL matches and subtracted AFTER every immediate add — otherwise
    # an atom added by one match and removed by another survives or dies depending on
    # match ORDER. That is the set-difference bug: Set_Ops_05 {a,b,c}\{b,c,d} upstream
    # = {a}, but our per-match immediate path gave {a,c}. Deferring removes to finalize
    # (after the adds) = upstream's "collect paths, subtract_into on finalize" → removes
    # win, result is order-independent. The struct already collects into `s.remove`; it
    # just was never marked accumulating, so it was created fresh-per-match.
    name == "-" && return true
    false
end

# Mirrors transform_multi_multi_io(pat_expr, tpl_expr, add, no_source, no_sink)
# no_source=true  → pattern is `,`  (query the trie — compat path)
# no_source=false → pattern is `I`  (external ACT/Z3 source via query_multi_i;
#                                    not ported — requires mmaps/z3s infrastructure.
#                                    Falls back to trie query for now.)
# no_sink=true    → template is `,` (direct set_val_at!)
# no_sink=false   → template is `O` (dispatch through sink machinery)
function space_transform_multi_multi!(s::Space, pat_expr::MORK.Expr, pat_v::UInt8,
    tpl_expr::MORK.Expr, tpl_v::UInt8,
    add_expr::MORK.Expr;
    no_source::Bool=true,
    no_sink::Bool=true,
    prefix::Vector{UInt8}=UInt8[])::Tuple{Int, Bool}
    # `prefix` (default empty = root, behaviour unchanged) scopes a prefixed-
    # region exec.  Reads anchor under `prefix` (space_query_multi_at); writes
    # land under `prefix` — directly (no_sink: `prefix ++ result`) or via the
    # PrefixBtm wrapper handed to O-sinks (no_sink=false), which redirects their
    # btm touches into the region while leaving their internal accumulators raw.
    # Covers comma/comma (Stage A) + comma/O O-sinks (Stage B).  I-source (`I`)
    # under a non-empty prefix is still guarded in space_interpret! (its ASource
    # read path doesn't thread `prefix` yet).
    sink_btm = isempty(prefix) ? s.btm : PrefixBtm(s.btm, prefix)
    tpl_args = ExprEnv[]
    ee_tpl = ExprEnv(UInt8(0), tpl_v, UInt32(0), tpl_expr)
    ee_args!(ee_tpl, tpl_args)
    template_ees = tpl_args[2:end]

    any_new = Ref(false)

    # Pre-create persistent (accumulating) sinks for O-templates.
    # CountSink accumulates sources across all matches before finalizing once.
    # Other sinks are created fresh per match (persistent_sinks[k] = nothing).
    persistent_sinks = if no_sink
        nothing
    else
        map(template_ees) do ee
            tpl_span = expr_span(ee.base, Int(ee.offset) + 1)
            raw_bytes = Vector{UInt8}(tpl_span)
            _is_accumulating_sink(raw_bytes) ? asink_new(MORK.Expr(raw_bytes)) : nothing
        end
    end

    # Build read_btm.
    # Prefix-gated: if the pattern's constant prefix cannot match _EXEC_PREFIX,
    # use s.btm directly (exec atom was already removed by the driver — it couldn't
    # match a data pattern anyway).  ReadZipperCore captures root_node as an Rc
    # snapshot at construction; COW writes during the match closure fork s.btm's
    # spine independently, so they are invisible to the ongoing query (same next-step
    # semantics as the old separate-read_btm path). Self-feeding data rules are safe.
    #
    # If the pattern CAN match exec atoms (meta-rules with (exec ...) patterns),
    # fall through to the pjoin path so the atom is visible in an isolated map.
    #
    # Saves ~12 KB/step (singleton + spine) on the overwhelmingly common data-rule path.
    read_btm = if !_pat_overlaps_exec_prefix(pat_expr)
        s.btm                        # fast path: no pjoin, no singleton
    else
        # Meta-pattern: re-insert exec atom into an isolated read_btm so the
        # pattern can see it without the driver re-selecting it.
        _exec_singleton = PathMap{UnitVal}()
        set_val_at!(_exec_singleton, add_expr.buf, UNIT_VAL)
        pjoin(s.btm, _exec_singleton).value
    end

    # Pre-allocate per-template scratch buffers outside the match closure.
    # Mirrors upstream space.rs: ass/astack/buffer pre-allocated before query_multi,
    # cleared between iterations with ass.clear() / astack.clear() / buffer.clear().
    # Saves 5+ heap allocs per (match × template): template copy, output buf, result
    # slice, rename dict, free/new var vecs.
    n_tpl = length(template_ees)
    tpl_exprs = Vector{MORK.Expr}(undef, n_tpl)    # template Expr per ee
    out_bufs = Vector{Vector{UInt8}}(undef, n_tpl) # reusable output buffers
    tpl_ezs = Vector{ExprZipper}(undef, n_tpl)    # read zippers (reset loc=1 each call)
    tpl_ozs = Vector{ExprZipper}(undef, n_tpl)    # write zippers (reset loc=1 each call)
    tpl_rdicts = [Dict{ExprVar, UInt8}() for _ in 1:n_tpl]  # rename maps (empty! each call)
    tpl_fvecs = [ExprVar[] for _ in 1:n_tpl]              # free_vars  (empty! each call)
    tpl_nvecs = [ExprVar[] for _ in 1:n_tpl]              # new_vars   (empty! each call)
    for (k, ee) in enumerate(template_ees)
        tpl_span = expr_span(ee.base, Int(ee.offset) + 1)
        tpl_exprs[k] = MORK.Expr(Vector{UInt8}(tpl_span))
        out_bufs[k] = Vector{UInt8}(undef, max(length(tpl_span) * 4, 64))
        tpl_ezs[k] = ExprZipper(tpl_exprs[k], 1)
        tpl_ozs[k] = ExprZipper(MORK.Expr(out_bufs[k]), 1)
    end

    # Two-phase apply scratch (oi = pattern var-intro count; new_intros=0 for templates).
    discard_buf = Vector{UInt8}(undef, 1 << 16)
    pat_apply_ez = ExprZipper(pat_expr, 1)
    pat_apply_oz = ExprZipper(MORK.Expr(discard_buf), 1)
    pat_cyc = Dict{ExprVar, UInt8}()
    pat_stk = ExprVar[]
    pat_asn = ExprVar[]

    # space_query_multi_i uses s.mmaps for ACT file caching (I-pattern)
    # no_source path uses space_query_multi_at so a non-empty `prefix` anchors
    # the pattern read to the prefix-subtrie (delegates to space_query_multi
    # when prefix is empty — the root path is byte-identical to before).
    query_fn = if no_source
        ((btm, pat, v, f) -> space_query_multi_at(btm, prefix, pat, v, f))
    else
        (btm, pat, v, f) -> space_query_multi_i(btm, pat, v, f; mmaps=s.mmaps)
    end
    touched = query_fn(
        read_btm,
        pat_expr,
        pat_v,
        (bindings, loc_expr) -> begin
            # oi = the pattern's introduced-var count, counted BOUNDED to the pattern's own span
            # (_ee_traverseh stops at the expr boundary — NOT a full-buffer walk, which would run
            # past the pattern into the template and over-count). Template NewVars then number from
            # oi so they don't collide with pattern-bound vars at key (0, k<oi).
            (pat_nv, _, _) = _ee_traverseh(UInt8(0), ExprEnv(UInt8(0), pat_v, UInt32(0), pat_expr),
                (h, o) -> (h + UInt8(1), nothing), (h, o, r) -> (h, nothing),
                (h, o, sl) -> (h, nothing), (h, o, a) -> (h, nothing),
                (h, o, x, y) -> (h, nothing), (h, o, acc) -> (h, acc))
            oi = pat_v + pat_nv
            if no_sink
                # `,` template functor — apply each template and insert result directly
                for (k, ee) in enumerate(template_ees)
                    ez = tpl_ezs[k];
                    ez.loc = 1          # reset read position
                    oz = tpl_ozs[k];
                    oz.loc = 1          # reset write position (≡ buffer.clear())
                    empty!(tpl_rdicts[k]);
                    empty!(tpl_fvecs[k]);
                    empty!(tpl_nvecs[k])
                    (toi, _) = expr_apply(UInt8(0), oi, UInt8(0), ez, bindings, oz,
                        tpl_rdicts[k], tpl_fvecs[k], tpl_nvecs[k])
                    oi = toi
                    result_view = @view out_bufs[k][1:(oz.loc - 1)]   # zero-copy view (no slice alloc)
                    # Prefixed-region write: outputs land under `prefix` so a
                    # prefix-scoped exec stays inside its region.  Empty prefix →
                    # write the bare result view (zero-copy, unchanged root path).
                    wpath = isempty(prefix) ? result_view : vcat(prefix, result_view)
                    old = get_val_at(s.btm, wpath)
                    set_val_at!(s.btm, wpath, UNIT_VAL)
                    old === nothing && (any_new[] = true)
                end
            else
                # `O` template functor — apply each template then dispatch to sink.
                # Accumulating sinks (CountSink) use persistent_sinks created before query.
                ps = persistent_sinks::Vector
                for (k, ee) in enumerate(template_ees)
                    ez = tpl_ezs[k];
                    ez.loc = 1
                    oz = tpl_ozs[k];
                    oz.loc = 1
                    empty!(tpl_rdicts[k]);
                    empty!(tpl_fvecs[k]);
                    empty!(tpl_nvecs[k])
                    (toi, _) = expr_apply(UInt8(0), oi, UInt8(0), ez, bindings, oz,
                        tpl_rdicts[k], tpl_fvecs[k], tpl_nvecs[k])
                    oi = toi
                    result_expr = MORK.Expr(out_bufs[k][1:(oz.loc - 1)]) # copy needed: sink stores ref
                    if ps[k] !== nothing
                        # Accumulating sink: apply but don't finalize yet
                        sink_apply!(ps[k], bindings, result_expr.buf, sink_btm)
                    else
                        # Immediate sink: create fresh, apply, finalize
                        sink = asink_new(result_expr)
                        sink_apply!(sink, bindings, result_expr.buf, sink_btm)
                        changed = sink_finalize!(sink, sink_btm)
                        changed && (any_new[] = true)
                    end
                end
            end
            true
        end
    )

    # Finalize accumulating sinks (CountSink etc.) once after all matches
    if !no_sink && persistent_sinks !== nothing
        for sink in persistent_sinks::Vector
            sink === nothing && continue
            changed = sink_finalize!(sink, sink_btm)
            changed && (any_new[] = true)
        end
    end

    (touched, any_new[])
end

# Compat wrapper for callers without v parameters (v defaults to 0)
space_transform_multi_multi!(s::Space, pat_expr::MORK.Expr, tpl_expr::MORK.Expr,
    add_expr::MORK.Expr) =
    space_transform_multi_multi!(s, pat_expr, UInt8(0), tpl_expr, UInt8(0), add_expr)

# ── specialize_io named variants (mirrors #[cfg(feature="specialize_io")] in Rust) ─────
#
# In Rust, specialize_io creates separate function bodies to avoid runtime flag checks
# and let the compiler eliminate dead branches.  In Julia, JIT specializes on Bool
# constants anyway, but named dispatch makes the intent clear and matches upstream.
#
# (`,`, `,`) — most common: trie query + direct write
"""
    space_transform_comma_comma!(s, pat, tpl, add) — `,` source, `,` sink.
Mirrors `transform_multi_multi_` (the most common, fastest path).
Uses ProductZipper trie query + direct set_val_at! (no sink object overhead).
"""
space_transform_comma_comma!(s::Space, pat::MORK.Expr, tpl::MORK.Expr, add::MORK.Expr;
    prefix::Vector{UInt8}=UInt8[]) =
    space_transform_multi_multi!(s, pat, UInt8(0), tpl, UInt8(0), add;
        no_source=true, no_sink=true, prefix=prefix)

# (`I`, `,`) — external ASource + direct write
"""
    space_transform_i_comma!(s, pat, tpl, add) — `I` source, `,` sink.
Mirrors `transform_multi_multi_i`. Uses ASource dispatch (BTM/CmpSource/ACTSource)
for the source, direct set_val_at! for output.
"""
space_transform_i_comma!(s::Space, pat::MORK.Expr, tpl::MORK.Expr, add::MORK.Expr) =
    space_transform_multi_multi!(s, pat, UInt8(0), tpl, UInt8(0), add;
        no_source=false, no_sink=true)

# (`,`, `O`) — trie query + sink dispatch
"""
    space_transform_comma_o!(s, pat, tpl, add) — `,` source, `O` sink.
Mirrors `transform_multi_multi_o`. Uses ProductZipper trie query; routes output
through ASink machinery (CountSink, FloatReductionSink, PureSink, etc.).
"""
space_transform_comma_o!(s::Space, pat::MORK.Expr, tpl::MORK.Expr, add::MORK.Expr) =
    space_transform_multi_multi!(s, pat, UInt8(0), tpl, UInt8(0), add;
        no_source=true, no_sink=false)

# (`I`, `O`) — external ASource + sink dispatch (the fully general path)
"""
    space_transform_i_o!(s, pat, tpl, add) — `I` source, `O` sink.
Mirrors `transform_multi_multi_io`. Fully general: ASource dispatch + ASink dispatch.
"""
space_transform_i_o!(s::Space, pat::MORK.Expr, tpl::MORK.Expr, add::MORK.Expr) =
    space_transform_multi_multi!(s, pat, UInt8(0), tpl, UInt8(0), add;
        no_source=false, no_sink=false)

# =====================================================================
# ExecError — mirrors ExecError<S> enum in space.rs (server branch)
# All 10 variants. Permission variants carry a message string (Julia
# has no generic PermissionErr type parameter).
# =====================================================================

struct ExecError
    kind::Symbol
    message::String
end
ExecError(kind::Symbol) = ExecError(kind, "")
Base.show(io::IO, e::ExecError) = print(io, "ExecError($(e.kind)): $(e.message)")

_exec_err_arity4(msg) = ExecError(:ExpectedArity4, msg)
_exec_err_keyword(msg) = ExecError(:ExpectedExecKeyword, msg)
_exec_err_thread_pair(msg) = ExecError(:ExpectedThreadIdPair, msg)
_exec_err_comma_pat(msg) = ExecError(:ExpectedCommaListPatterns, msg)
_exec_err_comma_tpl(msg) = ExecError(:ExpectedCommaListTemplates, msg)
_exec_err_ground_priority(msg) = ExecError(:ExpectedGroundPriority, msg)
_exec_err_other(msg) = ExecError(:OtherFmtErr, msg)
_exec_err_system_perm(msg) = ExecError(:SystemPermissionErr, msg)
_exec_err_user_perm(msg) = ExecError(:UserPermissionErr, msg)
_exec_err_retry_limit(msg) = ExecError(:RetryLimit, msg)

is_user_perm_err(e::ExecError) = e.kind === :UserPermissionErr
exec_error_message(e::ExecError) = "$(e.kind): $(e.message)"

# =====================================================================
# space_interpret! / space_metta_calculus! — rule evaluation engine
# =====================================================================

# exec prefix: [4] exec  (6 bytes)
const _EXEC_PREFIX = UInt8[
    item_byte(ExprArity(UInt8(4))),
    item_byte(ExprSymbol(UInt8(4))),
    UInt8('e'), UInt8('x'), UInt8('e'), UInt8('c')
]

"""
    space_interpret!(s, rt) → Union{Nothing, ExecError}

Execute one `(exec (thread_id priority) (, src...) (, tpl...))` atom.
Mirrors `interpret_impl` in space.rs (server branch).

Returns `nothing` on success, an `ExecError` on any format violation
or permission conflict. `UserPermissionErr` → caller should re-insert
and retry; all other errors → halt.
"""
function space_interpret!(s::Space, rt::MORK.Expr;
    prefix::Vector{UInt8}=UInt8[])::Union{Nothing, ExecError}
    buf = rt.buf
    # Safe serialisation — expr_serialize throws on reserved bytes; fall back to hex.
    dbg = () -> try
        expr_serialize(buf)
    catch
        ;
        bytes2hex(buf)
    end

    # ── Overall shape: arity-4 + "exec" keyword ───────────────────────
    length(buf) < 6 && return _exec_err_arity4(dbg())
    t1 = byte_item(buf[1])
    (t1 isa ExprArity && t1.arity == 4) || return _exec_err_arity4(dbg())
    t2 = byte_item(buf[2])
    (t2 isa ExprSymbol && t2.size == 4) || return _exec_err_keyword(dbg())
    buf[3:6] == UInt8[UInt8('e'), UInt8('x'), UInt8('e'), UInt8('c')] ||
        return _exec_err_keyword(dbg())

    # Decompose top-level args: [1]="exec", [2]=(thread_id priority), [3]=patterns, [4]=templates
    ee_rt = ExprEnv(UInt8(0), UInt8(0), UInt32(0), rt)
    args = ExprEnv[]
    ee_args!(ee_rt, args)
    length(args) < 4 && return _exec_err_arity4(dbg())

    # ── Validate loc arg: (thread_id priority) pair OR plain ground atom ──
    # Server branch requires arity-2 (thread_id priority) pair.
    # For backward compatibility with old-format (exec 0 (, ...) (, ...))
    # we accept any loc arg that is ground — just like `debug_assert!(loc.variables() == 0)`.
    # When loc IS arity-2, additionally validate thread_id and priority are ground.
    loc_ee = args[2]
    loc_buf = loc_ee.base.buf
    loc_off = Int(loc_ee.offset)
    if length(loc_buf) > loc_off
        lt = byte_item(loc_buf[loc_off + 1])
        if lt isa ExprArity && lt.arity == 2
            # New format: validate both children are ground
            loc_sub_args = ExprEnv[]
            ee_loc = ExprEnv(UInt8(0), UInt8(0), UInt32(loc_off), loc_ee.base)
            ee_args!(ee_loc, loc_sub_args)
            if length(loc_sub_args) >= 2
                tid_ee = loc_sub_args[2]
                tid_buf = tid_ee.base.buf
                tid_off = Int(tid_ee.offset)
                if length(tid_buf) > tid_off && (
                    byte_item(tid_buf[tid_off + 1]) isa ExprNewVar ||
                    byte_item(tid_buf[tid_off + 1]) isa ExprVarRef
                )
                    return _exec_err_other(dbg())
                end
            end
            if length(loc_sub_args) >= 3
                pri_ee = loc_sub_args[3]
                pri_buf = pri_ee.base.buf
                pri_off = Int(pri_ee.offset)
                if length(pri_buf) > pri_off && (
                    byte_item(pri_buf[pri_off + 1]) isa ExprNewVar ||
                    byte_item(pri_buf[pri_off + 1]) isa ExprVarRef
                )
                    return _exec_err_ground_priority(dbg())
                end
            end
        end
        # Old format (plain atom): accepted as long as it is not a raw variable
        if lt isa ExprNewVar || lt isa ExprVarRef
            return _exec_err_thread_pair(dbg())
        end
    end

    # ── Validate pattern list: must start with "," ────────────────────
    pat_ee = args[3]
    pat_buf = pat_ee.base.buf
    pat_off = Int(pat_ee.offset)
    length(pat_buf) <= pat_off && return _exec_err_comma_pat(dbg())
    pt = byte_item(pat_buf[pat_off + 1])
    (pt isa ExprArity && pt.arity > 0) || return _exec_err_comma_pat(dbg())
    length(pat_buf) <= pat_off + 1 && return _exec_err_comma_pat(dbg())
    pt2 = byte_item(pat_buf[pat_off + 2])
    (pt2 isa ExprSymbol && pt2.size == 1) || return _exec_err_comma_pat(dbg())
    pat_buf[pat_off + 3] == UInt8(',') || pat_buf[pat_off + 3] == UInt8('I') ||
        return _exec_err_comma_pat(dbg())

    # ── Validate template list: must start with "," or "O" ───────────
    tpl_ee = args[4]
    tpl_buf = tpl_ee.base.buf
    tpl_off = Int(tpl_ee.offset)
    length(tpl_buf) <= tpl_off && return _exec_err_comma_tpl(dbg())
    tt = byte_item(tpl_buf[tpl_off + 1])
    (tt isa ExprArity && tt.arity > 0) || return _exec_err_comma_tpl(dbg())

    pat_expr = MORK.Expr(pat_buf[(pat_off + 1):end])
    tpl_expr = MORK.Expr(tpl_buf[(tpl_off + 1):end])

    pat_functor = pat_buf[pat_off + 3]
    tpl_functor = tpl_buf[tpl_off + 3]

    comma = UInt8(',');
    i_src = UInt8('I');
    o_snk = UInt8('O')

    # Prefix-scoped exec covers comma source with comma OR O-sink templates:
    #   - comma/comma: read via space_query_multi_at, write `prefix ++ result`.
    #   - comma/O    : O-sinks write through the PrefixBtm wrapper (Stage B).
    # I-source (`I`) under a prefix is still guarded — its ASource read path
    # (space_query_multi_i) doesn't thread `prefix` yet, so it would read across
    # regions.  Guard rather than silently mis-scope.
    if !isempty(prefix) && pat_functor == i_src
        return _exec_err_other(
            "prefix-scoped exec does not yet support I-source patterns; " *
            "got pat=$(Char(pat_functor)) tpl=$(Char(tpl_functor)) (I-source under a prefix is future work)"
        )
    end

    if pat_functor == comma && tpl_functor == comma
        space_transform_comma_comma!(s, pat_expr, tpl_expr, rt; prefix=prefix)
    elseif pat_functor == i_src && tpl_functor == comma
        space_transform_multi_multi!(s, pat_expr, pat_ee.v, tpl_expr, tpl_ee.v, rt;
            no_source=false, no_sink=true)
    elseif pat_functor == comma && tpl_functor == o_snk
        space_transform_multi_multi!(s, pat_expr, pat_ee.v, tpl_expr, tpl_ee.v, rt;
            no_source=true, no_sink=false, prefix=prefix)
    elseif pat_functor == i_src && tpl_functor == o_snk
        space_transform_multi_multi!(s, pat_expr, pat_ee.v, tpl_expr, tpl_ee.v, rt;
            no_source=false, no_sink=false)
    else
        return _exec_err_other(
            "unknown functor combination: pat=$(Char(pat_functor)) tpl=$(Char(tpl_functor))"
        )
    end
    nothing
end

"""
    space_metta_calculus!(s, steps=∞) → Int

Repeatedly find `(exec ...)` atoms, remove and execute them.
Mirrors `metta_calculus_impl` in space.rs (server branch):
  - On `UserPermissionErr` re-inserts the atom and retries (up to
    `_METTA_CALCULUS_MAX_RETRIES` times with a 1ms sleep).
  - On any other error logs and halts.
Returns steps executed.
"""
const _METTA_CALCULUS_MAX_RETRIES = 2000

function space_metta_calculus!(s::Space, steps::Int=typemax(Int))::Int
    done = 0
    retry = false
    retry_cnt = _METTA_CALCULUS_MAX_RETRIES
    # Reused scratch buffer — wires the Rust buffer: Vec<u8> reset-to-prefix pattern.
    # Eliminates collect(zipper_path) + vcat(_EXEC_PREFIX, rel_path) each iteration.
    path_buf = UInt8[]

    while done < steps
        rz = read_zipper_at_path(s.btm, _EXEC_PREFIX)
        found = zipper_to_next_val!(rz)

        if !found
            if retry && retry_cnt > 0
                retry_cnt -= 1
                sleep(0.001)   # 1 ms — mirrors std::thread::sleep(1ms)
                continue
            end
            break  # all execs consumed
        end

        empty!(path_buf)
        append!(path_buf, _EXEC_PREFIX)
        append!(path_buf, zipper_path(rz))   # view → bytes copied in; no collect, no vcat
        remove_val_at!(s.btm, path_buf)

        rt = MORK.Expr(copy(path_buf))      # independent copy for space_interpret!
        err = space_interpret!(s, rt)

        if err === nothing
            retry = false
            retry_cnt = _METTA_CALCULUS_MAX_RETRIES
            done += 1
        elseif is_user_perm_err(err)
            # Re-insert using the intact path_buf (not modified between remove and here)
            set_val_at!(s.btm, path_buf, UNIT_VAL)
            retry = true
            if retry_cnt <= 0
                @warn "space_metta_calculus!: retry limit exceeded — $(exec_error_message(err))"
                break
            end
            retry_cnt -= 1
            sleep(0.001)
        else
            @warn "space_metta_calculus!: $(exec_error_message(err))"
            break
        end
    end
    done
end

# =====================================================================
# prefix_subsumption — group prefixes by longest shared prefix
# Mirrors Space::prefix_subsumption in space.rs (line 1278)
# =====================================================================

function space_prefix_subsumption(prefixes::Vector{Vector{UInt8}})::Vector{Int}
    n = length(prefixes)
    out = Vector{Int}(undef, n)
    for i in 1:n
        cur = prefixes[i]
        best_idx = i
        best_len = length(cur)
        for j in 1:n
            cand = prefixes[j]
            # cand is a prefix of cur iff cand == cur[1:length(cand)]
            cl = length(cand)
            if cl <= length(cur) && cur[1:cl] == cand
                if cl < best_len || (cl == best_len && j < best_idx)
                    best_idx = j
                    best_len = cl
                end
            end
        end
        out[i] = best_idx
    end
    out
end

# =====================================================================
# space_token_bfs — BFS from token prefix, return unifiable matches
# Mirrors Space::token_bfs in space.rs (line 1750)
# =====================================================================

function space_token_bfs(
    s::Space, token::Vector{UInt8}, pattern::MORK.Expr
)::Vector{Tuple{Vector{UInt8}, MORK.Expr, Int}}
    rz = read_zipper_at_path(s.btm, token)
    zipper_descend_until!(rz)
    res = Tuple{Vector{UInt8}, MORK.Expr, Int}[]
    cm = zipper_child_mask(rz)
    # General case: visit all subtries below the branch.
    for b in cm
        zipper_descend_to_byte!(rz, b)
        # Get representative expression for this byte position:
        # - If already at a value (single-byte key is a leaf value), use current position.
        # - Otherwise advance rzc to the first value in the subtrie via to_next_val!.
        # NOTE: iter_token_for_path starts AFTER the current key, so zipper_to_next_val!
        # on a value position would skip it and return the wrong expression.
        origin = if zipper_is_val(rz)
            copy(rz.prefix_buf)
        else
            rzc = deepcopy(rz)
            zipper_to_next_val!(rzc) || (zipper_ascend_byte!(rz); continue)
            copy(rzc.prefix_buf)
        end
        e = MORK.Expr(origin)
        expr_path_len = length(origin)   # used for child_count branch (dbf9d50)
        # expr_unifiable: attempt unification, return true if succeeds
        pairs = Tuple{ExprEnv, ExprEnv}[
            (ExprEnv(UInt8(0), UInt8(0), UInt32(0), e),
            ExprEnv(UInt8(1), UInt8(0), UInt32(0), pattern))
        ]
        scratch = Dict{ExprVar, ExprEnv}()
        if _expr_unify_inplace!(pairs, scratch) === true
            # Port of upstream MORK dbf9d50: compute child_count so the client
            # can decide whether further exploration from this token is fruitful.
            # Walk: descend_until + count children of the resulting node, then
            # ascend back to where we were so the outer loop's next iteration
            # sees the same state.
            path_len_before = length(zipper_path(rz))
            zipper_descend_until!(rz)
            cur_path_total = rz.origin_path_len + length(zipper_path(rz))
            child_count = if expr_path_len > cur_path_total
                # The matched expr extends beyond where descend_until landed —
                # there's a true branching node below us; count its children.
                sum(1 for _ in zipper_child_mask(rz); init=0)
            else
                # descend_until reached the end of the matched expr — there's
                # exactly one concrete atom below.
                1
            end
            zipper_ascend!(rz, length(zipper_path(rz)) - path_len_before)
            push!(
                res,
                (
                    copy(rz.prefix_buf[1:(rz.origin_path_len + length(zipper_path(rz)))]),
                    e,
                    child_count
                )
            )
        end
        zipper_ascend_byte!(rz)
    end
    # Port of upstream MORK b95e2f7: special case for a single concrete atom.
    # When the general loop produces no results AND the focus token is non-empty,
    # there may be exactly one atom below the pattern that the child-mask
    # iteration missed (e.g. the subtrie is a single concrete value, not a
    # branching node).  Fork the zipper, advance to that value, check
    # unification, and emit with an EMPTY token — no further exploration from
    # this point is fruitful.  child_count = 0 (matches upstream).
    if isempty(res) && length(zipper_path(rz)) > 0
        rzc = deepcopy(rz)
        if zipper_to_next_val!(rzc)
            e = MORK.Expr(copy(rzc.prefix_buf))
            pairs = Tuple{ExprEnv, ExprEnv}[
                (ExprEnv(UInt8(0), UInt8(0), UInt32(0), e),
                ExprEnv(UInt8(1), UInt8(0), UInt32(0), pattern))
            ]
            scratch = Dict{ExprVar, ExprEnv}()
            if _expr_unify_inplace!(pairs, scratch) === true
                push!(res, (UInt8[], e, 0))
            end
        end
    end
    res
end

# =====================================================================
# space_load_csv! — load CSV rows as expressions via pattern/template
# Mirrors Space::load_csv in space.rs (line 509)
# =====================================================================

function space_load_csv!(s::Space, src, pattern::MORK.Expr, template::MORK.Expr,
    separator::UInt8=UInt8(','))::Int
    bytes = src isa Vector{UInt8} ? src : Vector{UInt8}(src)
    count = 0
    for (i, line) in enumerate(split(String(bytes), '\n'))
        isempty(line) && continue
        fields = split(line, Char(separator))
        # Build expr: (arity+1 row_index field1 field2 ...)
        # row_index = i-1 as decimal string symbol, matching Rust i.to_string()
        row_sym = string(i - 1)
        parts = vcat([row_sym], String.(fields))
        arity = length(parts)
        buf = UInt8[]
        push!(buf, item_byte(ExprArity(UInt8(arity))))
        for p in parts
            pb = Vector{UInt8}(p)
            push!(buf, item_byte(ExprSymbol(UInt8(length(pb)))))
            append!(buf, pb)
        end
        data_expr = MORK.Expr(buf)

        # Unify with pattern, apply template
        bindings = Dict{ExprVar, ExprEnv}()
        pairs = Tuple{ExprEnv, ExprEnv}[
            (ExprEnv(UInt8(0), UInt8(0), UInt32(0), pattern),
            ExprEnv(UInt8(1), UInt8(0), UInt32(0), data_expr))
        ]
        _expr_unify_inplace!(pairs, bindings) === true || continue

        out_buf = Vector{UInt8}(undef, max(length(template.buf) * 4, 256))
        ez_tpl = ExprZipper(template, 1)
        oz = ExprZipper(MORK.Expr(out_buf), 1)
        expr_apply(UInt8(0), UInt8(0), UInt8(0), ez_tpl, bindings, oz,
            Dict{ExprVar, UInt8}(), ExprVar[], ExprVar[])
        set_val_at!(s.btm, oz.root.buf[1:(oz.loc - 1)], UNIT_VAL)
        count += 1
    end
    count
end

# =====================================================================
# space_add_sexpr! / space_remove_sexpr! — pattern+template variants
# Mirrors Space::add_sexpr / remove_sexpr / load_sexpr_impl in space.rs
# =====================================================================

function space_add_sexpr!(s::Space, src, pattern::MORK.Expr, template::MORK.Expr)::Int
    _space_load_sexpr_impl!(s, src, pattern, template, true)
end

function space_remove_sexpr!(s::Space, src, pattern::MORK.Expr, template::MORK.Expr)::Int
    _space_load_sexpr_impl!(s, src, pattern, template, false)
end

function _space_load_sexpr_impl!(
    s::Space, src, pattern::MORK.Expr, template::MORK.Expr, add::Bool
)::Int
    bytes = src isa Vector{UInt8} ? src : Vector{UInt8}(src)
    ctx = SexprContext(bytes)
    parser = SpaceParser()
    count = 0
    while true
        buf = Vector{UInt8}(undef, max(length(bytes) * 2, 64))
        z = ExprZipper(MORK.Expr(buf), 1)
        try
            sexpr_parse!(parser, ctx, z)
        catch e
            e isa SexprException && e.err == SERR_INPUT_FINISHED && break
            rethrow()
        end
        data_expr = MORK.Expr(z.root.buf[1:(z.loc - 1)])
        empty!(ctx.variables)

        # Unify data_expr with pattern, apply template
        bindings = Dict{ExprVar, ExprEnv}()
        pairs = Tuple{ExprEnv, ExprEnv}[
            (ExprEnv(UInt8(0), UInt8(0), UInt32(0), pattern),
            ExprEnv(UInt8(1), UInt8(0), UInt32(0), data_expr))
        ]
        _expr_unify_inplace!(pairs, bindings) === true || continue

        out_buf = Vector{UInt8}(undef, max(length(template.buf) * 4, 256))
        ez_tpl = ExprZipper(template, 1)
        oz = ExprZipper(MORK.Expr(out_buf), 1)
        expr_apply(UInt8(0), UInt8(0), UInt8(0), ez_tpl, bindings, oz,
            Dict{ExprVar, UInt8}(), ExprVar[], ExprVar[])
        result_bytes = oz.root.buf[1:(oz.loc - 1)]
        if add
            ;
            set_val_at!(s.btm, result_bytes, UNIT_VAL)
        else
            ;
            remove_val_at!(s.btm, result_bytes);
        end
        count += 1
    end
    count
end

# =====================================================================
# space_dump_sexpr — dump matching expressions via pattern/template
# Mirrors Space::dump_sexpr in space.rs
# =====================================================================

function space_dump_sexpr(s::Space, pattern::MORK.Expr, template::MORK.Expr, io::IO)::Int
    # Wrap pattern in comma functor: (, pattern) so query_multi can process it
    pat_wrap_buf = vcat(
        item_byte(ExprArity(UInt8(2))),
        item_byte(ExprSymbol(UInt8(1))), UInt8(','),
        pattern.buf
    )
    pat_wrapped = MORK.Expr(pat_wrap_buf)

    count = Ref(0)
    space_query_multi(
        s.btm,
        pat_wrapped,
        UInt8(0),
        (bindings, _loc_buf) -> begin
            out_buf = Vector{UInt8}(undef, max(length(template.buf) * 4, 256))
            ez_tpl = ExprZipper(template, 1)
            oz = ExprZipper(MORK.Expr(out_buf), 1)
            expr_apply(UInt8(0), UInt8(0), UInt8(0), ez_tpl, bindings, oz,
                Dict{ExprVar, UInt8}(), ExprVar[], ExprVar[])
            result_bytes = oz.root.buf[1:(oz.loc - 1)]
            println(io, expr_serialize(result_bytes))
            count[] += 1
            true
        end
    )
    count[]
end

space_dump_sexpr(s::Space, pattern::MORK.Expr, template::MORK.Expr) =
    space_dump_sexpr(s, pattern, template, stdout)

# =====================================================================
# Persistence — backup/restore tree and paths
# Mirrors Space::backup_tree/restore_tree/backup_paths/restore_paths
# backup_symbols/restore_symbols are no-ops (no interning in this port)
# =====================================================================

function space_backup_tree(s::Space, path::AbstractString)
    # Upstream Space::backup_tree = ArenaCompactTree::dump_from_zipper — an ACT-format file that
    # `(ACT …)` sources mmap-read. The prior port used serialize_paths (that's backup_PATHS), so
    # ACT reads of a backup_tree file crashed with "Invalid ACTree magic". Mirror upstream: write
    # the ArenaCompactTree via the same act_from_zipper/act_save the ACTSink uses.
    act_save(act_from_zipper(s.btm, _ -> UInt64(0)), path)
end

function space_restore_tree!(s::Space, path::AbstractString)
    # Upstream Space::restore_tree = open_mmap + insert each path. Mirrors backup_tree's ACT format.
    tree = act_open_mmap(path)
    rz = ACTZipper(tree)
    while zipper_to_next_val!(rz)
        set_val_at!(s.btm, collect(zipper_path(rz)), UNIT_VAL)
    end
end

function space_backup_paths(s::Space, path::AbstractString)
    open(path, "w") do io
        ;
        serialize_paths(s.btm, io);
    end
end

function space_restore_paths!(s::Space, path::AbstractString)
    open(path, "r") do io
        ;
        deserialize_paths(s.btm, io, UNIT_VAL);
    end
end

space_backup_symbols(::Space, ::AbstractString) = nothing  # no interning in this port
space_restore_symbols!(::Space, ::AbstractString) = nothing

# =====================================================================
# Exports
# =====================================================================

export SPACE_SIZES, SPACE_ARITIES, SPACE_VARS
export SpaceParser
export Space, new_space, space_val_count, space_statistics
export space_add_all_sexpr!, space_remove_all_sexpr!
export space_add_sexpr!, space_remove_sexpr!
export space_dump_all_sexpr, space_dump_sexpr, space_load_json!
export space_backup_tree, space_restore_tree!
export space_backup_paths, space_restore_paths!
# =====================================================================
# space_sexpr_to_expr — server-branch addition
# Mirrors sexpr_to_path / Space::sexpr_to_expr in space_temporary.rs
# =====================================================================

function space_sexpr_to_expr(s::Space, sexpr::AbstractString)::MORK.Expr
    sexpr_to_expr(sexpr)
end

# =====================================================================
# space_metta_calculus_at! — server-branch addition
# Mirrors Space::metta_calculus(thread_id_sexpr_str, ...) in space_temporary.rs
# Runs metta_calculus consuming only (exec (<location> $priority) ...) atoms.
# =====================================================================

function space_metta_calculus_at!(s::Space, location_sexpr::AbstractString,
    max_steps::Int=typemax(Int))::Int
    # Build the exec prefix for this location: (exec (<location> $) $ $)
    # Mirrors upstream metta_calculus_impl (kernel/src/space.rs:1035):
    # prefix_e = format!("(exec ({} $) $ $)", thread_id)
    prefix_str = "(exec ($location_sexpr \$) \$ \$)"
    try
        prefix_expr = sexpr_to_expr(prefix_str)
        prefix_bytes = _derive_prefix(prefix_expr)
        return _space_metta_calculus_inner!(s, prefix_bytes, max_steps, location_sexpr)
    catch e
        @warn "space_metta_calculus_at!: $e"
        0
    end
end

"""
    space_metta_calculus_at!(s::Space, anchor_bytes::Vector{UInt8}, max_steps) :: Int

Raw-bytes variant — Julia-specific extension (no upstream Rust equivalent;
upstream's `metta_calculus_impl` only takes `thread_id_sexpr_str: &str`).
Unlike the `AbstractString` overload (which wraps the location in
`(exec (loc \$) \$ \$)` and derives a prefix from that), this variant takes
a pre-computed byte-anchor and walks the calculus directly under it.

For the "run all exec atoms in a named space" use case (Stage 1 multi-space),
prefer `space_metta_calculus_in_prefix!` which composes the space prefix
with `_EXEC_PREFIX` internally — that's a cleaner abstraction than
hand-composing bytes.
"""
function space_metta_calculus_at!(s::Space, anchor_bytes::Vector{UInt8},
    max_steps::Int=typemax(Int))::Int
    try
        _space_metta_calculus_inner!(s, anchor_bytes, max_steps, "<bytes>")
    catch e
        @warn "space_metta_calculus_at! (bytes): $e"
        0
    end
end

"""
    space_metta_calculus_in_prefix!(s, space_prefix, max_steps) :: Int

Run the exec-atom calculus for atoms stored under `space_prefix ++
_EXEC_PREFIX` — the canonical entry point for "run this space's exec
atoms" in Core's prefix-region multi-space model (Stage 1).

`space_prefix == UInt8[]` makes this equivalent to `space_metta_calculus!`
(whole-trie exec processing).  For named spaces with non-empty prefix,
this scopes execution to that space's region only — exec atoms in OTHER
named-space prefixes are NOT touched.

Keeps `_EXEC_PREFIX` private (an internal MORK constant) by composing it
inside the kernel rather than requiring callers to import or reproduce it.
"""
function space_metta_calculus_in_prefix!(s::Space, space_prefix::Vector{UInt8},
    max_steps::Int=typemax(Int))::Int
    isempty(space_prefix) && return space_metta_calculus!(s, max_steps)
    try
        anchor = vcat(space_prefix, _EXEC_PREFIX)
        _space_metta_calculus_inner!(s, anchor, max_steps, "<space-prefix>";
            space_prefix=space_prefix)
    catch e
        @warn "space_metta_calculus_in_prefix!: $e"
        0
    end
end

# Internal: walks exec atoms under `prefix_bytes`, executes each.  Extracted
# from `space_metta_calculus_at!` so both the string-form (which builds an
# `(exec (loc $) $ $)` prefix) and the byte-form (raw anchor) share one loop.
function _space_metta_calculus_inner!(s::Space, prefix_bytes::Vector{UInt8},
    max_steps::Int, loc_label::AbstractString;
    space_prefix::Vector{UInt8}=UInt8[])::Int
    # `space_prefix` (default empty) is the byte-region anchor for a prefixed
    # multi-space.  The exec atom lives in the trie at the FULL path
    # `prefix_bytes ++ rel` (where prefix_bytes = space_prefix ++ _EXEC_PREFIX),
    # so we walk + remove + re-insert at that full path.  But the EXEC EXPRESSION
    # handed to space_interpret! must omit `space_prefix` — it has to start with
    # the exec arity tag (_EXEC_PREFIX ++ body), not the raw region bytes, or the
    # decoder rejects them as reserved.  `prefix=space_prefix` then scopes the
    # exec's reads + writes back into the region.
    done = 0
    retry = false
    retry_cnt = _METTA_CALCULUS_MAX_RETRIES
    path_buf = UInt8[]   # reused scratch — same pattern as space_metta_calculus!
    sp_len = length(space_prefix)

    while done < max_steps
        rz = read_zipper_at_path(s.btm, prefix_bytes)
        found = zipper_to_next_val!(rz)
        if !found
            if retry && retry_cnt > 0
                retry_cnt -= 1
                sleep(0.001)
                continue
            end
            break
        end

        empty!(path_buf)
        append!(path_buf, prefix_bytes)
        append!(path_buf, zipper_path(rz))
        remove_val_at!(s.btm, path_buf)

        # Exec expr omits the space_prefix region bytes (must begin with the
        # exec arity tag).  sp_len==0 → full path_buf (root, unchanged).
        rt = MORK.Expr(path_buf[(sp_len + 1):end])
        err = space_interpret!(s, rt; prefix=space_prefix)

        if err === nothing
            retry = false
            retry_cnt = _METTA_CALCULUS_MAX_RETRIES
            done += 1
        elseif is_user_perm_err(err)
            set_val_at!(s.btm, path_buf, UNIT_VAL)
            retry = true
            if retry_cnt > 0
                (retry_cnt -= 1; sleep(0.001))
            else
                (@warn "space_metta_calculus_at!: retry limit at $loc_label"; break)
            end
        else
            @warn "space_metta_calculus_at!: $(exec_error_message(err))"
            break
        end
    end
    done
end

# =====================================================================
# space_acquire_transform_permissions — server-branch addition
# Mirrors Space::acquire_transform_permissions in space_temporary.rs.
# Returns (read_map, template_prefixes, writer_paths) where:
#   read_map          = PathMap copy of all pattern subtries
#   template_prefixes = Vector{Tuple{Int,Int}} (incremental_start, writer_idx)
#   writer_paths      = Vector{Vector{UInt8}} (one path per unique writer slot)
# =====================================================================

"""
    space_acquire_transform_permissions(s, patterns, templates)
      → (read_map, template_prefixes, writer_slots)

Mirrors `Space::acquire_transform_permissions` in space_temporary.rs.

1. Compute constant prefix for each template (bytes up to first variable).
2. Sort template prefixes shortest-first; find minimal writer slots via
   prefix subsumption (a longer prefix is subsumed by a shorter one that
   is a prefix of it — they share one write lock).
3. Copy each pattern's subtrie into `read_map` (a local PathMap snapshot).
4. Return:
   - `read_map`          — PathMap containing all pattern atoms
   - `template_prefixes` — Vector of (incremental_start::Int, slot_idx::Int)
   - `writer_slots`      — Vector{Vector{UInt8}} (one path per unique slot)
"""
function space_acquire_transform_permissions(s::Space,
    patterns::Vector{MORK.Expr},
    templates::Vector{MORK.Expr})
    # Constant prefix: bytes up to first variable byte (NewVar 0xC0 or VarRef 0x80-0xBF)
    function _const_prefix(e::MORK.Expr)
        buf = e.buf
        i = 1
        while i <= length(buf)
            b = buf[i]
            t = byte_item(b)
            if t isa ExprNewVar || t isa ExprVarRef
                break
            elseif t isa ExprSymbol
                i += 1 + Int(t.size)
            elseif t isa ExprArity
                i += 1
            else
                break
            end
        end
        buf[1:(i - 1)]
    end

    # ── Writer slot subsumption (mirrors template_path_table sort + loop) ──
    # Table: (path, original_template_idx, writer_slot_idx)
    tpl_table = [(copy(_const_prefix(templates[i])), i, 0) for i in eachindex(templates)]
    sort!(tpl_table; by=t -> length(t[1]))   # shortest-first

    writer_slots = Vector{UInt8}[]
    slot_of = zeros(Int, length(templates))   # template_idx → slot_idx

    for k in eachindex(tpl_table)
        path, orig_idx, _ = tpl_table[k]
        subsumed = false
        for (slot_idx, slot_path) in enumerate(writer_slots)
            # slot_path is a prefix of path iff path starts with slot_path
            if length(slot_path) <= length(path) &&
                path[1:length(slot_path)] == slot_path
                slot_of[orig_idx] = slot_idx
                tpl_table[k] = (path, orig_idx, slot_idx)
                subsumed = true
                break
            end
        end
        if !subsumed
            push!(writer_slots, path)
            new_slot = length(writer_slots)
            slot_of[orig_idx] = new_slot
            tpl_table[k] = (path, orig_idx, new_slot)
        end
    end

    # template_prefixes[i] = (incremental_start, slot_idx)
    # incremental_start = length of the writer slot path (bytes already
    # implied by the slot prefix; template path bytes beyond that are
    # "incremental" relative to the slot zipper position).
    template_prefixes = [
        (length(writer_slots[slot_of[i]]), slot_of[i])
        for i in eachindex(templates)
    ]

    # ── Build read_map: snapshot all pattern subtries ──────────────────
    read_map = PathMap{UnitVal}()
    for pat in patterns
        prefix = _const_prefix(pat)
        rz = read_zipper_at_path(s.btm, prefix)
        while zipper_to_next_val!(rz)
            p = vcat(prefix, collect(zipper_path(rz)))
            set_val_at!(read_map, p, UNIT_VAL)
        end
    end

    (read_map, template_prefixes, writer_slots)
end

export space_backup_symbols, space_restore_symbols!
export space_prefix_subsumption, space_token_bfs, space_load_csv!
export BreakQuery, space_query_multi, space_query_multi_i, _space_query_multi_inner!
export space_query_coref, _coreferential_transition!
export _var_children, _size_children, _arity_children
export space_transform_multi_multi!
export space_transform_comma_comma!, space_transform_i_comma!
export space_transform_comma_o!, space_transform_i_o!
export ExecError, is_user_perm_err, exec_error_message
export space_interpret!, space_metta_calculus!, _METTA_CALCULUS_MAX_RETRIES
export _grounded_call_no_args,
    _grounded_call_with_bindings, _grounded_decode_args, _grounded_encode_results
export space_sexpr_to_expr, space_metta_calculus_at!, space_acquire_transform_permissions
export space_metta_calculus_in_prefix!, space_query_multi_at

# Precompile hot-path method specializations so JIT fires at package load,
# not on first user call. Mirrors upstream's statically-compiled hot paths.
precompile(space_metta_calculus!, (Space, Int))
precompile(space_interpret!, (Space, MORK.Expr))
precompile(space_add_all_sexpr!, (Space, String))
precompile(space_dump_all_sexpr, (Space,))
precompile(
    _space_query_multi_inner!,
    (
        PathMap{UnitVal},
        MORK.Expr,
        Int,
        Function,
        Dict{ExprVar, ExprEnv},
        Vector{Tuple{ExprEnv, ExprEnv}}
    )
)
