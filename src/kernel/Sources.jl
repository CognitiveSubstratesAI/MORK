"""
Sources — port of `mork/kernel/src/sources.rs`.

Provides the `ASource` / `AFactor` abstraction for creating factor zippers
in the multi-source query engine.  Mirrors the `Source` trait + implementors.

Julia translation notes
========================
  - Rust `Source` trait → Julia abstract type `AbstractSource`
  - Rust `AFactor<'trie>` enum (PolyZipper derive) → Union type `AFactorZipper`
  - Rust `gen move` coroutine → regular iterator / Array
  - Rust `ACTMmapZipper` → ported as ACTSource + ACTZipper (act_open_mmap)
  - Rust `CmpSource` → ported with DependentZipper equality/inequality policy
  - Rust `Z3Source` → skipped (external Z3 dep, Linux-only in upstream)
  - Rust `destruct!` proc-macro → direct byte inspection
  - ResourceRequest/Resource enums → Julia enums/structs
"""

# =====================================================================
# ResourceRequest / Resource
# =====================================================================

"""
    ResourceRequest

Which backing store a source needs access to.
Mirrors `ResourceRequest` in sources.rs.
"""
@enum ResourceRequestKind begin
    RREQ_BTM
    RREQ_ACT
    RREQ_Z3
end

struct ResourceRequest
    kind::ResourceRequestKind
    name::String   # ACT filename or Z3 instance name; empty for BTM
end

ResourceRequest(k::ResourceRequestKind) = ResourceRequest(k, "")

# =====================================================================
# AbstractSource / ASource dispatch
# =====================================================================

"""
    AbstractSource

Abstract type for query factor sources.
Mirrors the `Source` trait in sources.rs.
"""
abstract type AbstractSource end

"""
    source_requests(s) → Vector{ResourceRequest}

List of resources this source requires.
"""
function source_requests end

"""
    source_factor(s, btm) → ReadZipperCore

Create the read zipper (factor) for this source.
"""
function source_factor end

# ── CompatSource (BTM, no prefix) ────────────────────────────────────

"""
    CompatSource

Plain BTM read zipper with no prefix constraint.
Mirrors `CompatSource` in sources.rs.
"""
struct CompatSource
    expr::MORK.Expr
end

source_requests(s::CompatSource) = [ResourceRequest(RREQ_BTM)]

function source_factor(s::CompatSource, btm::PathMap{UnitVal})
    read_zipper_at_path(btm, UInt8[])
end

# ── BTMSource (BTM, with [2] BTM prefix) ─────────────────────────────

"""
    BTMSource

BTM read zipper scoped to the `[2] BTM` prefix subtrie.
Mirrors `BTMSource` in sources.rs.
"""
struct BTMSource
    expr::MORK.Expr
end

const _BTM_SOURCE_PREFIX = UInt8[
    item_byte(ExprArity(UInt8(2))),
    item_byte(ExprSymbol(UInt8(3))),
    UInt8('B'), UInt8('T'), UInt8('M')
]

source_requests(s::BTMSource) = [ResourceRequest(RREQ_BTM)]

function source_factor(s::BTMSource, btm::PathMap{UnitVal})
    inner = read_zipper_at_path(btm, UInt8[])
    PrefixZipper(_BTM_SOURCE_PREFIX, inner)
end

# ── ACTSource (memory-mapped ACT file) ───────────────────────────────

"""
    ACTSource

Reads from an ArenaCompactTree memory-mapped file.
Mirrors `ACTSource` in sources.rs.
"""
struct ACTSource
    expr::MORK.Expr
    act::String
end

source_requests(s::ACTSource) = [ResourceRequest(RREQ_ACT, s.act)]

# 2-arg fallback (no mmaps cache) — opens the file fresh every call
source_factor(s::ACTSource, btm::PathMap{UnitVal}) =
    source_factor(s, btm, Dict{String, ArenaCompactTree}())

"""
    source_factor(s::ACTSource, btm, mmaps) → PrefixZipper{ACTZipper}

Open (or reuse from cache) the `.act` file named `s.act` and return a
PrefixZipper wrapping its read zipper.  Mirrors `ACTSource::source` in sources.rs.

`ACT_PATH` mirrors upstream's `pub static ACT_PATH` (kernel/src/space.rs:35), whose value is
**`"/dev/shm/"`** — NOT `"."`. This docstring previously claimed upstream defaulted to `"."`, which
was false, and the mismatched default silently broke cross-engine `.act` interop: the upstream
binary writes `/dev/shm/<name>.act` while we looked in the CWD, so importing an upstream-produced
ACT via `(I (ACT <name> …))` found nothing (upstream itself panics `NotFound` at space.rs:1045 in
the mirror-image case). Surfaced by the chaining repo's `gen-fromNumber.mm2 → gen-lte.mm2 →
bfc-xp.mm2` pipeline, which passes state between programs exclusively through `.act` files.

Kept as a `Ref` (upstream's is a compile-time constant) so tests and embedders can redirect it;
only the DEFAULT is aligned. Tests that need isolation set `ACT_PATH[] = mktempdir()` and restore.
"""
const ACT_PATH = Ref{String}("/dev/shm/")

function source_factor(
    s::ACTSource, btm::PathMap{UnitVal}, mmaps::Dict{String, ArenaCompactTree}
)
    # Build prefix: [3] ACT <symbol_size_byte> <name_bytes>
    # Mirrors CONSTANT_PREFIX + name encoding in ACTSource::source.
    name = s.act
    prefix = UInt8[
        item_byte(ExprArity(UInt8(3))),
        item_byte(ExprSymbol(UInt8(3))),
        UInt8('A'), UInt8('C'), UInt8('T'),
        item_byte(ExprSymbol(UInt8(length(name))))
    ]
    append!(prefix, codeunits(name))

    # Open or reuse ACT file
    tree = get!(mmaps, name) do
        path = joinpath(ACT_PATH[], name * ".act")
        act_open_mmap(path)
    end
    rz = ACTZipper(tree)
    PrefixZipper(prefix, rz)
end

# ── CmpSource (equality / inequality comparison) ──────────────────────

"""
    CmpSource

DependentZipper-based equality/inequality comparison source.
Mirrors `CmpSource` in sources.rs.
`==` matches paths equal to the primary; `!=` matches all paths except the primary.
"""
struct CmpSource
    expr::MORK.Expr
    cmp::Int   # 0 = ==, 1 = !=
end

source_requests(s::CmpSource) = [ResourceRequest(RREQ_BTM)]

# Mirrors CmpSource::source in sources.rs.
# Returns PrefixZipper(EQ/NE_PREFIX, DependentZipper(btm_rz, policy))
# The DependentZipper extends the BTM read zipper's path with the secondary,
# so origin_path = [3]== + (primary_path)(secondary_path).
function source_factor(s::CmpSource, btm::PathMap{UnitVal})
    cmp = s.cmp
    # SRC-1 fix (audit 2026-06-04): removed the setup `deepcopy(btm)` AND the per-path
    # `deepcopy(map_clone)` inside the policy closure — a full O(space) copy for EVERY
    # enrolled path, the opposite of the COW discipline the stack is built on. `psubtract`
    # is non-mutating and COW-shares structure, so `btm \ {path}` costs the touched spine
    # only, not a whole-space copy.

    # Policy: (payload, path, c) → (payload, Union{nothing, ReadZipperCore})
    # Mirrors CmpSource::policy in sources.rs
    function cmp_policy(payload, path::Vector{UInt8}, c::Int)
        if c == 0
            if cmp == 0  # ==: secondary = single-entry PathMap at the SHIFTED path
                # Upstream enrolls a SHIFTED copy (sources.rs:142-146):
                #     e.shift(e.newvars() as _, &mut ExprZipper::new(Expr{ ptr: qv.as_mut_ptr() }))
                # `Expr::shift` (expr/src/lib.rs:620) leaves NewVar alone and rewrites
                # VarRef(i) → VarRef(i+n), re-basing this RHS copy so its back-references point at
                # the RHS's OWN introduced variable inside the combined `(== lhs rhs)` expression,
                # not at the LHS's. Upstream's comment at :142 calls the unshifted form a bug and
                # the very next line fixes it — we ported the code WITHOUT the fix.
                #
                # Effect (space.rs sweep, s2_isrc_eq_debruijn): `(== (p $x $y) (p $z $w))` over the
                # var-bearing atom `(p $u $u)` gave `(eqr $a $a $b $a)` — the FOURTH variable
                # corefered with the FIRST pair — where upstream gives `(eqr $a $a $b $b)`.
                # Same de-Bruijn re-basing family as the PureSink bug; `_expr_shift!` is the port of
                # `Expr::shift` added for that fix.
                shifted = UInt8[]
                _expr_shift!(path, _expr_newvars(path, 1, length(path)), shifted)
                single = PathMap{UnitVal}()
                set_val_at!(single, shifted, UNIT_VAL)
                return (payload, read_zipper(single))
            else          # !=: secondary = btm minus this path (COW-shared, no deepcopy)
                # NB no shift here: upstream's `!=` branch removes the RAW path (sources.rs:148-151).
                single = PathMap{UnitVal}()
                set_val_at!(single, path, UNIT_VAL)
                # psubtract returns an AlgebraicResult, not a bare PathMap: Element holds
                # the subtracted map; Identity (SELF_IDENT) means btm was unchanged (path
                # ∉ btm); None means the result is empty (btm ⊆ {path}). Mirror the
                # three-way unwrap PathMap's own prestrict uses. (Was: `read_zipper` on the
                # raw AlgResElement → MethodError; source_cmp_ne / source_cmp_rel crashed.)
                res = psubtract(btm, single)
                complement = res isa AlgResElement ? res.value :
                             res isa AlgResIdentity ? btm :
                             PathMap{UnitVal}()
                return (payload, read_zipper(complement))
            end
        else
            return (payload, nothing)
        end
    end

    primary_rz = read_zipper_at_path(btm, UInt8[])
    dpz = DependentZipper(primary_rz, nothing, cmp_policy)
    prefix = cmp == 0 ? _EQ_PREFIX : _NE_PREFIX
    PrefixZipper(prefix, dpz)
end

const _EQ_PREFIX = UInt8[
    item_byte(ExprArity(UInt8(3))), item_byte(ExprSymbol(UInt8(2))), UInt8('='), UInt8('=')
]
const _NE_PREFIX = UInt8[
    item_byte(ExprArity(UInt8(3))), item_byte(ExprSymbol(UInt8(2))), UInt8('!'), UInt8('=')
]

# =====================================================================
# GroundedSource — Phase 2: Julia function registry
# =====================================================================
# When an I-pattern sub-expression has the form `(fn-name arg1 arg2 ...)`
# and `fn-name` is registered in GROUNDED_REGISTRY, the function is called
# directly with decoded string arguments. Its return value(s) are encoded
# back as byte paths and yielded as the source factor.
#
# This is the Julia equivalent of:
#   - hyperon-experimental: `Grounded { fn as_execute() → Option<&dyn CustomExecute> }`
#   - CeTTa: `grounded_dispatch(head, args, nargs)` + `is_grounded_op`
#   - PeTTa: `mork_ffi` foreign predicate
#
# MORK kernel itself has no grounding — this is the layer above (per upstream
# design). We add it here as a GroundedSource in the I-pattern path so that
# grounded calls integrate with the existing multi-source query engine.

"""
    GROUNDED_REGISTRY

Global registry mapping MeTTa symbol names to Julia functions.

Registered functions are called when that symbol appears as the head of
a sub-expression in an `I`-functor pattern position:

    (exec (t 0) (I (my-fn \$x)) (, (result \$y)))

When `my-fn` is registered, `my-fn(decoded_x)` is called; its results
are encoded as MORK byte-paths and yielded into the query engine.

Function signature: `(args::Vector{String}) → Union{String, Vector{String}, Nothing}`
  - Return a single S-expression string, a list of them, or `nothing` (no result).
"""
const GROUNDED_REGISTRY = Dict{String, Function}()

"""
    register_grounded!(name, f)

Register Julia function `f` as a grounded atom callable under `name`.
`f` receives a `Vector{String}` of decoded argument S-expressions and
must return a `String`, `Vector{String}`, or `nothing`.
"""
function register_grounded!(name::String, f::Function)
    GROUNDED_REGISTRY[name] = f
end

"""
    is_grounded(name) → Bool

True iff `name` has a registered grounded function.
"""
is_grounded(name::String) = haskey(GROUNDED_REGISTRY, name)

"""
    GroundedSource

I-pattern source that calls a registered Julia function.
`expr` is the full sub-pattern (including the functor symbol and args).
`name` is the registered function name (extracted from `expr`).
"""
struct GroundedSource
    expr::MORK.Expr
    name::String
end

source_requests(s::GroundedSource) = ResourceRequest[]   # no trie resource needed

"""
    source_factor(s::GroundedSource, btm) → StaticZipper

Call the registered Julia function with decoded arguments, encode results
as byte paths, return a StaticZipper over those paths.
"""
function source_factor(s::GroundedSource, btm::PathMap{UnitVal})
    f = get(GROUNDED_REGISTRY, s.name, nothing)
    f === nothing && return StaticZipper(Vector{UInt8}[])

    # Decode argument expressions to strings
    args = _grounded_decode_args(s.expr)

    # Call the function; accept String, Vector, or nothing
    raw = try
        f(args)
    catch e
        @warn "GroundedSource: $(s.name) threw: $e"
        nothing
    end

    # Encode results back to byte paths
    paths = _grounded_encode_results(raw)
    StaticZipper(paths)
end

# ── StaticZipper — iterate a fixed list of pre-encoded paths ──────────

"""
    StaticZipper

An iterator over pre-encoded byte paths, used by `source_factor(::GroundedSource)`.
NOT a full zipper — never passed to `ProductZipperG`.
`GroundedSource` factors are consumed separately in `space_query_multi_i`
before the `ProductZipperG` is constructed for trie sources.
"""
mutable struct StaticZipper
    paths::Vector{Vector{UInt8}}
    idx::Int
end
StaticZipper(paths::Vector{Vector{UInt8}}) = StaticZipper(paths, 0)

# Simple iteration — not part of the PathMap zipper protocol
function static_next!(z::StaticZipper)::Bool
    z.idx += 1
    z.idx <= length(z.paths)
end

static_current(z::StaticZipper)::Vector{UInt8} =
    (z.idx > 0 && z.idx <= length(z.paths)) ? z.paths[z.idx] : UInt8[]

static_reset!(z::StaticZipper) = (z.idx=0; nothing)

# ── Internal helpers ──────────────────────────────────────────────────

"""Decode argument S-expressions from a GroundedSource expr to strings."""
function _grounded_decode_args(expr::MORK.Expr)::Vector{String}
    buf = expr.buf
    length(buf) < 1 && return String[]

    # expr layout: [arity] [functor-sym-bytes...] [arg1-bytes...] [arg2-bytes...] ...
    # Skip the functor (first sub-expression) to get args
    args = ExprEnv[]
    ee = ExprEnv(UInt8(0), UInt8(0), UInt32(0), expr)
    ee_args!(ee, args)
    length(args) <= 1 && return String[]   # args[1] = functor, rest = arguments

    result = String[]
    for i in 2:length(args)
        ee_arg = args[i]
        span = expr_span(ee_arg.base, Int(ee_arg.offset) + 1)
        # Serialise bytes back to S-expression string
        s = try
            expr_serialize(Vector{UInt8}(span))
        catch
            ;
            bytes2hex(Vector{UInt8}(span));
        end
        push!(result, s)
    end
    result
end

"""Encode function return value(s) as byte paths for StaticZipper."""
function _grounded_encode_results(raw)::Vector{Vector{UInt8}}
    raw === nothing && return Vector{UInt8}[]
    strs = if raw isa AbstractString
        [raw]
    elseif raw isa AbstractVector
        collect(String, raw)
    else
        [string(raw)]
    end
    paths = Vector{UInt8}[]
    for s in strs
        bytes = try
            e = sexpr_to_expr(s)
            e.buf
        catch
            codeunits(s) |> collect
        end
        push!(paths, bytes)
    end
    paths
end

# ── Z3Source (external SMT solver: query a named z3 instance for its model) ──────────
# Real port of Rust `Z3Source` (feature-gated upstream, space.rs:1051-1078). `(z3 <instance> <se>)` queries
# the live z3 subprocess named <instance>: sends (check-sat)+(get-model) and, on `sat`, injects the model atoms
# (prefixed `[3] z3 <instance>`) as this factor's data so the join can match <se> against the model. z3 processes
# live in a session-global pool — both Z3Source and Z3Sink reach them by name (the sink-apply API carries no Space
# handle, mirroring upstream's per-space `z3s` map at the session granularity that actually works here).
const _Z3_BIN = Ref{String}("z3")
const _Z3_POOL = Dict{String, Base.Process}()
z3_available() = try; success(`$(_Z3_BIN[]) --version`); catch; false; end
function z3_instance!(name::AbstractString)::Base.Process
    p = get(_Z3_POOL, name, nothing)
    (p !== nothing && process_running(p)) && return p
    proc = open(`$(_Z3_BIN[]) -in -smt2`, "r+")               # duplex pipe: write SMT-LIB, read the model
    _Z3_POOL[String(name)] = proc
    proc
end
"Close all live z3 subprocesses and clear the pool (session cleanup / test isolation)."
z3_reset!() = (for p in values(_Z3_POOL); try; close(p); catch; end; end; empty!(_Z3_POOL); nothing)

struct Z3Source
    expr::MORK.Expr
    ins::String
end
source_requests(s::Z3Source) = [ResourceRequest(RREQ_Z3, s.ins)]

function source_factor(s::Z3Source, btm::PathMap{UnitVal})
    prefix = UInt8[item_byte(ExprArity(UInt8(3))), item_byte(ExprSymbol(UInt8(2))), UInt8('z'), UInt8('3'),
                   item_byte(ExprSymbol(UInt8(length(s.ins))))]
    append!(prefix, codeunits(s.ins))
    model = PathMap{UnitVal}()
    proc = z3_instance!(s.ins)
    write(proc, "(check-sat)\n(get-model)\n"); flush(proc)
    if strip(readline(proc)) == "sat"                          # read model lines until the lone closing ")"
        lines = String[]
        while true
            ln = readline(proc); push!(lines, ln)
            (strip(ln) == ")" || eof(proc)) && break
        end
        text = strip(join(lines, "\n"))
        if length(text) >= 2                                    # strip the outer ( … ) wrapper (upstream v[1..last])
            inner = text[nextind(text, firstindex(text)):prevind(text, lastindex(text))]
            tmp = new_space(); space_add_all_sexpr!(tmp, inner); model = tmp.btm
        end
    end
    PrefixZipper(prefix, read_zipper_at_path(model, UInt8[]))
end

# ── ASource — dispatch wrapper ────────────────────────────────────────

"""
    ASource

Union type dispatching to the correct concrete source implementation.
Mirrors `ASource` enum in sources.rs; extended with `GroundedSource`
for Julia-native grounded function dispatch (Phase 2) and `Z3Source` (real SMT).
"""
const ASource = Union{CompatSource, BTMSource, ACTSource, CmpSource, GroundedSource, Z3Source}

"""
    asource_new(expr) → ASource

Construct the appropriate source for the given pattern expression.
Mirrors `ASource::new` in sources.rs; checks GROUNDED_REGISTRY first
so registered Julia functions take priority over BTM trie queries.
"""
function asource_new(e::MORK.Expr)::ASource
    buf = e.buf
    length(buf) >= 1 || return CompatSource(e)

    # ── GroundedSource: check registry before any prefix match ─────────
    # A grounded sub-expression looks like:
    #   [arity≥2] [symbol-size-byte] [symbol-bytes...] [arg-bytes...]
    # We only need to decode the functor symbol to check the registry.
    t1 = byte_item(buf[1])
    if t1 isa ExprArity && t1.arity >= 1 && length(buf) >= 2
        t2 = byte_item(buf[2])
        if t2 isa ExprSymbol && Int(t2.size) > 0
            name_end = 2 + Int(t2.size)
            if name_end <= length(buf)
                name = String(buf[3:name_end])
                if is_grounded(name)
                    return GroundedSource(e, name)
                end
            end
        end
    end

    # [2] BTM ...
    if length(buf) >= 5 &&
        buf[1] == item_byte(ExprArity(UInt8(2))) &&
        buf[2] == item_byte(ExprSymbol(UInt8(3))) &&
        buf[3] == UInt8('B') && buf[4] == UInt8('T') && buf[5] == UInt8('M')
        return BTMSource(e)
    end

    # [3] ACT <name> ...
    if length(buf) >= 5 &&
        buf[1] == item_byte(ExprArity(UInt8(3))) &&
        buf[2] == item_byte(ExprSymbol(UInt8(3))) &&
        buf[3] == UInt8('A') && buf[4] == UInt8('C') && buf[5] == UInt8('T')
        name_tag = byte_item(buf[6])
        if name_tag isa ExprSymbol
            act_name = String(buf[7:(6 + Int(name_tag.size))])
            return ACTSource(e, act_name)
        end
    end

    # [3] == ... or [3] != ...
    if length(buf) >= 4 &&
        buf[1] == item_byte(ExprArity(UInt8(3))) &&
        buf[2] == item_byte(ExprSymbol(UInt8(2)))
        if buf[3] == UInt8('=') && buf[4] == UInt8('=')
            return CmpSource(e, 0)
        elseif buf[3] == UInt8('!') && buf[4] == UInt8('=')
            return CmpSource(e, 1)
        elseif buf[3] == UInt8('z') && buf[4] == UInt8('3')     # [3] z3 <instance> <se>
            name_tag = byte_item(buf[5])
            if name_tag isa ExprSymbol
                return Z3Source(e, String(buf[6:(5 + Int(name_tag.size))]))
            end
        end
    end

    CompatSource(e)   # fallback
end

asource_compat(e::MORK.Expr) = CompatSource(e)

# =====================================================================
# Exports
# =====================================================================

export ResourceRequestKind, RREQ_BTM, RREQ_ACT, RREQ_Z3
export ResourceRequest
export AbstractSource, CompatSource, BTMSource, ACTSource, CmpSource
export GroundedSource, StaticZipper, Z3Source, z3_available, z3_instance!, z3_reset!
export GROUNDED_REGISTRY, register_grounded!, is_grounded
export ASource, asource_new, asource_compat
export source_requests, source_factor
export ACT_PATH
