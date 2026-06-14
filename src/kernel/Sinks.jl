"""
Sinks — port of `mork/kernel/src/sinks.rs`.

Provides the `AbstractSink` / `ASink` abstraction for writing query results.
Each sink consumes pattern-matched paths and applies some operation.

Julia translation notes
========================
  - Rust `Sink` trait → Julia abstract type `AbstractSink` + functions
  - Rust `WriteZipperTracked` arg → mutating the btm PathMap directly
  - Rust `USink`, `AUSink` (coroutine-based) → iterative
  - Rust `ACTSink` → ported (act_from_zipper + act_save, tested)
  - Rust `WASMSink` → skipped (external wasmtime dep)
  - Rust `Z3Sink` → skipped (external Z3 dep, Linux-only in upstream)
  - Rust `PureSink` (eval-ffi) → skipped (eval-ffi experiment only)
  - `AlgebraicStatus` return from `subtract_into`/`join_into` → Bool
"""

# =====================================================================
# AbstractSink interface
# =====================================================================

"""
    AbstractSink

Abstract type for write sinks in the MORK query/transform engine.
Mirrors the `Sink` trait in sinks.rs.

Concrete sinks implement:
  - `sink_apply!(s, bindings, path_bytes, btm)` — handle one matched path
  - `sink_finalize!(s, btm)::Bool`              — commit results, return changed
"""
abstract type AbstractSink end

function sink_apply! end
function sink_finalize! end

# =====================================================================
# PrefixBtm — byte-region scoping wrapper for prefixed multi-space exec
# =====================================================================
#
# PRIMUS-original (the byte-prefix multi-space model is not upstream — upstream
# scopes exec by thread-id).  Sinks write/read the destination map `btm` via
# absolute paths (PRIMUS's intentional direct-`s.btm` adaptation of upstream's
# writer-zipper sink interface).  For a prefixed-region exec, every such btm
# touch must land under the region's `prefix`.
#
# Rather than thread `prefix` into all ~14 sinks' touch points, we wrap the
# destination as `PrefixBtm(inner, prefix)` and overload the five PathMap ops
# the sinks call on it to prepend `prefix`.  Sinks keep writing relative paths;
# the wrapper redirects them into the region.  INTERNAL accumulators
# (`s.head`, `s.unique`, `by_template[..][3]`, …) are raw `PathMap`s, never the
# `btm` arg, so they are untouched — exactly the read/write split each sink uses.
#
# Empty prefix is never wrapped (callers pass the bare `PathMap`), so the root
# path is byte-identical and zero-overhead.
struct PrefixBtm
    inner::PathMap{UnitVal}
    prefix::Vector{UInt8}
end

const SinkBtm = Union{PathMap{UnitVal}, PrefixBtm}

@inline _pp(p::PrefixBtm, path::AbstractVector{UInt8}) = vcat(p.prefix, path)

# Extend (not shadow) the PathMap ops with a PrefixBtm method.  These arrive in
# MORK via `using PathMap` (for calls); to ADD a method we must `import` them so
# the unqualified definition extends PathMap's function instead of defining a
# new MORK-local one that would hide `set_val_at!(::PathMap, …)` from every
# other caller.  (Module-qualifying as `PathMap.set_val_at!` fails — in MORK's
# scope `PathMap` is the exported TYPE, not the module.)  Mirrors the existing
# `import PathMap: ez_reset!` pattern in MORK.jl.
import PathMap: set_val_at!, get_val_at, remove_val_at!, read_zipper, write_zipper

set_val_at!(p::PrefixBtm, path::AbstractVector{UInt8}, v) =
    set_val_at!(p.inner, _pp(p, path), v)
get_val_at(p::PrefixBtm, path::AbstractVector{UInt8}) = get_val_at(p.inner, _pp(p, path))
remove_val_at!(p::PrefixBtm, path::AbstractVector{UInt8}) =
    remove_val_at!(p.inner, _pp(p, path))
# Zippers root at the prefix node so descend/iterate stay anchor-relative.
read_zipper(p::PrefixBtm) = read_zipper_at_path(p.inner, p.prefix)
write_zipper(p::PrefixBtm) = write_zipper_at_path(p.inner, p.prefix)

# =====================================================================
# Helper: compute the constant prefix of an expression
# =====================================================================

"""
    _sink_prefix(e) → Vector{UInt8}

Return the longest constant prefix of expression `e` — the bytes before the
first variable or compound subexpression.  Used by sinks to scope their
WriteZipper to the appropriate path.
"""
function _sink_prefix(e::MORK.Expr)::Vector{UInt8}
    buf = e.buf
    n = length(buf)
    i = 1
    while i <= n
        b = buf[i]
        tag = try
            byte_item(b)
        catch
            ;
            break
        end
        if tag isa ExprNewVar || tag isa ExprVarRef
            break
        elseif tag isa ExprArity
            i += 1   # include the arity byte but then stop (children may vary)
            break
        elseif tag isa ExprSymbol
            i += 1 + Int(tag.size)   # include symbol bytes
        end
    end
    buf[1:(i - 1)]
end

# =====================================================================
# CompatSink — insert path directly into BTM
# =====================================================================

"""
    CompatSink

Insert each matched path verbatim into the destination PathMap.
Mirrors `CompatSink` in sinks.rs.
"""
mutable struct CompatSink <: AbstractSink
    expr::MORK.Expr
    changed::Bool
end

CompatSink(e::MORK.Expr) = CompatSink(e, false)

function sink_apply!(s::CompatSink, bindings::Dict{ExprVar, ExprEnv},
    path::Vector{UInt8}, btm::SinkBtm)
    set_val_at!(btm, path, UNIT_VAL) === nothing && (s.changed = true)
end

sink_finalize!(s::CompatSink, ::SinkBtm)::Bool = s.changed

# =====================================================================
# AddSink — [2] + <expr>: insert after skipping [2]+ prefix
# =====================================================================

"""
    AddSink

Insert matched paths, skipping the first 3 bytes (`[2] +`).
Mirrors `AddSink` in sinks.rs.
"""
mutable struct AddSink <: AbstractSink
    expr::MORK.Expr
    changed::Bool
end

AddSink(e::MORK.Expr) = AddSink(e, false)

function sink_apply!(s::AddSink, bindings::Dict{ExprVar, ExprEnv},
    path::Vector{UInt8}, btm::SinkBtm)
    length(path) > 3 || return nothing
    set_val_at!(btm, path[4:end], UNIT_VAL) === nothing && (s.changed = true)
end

sink_finalize!(s::AddSink, ::SinkBtm)::Bool = s.changed

# =====================================================================
# RemoveSink — [2] - <expr>: collect paths to remove, apply in finalize
# =====================================================================

"""
    RemoveSink

Collect paths to remove, then subtract them from BTM on finalize.
Mirrors `RemoveSink` in sinks.rs.
"""
# Upstream: collects paths into an internal PathMap, then calls wz.subtract_into
# on finalize — one trie-level operation instead of N individual removes.
mutable struct RemoveSink <: AbstractSink
    expr::MORK.Expr
    remove::PathMap{UnitVal}
end

RemoveSink(e::MORK.Expr) = RemoveSink(e, PathMap{UnitVal}())

function sink_apply!(s::RemoveSink, bindings::Dict{ExprVar, ExprEnv},
    path::Vector{UInt8}, btm::SinkBtm)
    length(path) > 3 || return nothing
    set_val_at!(s.remove, path[4:end], UNIT_VAL)
end

function sink_finalize!(s::RemoveSink, btm::SinkBtm)::Bool
    # Subtract collected paths from btm using per-path removal.
    changed = false
    rz = read_zipper(s.remove)
    while zipper_to_next_val!(rz)
        path = collect(zipper_path(rz))
        old = get_val_at(btm, path)
        if old !== nothing
            remove_val_at!(btm, path)
            changed = true
        end
    end
    changed
end

# =====================================================================
# HeadSink — [3] head <N> <expr>: keep top-N lexicographic paths
# =====================================================================

"""
    HeadSink

Keep at most `max` lexicographically smallest paths.
Mirrors `HeadSink` in sinks.rs.
"""
# Upstream: collects paths into an internal PathMap (not Vector).
# `top` is the eviction boundary; `is_head` selects head vs tail (mirrors upstream
# HeadTailSink<const head: bool>, sinks.rs): head keeps the N lexicographically
# SMALLEST paths (Unix `head`, boundary = max kept), tail keeps the N LARGEST
# (`tail`, boundary = min kept).
# finalize uses wz_join_into! (one trie-level merge instead of N individual inserts).
mutable struct HeadSink <: AbstractSink
    expr::MORK.Expr
    is_head::Bool           # true = head (keep N smallest); false = tail (keep N largest)
    head::PathMap{UnitVal}  # collected paths — mirrors upstream PathMap<()>
    skip::Int
    count::Int
    max::Int
    top::Vector{UInt8}      # eviction boundary: max kept (head) | min kept (tail)
end

# Shared builder for the head/tail family. The `(head|tail <N>` prefix is the
# same byte length either way (both heads are 4 chars), so the skip offset math
# is identical — only `is_head` differs.
function _headtail_sink(e::MORK.Expr, is_head::Bool)
    buf = e.buf
    skip = 6
    max_n = 10
    if length(buf) >= 8 && byte_item(buf[1]) isa ExprArity
        num_tag = byte_item(buf[7])
        if num_tag isa ExprSymbol
            num_str = String(buf[8:(7 + Int(num_tag.size))])
            parsed = tryparse(Int, num_str)
            if parsed !== nothing
                skip = 1 + 1 + 4 + 1 + Int(num_tag.size)
                max_n = parsed
            end
        end
    end
    HeadSink(e, is_head, PathMap{UnitVal}(), skip, 0, max_n, UInt8[])
end

HeadSink(e::MORK.Expr) = _headtail_sink(e, true)
TailSink(e::MORK.Expr) = _headtail_sink(e, false)

function sink_apply!(s::HeadSink, bindings::Dict{ExprVar, ExprEnv},
    path::Vector{UInt8}, btm::SinkBtm)
    length(path) <= s.skip && return nothing
    mpath = path[(s.skip + 1):end]
    if s.count == s.max
        # At capacity. head: ignore mpath ≥ boundary(=max kept), else displace the
        # max. tail: ignore mpath ≤ boundary(=min kept), else displace the min.
        # (upstream sinks.rs: `if head { extremum <= mpath } else { extremum >= mpath }`)
        if s.is_head ? (mpath >= s.top) : (mpath <= s.top)
            return nothing  # doesn't displace
        end
        set_val_at!(s.head, mpath, UNIT_VAL)
        remove_val_at!(s.head, s.top)
        # recompute the boundary from the kept set: head → last/max path,
        # tail → first/min value (upstream: descend_last_path vs to_next_val).
        rz = read_zipper(s.head)
        if s.is_head
            zipper_descend_last_path!(rz)
        else
            zipper_to_next_val!(rz)
        end
        s.top = collect(zipper_path(rz))
    else
        if set_val_at!(s.head, mpath, UNIT_VAL) === nothing  # newly inserted
            s.count += 1
            # Track the eviction boundary while filling: head keeps it at the MAX
            # inserted, tail at the MIN. NB upstream's fill branch is shared and
            # tracks the max for BOTH — fine for head, but leaves tail's boundary
            # stale at the fill→capacity transition (wrong eviction for max≥2). We
            # split it here so tail is correct from the first capacity decision;
            # head is byte-identical to before. (Verified by discriminating test;
            # flag upstream sinks.rs HeadTailSink shared fill branch.)
            if isempty(s.top) || (s.is_head ? (mpath > s.top) : (mpath < s.top))
                s.top = copy(mpath)
            end
        end
    end
end

function sink_finalize!(s::HeadSink, btm::SinkBtm)::Bool
    s.head.root === nothing && return false   # empty head — nothing to join
    wz = write_zipper(btm)
    # wz_join_into! takes an AbstractNodeRef, not a TrieNodeODRc — passing the bare
    # root threw MethodError. wz_join_map_into! is the map-level join API: it reads
    # map.root itself and is COW-safe (copy()s on identity arms). Mirrors Rust
    # HeadSink finalize `wz.join_into(&self.head.read_zipper())` (sinks.rs:426).
    status = wz_join_map_into!(wz, s.head)
    status != ALG_STATUS_IDENTITY
end

# =====================================================================
# CountSink — [4] count <result_sym> <source_sym> <expr>: count unique
# =====================================================================

"""
    CountSink

Count unique source values per output template, then write the result.
Mirrors `CountSink` in sinks.rs. Three modes from upstream tests:

  1. Fixed guard  — count-var arg is a literal (e.g. `18`):
       Only emit template if actual count == that literal.
       Example: `(count (all eighteen) 18 source)` → emits `(all eighteen)` iff count=18
  2. Variable-embed — count-var arg is a variable AND template contains it:
       Substitute variable in template with actual count.
       Example: `(count (all \$k) \$k source)` → emits `(all 3)` for count=3
  3. Variable-no-embed — count-var is a variable but template has no variables:
       Always emit template unchanged (count captured but not in result).
       Example: `(count (all stupid) \$k source)` → always emits `(all stupid)`
"""
mutable struct CountSink <: AbstractSink
    expr::MORK.Expr
    # Groups: (template_bytes, count_var_bytes, unique_sources PathMap)
    # count_var_bytes = raw bytes of arg3 (literal or variable).
    by_template::Vector{Tuple{Vector{UInt8}, Vector{UInt8}, PathMap{UnitVal}}}
end

CountSink(e::MORK.Expr) =
    CountSink(e, Tuple{Vector{UInt8}, Vector{UInt8}, PathMap{UnitVal}}[])

function sink_apply!(s::CountSink, bindings::Dict{ExprVar, ExprEnv},
    path::Vector{UInt8}, btm::SinkBtm)
    # path = bound expression: (count <template> <count-var> <source>)
    length(path) < 7 && return nothing
    args = ExprEnv[]
    ee_args!(ExprEnv(UInt8(0), UInt8(0), UInt32(0), MORK.Expr(path)), args)
    length(args) < 4 && return nothing

    tpl_start = Int(args[2].offset) + 1
    tpl_end = _expr_end_offset(path, tpl_start)
    tpl_bytes = path[tpl_start:(tpl_end - 1)]

    # arg3 = count-var or fixed guard value
    var_start = Int(args[3].offset) + 1
    var_end = _expr_end_offset(path, var_start)
    var_bytes = path[var_start:(var_end - 1)]

    src_start = Int(args[4].offset) + 1
    src_end = _expr_end_offset(path, src_start)
    src_bytes = path[src_start:(src_end - 1)]

    # Group by (template, count-var) — both vary with outer variable bindings
    entry = findfirst(t -> t[1] == tpl_bytes && t[2] == var_bytes, s.by_template)
    if entry === nothing
        push!(s.by_template, (tpl_bytes, var_bytes, PathMap{UnitVal}()))
        entry = length(s.by_template)
    end
    set_val_at!(s.by_template[entry][3], src_bytes, UNIT_VAL)
end

function sink_finalize!(s::CountSink, btm::SinkBtm)::Bool
    changed = false
    for (tpl_bytes, var_bytes, sources) in s.by_template
        cnt = val_count(sources)
        cnt_str = string(cnt)
        cnt_mork = vcat(item_byte(ExprSymbol(UInt8(length(cnt_str)))),
            Vector{UInt8}(cnt_str))

        # Mode 1 (fixed guard): var_bytes is a literal symbol, not a variable.
        # Only emit if actual count matches the literal exactly.
        is_var =
            !isempty(var_bytes) &&
            (
                byte_item(var_bytes[1]) isa ExprNewVar ||
                byte_item(var_bytes[1]) isa ExprVarRef
            )

        out = if is_var
            # Mode 2/3: substitute count into template variable, or emit as-is.
            sub = _pure_substitute_first_var(tpl_bytes, 1, length(tpl_bytes), cnt_mork)
            sub !== nothing ? sub : tpl_bytes   # mode 3: no variable in template
        else
            # Mode 1: fixed guard — skip unless count matches literal
            var_bytes == cnt_mork || continue
            tpl_bytes
        end

        old = get_val_at(btm, out)
        set_val_at!(btm, out, UNIT_VAL)
        old === nothing && (changed = true)
    end
    changed
end


# =====================================================================
# SumSink — [4] sum <result_sym> <source_sym> <expr>: sum matched values
# =====================================================================

"""
    SumSink — `(sum <result> <expected> <x>)`

Ports `SumSink` in sinks.rs (the literal branch of `SumSink::finalize`). Template form is
`(sum <result-expr> <expected> <x>)`: accumulate the DECIMAL-STRING value `<x>` over every match,
grouped by `(<result-expr> <expected>)`, and emit `<result-expr>` **iff** the accumulated sum equals
the `<expected>` literal. So `(foo 1)(foo 2)(foo 3)` under `(sum (correct) 6 \$x)` sums to 6, equals
the literal `6`, and emits `(correct)`; `(sum (incorrect) 5 \$x)` sums to 6 ≠ 5 and emits nothing.

This REQUIRES `sum` to be an accumulating sink (`_is_accumulating_sink`, Space.jl) so all matches
land in one `unique` before finalize — a per-match sink could never sum across matches.

Numbers are decimal-string symbols (`u32::from_str_radix(…,10)` in, `total.to_string()` out),
consistent with CountSink and the float reductions. (Prior port was a placeholder that flat-summed
the raw symbol bytes and emitted a bare number, ignoring `<result>`/`<expected>` — `sink_sum_literal`
emitted nothing.)
"""
mutable struct SumSink <: AbstractSink
    expr::MORK.Expr
    unique::PathMap{UnitVal}
end

SumSink(e::MORK.Expr) = SumSink(e, PathMap{UnitVal}())

# Bytes of the `(sum` keyword prefix to strip from each instantiated template: the arity byte +
# the 3-char symbol "sum" + its size byte. Mirrors upstream's `path[5+root..]`.
const _SUM_KEYWORD_PREFIX_LEN = 5

function sink_apply!(s::SumSink, bindings::Dict{ExprVar, ExprEnv},
    path::Vector{UInt8}, btm::SinkBtm)
    # Store the args after `(sum` (i.e. `<result> <expected> <x>`); finalize groups + sums them.
    length(path) > _SUM_KEYWORD_PREFIX_LEN || return nothing
    set_val_at!(s.unique, path[(_SUM_KEYWORD_PREFIX_LEN + 1):end], UNIT_VAL)
end

# Parse one accumulated entry `<result-expr> <expected-sym> <x-sym>` → (result_bytes, expected_str, x).
# Returns nothing if the layout isn't a complete expr followed by two symbols.
function _sum_parse_entry(p::Vector{UInt8})
    isempty(p) && return nothing
    rspan = expr_span(MORK.Expr(p), 1)          # first complete sub-expression = <result>
    i = length(rspan) + 1                        # <expected> symbol tag position
    i <= length(p) || return nothing
    te = byte_item(p[i]); te isa ExprSymbol || return nothing
    esz = Int(te.size); i + esz <= length(p) || return nothing
    expected = String(p[(i + 1):(i + esz)])
    j = i + esz + 1                              # <x> symbol tag position
    j <= length(p) || return nothing
    tx = byte_item(p[j]); tx isa ExprSymbol || return nothing
    xsz = Int(tx.size); j + xsz <= length(p) || return nothing
    xval = tryparse(Int64, String(p[(j + 1):(j + xsz)]))
    xval === nothing && return nothing
    (Vector{UInt8}(rspan), expected, xval)
end

function sink_finalize!(s::SumSink, btm::SinkBtm)::Bool
    # group key = result ++ expected bytes → (result_bytes, expected_str, running_sum)
    groups = Dict{Vector{UInt8}, Tuple{Vector{UInt8}, String, Int64}}()
    rz = read_zipper(s.unique)
    while zipper_to_next_val!(rz)
        parsed = _sum_parse_entry(collect(zipper_path(rz)))
        parsed === nothing && continue
        (rbytes, expected, xval) = parsed
        gkey = vcat(rbytes, Vector{UInt8}(expected))
        g = get(groups, gkey, nothing)
        groups[gkey] = g === nothing ? (rbytes, expected, xval) : (g[1], g[2], g[3] + xval)
    end
    changed = false
    for (_, (rbytes, expected, total)) in groups
        # Emit <result> iff the literal <expected> equals the decimal sum (upstream's
        # `fixed_number == cnt_str`).
        if expected == string(total)
            old = get_val_at(btm, rbytes)
            set_val_at!(btm, rbytes, UNIT_VAL)
            old === nothing && (changed = true)
        end
    end
    changed
end

# =====================================================================
# AndSink — [4] and <result_sym> <source_sym> <expr>: logical AND
# =====================================================================

"""
    AndSink

Logical AND of matched boolean flag values.
Mirrors `AndSink` in sinks.rs (simplified).
"""
mutable struct AndSink <: AbstractSink
    expr::MORK.Expr
    result::Bool
end

AndSink(e::MORK.Expr) = AndSink(e, true)

function sink_apply!(s::AndSink, bindings::Dict{ExprVar, ExprEnv},
    path::Vector{UInt8}, btm::SinkBtm)
    # Check if path ends in a "false" symbol
    if !isempty(path)
        p = collect(path)
        tag = byte_item(p[1])
        if tag isa ExprSymbol
            sym = String(p[2:(1 + Int(tag.size))])
            sym == "false" && (s.result = false)
        end
    end
end

function sink_finalize!(s::AndSink, btm::SinkBtm)::Bool
    key = s.result ? Vector{UInt8}("true") : Vector{UInt8}("false")
    key_enc = vcat(UInt8[item_byte(ExprSymbol(UInt8(length(key))))], key)
    old = get_val_at(btm, key_enc)
    set_val_at!(btm, key_enc, UNIT_VAL)
    old === nothing
end

# =====================================================================
# External-dep stubs — require wasmtime / Z3 (skip)
# =====================================================================

struct WASMSink <: AbstractSink
    ;
    expr::MORK.Expr;
end
struct Z3Sink <: AbstractSink
    ;
    expr::MORK.Expr;
end

for T in (WASMSink, Z3Sink)
    @eval sink_apply!(::$T, ::Dict, ::Vector{UInt8}, ::SinkBtm) =
        error($(string(T)) * " requires external runtime (wasmtime/Z3)")
    @eval sink_finalize!(::$T, ::SinkBtm) =
        error($(string(T)) * " requires external runtime (wasmtime/Z3)")
end

# =====================================================================
# ACTSink — write matched paths to an ArenaCompact (.act) file
# (ACT <filename> <expr>)
# Mirrors ACTSink in sinks.rs — Julia-native: uses act_from_zipper + act_save.
# =====================================================================

mutable struct ACTSink <: AbstractSink
    expr::MORK.Expr
    tmp::PathMap{UnitVal}
    name::String
    skip::Int
end

function ACTSink(e::MORK.Expr)
    buf = e.buf
    name = ""
    # buf layout: [3] ACT <name_sym> <name_bytes> <content_expr>
    # bytes:       1    4     1          name_len
    if length(buf) >= 6
        name_tag = byte_item(buf[6])
        if name_tag isa ExprSymbol
            nl = Int(name_tag.size)
            name = String(buf[7:(6 + nl)])
        end
    end
    # skip = arity(1) + sym_header(1) + "ACT"(3) + name_sym_header(1) + name_bytes
    skip = 6 + length(name)
    ACTSink(e, PathMap{UnitVal}(), name, skip)
end

function sink_apply!(s::ACTSink, ::Dict, path::Vector{UInt8}, ::SinkBtm)
    length(path) > s.skip || return nothing
    set_val_at!(s.tmp, path[(s.skip + 1):end], UNIT_VAL)
end

function sink_finalize!(s::ACTSink, ::SinkBtm)::Bool
    isempty(s.tmp) && return false
    tree = act_from_zipper(s.tmp, _ -> UInt64(0))
    filepath = joinpath(ACT_PATH[], s.name * ".act")
    act_save(tree, filepath)
    # reset for potential reuse
    s.tmp = PathMap{UnitVal}()
    true
end

# =====================================================================
# USink — unification sink: accumulate matches → MGU → insert
# (U <expr>)
# Mirrors USink in sinks.rs — Julia-enhanced: uses expr_unify + expr_apply
# instead of raw unsafe pointer arithmetic.
# =====================================================================

mutable struct USink <: AbstractSink
    expr::MORK.Expr
    buf::Union{Nothing, Vector{UInt8}}  # accumulated MGU bytes
    conflict::Bool
end

USink(e::MORK.Expr) = USink(e, nothing, false)

function sink_apply!(s::USink, ::Dict, path::Vector{UInt8}, ::SinkBtm)
    length(path) > 3 || return nothing
    s.conflict && return nothing
    # Skip [2] U header (3 bytes: arity + sym_header + 'U')
    expr_bytes = path[4:end]
    if s.buf === nothing
        s.buf = copy(expr_bytes)
    else
        acc = s.buf::Vector{UInt8}
        pairs = Tuple{ExprEnv, ExprEnv}[
            (ExprEnv(UInt8(0), UInt8(0), UInt32(0), MORK.Expr(acc)),
            ExprEnv(UInt8(0), UInt8(0), UInt32(0), MORK.Expr(expr_bytes)))
        ]
        result = expr_unify(pairs)
        if result isa UnificationFailure
            s.conflict = true
            return nothing
        end
        # Apply bindings to accumulator to get concrete MGU bytes
        ez = ExprZipper(MORK.Expr(acc))
        out = sizehint!(Vector{UInt8}(), max(length(acc) * 2, 64))
        resize!(out, max(length(acc) * 2, 64))
        oz = ExprZipper(MORK.Expr(out))
        expr_apply(ez, result, oz)
        s.buf = out[1:(oz.loc - 1)]
    end
end

function sink_finalize!(s::USink, btm::SinkBtm)::Bool
    s.conflict && return false
    s.buf === nothing && return false
    buf = s.buf::Vector{UInt8}
    old = get_val_at(btm, buf)
    set_val_at!(btm, buf, UNIT_VAL)
    s.buf = nothing;
    s.conflict = false   # reset
    old === nothing
end

# =====================================================================
# AUSink — anti-unification sink: find least-general generalisation
# (AU <expr>)
# Mirrors AUSink in sinks.rs — Julia-native implementation of anti-unify;
# no equivalent exists in upstream Julia mork_expr.
# Anti-unification: matching positions copied, differing positions → ExprNewVar.
# =====================================================================

# Anti-unification state — mirrors AuState in mork_expr/src/lib.rs.
# memo: (offset_in_e1, offset_in_e2) → variable_index (UInt8)
# Memoizing ensures the same disagreement pair reuses the same variable (LGG correctness).
mutable struct _AuState
    next_var::UInt8
    memo::Dict{Tuple{Int, Int}, UInt8}   # (i1,i2) → var_idx
end
_AuState() = _AuState(UInt8(0), Dict{Tuple{Int, Int}, UInt8}())

mutable struct AUSink <: AbstractSink
    expr::MORK.Expr
    buf::Union{Nothing, Vector{UInt8}}  # accumulated LGG bytes
    last::Int                            # valid length in buf
    st::_AuState                       # anti-unify memo (reset on finalize)
end

AUSink(e::MORK.Expr) = AUSink(e, nothing, 0, _AuState())

# Recursive anti-unification of two sub-expressions.
# Returns (bytes_consumed_from_e1, bytes_consumed_from_e2).
# Mirrors anti_unify_apply in mork_expr/src/lib.rs.
function _au_merge!(e1::Vector{UInt8}, i1::Int,
    e2::Vector{UInt8}, i2::Int,
    out::Vector{UInt8},
    st::_AuState)::Tuple{Int, Int}
    (i1 > length(e1) || i2 > length(e2)) &&
        (push!(out, item_byte(ExprNewVar())); return (0, 0))
    b1 = e1[i1];
    b2 = e2[i2]
    t1 = byte_item(b1);
    t2 = byte_item(b2)

    # decomposable: same symbol content
    if t1 isa ExprSymbol && t2 isa ExprSymbol && t1.size == t2.size
        n = Int(t1.size)
        if i1+n <= length(e1)+1 && i2+n <= length(e2)+1 &&
            view(e1, i1:(i1 + n)) == view(e2, i2:(i2 + n))
            append!(out, view(e1, i1:(i1 + n)))
            return (n+1, n+1)
        end
    end

    # decomposable: same arity — recurse into children
    if t1 isa ExprArity && t2 isa ExprArity && t1.arity == t2.arity
        push!(out, b1)
        c1 = 1;
        c2 = 1
        for _ in 1:Int(t1.arity)
            dc1, dc2 = _au_merge!(e1, i1+c1, e2, i2+c2, out, st)
            c1 += dc1;
            c2 += dc2
        end
        return (c1, c2)
    end

    # Disagreement (including variables treated as atoms per upstream).
    # Memoize: same (i1,i2) pair → reuse variable via VarRef (LGG correctness).
    key = (i1, i2)
    if haskey(st.memo, key)
        push!(out, item_byte(ExprVarRef(st.memo[key])))
    else
        v = st.next_var
        st.memo[key] = v
        st.next_var = UInt8(v + 1)
        push!(out, item_byte(ExprNewVar()))
    end
    s1 = _expr_end_offset(e1, i1) - i1
    s2 = _expr_end_offset(e2, i2) - i2
    (s1, s2)
end

function sink_apply!(s::AUSink, ::Dict, path::Vector{UInt8}, ::SinkBtm)
    length(path) > 4 || return nothing
    # Skip [2] AU header: arity(1) + sym_header(1) + 'A'(1) + 'U'(1) = 4 bytes
    expr_bytes = path[5:end]
    if s.buf === nothing
        s.buf = copy(expr_bytes)
        s.last = length(expr_bytes)
    else
        acc = s.buf::Vector{UInt8}
        out = sizehint!(Vector{UInt8}(), max(length(acc), 32))
        _au_merge!(acc, 1, expr_bytes, 1, out, s.st)
        s.buf = out
        s.last = length(out)
    end
end

function sink_finalize!(s::AUSink, btm::SinkBtm)::Bool
    s.buf === nothing && return false
    buf = s.buf::Vector{UInt8}
    last = s.last
    last == 0 && return false
    key = buf[1:last]
    old = get_val_at(btm, key)
    set_val_at!(btm, key, UNIT_VAL)
    s.buf = nothing;
    s.last = 0;
    s.st = _AuState()   # reset
    old === nothing
end

# =====================================================================
# HashSink — content-addressed hash verification sink
# (hash <result-tpl> <context> <hash-expr>)
# Mirrors HashSink in sinks.rs — Julia-native: uses zipper_fork! + path
# enumeration hash instead of raw-pointer subtrie hash.
# Semantics: for each collected path, verify that the last SIZE bytes
# equal the structural hash of the sub-trie rooted just before those bytes.
# If verified, write the path (minus the hash bytes) to btm.
# =====================================================================

mutable struct HashSink <: AbstractSink
    expr::MORK.Expr
    unique::PathMap{UnitVal}
    skip::Int
end

function HashSink(e::MORK.Expr)
    buf = e.buf
    # layout: [4] hash <result-tpl> <context> <hash-expr>
    # skip = arity(1) + sym_header(1) + "hash"(4) = 6 bytes
    skip = 6
    HashSink(e, PathMap{UnitVal}(), skip)
end

function sink_apply!(s::HashSink, ::Dict, path::Vector{UInt8}, ::SinkBtm)
    length(path) > s.skip || return nothing
    set_val_at!(s.unique, path[(s.skip + 1):end], UNIT_VAL)
end

# Compute a deterministic structural hash of all paths reachable from zipper z.
# Julia-native equivalent of upstream fork_read_zipper().hash().
function _zipper_subtrie_hash(z::ReadZipperCore{UnitVal, GlobalAlloc})::UInt64
    fork = zipper_fork!(z)
    zipper_reset!(fork)
    h = UInt64(0xa9e17c4d3f8b21c5)   # fixed seed — deterministic across calls
    while zipper_to_next_val!(fork)
        for b in zipper_path(fork)
            ;
            h = hash(b, h);
        end
        h = hash(UInt64(0xffffffff), h)  # path terminator
    end
    h
end

function sink_finalize!(s::HashSink, btm::SinkBtm)::Bool
    isempty(s.unique) && return false
    changed = false

    rz = read_zipper(s.unique)
    zipper_reset!(rz)

    # Iterate over all collected paths
    while zipper_to_next_val!(rz)
        path = collect(zipper_path(rz))
        isempty(path) && continue

        # Scan path right-to-left for a symbol-size header byte
        i = length(path)
        while i >= 1
            tag = try
                byte_item(path[i])
            catch
                ;
                i -= 1;
                continue
            end
            tag isa ExprSymbol || (i -= 1; continue)
            sz = Int(tag.size)
            # Check that `sz` bytes follow the header
            i + sz > length(path) && (i -= 1; continue)

            hash_bytes = path[(i + 1):(i + sz)]

            # Position zipper at the prefix (everything before the size header)
            prefix = path[1:(i - 1)]
            rz2 = read_zipper(s.unique)
            zipper_descend_to!(rz2, prefix)
            zipper_path_exists(rz2) || (i -= 1; continue)

            # Compute structural hash of the sub-trie at this prefix
            computed = _zipper_subtrie_hash(rz2)
            cnt_str = reinterpret(UInt8, [hton(computed)])   # big-endian

            # Verify: do the hash bytes equal the computed hash?
            if hash_bytes == cnt_str[1:sz]
                # Write path without the size-header + hash bytes
                key = isempty(prefix) ? UInt8[] : prefix
                old = get_val_at(btm, key)
                set_val_at!(btm, key, UNIT_VAL)
                old === nothing && (changed = true)
            end
            break   # only check rightmost symbol — mirrors upstream
        end
    end

    # Reset for reuse
    s.unique = PathMap{UnitVal}()
    changed
end

# =====================================================================
# PureSink — port of PureSink in sinks.rs
# (pure <template> <var> <formula>)
# Evaluates <formula> using PURE_OPS, substitutes result into <template>,
# and stores the result in the space.
# =====================================================================

mutable struct PureSink <: AbstractSink
    expr::MORK.Expr
    changed::Bool
end
PureSink(e::MORK.Expr) = PureSink(e, false)

"""
    _pure_eval_formula(buf, off) → Union{Vector{UInt8}, Nothing}

Recursively evaluate a pure-ops formula rooted at byte offset `off` (1-based).

INVARIANT: returns a COMPLETE MORK sub-expression (header byte included):
  - Scalar symbol result  → ExprSymbol(n) + payload bytes
  - Compound expression   → ExprArity(n) + children (for `tuple`, `explode_symbol`, `quote`)
  - Skip signal           → nothing  (e.g. `ifnz` with zero cond and no else)

Args passed to `pure_apply` are stripped of their header (raw payloads).

Mirrors EvalScope::eval in experiments/eval/src/lib.rs.
"""
function _pure_eval_formula(buf::Vector{UInt8}, off::Int)::Union{Vector{UInt8}, Nothing}
    off > length(buf) && return nothing
    tag = byte_item(buf[off])

    if tag isa ExprSymbol
        # Return complete MORK symbol (header + payload)
        n = Int(tag.size)
        return buf[off:(off + n)]
    end

    if tag isa ExprArity
        n_args = Int(tag.arity) - 1   # first child is the functor name
        n_args < 0 && return nothing

        # Parse functor name
        fn_off = off + 1
        fn_tag = byte_item(buf[fn_off])
        fn_tag isa ExprSymbol || return nothing
        fn_size = Int(fn_tag.size)
        fn_name = String(buf[(fn_off + 1):(fn_off + fn_size)])

        # Collect arg byte spans
        arg_spans = UnitRange{Int}[]
        cur = fn_off + 1 + fn_size
        for _ in 1:n_args
            cur > length(buf) && break
            span_end = _expr_end_offset(buf, cur)
            push!(arg_spans, cur:(span_end - 1))
            cur = span_end
        end

        # ── ifnz: short-circuit conditional ──────────────────────────
        # Contract: (ifnz COND then THEN-EXPR [else ELSE-EXPR]) — `then`/`else` are literal
        # keyword symbols. SNK-1 (audit 2026-06-04): the keyword positions were SKIPPED
        # without validation, so a malformed shape like `(ifnz cond X Y)` (no keywords)
        # silently evaluated the wrong branch. Now validate the keyword bytes and return
        # `nothing` (skip) on a mismatch instead of mis-branching.
        if fn_name == "ifnz" && length(arg_spans) >= 3
            _ifnz_kw(span) = begin
                o = first(span)
                o <= length(buf) || return ""
                t = byte_item(buf[o])
                t isa ExprSymbol || return ""
                n = Int(t.size)
                (o + n) <= length(buf) ? String(@view buf[(o + 1):(o + n)]) : ""
            end
            _ifnz_kw(arg_spans[2]) == "then" || return nothing   # arg[2] must be `then`
            cond = _pure_eval_formula(buf, first(arg_spans[1]))
            cond === nothing && return nothing
            cond_payload = _pure_strip_header(cond)
            is_nz = !all(==(0x00), cond_payload)
            if is_nz
                return _pure_eval_formula(buf, first(arg_spans[3]))
            elseif length(arg_spans) == 5
                _ifnz_kw(arg_spans[4]) == "else" || return nothing   # arg[4] must be `else`
                return _pure_eval_formula(buf, first(arg_spans[5]))
            else
                return nothing
            end
        end

        # ── quote: return the inner expression bytes verbatim ─────────
        if fn_name == "'" && length(arg_spans) >= 1
            return buf[arg_spans[1]]
        end

        # ── Evaluate all args eagerly; pass raw payloads to pure_apply ─
        arg_results = Vector{UInt8}[]
        for span in arg_spans
            r = _pure_eval_formula(buf, first(span))
            r === nothing && return nothing
            push!(arg_results, _pure_strip_header(r))
        end

        # Ops that return full MORK expressions (not scalar payloads)
        if fn_name == "tuple" || fn_name == "explode_symbol"
            f = get(PURE_OPS, fn_name, nothing)
            f === nothing && return nothing
            result_mork = try
                f(arg_results)
            catch
                ;
                return nothing
            end
            return result_mork isa Vector{UInt8} ? result_mork : nothing
        end

        # Standard scalar ops: get payload, wrap as ExprSymbol
        result_payload = try
            pure_apply(fn_name, arg_results)
        catch
            return nothing
        end
        n = length(result_payload)
        n == 0 && return nothing
        return vcat(item_byte(ExprSymbol(UInt8(n))), result_payload)
    end

    nothing
end

"""
    _pure_strip_header(mork_expr) → Vector{UInt8}

Strip the leading ExprSymbol header byte from a scalar MORK expression to get
raw payload bytes. For arity expressions (tuple etc.), return as-is.
"""
function _pure_strip_header(mork_expr::Vector{UInt8})::Vector{UInt8}
    isempty(mork_expr) && return mork_expr
    tag = try
        byte_item(mork_expr[1])
    catch
        ;
        return mork_expr
    end
    tag isa ExprSymbol ? mork_expr[2:end] : mork_expr
end

"""
    _expr_end_offset(buf, off) → Int

Return the offset just past the expression starting at `off` (exclusive end).
"""
function _expr_end_offset(buf::Vector{UInt8}, off::Int)::Int
    off > length(buf) && return off
    tag = byte_item(buf[off])
    if tag isa ExprSymbol
        return off + 1 + Int(tag.size)
    elseif tag isa ExprArity
        cur = off + 1
        for _ in 1:Int(tag.arity)
            cur > length(buf) && break
            cur = _expr_end_offset(buf, cur)
        end
        return cur
    elseif tag isa ExprNewVar || tag isa ExprVarRef
        return off + 1
    end
    off + 1
end

function sink_apply!(s::PureSink, bindings::Dict, path::Vector{UInt8}, btm::SinkBtm)
    buf = s.expr.buf
    length(buf) < 2 || byte_item(buf[1]) isa ExprArity || return nothing

    # Parse (pure <template> <var> <formula>) — 4 children
    args = ExprEnv[]
    ee_args!(ExprEnv(UInt8(0), UInt8(0), UInt32(0), s.expr), args)
    length(args) < 4 && return nothing

    # Extract sub-expression byte spans
    tpl_ee = args[2]
    formula_ee = args[4]

    tpl_start = Int(tpl_ee.offset) + 1
    formula_start = Int(formula_ee.offset) + 1
    tpl_buf = tpl_ee.base.buf
    formula_buf = formula_ee.base.buf

    formula_start > length(formula_buf) && return nothing

    # Evaluate formula — returns a complete MORK sub-expression (header included)
    result_mork = _pure_eval_formula(formula_buf, formula_start)
    result_mork === nothing && return nothing

    # Substitute: walk template bytes, replace first VarRef/NewVar with result_mork
    tpl_end = _expr_end_offset(tpl_buf, tpl_start)
    out = _pure_substitute_first_var(tpl_buf, tpl_start, tpl_end - 1, result_mork)
    out === nothing && return nothing

    old = get_val_at(btm, out)
    set_val_at!(btm, out, UNIT_VAL)
    old === nothing && (s.changed = true)
end

"""
    _pure_substitute_first_var(buf, from, to, replacement) → Vector{UInt8}

Walk the expression in buf[from:to], replacing the first VarRef or NewVar
with `replacement` bytes. Returns the resulting byte vector, or `nothing`
if no variable slot was found.
"""
function _pure_substitute_first_var(buf::Vector{UInt8}, from::Int, to::Int,
    replacement::Vector{UInt8})::Union{Vector{UInt8}, Nothing}
    out = UInt8[]
    found = Ref(false)
    _pure_copy_subst!(buf, from, to, replacement, out, found)
    found[] ? out : nothing
end

function _pure_copy_subst!(buf::Vector{UInt8}, from::Int, to::Int,
    repl::Vector{UInt8}, out::Vector{UInt8}, found::Ref{Bool})
    from > to && return nothing
    tag = byte_item(buf[from])
    if (tag isa ExprNewVar || tag isa ExprVarRef) && !found[]
        append!(out, repl)
        found[] = true
        return nothing
    end
    if tag isa ExprSymbol
        n = Int(tag.size)
        append!(out, buf[from:(from + n)])
        return nothing
    end
    if tag isa ExprArity
        push!(out, buf[from])
        cur = from + 1
        for _ in 1:Int(tag.arity)
            cur > to && break
            child_end = _expr_end_offset(buf, cur) - 1
            _pure_copy_subst!(buf, cur, child_end, repl, out, found)
            cur = child_end + 1
        end
        return nothing
    end
    push!(out, buf[from])
end

sink_finalize!(s::PureSink, ::SinkBtm) = (c=s.changed; s.changed=false; c)

# Float reduction sinks
# Mirrors FloatReductionSink<Sum/Min/Max/Prod> in sinks.rs.
# Template format: (fsum (result-tpl) $c $x) where:
#   arg2 = result template  (e.g. "(sum $c)")
#   arg3 = key/context var  ($c — groups the reduction)
#   arg4 = value            ($x — the numeric value, already substituted)
mutable struct FloatReductionSink{R} <: AbstractSink
    expr::MORK.Expr
    op::Symbol   # :sum, :min, :max, :prod
    # Groups: (key_bytes → Vector{Float64})
    by_key::Vector{Tuple{Vector{UInt8}, Vector{Float64}}}
end

FloatReductionSink(e::MORK.Expr, op::Symbol) =
    FloatReductionSink{op}(e, op, Tuple{Vector{UInt8}, Vector{Float64}}[])

function sink_apply!(s::FloatReductionSink, bindings, path::Vector{UInt8}, btm)
    # path = bound expression bytes: (fXXX <tpl> <key> <value>)
    length(path) < 5 && return nothing
    args = ExprEnv[]
    ee_args!(ExprEnv(UInt8(0), UInt8(0), UInt32(0), MORK.Expr(path)), args)
    length(args) < 4 && return nothing

    # Extract key bytes (arg3) — the group-by variable/value
    key_start = Int(args[3].offset) + 1
    key_end = _expr_end_offset(path, key_start)
    key_bytes = path[key_start:(key_end - 1)]

    # Extract value bytes (arg4) — should be a Symbol containing a float string
    val_start = Int(args[4].offset) + 1
    val_start > length(path) && return nothing
    vtag = byte_item(path[val_start])
    vtag isa ExprSymbol || return nothing
    val_str = String(path[(val_start + 1):(val_start + Int(vtag.size))])
    fval = tryparse(Float64, val_str)
    fval === nothing && return nothing

    # Find or create the entry for this key
    idx = findfirst(t -> t[1] == key_bytes, s.by_key)
    if idx === nothing
        push!(s.by_key, (key_bytes, Float64[]))
        idx = length(s.by_key)
    end
    push!(s.by_key[idx][2], fval)
end

function sink_finalize!(s::FloatReductionSink, btm::SinkBtm)::Bool
    isempty(s.by_key) && return false
    changed = false
    op = s.op

    # Extract result template (arg2 of the sink expression)
    args = ExprEnv[]
    ee_args!(ExprEnv(UInt8(0), UInt8(0), UInt32(0), s.expr), args)
    length(args) < 2 && return false
    tpl_start = Int(args[2].offset) + 1
    tpl_buf = args[2].base.buf
    tpl_end = _expr_end_offset(tpl_buf, tpl_start)
    tpl_bytes = tpl_buf[tpl_start:(tpl_end - 1)]

    for (key_bytes, values) in s.by_key
        isempty(values) && continue
        result = if op === :sum
            sum(values)
        elseif op === :min
            minimum(values)
        elseif op === :max
            maximum(values)
        elseif op === :prod
            prod(values)
        else
            continue
        end

        # Format result as a MORK symbol
        result_str = string(result)
        result_mork = vcat(item_byte(ExprSymbol(UInt8(length(result_str)))),
            Vector{UInt8}(result_str))

        # Substitute result into the template:
        # If key_bytes is a variable (NewVar/VarRef), substitute result directly.
        # Otherwise, prepend key_bytes and append result (result stored as key→result).
        if length(key_bytes) == 1 && (
            byte_item(key_bytes[1]) isa ExprNewVar ||
            byte_item(key_bytes[1]) isa ExprVarRef
        )
            # Free context variable — substitute result into template's first var
            out = _pure_substitute_first_var(tpl_bytes, 1, length(tpl_bytes), result_mork)
            out === nothing && continue
            old = get_val_at(btm, out)
            set_val_at!(btm, out, UNIT_VAL)
            old === nothing && (changed = true)
        else
            # Bound key — substitute key into template, then append result
            # Produces: (sum <key_value> <result>)
            # First sub the key into the template
            keyed = _pure_substitute_first_var(tpl_bytes, 1, length(tpl_bytes), key_bytes)
            keyed === nothing && continue
            # Append result value as next atom
            out_bytes = vcat(keyed, result_mork)
            # Adjust the arity of the outermost expression
            if !isempty(out_bytes) && byte_item(out_bytes[1]) isa ExprArity
                old_arity = Int(byte_item(out_bytes[1]).arity)
                out_bytes[1] = item_byte(ExprArity(UInt8(old_arity + 1)))
            end
            old = get_val_at(btm, out_bytes)
            set_val_at!(btm, out_bytes, UNIT_VAL)
            old === nothing && (changed = true)
        end
    end
    empty!(s.by_key)
    changed
end

# =====================================================================
# ASink — dispatch union
# =====================================================================

"""
    asink_new(expr) → AbstractSink

Construct the appropriate sink from the pattern expression.
Mirrors `ASink::new` in sinks.rs.
"""
function asink_new(e::MORK.Expr)::AbstractSink
    buf = e.buf
    length(buf) < 2 && return CompatSink(e)

    a1 = buf[1];
    a2 = buf[2]

    # [2] + → AddSink
    if a1 == item_byte(ExprArity(UInt8(2))) && a2 == item_byte(ExprSymbol(UInt8(1))) &&
        length(buf) >= 3 && buf[3] == UInt8('+')
        return AddSink(e)
    end

    # [2] - → RemoveSink
    if a1 == item_byte(ExprArity(UInt8(2))) && a2 == item_byte(ExprSymbol(UInt8(1))) &&
        length(buf) >= 3 && buf[3] == UInt8('-')
        return RemoveSink(e)
    end

    # [2] U → USink
    if a1 == item_byte(ExprArity(UInt8(2))) && a2 == item_byte(ExprSymbol(UInt8(1))) &&
        length(buf) >= 3 && buf[3] == UInt8('U')
        return USink(e)
    end

    # [2] AU → AUSink
    if a1 == item_byte(ExprArity(UInt8(2))) && a2 == item_byte(ExprSymbol(UInt8(2))) &&
        length(buf) >= 4 && buf[3] == UInt8('A') && buf[4] == UInt8('U')
        return AUSink(e)
    end

    # [3] head N <expr> → HeadSink
    if a1 == item_byte(ExprArity(UInt8(3))) && a2 == item_byte(ExprSymbol(UInt8(4))) &&
        length(buf) >= 6 &&
        buf[3:6] == UInt8[UInt8('h'), UInt8('e'), UInt8('a'), UInt8('d')]
        return HeadSink(e)
    end

    # [3] tail N <expr> → TailSink (HeadSink with is_head=false)
    if a1 == item_byte(ExprArity(UInt8(3))) && a2 == item_byte(ExprSymbol(UInt8(4))) &&
        length(buf) >= 6 &&
        buf[3:6] == UInt8[UInt8('t'), UInt8('a'), UInt8('i'), UInt8('l')]
        return TailSink(e)
    end

    # [4] count <r> <s> <p> → CountSink
    if a1 == item_byte(ExprArity(UInt8(4))) && a2 == item_byte(ExprSymbol(UInt8(5))) &&
        length(buf) >= 7 && buf[3:7] == Vector{UInt8}("count")
        return CountSink(e)
    end

    # [4] hash → HashSink
    if a1 == item_byte(ExprArity(UInt8(4))) && a2 == item_byte(ExprSymbol(UInt8(4))) &&
        length(buf) >= 6 && buf[3:6] == Vector{UInt8}("hash")
        return HashSink(e)
    end

    # [4] sum → SumSink
    if a1 == item_byte(ExprArity(UInt8(4))) && a2 == item_byte(ExprSymbol(UInt8(3))) &&
        length(buf) >= 5 && buf[3:5] == Vector{UInt8}("sum")
        return SumSink(e)
    end

    # [4] and → AndSink
    if a1 == item_byte(ExprArity(UInt8(4))) && a2 == item_byte(ExprSymbol(UInt8(3))) &&
        length(buf) >= 5 && buf[3:5] == Vector{UInt8}("and")
        return AndSink(e)
    end

    # [4] fsum / fmin / fmax → FloatReductionSink
    if a1 == item_byte(ExprArity(UInt8(4))) && a2 == item_byte(ExprSymbol(UInt8(4))) &&
        length(buf) >= 6
        if buf[3] == UInt8('f') && buf[4] == UInt8('s')
            return FloatReductionSink(e, :sum)
        elseif buf[3] == UInt8('f') && buf[4] == UInt8('m') && buf[5] == UInt8('i')
            return FloatReductionSink(e, :min)
        elseif buf[3] == UInt8('f') && buf[4] == UInt8('m') && buf[5] == UInt8('a')
            return FloatReductionSink(e, :max)
        end
    end

    if a1 == item_byte(ExprArity(UInt8(4))) && a2 == item_byte(ExprSymbol(UInt8(5))) &&
        length(buf) >= 7 && buf[3] == UInt8('f') && buf[4] == UInt8('p')
        return FloatReductionSink(e, :prod)
    end

    # [4] pure → PureSink
    if a1 == item_byte(ExprArity(UInt8(4))) && a2 == item_byte(ExprSymbol(UInt8(4))) &&
        length(buf) >= 6 && buf[3:6] == Vector{UInt8}("pure")
        return PureSink(e)
    end

    # [3] ACT → ACTSink
    if a1 == item_byte(ExprArity(UInt8(3))) && a2 == item_byte(ExprSymbol(UInt8(3))) &&
        length(buf) >= 5 && buf[3:5] == Vector{UInt8}("ACT")
        return ACTSink(e)
    end

    # [3] wasm → WASMSink
    if a1 == item_byte(ExprArity(UInt8(3))) && a2 == item_byte(ExprSymbol(UInt8(4))) &&
        length(buf) >= 6 && buf[3:6] == Vector{UInt8}("wasm")
        return WASMSink(e)
    end

    CompatSink(e)   # fallback
end

asink_compat(e::MORK.Expr) = CompatSink(e)

# =====================================================================
# Exports
# =====================================================================

export AbstractSink, sink_apply!, sink_finalize!
export CompatSink, AddSink, RemoveSink, HeadSink, TailSink
export CountSink, SumSink, AndSink
export ACTSink, WASMSink, PureSink, Z3Sink, USink, AUSink, HashSink
export _pure_eval_formula, _expr_end_offset
export FloatReductionSink
export asink_new, asink_compat
export _au_merge!, _zipper_subtrie_hash
