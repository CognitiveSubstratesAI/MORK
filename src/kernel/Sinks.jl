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
  - Rust `WASMSink` → PORTED (`struct WASMSink <: AbstractSink`, line 606)
  - Rust `Z3Sink`   → PORTED (`mutable struct Z3Sink <: AbstractSink`, line 618)
  - Rust `PureSink` → PORTED (`mutable struct PureSink <: AbstractSink`, line 955) — and it is the
    host of all 532 `PURE_OPS`, i.e. the single most load-bearing sink in the file
  #
  # ⚠️ CORRECTED 2026-07-30. Those three lines previously read "→ skipped": WASMSink "skipped
  # (external wasmtime dep)", Z3Sink "skipped (external Z3 dep, Linux-only in upstream)", PureSink
  # "skipped (eval-ffi experiment only)". ALL THREE ARE FALSE — each is a real struct defined in this
  # file, at the lines cited above. PureSink in particular carries the entire pure-op surface.
  #
  # This is the FOURTH stale comment found contradicting its own code in two days, after
  # `mm2_is_relational`'s justification (claimed GROUNDED_REGISTRY held "only the 3 WILLIAM ops";
  # it holds 69), `space_metta_calculus!`'s docstring (claimed it HALTS on error; it continues), and
  # a `nothing ≡ ExecNoReduce` equivalence claim. The pattern is not carelessness — it is that
  # nothing CHECKS prose. A "skipped" note is exactly the kind of claim that makes a reader stop
  # looking, so it is worse than silence: it was still here while the sink layer got an intense
  # debugging pass. If you write "skipped"/"absent"/"not ported" anywhere in this repo, grep for the
  # symbol first.
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
# =====================================================================
# sink_request — upstream `Sink::request()` (ROOT ONLY; writes nothing yet)
# =====================================================================
#
# STATUS 2026-08-03: STEP 1 OF THE WRITE-ROOTING PORT. This computes WHAT the root is.
# Nothing consumes it yet — `sink_apply!` still takes a flat absolute path. That separation is
# deliberate: the previous attempt at root-doubling conflated "what the root is" with "how it is
# written", prepended the root in branches 1+2, and was MEASURED to fix 11 probes and break 16
# (corpus 237->232). So the root is landed and pinned FIRST, on its own oracle.
#
# WHAT UPSTREAM DOES. Every BTM sink asks for a write zipper rooted at its own expression's GROUND
# PREFIX, minus its keyword header:
#
#     let p = &self.e.prefix().unwrap_or_else(<ground fallback>)[<skip>..];
#     std::iter::once(WriteResourceRequest::BTM(p))
#
# `Expr::prefix()` is the bytes before the FIRST VARIABLE; when the expression is fully ground it
# has no proper prefix and each sink supplies its own fallback. There are exactly TWO fallbacks and
# the difference is load-bearing — `RemoveSink` states why at sinks.rs:341:
#
#     "we're never grabbing the full expression path, because then we don't have the ability to
#      remove the root value"
#
#   FULL span      : Compat(skip 0) · Add(3) · U(3) · AU(4)
#   span MINUS ONE : Remove(3) · And(5) · Sum(5) · Hash(6) · Pure(6) · Count(7) · FloatReduction(2+len(NAME))
#
# `skip` is uniformly `2 + length(keyword)` — the Arity byte plus the SymbolSize byte plus the
# keyword itself (Compat strips nothing). Non-BTM sinks request a different resource entirely and
# have NO root: ACTSink asks for an ACT file (sinks.rs:320), Z3Sink for a Z3 instance (:1204).
#
# CHECKED ARITHMETICALLY AGAINST THE BINARY'S OWN OUTPUT before this was written:
#   (and (ok $z) 2 $i)      first var $z at 10 -> stop 9,  skip 5 -> root `(ok`
#                           binary emits (ok (ok $a))        = root ++ result  ✓
#   (fsum (res p $z) $c $x) first var $z at 14 -> stop 13, skip 6 -> root `(res p`
#                           binary emits (res p (res p $a))  = root ++ result  ✓
#   (sum (correct) 6 $x)    result is GROUND, so the first var is $x and the root runs PAST the
#                           result into the source slot -> `(correct) 6`. This is exactly why
#                           "prepend the root" is NOT the doubling rule and why the shortcut failed.
"""
    sink_request(s::AbstractSink) → Union{Nothing, Vector{UInt8}}

The BTM write root this sink asks for, or `nothing` for sinks that request a non-BTM resource.
Pure and read-only — see the block comment above for the upstream correspondence.
"""
function sink_request end

# `skip` bytes of `(<keyword>` header, and whether the GROUND fallback drops the final byte.
function _sink_root(e::MORK.Expr, skip::Int, ground_minus_one::Bool)::Vector{UInt8}
    buf = e.buf; n = length(buf); i = 1; varpos = 0
    while i <= n
        t = byte_item(buf[i])
        if t isa ExprNewVar || t isa ExprVarRef
            varpos = i; break
        elseif t isa ExprSymbol
            i += 1 + Int(t.size)
        else
            i += 1                                  # Arity
        end
    end
    stop = varpos != 0 ? (varpos - 1) : (ground_minus_one ? n - 1 : n)
    stop <= skip && return UInt8[]
    Vector{UInt8}(buf[(skip + 1):stop])
end

# (the per-sink methods are defined at the END of this file, after every sink struct exists)

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
        # PRUNE=TRUE, because that is what upstream's call resolves to. `sinks.rs:399` is
        #     self.extrema.remove(&self.extremum[..]);
        # and `remove` is PathMap's collection-style ALIAS, `trie_map.rs:379-381`:
        #     pub fn remove<K>(&mut self, path: K) -> Option<V> { self.remove_val_at(path, true) }
        # Our `remove_val_at!` defaults `prune=false` (WriteZipper.jl — an ergonomic Julia default;
        # Rust has no default args), and we never ported the `remove` alias, so this call silently
        # took the non-pruning path.
        #
        # Why that is a wrong ANSWER: `zipper_descend_last_path!` below walks STRUCTURE, not values
        # — upstream documents it as "the last path reachable by descent … equivalent to
        # descend_last_byte in a loop" (zipper.rs:633-640). An unpruned removal leaves the path in
        # the trie with no value, so the descent RE-FINDS THE REMOVED KEY and `s.top` never advances
        # past the first eviction. Every later removal then targets a key already gone, and the set
        # grows to N-1 instead of `max`. Confirmed against the live binary: `(head 2 …)` over 5
        # inputs kept 4 here and 2 upstream.
        remove_val_at!(s.head, s.top, true)
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
    # map.root itself. Mirrors Rust HeadSink finalize
    # `wz.join_into(&self.head.read_zipper())` (sinks.rs:426).
    #
    # ⚠️ THIS COMMENT HAS BEEN WRONG TWICE — the second correction is the one that stuck.
    #   v1 claimed wz_join_map_into! "is COW-safe (copy()s on identity arms)". False at the time.
    #   v2 (2026-08-01, earlier) claimed it CONSUMES `map` by design, faithfully to upstream's
    #      by-value `join_map_into(&mut self, map: PathMap<V,A>)`, and warned that `s.head` was safe
    #      here only because the sink finalizes once. Also false: the mutation was a PathMap DEFECT,
    #      not a contract. `LineListNode::join_into_dyn!` merged into its right-hand operand where
    #      upstream clones it (line_list_node.rs:2515-2532). Fixed; fuzz ratchet 31 → 30 (case 00324).
    # `s.head` now survives the join intact, so neither a second finalize nor a later read of
    # `s.head` can see a polluted map. Pinned in PathMap/test/test_join_preserves_source.jl.
    status = wz_join_map_into!(wz, s.head)
    status != ALG_STATUS_IDENTITY
end

# =====================================================================
# CountSink — [4] count <result_sym> <source_sym> <expr>: count unique
# =====================================================================

"""
    CountSink — `(count <result> <source> <value>)`

Ports `CountSink` (sinks.rs:547-623). Counts the entries accumulated under each `<result>` and then
dispatches the SAME three branches as the other accumulating sinks (see `_redsink_finalize!`):
a literal `<source>` emits `<result>` iff it equals the count, a bare NewVar emits `<result>`
unchanged, and a `VarRef(k)` splices the count into `<result>` at de-Bruijn index k.

⚠️ Unlike And/Sum/FloatReduction, the reduction here is computed at the **context** level: upstream
takes `cnt = prz.val_count()` (sinks.rs:580) BEFORE descending into the `<source>` slot, so the group
is `<result>` ALONE and the count spans every source slot beneath it. The others fold AFTER descending,
making their group `(<result>, <source>)`. That is why this cannot simply reuse `_redsink_finalize!`.

FIXED 2026-07-26: the port previously grouped by `(template, source)` and counted only that group's
sources — so a query variable in the source slot split one upstream group into several and fabricated
matches — and it collapsed upstream's NewVar and VarRef branches into a single `is_var` case that
substituted at the template's FIRST variable instead of at index k. Both were silent wrong answers;
the CTL fixture never caught them because its template has exactly one variable, where k == 0 == first.
"""
mutable struct CountSink <: AbstractSink
    expr::MORK.Expr
    unique::PathMap{UnitVal}
end

CountSink(e::MORK.Expr) = CountSink(e, PathMap{UnitVal}())

function sink_apply!(s::CountSink, bindings::Dict{ExprVar, ExprEnv},
    path::Vector{UInt8}, btm::SinkBtm)
    # Store the INSTANTIATED `<result> <source> <value>` (upstream: unique.insert(mpath, ())).
    plen = _sink_keyword_prefix_len(s.expr)
    length(path) > plen || return nothing
    set_val_at!(s.unique, path[(plen + 1):end], UNIT_VAL)
end

function sink_finalize!(s::CountSink, btm::SinkBtm)::Bool
    # Group by <result> alone; count every stored entry beneath it, and remember which distinct
    # <source> slots occur there so each of the three branches can be tested independently
    # (upstream's three `if`s are not mutually exclusive — sinks.rs:584/595/603).
    counts = Dict{Vector{UInt8}, Int}()
    slots  = Dict{Vector{UInt8}, Vector{Vector{UInt8}}}()
    order  = Vector{Vector{UInt8}}()
    rz = read_zipper(s.unique)
    while zipper_to_next_val!(rz)
        parsed = _redsink_parse_entry(collect(zipper_path(rz)); symbol_value = false)
        parsed === nothing && continue
        (rbytes, source, _value) = parsed
        if !haskey(counts, rbytes)
            push!(order, rbytes); counts[rbytes] = 0; slots[rbytes] = Vector{UInt8}[]
        end
        counts[rbytes] += 1
        source in slots[rbytes] || push!(slots[rbytes], source)
    end

    changed = false
    for rbytes in order
        cnt_str = string(counts[rbytes])
        cnt_sym = vcat(item_byte(ExprSymbol(UInt8(ncodeunits(cnt_str)))), Vector{UInt8}(cnt_str))
        for source in slots[rbytes]
            t = byte_item(source[1])
            out = if t isa ExprNewVar
                rbytes                                   # branch 2 — ignored guard
            elseif t isa ExprVarRef
                k = Int(t.idx)                           # branch 3 — substitute at index k, re-basing
                k < _expr_newvars(rbytes, 1, length(rbytes)) ?
                    _expr_substitute_one_de_bruijn(rbytes, 1, length(rbytes), k, cnt_sym) : nothing
            else
                source == cnt_sym ? rbytes : nothing     # branch 1 — fixed literal
            end
            out === nothing && continue
            old = get_val_at(btm, out)
            set_val_at!(btm, out, UNIT_VAL)
            old === nothing && (changed = true)
        end
    end
    changed
end


# =====================================================================
# Shared three-branch reduction-sink finalize (AndSink / SumSink)
# =====================================================================
#
# Upstream's accumulating reduction sinks are ONE shape with THREE branches, dispatched on what the
# `<source>` slot holds. AndSink::finalize (sinks.rs:741-830) and SumSink::finalize (:851-940) are
# line-for-line identical apart from (init, accumulate, encode):
#
#   branch 1  SIZES fixed-literal  (:757-789 / :867-898) — `<source>` is a literal symbol. Reduce the
#             group and emit `<result>` IFF the encoded reduction equals that literal. A MISMATCH EMITS
#             NOTHING — the asymmetry is the whole point of the branch.
#   branch 2  NewVar ignored guard (:791-798 / :900-907) — `<source>` is a bare NewVar. Emit the path
#             minus that byte, i.e. `<result>` unchanged.
#   branch 3  VarRef(k)            (:799-826 / :908-935) — `<source>` is a backref into `<result>`.
#             Reduce the group and splice the value in with `substitute_one_de_bruijn(k, value)`, which
#             substitutes AT INDEX k and RE-BASES every trailing de-Bruijn var.
#
# Upstream walks a OneFactor/query_multi_raw trie traversal to enumerate groups; we group in a Dict
# keyed by (result, source), which yields the same partition — upstream's "context" IS the
# `<result> <source>` prefix, and the values it reduces are exactly the payloads stored under it.
#
# HISTORY (fixed 2026-07-26): our two sinks had each implemented a DIFFERENT SINGLE BRANCH of this —
# AndSink only branch 3 (and wrongly: it filled the FIRST NewVar rather than index k, and hand-rolled a
# byte copy that left trailing VarRefs dangling), SumSink only branch 1. Every unimplemented branch was
# a SILENT DROP, invisible to the suite because `ip_sudoku_hard.mm2` is the only corpus fixture using
# either sink and its shape is the one case where the old and new code agree. Regression:
# `test/integration/sink_and_sum_branches.jl` (9 probes, upstream-binary ground truth).

# Parse one accumulated entry `<result-expr> <source> <value>`.
# `<source>` is a NewVar/VarRef (1 byte) or a literal Symbol (tag + payload).
# Returns (result_bytes, source_node_bytes, value_bytes) or nothing if the layout doesn't fit.
#
# `symbol_value` controls how `<value>` is read. The reducing sinks (And/Sum/Float) fold a NUMBER, so
# they need the symbol PAYLOAD and must decline anything else — upstream reads `p[clen+1..]` assuming a
# symbol there. CountSink only COUNTS entries and never looks at the value, which is routinely a
# compound expression (`(count (all $k) $k (cux $z $y $x))`); requiring a symbol there silently dropped
# every entry and made the count 0 (caught by the mode-1/2/3 regressions, 2026-07-26).
function _redsink_parse_entry(p::Vector{UInt8}; symbol_value::Bool = true)
    isempty(p) && return nothing
    rspan = expr_span(MORK.Expr(p), 1)              # first complete sub-expression = <result>
    i = length(rspan) + 1
    i <= length(p) || return nothing
    ts = byte_item(p[i])
    slen = ts isa ExprSymbol ? 1 + Int(ts.size) : 1  # literal source spans its payload; a var is 1 byte
    (i + slen - 1) <= length(p) || return nothing
    source = Vector{UInt8}(p[i:(i + slen - 1)])
    j = i + slen
    j <= length(p) || return nothing
    value = if !symbol_value
        Vector{UInt8}(p[j:end])                      # opaque to CountSink
    else
        tx = byte_item(p[j])
        if tx isa ExprSymbol
            xsz = Int(tx.size); j + xsz <= length(p) || return nothing
            Vector{UInt8}(p[(j + 1):(j + xsz)])
        else
            # UPSTREAM DOES NOT TYPE-CHECK THIS SLOT. `sinks.rs:771` (and :808) is literally
            #     total &= p[clen+1];
            # a RAW BYTE with no tag inspection. For a COMPOUND value that byte is the arity-N
            # expression's FIRST CHILD HEADER (0xC1 = SymbolSize(1)), and upstream emits from it.
            #
            # Returning `nothing` here discarded the ENTRY, and since the caller groups by
            # (result, source), losing every entry of a group emitted NOTHING AT ALL — no error,
            # no partial result. Verified against the live binary: `sinks/g2_and_compound_value`
            # yields `(m a 3) (m a 6) (r \xc1)` upstream and dropped `(r \xc1)` here.
            #
            # Hand back the payload from j+1 so each `acc` reads it the way ITS upstream branch
            # does: `_and_acc` takes value[1] (= p[clen+1]); `_sum_acc` parses the whole slice
            # (= p[clen+1..], sinks.rs:880) and declines via `nothing` where upstream would
            # `unwrap()`-panic — this file's standing policy for panic shapes.
            j < length(p) || return nothing
            Vector{UInt8}(p[(j + 1):end])
        end
    end
    (Vector{UInt8}(rspan), source, value)
end

"""
    _redsink_finalize!(unique, btm, init, acc, enc) → Bool

Generic finalize for the accumulating reduction sinks. `acc(running, value_payload)` folds one entry
(returning `nothing` to SKIP an entry upstream would have panicked on, e.g. an unparseable number);
`enc(total)` renders the reduction as a complete symbol node (tag + payload), which is both the value
spliced in by branch 3 and the thing compared against the literal in branch 1.
"""
function _redsink_finalize!(unique::PathMap{UnitVal}, btm::SinkBtm, init::T, acc, enc)::Bool where {T}
    GK = Tuple{Vector{UInt8}, Vector{UInt8}}         # (result, source) — upstream's traversal "context"
    groups = Dict{GK, T}()                           # FOLDED total — ABSENT if no value ever folded
    order = GK[]                                     # EXISTENCE + deterministic order (Dict iteration is not)
    exists = Set{GK}()                               # membership test for `order`, O(1) not O(n)
    rz = read_zipper(unique)
    while zipper_to_next_val!(rz)
        parsed = _redsink_parse_entry(collect(zipper_path(rz)))
        parsed === nothing && continue
        (rbytes, source, value) = parsed
        key = (rbytes, source)
        # EXISTENCE IS RECORDED BEFORE FOLDING, and that separation is the whole point.
        # Upstream's branch 2 (the NewVar "ignored guard") reads NO VALUES — sinks.rs:900-907:
        #     if prz.descend_to_existing_byte(item_byte(Tag::NewVar)) {
        #         let ignored = &prz.path()[..prz.path().len()-1];
        #         wz.move_to_path(ignored); wz.set_val(()); changed |= true;
        #     }
        # Pure EXISTENCE of a NewVar-source path. Branches 1 and 3 by contrast both
        # `u32::from_str_radix(..).unwrap()` (sinks.rs:880, :917) and PANIC on a non-numeric value.
        #
        # Pushing the key only after a SUCCESSFUL fold meant a context whose values are ALL
        # unparseable never existed, so branch 2 could not fire. Confirmed against the live binary:
        # `sinks/g2_sum_ignored_nonnum` emits `(seen)` upstream and emitted nothing here.
        if !(key in exists)
            push!(exists, key); push!(order, key)
        end
        folded = acc(haskey(groups, key) ? groups[key] : init, value)
        folded === nothing && continue
        groups[key] = folded
    end

    changed = false
    for key in order
        (rbytes, source) = key
        t = byte_item(source[1])
        # `enc` may decline (return nothing) when the reduction cannot be represented as a symbol —
        # see `_freduce_enc`, where a float can render wider than the Rule-of-64 payload limit.
        # A group with NO folded total reaches `enc` only via branches 1/3, which decline below.
        encoded = (t isa ExprNewVar || !haskey(groups, key)) ? nothing : enc(groups[key])
        out = if t isa ExprNewVar
            rbytes                                   # branch 2 — ignored guard, NO value read (sinks.rs:900)
        elseif !haskey(groups, key)
            # Branches 1 and 3 need a total and NOTHING folded. Upstream reaches
            # `from_str_radix(..).unwrap()` here (sinks.rs:880/:917) and PANICS; this file's standing
            # policy is to skip the group rather than abort the engine. Only branch 2 survives this.
            nothing
        elseif encoded === nothing
            nothing
        elseif t isa ExprVarRef
            k = Int(t.idx)                           # branch 3 — substitute at index k, re-basing
            # Upstream indexes `vars[k]` and panics if k is out of range; a malformed template must not
            # take the engine down, so we skip that group instead (a CHECK, not a silent mask — reaching
            # this means the `<source>` backref does not name a NewVar of `<result>`).
            k < _expr_newvars(rbytes, 1, length(rbytes)) ?
                _expr_substitute_one_de_bruijn(rbytes, 1, length(rbytes), k, encoded) : nothing
        else                                         # branch 1 — SIZES fixed literal
            encoded == source ? rbytes : nothing
        end
        out === nothing && continue
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

Ports `SumSink` in sinks.rs (851-940). Template form is `(sum <result-expr> <source> <x>)`: accumulate
the DECIMAL-STRING value `<x>` over every match, grouped by `(<result-expr> <source>)`, then dispatch on
`<source>` through all THREE upstream branches (see `_redsink_finalize!` above). With a LITERAL source,
emit `<result-expr>` **iff** the sum equals it — `(foo 1)(foo 2)(foo 3)` under `(sum (correct) 6 \$x)`
sums to 6 and emits `(correct)`, while `(sum (incorrect) 5 \$x)` emits nothing. With a VarRef source the
sum is spliced into `<result-expr>`, so `(sum (total \$n) \$n \$x)` emits `(total 6)` (this branch was
missing until 2026-07-26 and silently dropped every entry).

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

# Sum reduction: upstream accumulates a `u32` over `u32::from_str_radix(<value>, 10)` and renders it
# with `total.to_string()` (sinks.rs:873/880/882). We match the width (wrapping, as Rust release does);
# a value upstream would panic on (`from_str_radix` error — negative or overflowing) skips that entry
# rather than taking the engine down.
# Upstream is `u32::from_str_radix(str::from_utf8(&p[clen+1..]).unwrap(), 10)` (sinks.rs:880), and
# Rust's `from_str_radix` ACCEPTS AN OPTIONAL LEADING '+'. Julia's `tryparse(UInt32, "+7")` returns
# `nothing`, so the term was silently dropped from the sum rather than contributing 7.
#
# That is a WRONG ANSWER, not a skip, and it was confirmed against the live binary through the
# public API (no test harness involved): `(fact a +7) (fact b 1)` gives `(total 8)` upstream and
# gave `(total 1)` here.
#
# Strip one leading '+' and parse the remainder — exactly `from_str_radix`'s sign handling for an
# unsigned type. '-' stays rejected, as Rust rejects it for u32. "+" alone becomes "" and still
# declines, matching upstream's error path.
function _sum_acc(running::UInt32, value::Vector{UInt8})
    s = String(copy(value))
    startswith(s, '+') && (s = s[2:end])
    v = tryparse(UInt32, s)
    v === nothing ? nothing : running + v
end

function _sum_enc(total::UInt32)
    s = string(total)
    vcat(item_byte(ExprSymbol(UInt8(length(s)))), Vector{UInt8}(s))
end

sink_finalize!(s::SumSink, btm::SinkBtm)::Bool =
    _redsink_finalize!(s.unique, btm, UInt32(0), _sum_acc, _sum_enc)

# =====================================================================
# AndSink — [4] and <result_sym> <source_sym> <expr>: logical AND
# =====================================================================

"""
    AndSink — `(and <result> <source> <value>)`

BITWISE-AND aggregation over grouped values — ports `AndSink` in sinks.rs (723-830). Group the matched
entries by `(<result> <source>)`, fold the `<value>` masks with `&`, then dispatch on `<source>` through
all THREE upstream branches (see `_redsink_finalize!` above): a literal emits `<result>` only on an exact
match (:757), a bare NewVar emits it unconditionally (:791), and a VarRef(k) splices the AND result into
`<result>` at index k via `substitute_one_de_bruijn` (:818).

ip_sudoku's `(and \$c \$nv) \$nv \$i)` is the VarRef branch — it narrows each cell's option-bitmask by
AND-ing the incoming \$i masks into \$nv. This replaces two earlier wrong ports: a BOOLEAN true/false AND
emitting a literal `true`/`false` atom (2026-07-23), and a VarRef-only version that filled the FIRST
NewVar instead of index k and left trailing de-Bruijn refs un-rebased (2026-07-26).
"""
mutable struct AndSink <: AbstractSink
    expr::MORK.Expr
    unique::PathMap{UnitVal}
end

AndSink(e::MORK.Expr) = AndSink(e, PathMap{UnitVal}())

const _AND_KEYWORD_PREFIX_LEN = 5   # [4] + "and"(sym3) + size byte — mirrors upstream path[5+root..]

function sink_apply!(s::AndSink, bindings::Dict{ExprVar, ExprEnv},
    path::Vector{UInt8}, btm::SinkBtm)
    length(path) > _AND_KEYWORD_PREFIX_LEN || return nothing
    set_val_at!(s.unique, path[(_AND_KEYWORD_PREFIX_LEN + 1):end], UNIT_VAL)
end

# Bitwise-AND reduction: upstream seeds `total = !0u8` and folds `total &= p[clen+1]` — the FIRST
# PAYLOAD BYTE of each value symbol, not the whole payload (sinks.rs:764/771, :801/808) — then renders
# the result as the one-byte symbol `[total]` (:773, :810-813).
_and_acc(running::UInt8, value::Vector{UInt8}) = isempty(value) ? running : running & value[1]

_and_enc(total::UInt8) = UInt8[item_byte(ExprSymbol(0x01)), total]

sink_finalize!(s::AndSink, btm::SinkBtm)::Bool =
    _redsink_finalize!(s.unique, btm, 0xff, _and_acc, _and_enc)

# =====================================================================
# External-dep stubs — require wasmtime / Z3 (skip)
# =====================================================================

struct WASMSink <: AbstractSink
    ;
    expr::MORK.Expr;
end
@eval sink_apply!(::WASMSink, ::Dict, ::Vector{UInt8}, ::SinkBtm) = error("WASMSink requires the wasmtime runtime")
@eval sink_finalize!(::WASMSink, ::SinkBtm) = error("WASMSink requires the wasmtime runtime")

# ── Z3Sink — write SMT-LIB assertions to a named z3 instance (real port of Rust Z3Sink) ──────────────
# `(z3 <instance> <se>)` on the sink side streams the matched <se> (bindings-substituted) as text to the live
# z3 subprocess named <instance> — e.g. <se> = (assert (> a 5)) or (declare-const a Int). Paired with Z3Source
# (which reads that instance's model back into the join), this gives SMT-guarded rewriting. Instance = the
# session-global pool in Sources.jl (`z3_instance!`).
mutable struct Z3Sink <: AbstractSink
    expr::MORK.Expr
    ins::String
    skip::Int          # bytes of the `[3] z3 <instance>` header to strip off a matched path → the <se> bytes
end
function Z3Sink(e::MORK.Expr)
    buf = e.buf
    name_tag = length(buf) >= 5 ? byte_item(buf[5]) : nothing
    ins = name_tag isa ExprSymbol ? String(buf[6:(5 + Int(name_tag.size))]) : ""
    Z3Sink(e, ins, 5 + length(ins))
end
function sink_apply!(s::Z3Sink, ::Dict, path::Vector{UInt8}, ::SinkBtm)
    length(path) > s.skip || return nothing
    text = expr_serialize(path[(s.skip + 1):end])            # the <se> assertion, e.g. (assert (> a 5))
    proc = z3_instance!(s.ins)
    write(proc, text); write(proc, "\n"); flush(proc)
    nothing
end
sink_finalize!(::Z3Sink, ::SinkBtm)::Bool = false            # assertions are streamed in apply; nothing to finalize

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
# memo: (lhs-bytes, rhs-bytes) → variable_index. Keyed by the CONTENT of the disagreeing pair, as
# upstream does (`(RelExprEnv::from(lhs), RelExprEnv::from(rhs))`, lib.rs:2284) — NOT by byte offsets,
# which are unique per position and would make the memo unhittable. The memo is what makes the result
# a LEAST general generalisation rather than merely *a* generalisation.
mutable struct _AuState
    next_var::UInt8
    memo::Dict{Tuple{Vector{UInt8}, Vector{UInt8}}, UInt8}
end
_AuState() = _AuState(UInt8(0), Dict{Tuple{Vector{UInt8}, Vector{UInt8}}, UInt8}())

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

    # Disagreement (including variables treated as atoms per upstream): introduce or REUSE a
    # generalisation variable.
    #
    # The memo MUST be keyed by the CONTENT of the disagreeing pair — upstream uses
    # `(RelExprEnv::from(lhs), RelExprEnv::from(rhs))` (lib.rs:2284) — so that the SAME pair recurring
    # at a DIFFERENT position reuses the SAME variable. That is the defining property of a least
    # general generalisation. We keyed by the byte OFFSETS `(i1, i2)`, which are unique per position,
    # so the memo could NEVER hit and every disagreement got a fresh variable:
    #     (f a b a) ⊓ (f x y x)          gave (f $a $b $c)      upstream (f $a $b $a)
    #     (g (h a) (h a)) ⊓ (g (h b) (h b))  gave two distinct vars   upstream one shared var
    # i.e. we produced a strictly MORE GENERAL expression than the lgg. Fixed 2026-07-26.
    e1_end = _expr_end_offset(e1, i1)
    e2_end = _expr_end_offset(e2, i2)
    s1 = e1_end - i1
    s2 = e2_end - i2
    key = (Vector{UInt8}(view(e1, i1:(e1_end - 1))), Vector{UInt8}(view(e2, i2:(e2_end - 1))))
    if haskey(st.memo, key)
        push!(out, item_byte(ExprVarRef(st.memo[key])))
    elseif st.next_var < 0x40
        v = st.next_var
        st.memo[key] = v
        st.next_var = UInt8(v + 1)
        push!(out, item_byte(ExprNewVar()))
    else
        # Rule of 64: a VarRef index must fit in 6 bits, so we cannot memoise a 65th distinct
        # disagreement. Upstream fails the WHOLE anti-unification here
        # (`AntiUnificationFailure::TooManyVars`, lib.rs:2291-2292); `_au_merge!` has no error channel,
        # so we emit an un-memoised fresh NewVar instead — valid output, strictly more general than
        # the lgg, and it cannot crash. DOCUMENTED DIVERGENCE, only reachable with >64 distinct
        # disagreement pairs in one anti-unification.
        push!(out, item_byte(ExprNewVar()))
    end
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

# Hash reduction. Upstream hashes the SUBTRIE at each context (`prz.fork_read_zipper().hash()`,
# sinks.rs:668/698) and emits it as a 16-byte symbol (u128 big-endian). We keep OUR 8-byte hash.
#
# DOCUMENTED DEVIATION — hash WIDTH and VALUES differ from upstream, deliberately:
#   * Matching upstream's bytes means porting `gxhash` bit-exactly — it is built on AES-NI hardware
#     intrinsics — PLUS PathMap's merkleization traversal (seed, node order, feed order). Large and
#     fragile, and it buys only byte-equality on hash probes.
#   * Upstream itself does NOT keep those bytes stable: PathMap/src/lib.rs:14-18 substitutes an
#     entirely different hand-rolled XOR/rotate hasher under `miri` / `riscv64`. Its hash values are a
#     per-TARGET artifact, not a portable contract.
#   * What the hash must actually be is CONSISTENT, which is all its real consumer needs —
#     ctl_model_checking.mm2:375-376 uses `(hash (h … $h) $h $s)` as the EG least-fixpoint TERMINATION
#     test, comparing hash(level l+1) against hash(level l) computed by the SAME engine.
#
# What WAS missing and is fixed here (2026-07-26): only the fixed-literal (Symbol) branch was
# implemented — the old finalize scanned right-to-left for a SymbolSize header and skipped everything
# else — so the NewVar and VarRef branches were silently dead, and with them CTL's EG operator. Now
# routed through the shared three-branch dispatch (`_redsink_finalize!`), the same one And/Sum/Float
# use, so all three upstream branches (sinks.rs:659 SIZES / :688 NewVar / :696 VarRef) are covered.
_hash_one(v::Vector{UInt8}) = begin
    h = UInt64(0xa9e17c4d3f8b21c5)
    for b in v; h = hash(b, h); end
    h
end

# XOR-combined so the group hash is ORDER-INDEPENDENT: our groups come out of a Dict, whose iteration
# order is arbitrary, whereas upstream hashes a trie in sorted order. Members are unique (they come
# from a PathMap), so XOR's cancel-on-duplicate weakness cannot bite.
_hash_acc(running::UInt64, value::Vector{UInt8}) = running ⊻ _hash_one(value)

_hash_enc(total::UInt64) =
    vcat(item_byte(ExprSymbol(UInt8(8))), collect(reinterpret(UInt8, [hton(total)])))

sink_finalize!(s::HashSink, btm::SinkBtm)::Bool =
    _redsink_finalize!(s.unique, btm, UInt64(0xa9e17c4d3f8b21c5), _hash_acc, _hash_enc)

# =====================================================================
# PureSink — port of PureSink in sinks.rs
# (pure <template> <var> <formula>)
# Evaluates <formula> using PURE_OPS, substitutes result into <template>,
# and stores the result in the space.
# =====================================================================

mutable struct PureSink <: AbstractSink
    expr::MORK.Expr
    changed::Bool
    # upstream `PureSink { e, unique, scope: EvalScope }` (sinks.rs:1087). The scope is PER-SINK
    # there — `PureSink::new` builds its own — and `scope_eval!` mutates its cursor/stack/alloc pool,
    # so a shared global one would race under `--threads`. `eval_scope_sharing` gives each sink its
    # own machine state over the one read-only op registry.
    scope::EvalScope
end
PureSink(e::MORK.Expr) = PureSink(e, false, eval_scope_sharing(PURE_SCOPE))

# ── `_pure_eval_formula` WAS HERE, and is now upstream's stack machine ──────────────────────
#
# 159 lines of hand-written recursive evaluator: our substitute for `scope.eval`, and the last
# real gap in the pure lane. `PureSink` now calls `scope_eval!` (Eval.jl), which is a 1:1 port of
# upstream `EvalScope::eval`/`push_eval`/`eval_impl` — see the call site below.
#
# THE MIGRATION WAS MEASURABLY MORE FAITHFUL, not merely equivalent: conformance went 248 -> 249
# passing, and the probe that flipped is `sinks/g4_arity_edge`, whose own header reads
# "upstream consume_head_check enforces exact arity, ours ignores extras". The old evaluator
# called `pure_apply(name, args)` with NO arity check, so `(i64_to_string 3 4)` and
# `(sub_i64 9 4 2)` produced values where upstream errors. `op_skeleton` supplies exactly that
# check — which is what it was written for, and it had never been reachable until now.



"""
    _expr_rebase_varrefs(buf, from, base) -> Vector{UInt8}

Copy the expression at `buf[from]`, reducing every `VarRef` index by `base`, so the result is
self-contained: its references count against its OWN binders rather than an enclosing expression's.

# Why this exists — upstream #135

A quoted `(x x)` inside a `pure` formula came out as two UNRELATED variables where one was written.

It is a SCOPE MISMATCH, not a corruption: nothing rewrites the bytes, they are read in the wrong
frame. `ee_args!` threads the de Bruijn base across the `(pure <tpl> <pat> <call>)` operands
(`env.v + new_var_count`, ExprAlg.jl:368), so the CALL's `VarRef`s are relative to however many
binders precede it. Measured on the issue's own program the operands carry `v = 0, 0, 1, 1` — base 1
for the call. `PureSink` then evaluated that call as a BARE SLICE, where the same bytes mean
something else: the first `NewVar` is now binder 0, so a `VarRef(1)` written against base 1 points
one PAST it and materialises a variable appearing nowhere in the input.

The base was therefore never missing — `ee_args!` had already computed it and the sink discarded it.
That is why this is a re-base and not a rewrite, and why the fix is expected to CONVERGE with
upstream's: any correct fix must honour the same value. (PR #137 extracts exactly this threading as
`ExprEnv::subterms`.)

# The consequence that made it worth deviating: `hash_expr` was not content-addressed

Reachable without mentioning quoting at all. Hash ONE expression from two templates differing only in
how many binders precede the call:

    1 binder before the call   ->  bssGabbteWo      upstream
    2 binders before the call  ->  0Z2xrn_VwuU      upstream, SAME expression
    either                     ->  lzt106T12AQ      ours, after this fix

A digest that changes with syntactic position cannot content-address anything, which is the op's
whole purpose. It hides well: a variable-free expression has no `VarRef` to mis-read, so it hashes
identically on both sides and the defect only appears once an expression contains a back-reference.

# Status: DELIBERATE DEVIATION

Upstream #135 is OPEN and its binary still exhibits this. Deviating is the narrow exception
`test/conformance/UPSTREAM_BUGS.md` reserves for silent corruption.

⚠️ The deviation is WIDER than #135's own symptom, and that is recorded where it bites:
`test/integration/sink_pure_advanced.jl`'s byte-parity assertion now differs from upstream's
`main.rs:1201-1225` for the expression containing a back-reference — the variable-free one still
matches exactly. Reconcile when #135 or PR #137 lands.

See `test/integration/upstream_issues.jl` for the three shapes this fixes, two of which were
PREDICTED from the diagnosis and confirmed against the release binary before the fix was written.
"""
function _expr_rebase_varrefs(buf::AbstractVector{UInt8}, from::Int, base::Int)::Vector{UInt8}
    # Only the call's OWN span is copied — `_expr_end_offset` gives its exclusive end, so a formula
    # sitting mid-buffer does not drag its trailing siblings along. (It takes an AbstractVector
    # precisely so this needs no `collect`: the sink hands us `formula_ee.base.buf`, and copying the
    # whole buffer per evaluation on this path would cost more than the re-base itself.)
    stop = _expr_end_offset(buf, from) - 1
    out = UInt8[]
    sizehint!(out, stop - from + 1)
    i = from
    @inbounds while i <= stop
        t = byte_item(buf[i])
        if t isa ExprVarRef
            # THE ONLY ITEM THAT MOVES. A back-reference is an index into the binder sequence, so
            # dropping `base` enclosing binders means every reference shifts down by `base`.
            idx = Int(t.idx)
            # Below `base` the reference names a binder OUTSIDE this call — the pattern's or the
            # template's. Standalone evaluation cannot resolve that, and silently clamping would
            # alias it onto an unrelated variable, which is the very failure this function exists to
            # remove. Raise instead; the sink treats EvalError as "skip this atom".
            idx >= base || throw(EvalError(
                "pure: variable reference _$(idx + 1) names a binder outside the call expression \
(de Bruijn base $base); it cannot be resolved when the call is evaluated on its own"))
            push!(out, item_byte(ExprVarRef(UInt8(idx - base))))
            i += 1
        elseif t isa ExprSymbol
            # Payload bytes are DATA, not tags. They must be copied wholesale and skipped over —
            # scanning them would decode arbitrary bytes as VarRefs and corrupt the symbol.
            n = Int(t.size)
            append!(out, @view buf[i:min(i + n, stop)])
            i += n + 1
        else
            # NewVar and Arity are copied VERBATIM, and NewVar is the interesting one: a binder is a
            # binder in any scope. Re-basing it too would renumber the very introductions the
            # references are counted against, reintroducing the bug in mirror image.
            push!(out, buf[i])
            i += 1
        end
    end
    out
end

"""
    _expr_end_offset(buf, off) → Int

Return the offset just past the expression starting at `off` (exclusive end).
"""

function _expr_end_offset(buf::AbstractVector{UInt8}, off::Int)::Int
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

    # Dispatch on the `<source>` slot, as every other sink does. Previously this slot was never
    # inspected at all: the formula was always evaluated and substituted at the template's FIRST
    # variable, which is only correct when that happens to be the slot k names (fixed 2026-07-26).
    tpl_end = _expr_end_offset(tpl_buf, tpl_start)
    tpl_bytes = Vector{UInt8}(tpl_buf[tpl_start:(tpl_end - 1)])
    src_start = Int(args[3].offset) + 1
    src_start > length(tpl_buf) && return nothing
    src_tag = byte_item(tpl_buf[src_start])

    out = if src_tag isa ExprNewVar
        # NewVar "ignored guard" (sinks.rs:1148-1155): emit the template with its variable INTACT.
        # The formula is not evaluated at all — upstream discards the value here.
        tpl_bytes
    elseif src_tag isa ExprVarRef
        # VarRef(k) (sinks.rs:1156-1186): evaluate, then splice in AT INDEX k, re-basing trailing vars.
        # ── THE LIVE PURE EVALUATOR IS NOW upstream's STACK MACHINE ──────────────────────
        # upstream: `match self.scope.eval(ExprSource::new(&p[clen])) { Ok(res) => res,
        #            Err(er) => { trace!(target: "pure", "err {}", er); continue 'vals } }`
        # (sinks.rs:1165-1168) — an EvalError means SKIP THIS ATOM, not abort the run.
        # This replaced `_pure_eval_formula`, a hand-written recursive evaluator that was our
        # substitute for `scope.eval` and the last real gap in the pure lane.
        #
        # Only EvalError is caught. Anything else is the analogue of an upstream PANIC and is left to
        # propagate rather than silently dropping an atom — silent skips are how a defect population
        # stays invisible.
        # ── upstream #135: give the call its OWN variable scope before evaluating it ──
        # `scope_eval!` reads the call as a standalone expression, so its `VarRef`s must be counted
        # against the binders INSIDE it. `formula_ee.v` is that base and `ee_args!` already computed
        # it (ExprAlg.jl:368) — this restores what the sink used to throw away. Full reasoning, and
        # the `hash_expr` content-addressing consequence, on `_expr_rebase_varrefs`.
        #
        # base 0 is the overwhelmingly common case (no binder precedes the call), and the re-base
        # would be an identity copy — so take the original buffer and skip the allocation entirely.
        fbase = Int(formula_ee.v)
        formula_src = fbase == 0 ? ExprSource(formula_buf, formula_start) :
                      ExprSource(_expr_rebase_varrefs(formula_buf, formula_start, fbase), 1)
        result_mork = try
            scope_eval!(s.scope, formula_src)
        catch err
            err isa EvalError || rethrow()
            return nothing
        end
        k = Int(src_tag.idx)
        k < _expr_newvars(tpl_bytes, 1, length(tpl_bytes)) ?
            _expr_substitute_one_de_bruijn(tpl_bytes, 1, length(tpl_bytes), k, result_mork) : nothing
    else
        # A fixed-literal or compound `<source>` slot is `todo!()` upstream (sinks.rs:1136/:1145),
        # i.e. a process abort. We decline the write rather than reproduce a crash.
        nothing
    end
    out === nothing && return nothing

    old = get_val_at(btm, out)
    set_val_at!(btm, out, UNIT_VAL)
    old === nothing && (s.changed = true)
end

"""
    _pure_substitute_first_var(buf, from, to, replacement) → Vector{UInt8}

Substitute the sink's computed value (`replacement`) for the template's sink
variable slot. When the template is a self-contained de-Bruijn expression the
substitution RE-BASES every other variable via the faithful port of upstream
`Expr::substitute_one_de_bruijn` (expr/src/lib.rs:539, used by every kernel sink
at sinks.rs:611/707/818/927/1069/1176): removing one NewVar binding shifts all
trailing VarRefs down, so a naive byte-copy leaves them dangling (the ip_sudoku
meta-rule respawn +1-shift bug, 2026-07-25).

Upstream derives the substituted index `k` from the explicit `VarRef(k)` at the
slot; we derive it from the template's first variable slot, which is provably the
same for every corpus program (a naive replace of the wrong slot would already
have diverged from the upstream binary, yet the full differential corpus is
byte-exact).

If the template holds a VarRef pointing outside its own NewVar count (not a
self-contained de-Bruijn term — `substitute_de_bruijn` would index its
`substitutions` array out of range), we fall back to the original naive
byte-copy so behaviour is unchanged for those cases.

Returns `nothing` if the template has no variable slot.
"""
function _pure_substitute_first_var(buf::Vector{UInt8}, from::Int, to::Int,
    replacement::Vector{UInt8})::Union{Vector{UInt8}, Nothing}
    idx, nvs, maxref = _first_var_index_and_bounds(buf, from, to)
    idx === nothing && return nothing
    # Self-contained ⇒ every VarRef targets a NewVar in-span AND the substituted
    # slot is a real NewVar binding (idx < nvs). Otherwise keep the old behaviour.
    if maxref < nvs && idx < nvs
        return _expr_substitute_one_de_bruijn(buf, from, to, idx, replacement)
    end
    return _pure_substitute_first_var_naive(buf, from, to, replacement)
end

# Single walk of buf[from:to] returning (first-var de-Bruijn index | nothing,
# NewVar count, max VarRef index or -1). The first-var index is the count of
# NewVars preceding the first variable slot (0 if it is itself the first NewVar)
# for a NewVar, or the referenced index for a leading VarRef.
function _first_var_index_and_bounds(buf::Vector{UInt8}, from::Int, to::Int)
    firstidx = nothing; nvs = 0; maxref = -1; i = from
    @inbounds while i <= to
        t = byte_item(buf[i])
        if t isa ExprNewVar
            firstidx === nothing && (firstidx = nvs)
            nvs += 1; i += 1
        elseif t isa ExprVarRef
            r = Int(t.idx)
            firstidx === nothing && (firstidx = r)
            r > maxref && (maxref = r)
            i += 1
        elseif t isa ExprSymbol
            i += 1 + Int(t.size)
        else  # Arity
            i += 1
        end
    end
    (firstidx, nvs, maxref)
end

function _pure_substitute_first_var_naive(buf::Vector{UInt8}, from::Int, to::Int,
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

# Float reduction sinks — ports FloatReductionSink<Sum/Min/Max/Prod> (sinks.rs:975-1081).
# Template: `(fsum <result> <source> <value>)`. Structurally IDENTICAL to And/Sum — same three-branch
# finalize (see `_redsink_finalize!`) over the same accumulate-then-group shape — differing only in
# (init, accumulate, encode). So it routes through the shared implementation.
#
# FIXED 2026-07-26 (three defects, all silent):
#   * It stored only the UNinstantiated template from `s.expr` and grouped by the source slot alone,
#     so matches that bind different values into `<result>` collapsed into ONE group — upstream groups
#     by the INSTANTIATED path and emits `(tot a 3)`/`(tot b 10)` where we emitted `(tot 13.0 13.0)`.
#     Storing the instantiated path (as upstream's `unique.insert(mpath, ())` does) fixes the grouping.
#   * It collapsed upstream's NewVar and VarRef branches into one and substituted at the template's
#     FIRST variable rather than at the de-Bruijn index k named by `<source>`.
#   * It rendered the reduction with Julia's `string(::Float64)`, so `61.0` serialised as "61.0" where
#     Rust's `f64::to_string()` gives "61" (and `1e20` as "1.0e20" vs 21 literal digits) —
#     see `_f64_rust_string`.
mutable struct FloatReductionSink{R} <: AbstractSink
    expr::MORK.Expr
    op::Symbol   # :sum, :min, :max, :prod
    unique::PathMap{UnitVal}
end

FloatReductionSink(e::MORK.Expr, op::Symbol) =
    FloatReductionSink{op}(e, op, PathMap{UnitVal}())

# Bytes of the `(<keyword>` prefix to strip from an instantiated template: the arity byte + the
# keyword's SymbolSize tag + its payload. Upstream spells this `2 + NAME.len()` per sink
# (sinks.rs:987 for the float family, :552 CountSink, :845 SumSink); reading the size off the
# expression itself keeps it correct for every keyword length.
_sink_keyword_prefix_len(e::MORK.Expr) =
    (length(e.buf) >= 2 && byte_item(e.buf[2]) isa ExprSymbol) ?
        2 + Int(byte_item(e.buf[2]).size) : 5

function sink_apply!(s::FloatReductionSink, bindings, path::Vector{UInt8}, btm)
    # Store the INSTANTIATED `<result> <source> <value>` (upstream: unique.insert(mpath, ())).
    plen = _sink_keyword_prefix_len(s.expr)
    length(path) > plen || return nothing
    set_val_at!(s.unique, path[(plen + 1):end], UNIT_VAL)
end

# Rust `f64::min`/`max` IGNORE NaN (returning the non-NaN operand); Julia's propagate it. Seeds are
# upstream's exactly: Sum 0.0, Prod 1.0, Min f64::MAX, Max f64::MIN — note Min/Max seed at the finite
# extrema, NOT ±Inf (sinks.rs:955/960/965/970).
_freduce_init(op::Symbol) =
    op === :sum ? 0.0 : op === :prod ? 1.0 :
    op === :min ? floatmax(Float64) : -floatmax(Float64)

function _freduce_acc(op::Symbol)
    (running::Float64, value::Vector{UInt8}) -> begin
        v = tryparse(Float64, String(copy(value)))   # upstream .unwrap()s; we skip unparseable
        v === nothing && return nothing
        op === :sum  ? running + v :
        op === :prod ? running * v :
        # Rust float min/max IGNORE NaN. This was open-coded here on 2026-07-26 and the rule was not
        # swept to the PURE ops, which propagated NaN until 2026-07-30. Now both call one helper
        # (Pure.jl `_rust_fmin`/`_rust_fmax`), so the next float reduction inherits it.
        # ⚠️ The SEEDS still differ deliberately and must not be unified: this sink seeds at the finite
        # extrema (f64::MAX/MIN, sinks.rs:955-970) while the pure `min_/max_f64` seed at ±Inf
        # (pure.rs:674-675). Same NaN rule, different identity element.
        op === :min  ? _rust_fmin(running, v) : _rust_fmax(running, v)
    end
end

function _freduce_enc(total::Float64)
    str = _f64_rust_string(total)
    n = ncodeunits(str)
    # A reduction can render wider than a symbol can hold: `1e300` expands to 302 decimal digits
    # (Rust Display never uses exponent form). Upstream writes `SymbolSize(len as _)`, and that
    # `as _` TRUNCATES the length byte — 302 & 0xff = 46 — so it emits a silently CORRUPTED 46-char
    # symbol (verified against the release binary on g3_bigsymbol). We refuse the write instead:
    # reproducing deliberate corruption is worse than dropping an unrepresentable value, and
    # crashing the engine on a large float is worse still. Related to the standing Rule-of-64 gap
    # (no general symbol-overflow guard on the write path).
    (n < 1 || n > 63) && return nothing        # Rule of 64: a symbol payload is 1..63 bytes
    vcat(item_byte(ExprSymbol(UInt8(n))), Vector{UInt8}(str))
end

sink_finalize!(s::FloatReductionSink, btm::SinkBtm)::Bool =
    _redsink_finalize!(s.unique, btm, _freduce_init(s.op), _freduce_acc(s.op), _freduce_enc)

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

    # [3] z3 <instance> <se> → Z3Sink
    if a1 == item_byte(ExprArity(UInt8(3))) && a2 == item_byte(ExprSymbol(UInt8(2))) &&
        length(buf) >= 4 && buf[3] == UInt8('z') && buf[4] == UInt8('3')
        return Z3Sink(e)
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
export _expr_end_offset
export FloatReductionSink
export asink_new, asink_compat
export _au_merge!, _zipper_subtrie_hash

# ── sink_request methods (see the block comment near the top of this file) ───────────────────
# Defined here because they dispatch on sink types declared throughout the file.
# `skip` = 2 + length(keyword); the Bool is the GROUND fallback (true = span minus one byte).
sink_request(s::CompatSink)  = _sink_root(s.expr, 0, false)
sink_request(s::AddSink)     = _sink_root(s.expr, 3, false)
sink_request(s::USink)       = _sink_root(s.expr, 3, false)
sink_request(s::AUSink)      = _sink_root(s.expr, 4, false)
sink_request(s::RemoveSink)  = _sink_root(s.expr, 3, true)
sink_request(s::AndSink)     = _sink_root(s.expr, 5, true)
sink_request(s::SumSink)     = _sink_root(s.expr, 5, true)
sink_request(s::HashSink)    = _sink_root(s.expr, 6, true)
sink_request(s::PureSink)    = _sink_root(s.expr, 6, true)
sink_request(s::CountSink)   = _sink_root(s.expr, 7, true)
# FloatReduction's header is `2 + Reduction::NAME.len()` upstream (sinks.rs:980). fsum/fmin/fmax
# are 4 and fprod is 5, so READ the length off the expression rather than hardcoding one — a
# future reduction name must not silently mis-skip.
function sink_request(s::FloatReductionSink)
    buf = s.expr.buf
    t = length(buf) >= 2 ? byte_item(buf[2]) : nothing
    _sink_root(s.expr, 2 + (t isa ExprSymbol ? Int(t.size) : 4), true)
end
# HeadSink/TailSink embed the N literal in their header, so reuse the width the constructor
# already computed (upstream: `[self.skip..]`, sinks.rs:383-389).
sink_request(s::HeadSink)    = _sink_root(s.expr, s.skip, true)
# Non-BTM resources have NO write root: ACTSink requests an ACT file (sinks.rs:320) and Z3Sink a
# Z3 instance (:1204).
sink_request(::ACTSink)      = nothing
sink_request(::Z3Sink)       = nothing

export sink_request
