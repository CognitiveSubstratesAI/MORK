"""
Expr.jl — port of `mork/expr/src/lib.rs` core expression types.

MORK uses a flat byte encoding for expressions ("Rule of 64"):
  NewVar    : 0b1100_0000 (0xC0)
  SymbolSize: 0b1100_SSSS (0xC1..0xFF) — S = 1..63 bytes follow
  VarRef    : 0b1000_IIII (0x80..0xBF) — I = 0..63 back-reference
  Arity     : 0b0000_AAAA (0x00..0x3F) — A = 0..63 children follow

Julia translation:
  - Rust `Expr { ptr: *mut u8 }` → Julia `ExprBuf{Vector{UInt8}}`
  - Rust `ExprZipper { root, loc }` → Julia `ExprZipper { buf, loc }`
  - Rust `ExprEnv { n, v, offset, base }` → Julia `ExprEnv { n, v, offset, base }`
  - unsafe pointer arithmetic → safe array indexing
"""

# =====================================================================
# ExprTag — 4-variant tag enum (Rule of 64)
# =====================================================================

"""
    ExprTag

Four variants of expression byte tags.
Mirrors `Tag` in mork/expr/src/lib.rs.
"""
abstract type ExprTag end

struct ExprNewVar <: ExprTag end
struct ExprVarRef <: ExprTag

    idx::UInt8
end   # 0-based back-reference
struct ExprSymbol <: ExprTag

    size::UInt8
end   # 1..63 bytes follow
struct ExprArity <: ExprTag

    arity::UInt8
end  # 0..63 children follow

"""
    item_byte(tag::ExprTag) → UInt8

Encode an ExprTag as a single byte.  Mirrors `item_byte` in mork_expr.
"""
function item_byte(tag::ExprTag)::UInt8
    # BOUNDS CHECKS RESTORED 2026-07-23 — upstream has them; this port had dropped them.
    #   upstream `mork/expr/src/lib.rs:117-124` (read, not inferred):
    #     Tag::NewVar        => { 0b1100_0000 | 0 }
    #     Tag::SymbolSize(s) => { debug_assert!(s > 0 && s < 64); 0b1100_0000 | s }
    #     Tag::VarRef(i)     => { debug_assert!(i < 64);          0b1000_0000 | i }
    #     Tag::Arity(a)      => { debug_assert!(a < 64);          0b0000_0000 | a }
    #   ours (before): `0b11000000 | (tag.size & 0x3f)` — MASKED instead of asserting.
    #
    # The mask does not clamp, it WRAPS, and it wraps ACROSS A TAG BOUNDARY: 64 is
    # 0b0100_0000, so `64 & 0x3f == 0` and the byte becomes 0b1100_0000 — which `byte_item`
    # (`lib.rs:128`) decodes as **NewVar**. An oversized symbol therefore did not merely lose
    # bytes, it could emit a structurally DIFFERENT node, silently. Observed downstream as a
    # 64-char id written and read back as 63 chars, so the lookup that used the original id
    # could never match its own atom (`WorldModel/src/Braid.jl` `content_id`; caught by a
    # round-trip property test, not by inspection).
    #
    # WHY 64 AT ALL — not an encoding accident. Upstream states three deliberate assumptions
    # "to avoid abuse" (MORK wiki `Home.md`, §"Where to start" → "Information about numerical
    # computations in these environments"; https://github.com/trueagi-io/MORK/wiki#where-to-start):
    #   a) max EXPRESSION size 64   — to avoid slow LISP-style processing
    #   b) max SYMBOL size 64       — to avoid slow string indexing
    #   c) max VARIABLE MENTIONS 64 — to avoid large unification problems
    #                                 ("instead of the more idiomatic many smaller ones")
    # These are a performance CONTRACT, not a budget to spend to the last byte. The lesson from
    # the CID incident is (b): A LONG OPAQUE STRING IS NOT A SYMBOL — digests, UUIDs, paths and
    # serialized payloads do not belong in symbol position.
    #
    # `@assert` vs Rust's debug-only `debug_assert!`: Julia asserts are on by default, so this is
    # closer to upstream's INTENT (catch the violation) than a release Rust build is. The `& 0x3f`
    # masks are kept as belt-and-braces for `--check-bounds=no`, where asserts may be elided.
    if tag isa ExprNewVar
        return 0b11000000
    elseif tag isa ExprVarRef
        @assert tag.idx < 64 "VarRef index $(tag.idx) exceeds the Rule of 64 (max 63)"
        return 0b10000000 | (tag.idx & 0x3f)
    elseif tag isa ExprSymbol
        @assert 0 < tag.size < 64 "symbol size $(tag.size) violates the Rule of 64 (1..63 bytes). \
A long opaque string is not a symbol — MORK wiki assumption (b), 'max symbol size 64 to avoid slow \
string indexing'. Store digests/paths/payloads as VALUES, not in symbol position."
        return 0b11000000 | (tag.size & 0x3f)
    elseif tag isa ExprArity
        @assert tag.arity < 64 "arity $(tag.arity) exceeds the Rule of 64 (max 63)"
        return 0b00000000 | (tag.arity & 0x3f)
    else

        error("Unknown ExprTag")
    end
end

"""
    byte_item(b::UInt8) → ExprTag

Decode a byte into an ExprTag.  Mirrors `byte_item` in mork_expr.
"""
function byte_item(b::UInt8)::ExprTag
    if b == 0b11000000
        return ExprNewVar()
    elseif (b & 0b11000000) == 0b11000000
        return ExprSymbol(b & 0x3f)
    elseif (b & 0b11000000) == 0b10000000
        return ExprVarRef(b & 0x3f)
    elseif (b & 0b11000000) == 0b00000000
        return ExprArity(b & 0x3f)
    else
        error("reserved byte: 0x$(string(b, base=16))")
    end
end

# ── `GxHasher::with_seed` / `finish_u128` DELIBERATELY NOT PORTED HERE ────────────────────────────
#
# They exist in upstream `expr/src/lib.rs:43-50`, inside `#[cfg(not(gxhash))] mod gxhash` — the STUB
# module, which is what compiles (the bare `cfg(gxhash)` is never set; `expr/Cargo.toml`'s
# `default = ["gxhash", …]` names the optional DEPENDENCY, a different switch).
#
# 🔴 IN THIS CRATE THEY ARE TEST-ONLY. The stub's live entry point is one line —
# `pub fn gxhash128(data, _seed) -> u128 { xxhash_rust::const_xxh3::xxh3_128(data) }` (lib.rs:59) —
# and it never touches `GxHasher`. Every use of `GxHasher::with_seed` in this crate is inside
# `#[cfg(test)]` (lib.rs:2317, 2731-2758). `Expr::hash()` therefore resolves to XXH3, which we port
# 1:1 in `kernel/XXH3.jl`. Porting the hasher here would have added API with no consumer — the same
# mistake as the 160 ours-only pure ops removed in 9b75c5e. (User-identified.)
#
# ⚠️ WHERE IT IS ACTUALLY NEEDED: **PathMap** — and the CALL GRAPH, not the dependency list, is what
# says so. Both crates depend on `xxhash-rust`, which invites the conclusion that the hash belongs in
# the shared/lower package. That conclusion is WRONG, measured by call site:
#
#     gxhash128 (-> xxh3)        MORK expr ONLY   (lib.rs:312, `Expr::hash`).  ZERO calls in PathMaps.
#     GxHasher::with_seed        PathMap ONLY     (merkleization.rs:56,79 · morphisms.rs:242,255 ·
#                                                  experimental/serialization.rs:139,146)
#
# PathMap depends on `xxhash-rust` only to DEFINE its own stub's `gxhash128`, and then never calls
# it. So `kernel/XXH3.jl` is in the right package — MORK is its sole consumer — and moving it to
# PathMap would serve nothing there. What PathMap needs is `GxHasher`, a DIFFERENT algorithm: a
# byte-at-a-time add/xor/rotate state mixer (`state_lo += i; state_hi ^= rotl(i,11);
# state_lo = rotl(state_lo,3)`), ~20 self-contained lines, nothing like xxh3.
#
# ⇒ If merkleization / `dag_serialization` / an upstream-compatible `Catamorphism::hash` is ever
# wanted, port `GxHasher` INTO PathMaps. Do not relocate XXH3, and do not substitute xxh3 for it.
# (Reading a dependency list instead of a call graph is the same error as counting a commented-out
# `nth_expr` as upstream API.)

"""
    expr_compute_length(s) → Int

upstream `compute_length` (expr/src/lib.rs:1516-1563) — the SERIALIZED BYTE LENGTH an expression
literal will occupy, counted without building it:

    `[n]` → 1 byte (an Arity tag)   ·   `\$` → 1 (NewVar)   ·   `_n` → 1 (VarRef)
    a word → 1 + its length (a SymbolSize tag plus the bytes)

Upstream is a `const fn` used only as `const N: usize = compute_length(\$s)` (lib.rs:1510) to size
the fixed array `parse<const N>` writes into. Julia sizes buffers dynamically, so nothing here needs
it — it is ported because it is a well-defined pure function, and it is genuinely useful for
predicting a buffer size before parsing.
"""
function expr_compute_length(s::AbstractString)::Int
    b = Vector{UInt8}(String(s))
    len = length(b)
    i = 1
    n = 0
    while i <= len
        while i <= len && b[i] == UInt8(' ')
            i += 1
        end
        i > len && break
        c = b[i]
        if c == UInt8('[')
            i += 1
            while i <= len && b[i] != UInt8(']')
                i += 1
            end
            i += 1                       # skip ']'
            n += 1                       # item_byte(Arity(k))
        elseif c == UInt8('$')
            i += 1
            n += 1                       # item_byte(NewVar)
        elseif c == UInt8('_')
            i += 1
            while i <= len && UInt8('0') <= b[i] <= UInt8('9')
                i += 1
            end
            n += 1                       # item_byte(VarRef(k-1))
        else
            word = 0
            while i <= len && b[i] != UInt8(' ')
                word += 1
                i += 1
            end
            n += 1 + word                # item_byte(SymbolSize) + the bytes
        end
    end
    n
end

"""
    maybe_byte_item(b) → Union{ExprTag, UInt8}

upstream `maybe_byte_item` (expr/src/lib.rs:135-141) — the NON-THROWING sibling of `byte_item`.
Upstream returns `Result<Tag, u8>`: `Ok(tag)`, or `Err(b)` giving the offending byte back. Julia has
no `Result`, so the tag is returned on success and the raw `UInt8` on failure — the two are
distinguishable by type, which is what callers need.

`byte_item` raises on a reserved byte; this is for callers that must inspect possibly-invalid bytes
without an exception, e.g. a decoder walking untrusted input.
"""
function maybe_byte_item(b::UInt8)::Union{ExprTag, UInt8}
    if b == 0b11000000
        return ExprNewVar()
    elseif (b & 0b11000000) == 0b11000000
        return ExprSymbol(b & 0x3f)
    elseif (b & 0b11000000) == 0b10000000
        return ExprVarRef(b & 0x3f)
    elseif (b & 0b11000000) == 0b00000000
        return ExprArity(b & 0x3f)
    else
        return b
    end
end

# =====================================================================
# Expr — a flat byte-buffer expression
# =====================================================================

"""
    Expr

Flat byte-encoded expression.  Julia equivalent of Rust `Expr { ptr }`.
The buffer owns its bytes; the expression starts at byte 1 (1-based).
"""
struct Expr
    buf::Vector{UInt8}
end

Expr() = Expr(UInt8[])
Expr(bytes::AbstractVector{UInt8}) = Expr(Vector{UInt8}(bytes))

Base.length(e::Expr) = length(e.buf)
Base.getindex(e::Expr, i) = e.buf[i]
Base.isempty(e::Expr) = isempty(e.buf)

"""Byte tag at position `offset` (1-based)."""
expr_tag_at(e::Expr, offset::Int=1) = byte_item(e.buf[offset])

"""Span (all bytes) of the sub-expression starting at `offset`."""
# E-1 (audit 2026-06-04): traced + VERIFIED CORRECT (the audit's "correct-by-coincidence"
# is refuted). Standard flat-arity expression-end walk: `depth` tracks pending
# sub-expressions. A leaf consumes one (depth -= 1); an Arity(n) header introduces n
# children (depth += n) then is itself consumed (depth -= 1) — net +(n-1). The expression
# ends exactly when depth returns to 0. Produces spans identical to the recursive
# `_expr_end_offset` (Sinks.jl) on flat + nested shapes. DUPLICATION NOTE: the two compute
# the same thing; a future cleanup should move `_expr_end_offset` up to the expr layer and
# have both use it — deferred (not worth a backward expr→kernel dependency or a behavioural
# change to this hot, correct walker now).
function expr_span(e::Expr, offset::Int=1)
    i = offset
    depth = 0
    while i <= length(e.buf)
        tag = byte_item(e.buf[i])
        if tag isa ExprSymbol
            i += 1 + Int(tag.size)
            depth == 0 && return view(e.buf, offset:(i - 1))
        elseif tag isa ExprArity
            i += 1
            tag.arity == 0 && depth == 0 && return view(e.buf, offset:(i - 1))
            depth += Int(tag.arity)
        else  # NewVar or VarRef — leaf
            i += 1
            depth == 0 && return view(e.buf, offset:(i - 1))
        end
        depth == 0 && return view(e.buf, offset:(i - 1))
        depth -= 1
    end
    view(e.buf, offset:length(e.buf))
end

# =====================================================================
# ExprZipper — cursor over a flat expression buffer
# =====================================================================

"""
    Breadcrumb

upstream `Breadcrumb` (lib.rs:83-87) — one frame of `ExprZipper.trace`: where the Arity node that
opened this level sits, its arity, and how many of its children have been consumed.

IMMUTABLE here, where upstream's derives `Copy` and is mutated through `&mut`. That is not a
stylistic choice: `next_descendant` snapshots the trace with `self.trace.clone()` and restores it on
failure, which is a genuine deep copy only because Breadcrumb is `Copy`. With a Julia
`mutable struct`, `copy(trace)` would share frames with the live trace and the restore would
silently restore nothing — a defect that no type error would catch.

`parent` is a 1-BASED loc, like every other loc in this port; upstream's is 0-based.
"""
struct Breadcrumb
    parent::UInt32
    arity::UInt8
    seen::UInt8
end

"""
    ExprZipper

Cursor for traversing a flat byte-encoded expression.
Mirrors `ExprZipper` in mork_expr.

`trace` is upstream's breadcrumb stack (lib.rs:1225). It is what makes `ez_gnext!` / `ez_parent!` /
`ez_next_descendant!` able to tell "this expression is finished" from "the buffer ran out" — see
the note on `ez_next!`, which is our own simpler walker and deliberately does NOT maintain it.
"""
mutable struct ExprZipper
    root::Expr
    loc::Int       # current byte offset (1-based)
    # LAZILY MATERIALISED — `nothing` until a trace-based function needs it. Building it eagerly in
    # the constructor cost a Vector allocation on EVERY zipper, including the output zippers and
    # ez_next! walks that never look at it, and that showed up as a measured +2.7% on the
    # `space_metta_calculus!` per-step allocation budget (test/alloc_budget.jl C2: 92465 vs a 90000
    # ceiling). Laziness changes no semantics: the trace describes the position it was built at, so
    # a zipper advanced by ez_next! has a root-relative trace either way — see the note above.
    trace::Union{Nothing, Vector{Breadcrumb}}
end

# upstream `ExprZipper::new` (lib.rs:1229-1243): a leaf root gets an EMPTY trace, so `next()` on a
# bare symbol or variable is false immediately; an Arity root gets one frame.
function _ez_initial_trace(e::Expr)::Vector{Breadcrumb}
    isempty(e.buf) && return Breadcrumb[]
    t = maybe_byte_item(e.buf[1])
    t isa ExprArity ? [Breadcrumb(UInt32(1), t.arity, UInt8(0))] : Breadcrumb[]
end

ExprZipper(e::Expr, loc::Int) = ExprZipper(e, loc, nothing)

"""Materialise and return the breadcrumb trace, building it from the root on first use."""
function _ez_trace!(z::ExprZipper)::Vector{Breadcrumb}
    t = z.trace
    t === nothing || return t
    nt = _ez_initial_trace(z.root)
    z.trace = nt
    nt
end
ExprZipper(e::Expr) = ExprZipper(e, 1)
ExprZipper(bytes::Vector{UInt8}) = ExprZipper(Expr(bytes), 1)

"""Current tag at the zipper's position."""
ez_tag(z::ExprZipper) = expr_tag_at(z.root, z.loc)

"""Current raw byte at the zipper's position."""
ez_item(z::ExprZipper) = z.root.buf[z.loc]

"""Advance the zipper past the current leaf/expression. Returns false if done."""
function ez_next!(z::ExprZipper)::Bool
    i = z.loc
    length(z.root) < i && return false
    tag = byte_item(z.root.buf[i])
    if tag isa ExprSymbol
        z.loc += 1 + Int(tag.size)
    elseif tag isa ExprArity
        z.loc += 1   # just advance past the header; children follow
    else
        z.loc += 1
    end
    z.loc <= length(z.root)
end

"""Return the span of the sub-expression at the current position."""
ez_span(z::ExprZipper) = expr_span(z.root, z.loc)

# =====================================================================
# Breadcrumb traversal — upstream ExprZipper::gnext / next_skip / parent / next_descendant
# =====================================================================
#
# ⚠️ RELATIONSHIP TO `ez_next!`, stated precisely because getting it wrong is silent:
#
# `ez_next!` is OURS, not upstream's. Upstream has one traversal, `next() = gnext(0)`, which knows the
# expression is finished when the TRACE empties. `ez_next!` instead stops when the BUFFER runs out.
# For a zipper over exactly one complete expression the two visit the same positions in the same
# order and stop together (pinned by a test). They part when the buffer holds MORE than the
# expression — which is exactly what `ez_subexpr` returns, since it carries the whole remaining tail:
# there `ez_next!` walks on into the following siblings and `ez_gnext!` stops at the end of the
# sub-expression. `ez_gnext!` is the correct one.
#
# `ez_next!` does NOT maintain `trace`. So do not advance with `ez_next!` and then ask `ez_parent!`
# where you are — the trace will describe a position you no longer occupy. Pick one family per walk.

"""
    ez_gnext!(z, offset=0) → Bool

upstream `ExprZipper::gnext` (lib.rs:1325-1352); `ez_gnext!(z)` is upstream's `next()` (lib.rs:1321).

Consumes one child of the innermost open Arity node. When that node's children are exhausted the
frame is popped and the search continues in the parent — so `false` means "the whole expression is
finished", not "the buffer ended".

`offset` bounds how far down the stack the search may pop: upstream slices `trace[offset..]`, so an
`offset` at or beyond the stack depth yields `None` -> false. Note upstream's recursive call is
`self.next()`, i.e. `gnext(0)` — the offset is NOT carried into the recursion, and that is faithful
here.
"""
function ez_gnext!(z::ExprZipper, offset::Int=0)::Bool
    tr = _ez_trace!(z)
    length(tr) <= offset && return false
    bc = tr[end]
    if bc.seen < bc.arity
        tr[end] = Breadcrumb(bc.parent, bc.arity, bc.seen + UInt8(0x01))
        t = byte_item(z.root.buf[z.loc])
        z.loc += t isa ExprSymbol ? Int(t.size) + 1 : 1
        # upstream reads `self.tag()` here unconditionally — a raw pointer read that runs off the end
        # for a TRUNCATED expression. Guarded: a well-formed expression never reaches past the buffer.
        if z.loc <= length(z.root.buf)
            nt = maybe_byte_item(z.root.buf[z.loc])
            nt isa ExprArity && push!(tr, Breadcrumb(UInt32(z.loc), nt.arity, UInt8(0)))
        end
        return true
    else
        pop!(tr)
        return ez_gnext!(z, 0)
    end
end

"""
    ez_next_skip!(z) → Bool

upstream `ExprZipper::next_skip` (lib.rs:1354-1403) — like `ez_gnext!` but steps OVER a sub-expression
instead of into it: an Arity node advances by its whole span, and no frame is pushed. The result is a
walk of one level's children.

⚠️ THIS IS UNFINISHED UPSTREAM WORK, ported for completeness rather than for use. Its only reference
in the entire upstream tree is its own recursive self-call (lib.rs:1399) — no caller, no test. It
still carries two live `println!` calls, three commented-out blocks and an unused binding. The prints
are debug noise, not behaviour, and are not reproduced.

Its behaviour FROM THE ROOT is degenerate and faithfully preserved: the tag at the root of an Arity
expression is that whole expression, so the first call advances past ALL of it and returns true.
Meaningful use is after descending, where it then walks one level's siblings.

Upstream reads the tag at the resulting position on the next call, which for that root case is past
the end of the allocation. We return false instead of reading out of bounds; upstream's behaviour
there is undefined, so there is nothing faithful to preserve.
"""
function ez_next_skip!(z::ExprZipper)::Bool
    tr = _ez_trace!(z)
    isempty(tr) && return false
    z.loc > length(z.root.buf) && return false
    bc = tr[end]
    if bc.seen < bc.arity
        tr[end] = Breadcrumb(bc.parent, bc.arity, bc.seen + UInt8(0x01))
        t = byte_item(z.root.buf[z.loc])
        z.loc += if t isa ExprSymbol
            Int(t.size) + 1
        elseif t isa ExprArity
            length(expr_span(z.root, z.loc))
        else
            1
        end
        return true
    else
        pop!(tr)
        return ez_next_skip!(z)
    end
end

"""
    ez_parent!(z) → Bool

upstream `ExprZipper::parent` (lib.rs:1405-1410) — move to the Arity node that opened the current
level and pop its frame. `false` when already at the root.
"""
function ez_parent!(z::ExprZipper)::Bool
    tr = _ez_trace!(z)
    isempty(tr) && return false
    z.loc = Int(tr[end].parent)
    pop!(tr)
    true
end

"""
    ez_next_child!(z) → Bool

upstream `ExprZipper::next_child` (lib.rs:1421-1423) — `next_descendant(0, 0)`.
"""
ez_next_child!(z::ExprZipper)::Bool = ez_next_descendant!(z, 0, 0)

"""
    ez_next_descendant!(z, to, offset) → Bool

upstream `ExprZipper::next_descendant` (lib.rs:1425-1454) — advance with `ez_gnext!` until landing on
a position whose parent is `base`, where `base` is selected by `to`:

    to < 0  : the frame `to` from the TOP of the stack        (upstream `trace[len + to]`)
    to > 0  : the frame at depth `to`                          (upstream `trace[to - 1]`)
    to == 0 : the ROOT                                         (upstream's literal `0`)

On exhaustion the trace is RESTORED to its entry value and `false` returned, so a failed search
leaves the zipper's stack — though not its `loc` — as it was. That restore is only sound because
`Breadcrumb` is immutable here; see its docstring.

Index translation: upstream's `l = trace.len() - 1 - offset` is a 0-based index, so ours is
`length(trace) - offset`, and upstream's `trace[l - 1]` is ours at one less again. Upstream's guard
`l > 0` becomes `li > 1`.
"""
function ez_next_descendant!(z::ExprZipper, to::Int, offset::Int)::Bool
    tr = _ez_trace!(z)
    base = if to < 0
        tr[length(tr) + to + 1].parent              # +1: upstream's index is 0-based
    elseif to > 0
        tr[to].parent                               # upstream trace[to-1], 0-based
    else
        UInt32(1)                                   # upstream's literal 0 = the root loc; ours is 1
    end
    initial = copy(tr)
    while true
        if !ez_gnext!(z, 0)
            z.trace = initial
            return false
        end
        tr = _ez_trace!(z)
        li = length(tr) - offset
        t = byte_item(z.root.buf[z.loc])
        if t isa ExprArity
            li > 1 && tr[li - 1].parent == base && return true
        else
            li >= 1 && tr[li].parent == base && return true
        end
    end
end

"""
    ez_tag_str(z) → String

upstream `ExprZipper::tag_str` (lib.rs:1293-1300) — render the tag at the current position:
`\$` for a NewVar, `_N` for `VarRef(N-1)` (**one-based on display**), `(N)` for `SymbolSize(N)`,
`[N]` for `Arity(N)`.
"""
function ez_tag_str(z::ExprZipper)::String
    t = byte_item(z.root.buf[z.loc])
    t isa ExprNewVar && return "\$"
    t isa ExprVarRef && return "_$(Int(t.idx) + 1)"
    t isa ExprSymbol && return "($(Int(t.size)))"
    "[$(Int((t::ExprArity).arity))]"
end

"""
    ez_item_str(z) → String

upstream `ExprZipper::item_str` (lib.rs:1302-1319) — like `tag_str`, except a SYMBOL renders as its
own bytes rather than as its size: upstream's `item()` returns `Err(bytes)` for a symbol, and the
`Err` arm prints the UTF-8 text (falling back to a byte-array debug form when it is not valid UTF-8).
"""
function ez_item_str(z::ExprZipper)::String
    t = byte_item(z.root.buf[z.loc])
    t isa ExprSymbol || return ez_tag_str(z)
    b = collect(ez_symbol(z))
    isvalid(String(copy(b))) ? String(copy(b)) : string(b)
end

"""Symbol bytes at current position (only valid if tag is ExprSymbol)."""
function ez_symbol(z::ExprZipper)
    tag = byte_item(z.root.buf[z.loc])
    tag isa ExprSymbol || return UInt8[]
    view(z.root.buf, (z.loc + 1):(z.loc + Int(tag.size)))
end

"""Ensure buffer has at least `needed` bytes total, resizing if required."""
function ez_ensure!(z::ExprZipper, needed::Int)
    length(z.root.buf) < needed && resize!(z.root.buf, max(needed * 2, 64))
end

"""Write a NewVar byte at current position and advance."""
function ez_write_new_var!(z::ExprZipper)
    ez_ensure!(z, z.loc)
    z.root.buf[z.loc] = item_byte(ExprNewVar())
    z.loc += 1
end

"""Write a VarRef byte at current position and advance."""
function ez_write_var_ref!(z::ExprZipper, idx::UInt8)
    ez_ensure!(z, z.loc)
    z.root.buf[z.loc] = item_byte(ExprVarRef(idx))
    z.loc += 1
end

"""Write an arity header byte at current position and advance."""
function ez_write_arity!(z::ExprZipper, arity::UInt8)
    ez_ensure!(z, z.loc)
    z.root.buf[z.loc] = item_byte(ExprArity(arity))
    z.loc += 1
end

"""Overwrite the byte at `offset` (1-based) with a new arity — used to backpatch counted arities."""
function ez_patch_arity!(z::ExprZipper, offset::Int, arity::UInt8)
    z.root.buf[offset] = item_byte(ExprArity(arity))
end

"""Write a symbol header + bytes at current position and advance."""
function ez_write_symbol!(z::ExprZipper, sym::AbstractVector{UInt8})
    n = length(sym)
    ez_ensure!(z, z.loc + n)
    z.root.buf[z.loc] = item_byte(ExprSymbol(UInt8(n)))
    copyto!(z.root.buf, z.loc + 1, sym, 1, n)
    z.loc += 1 + n
end

"""Write a slice of bytes at current position and advance."""
function ez_write_move!(z::ExprZipper, bytes::AbstractVector{UInt8})
    n = length(bytes)
    ez_ensure!(z, z.loc + n - 1)
    copyto!(z.root.buf, z.loc, bytes, 1, n)
    z.loc += n
end

"""Final span (the expression from start to current position)."""
ez_finish_span(z::ExprZipper) = view(z.root.buf, 1:(z.loc - 1))

# =====================================================================
# serialize — bytes → human-readable string
# =====================================================================

"""
    expr_serialize(bytes) → String

Convert a flat byte-encoded expression to a human-readable s-expression string.
Mirrors `SerializerTraversal` in mork_expr (produces parenthesized s-expressions).
"""
function expr_serialize(bytes::AbstractVector{UInt8})::String
    io = IOBuffer()
    # Stack tracks (children_remaining) for open arity nodes.
    # When children_remaining hits 0 we close with ')'.
    stack = Int[]
    transient = false   # true = need a space before next element

    i = 1
    while i <= length(bytes)
        tag = byte_item(bytes[i])

        if tag isa ExprArity
            transient && write(io, ' ')
            write(io, '(')
            transient = false
            push!(stack, Int(tag.arity))
            i += 1
        elseif tag isa ExprSymbol
            transient && write(io, ' ')
            n = Int(tag.size)
            i += 1
            # VERBATIM BYTES — exactly what upstream does. `Space::dump_all_sexpr`
            # (kernel/src/space.rs:898-912) hands the symbol slice to
            # `str::from_utf8_unchecked(s)` and writes it: no validation, no escaping, no
            # re-encoding. A symbol's bytes are its bytes.
            #
            # ⚠️ THIS USED TO ESCAPE, AND THE ESCAPING DID NOT ROUND-TRIP. It wrote
            # `Char(cb)` for "printable" bytes and `\xNN` text otherwise, which broke two ways:
            #   * `write(io, Char(cb))` UTF-8 ENCODES — byte 0xC8 became Char 'È' became the TWO
            #     bytes 0xC3 0x88, so the payload GREW; and `isprint(Char(0x8C))` is false, so
            #     0x8C became the four literal characters `\x8c`.
            #   * NOTHING DECODES EITHER FORM ON THE WAY BACK IN. The parser reads those bytes
            #     literally, so `space_add_all_sexpr!(space_dump_all_sexpr(s))` did not preserve
            #     the space — measured: `(v ü)` re-parsed and re-dumped as `(v Ã¼)`, and
            #     `(w ?È\x8cá)` as `(w ?Ã\x88\x5cx8cÃ¡)`, corrupting further on every round.
            # Upstream round-trips by construction because both sides are raw bytes.
            #
            # Consequence for text consumers (Core's MM2Router / PatternMiner / MeTTaIL split
            # this on '\n'): unchanged for ASCII symbols, which is every ordinary MeTTa atom.
            # Symbols with non-ASCII bytes now render as those bytes instead of a corrupted
            # expansion — a Julia String may then hold invalid UTF-8, which is legal and is what
            # byte-exact comparison against upstream requires.
            for j in i:min(i + n - 1, length(bytes))
                write(io, bytes[j])
            end
            i += n
            transient = true
        elseif tag isa ExprNewVar
            transient && write(io, ' ')
            write(io, '$')
            i += 1
            transient = true
        elseif tag isa ExprVarRef
            transient && write(io, ' ')
            write(io, "_$(Int(tag.idx) + 1)")
            i += 1
            transient = true
        else
            i += 1
        end

        # Close any fully-consumed arity nodes
        while !isempty(stack)
            stack[end] -= 1
            if stack[end] < 0
                pop!(stack)
                write(io, ')')
                transient = true
            else
                break
            end
        end
    end
    # Close any unclosed parens (shouldn't happen in well-formed expressions)
    for _ in stack
        write(io, ')')
    end
    String(take!(io))
end

expr_serialize(e::Expr) = expr_serialize(e.buf)

"""
    EXPR_VARNAMES

upstream `Expr::VARNAMES` (lib.rs:897) — the 64 names variables are printed under: `\$a`..`\$j` for
indices 0-9, then `\$x10`..`\$x63`. Sixty-four because that is the Rule-of-64 ceiling on VarRef.
"""
const EXPR_VARNAMES = String[i < 10 ? "\$" * ('a' + i) : "\$x$(i)" for i in 0:63]

"""
    expr_varname(i, intro) → String

upstream's default `map_variable` (`|i, intro| Expr::VARNAMES[i as usize]`, space.rs:913/960). Note
it IGNORES `intro`: a binder and a back-reference to it print the SAME name, which is what makes the
output re-readable.
"""
expr_varname(i::Integer, _intro::Bool)::String = EXPR_VARNAMES[Int(i) + 1]

"""
    expr_serialize2(bytes; map_symbol=nothing, map_variable=expr_varname) → String

upstream `Expr::serialize2` (lib.rs:900-904) — the serializer used by BOTH of upstream's dump paths
(`dump_all_sexpr` space.rs:903, and the query dump at :952).

It differs from [`expr_serialize`] in one respect that matters a great deal: variables are rendered
through `map_variable` under a NAME rather than as the raw encoding. Upstream passes VARNAMES, so a
binder and every back-reference to it share one name:

    encoding        expr_serialize (upstream `serialize`)   expr_serialize2 (upstream `serialize2`)
    [2] pat \$       (pat \$)                                 (pat \$a)
    [3] two \$ \$     (two \$ \$)                               (two \$a \$b)
    [3] twice \$ _1  (twice \$ _1)                            (twice \$a \$a)

Both forms round-trip through our own parser — CHECKED, not assumed: dumping `(twice \$y \$y)` and
re-reading it reproduces the identical encoding under either serializer, because our s-expression
parser accepts `_N` as a back-reference and a repeated variable NAME also encodes as binder +
back-reference. So the reason to prefer this one is parity with upstream's actual dump output, not
data loss in ours.

Our conformance harness already knew about the difference and canonicalises it away: it maps
upstream's `\$a`/`\$b` and our `\$`/`_N` onto `V0`,`V1`,… by first occurrence
(`test/conformance/run_conformance.jl:30`). Using `serialize2` in the dump paths is what makes that
normalisation unnecessary for variables rather than load-bearing.

`map_symbol=nothing` means "write the symbol's bytes verbatim", which is upstream's non-interning
path and is required for byte-exactness; see the long note in [`expr_serialize`] about the escaping
that used to corrupt round-trips here.
"""
function expr_serialize2(bytes::AbstractVector{UInt8};
    map_symbol=nothing,
    map_variable=expr_varname)::String
    io = IOBuffer()
    stack = Int[]
    transient = false
    n = 0                     # upstream SerializerTraversal2.n — how many binders have been printed
    i = 1
    while i <= length(bytes)
        tag = byte_item(bytes[i])

        if tag isa ExprArity
            transient && write(io, ' ')
            write(io, '(')
            transient = false
            push!(stack, Int(tag.arity))
            i += 1
        elseif tag isa ExprSymbol
            transient && write(io, ' ')
            m = Int(tag.size)
            i += 1
            sym = view(bytes, i:min(i + m - 1, length(bytes)))
            if map_symbol === nothing
                for b in sym
                    write(io, b)
                end
            else
                write(io, map_symbol(sym))
            end
            i += m
            transient = true
        elseif tag isa ExprNewVar
            transient && write(io, ' ')
            write(io, map_variable(UInt8(n), true))
            n += 1
            i += 1
            transient = true
        elseif tag isa ExprVarRef
            transient && write(io, ' ')
            write(io, map_variable(tag.idx, false))
            i += 1
            transient = true
        else
            i += 1
        end

        while !isempty(stack)
            stack[end] -= 1
            if stack[end] < 0
                pop!(stack)
                write(io, ')')
                transient = true
            else
                break
            end
        end
    end
    for _ in stack
        write(io, ')')
    end
    String(take!(io))
end

expr_serialize2(e::Expr; kwargs...) = expr_serialize2(e.buf; kwargs...)

"""
    expr_serialize_highlight(bytes; target, map_symbol=nothing, map_variable=expr_varname,
                             start_code="\e[43m", end_code="\e[0m") → String

upstream `Expr::serialize_highlight` (lib.rs:906-911) — `expr_serialize2` with the item that BEGINS
at byte `target` wrapped in ANSI codes. For an Arity node the closing code is carried in the fold's
accumulator and emitted AFTER its `)`, so a whole sub-expression highlights, not just its head.

⚠️ Upstream's own wrapper is marked unfinished: it builds
`[(target, "\x1B[43m", "\x1B[0m")].repeat(10)  // FIXE` — the same target ten times, because the
traversal indexes `targets[0]` unconditionally and CONSUMES an entry on every match, so a shorter
list would panic. Ten copies is the padding. We take one target and simply stop matching once it has
fired, which is the same observable behaviour without the sentinel-list trick.

⚠️ RELATIONSHIP TO [`ee_show`]: upstream's `ExprEnv::show` (lib.rs:1777-1785) is built on THIS —
it serializes the whole `base` and highlights the env's current `offset`. Our `ee_show` instead
renders just the sub-expression AT that offset, which is upstream's own COMMENTED-OUT alternative
on the very next line (`// self.subsexpr().serialize2(...)`, lib.rs:1782). That is left as it is
deliberately: `ee_show` feeds diagnostics and unification traces, and the live upstream form would
put raw ANSI escapes into those strings on the strength of a line upstream marks `FIXE`. The
mechanism is here if it is ever wanted.
"""
function expr_serialize_highlight(bytes::AbstractVector{UInt8};
    target::Int,
    map_symbol=nothing,
    map_variable=expr_varname,
    start_code::String="\e[43m",
    end_code::String="\e[0m")::String
    io = IOBuffer()
    stack = Tuple{Int, String}[]      # (children remaining, closing code to emit after `)`)
    transient = false
    n = 0
    fired = false
    i = 1
    while i <= length(bytes)
        tag = byte_item(bytes[i])
        hit = !fired && i == target
        hit && (fired = true)

        if tag isa ExprArity
            transient && write(io, ' ')
            hit && write(io, start_code)
            write(io, '(')
            transient = false
            push!(stack, (Int(tag.arity), hit ? end_code : ""))
            i += 1
        elseif tag isa ExprSymbol
            transient && write(io, ' ')
            hit && write(io, start_code)
            m = Int(tag.size)
            i += 1
            sym = view(bytes, i:min(i + m - 1, length(bytes)))
            if map_symbol === nothing
                for b in sym
                    write(io, b)
                end
            else
                write(io, map_symbol(sym))
            end
            i += m
            hit && write(io, end_code)
            transient = true
        elseif tag isa ExprNewVar
            transient && write(io, ' ')
            hit && write(io, start_code)
            write(io, map_variable(UInt8(n), true))
            hit && write(io, end_code)
            n += 1
            i += 1
            transient = true
        elseif tag isa ExprVarRef
            transient && write(io, ' ')
            hit && write(io, start_code)
            write(io, map_variable(tag.idx, false))
            hit && write(io, end_code)
            i += 1
            transient = true
        else
            i += 1
        end

        while !isempty(stack)
            (rem, close) = stack[end]
            rem -= 1
            if rem < 0
                pop!(stack)
                write(io, ')')
                isempty(close) || write(io, close)
                transient = true
            else
                stack[end] = (rem, close)
                break
            end
        end
    end
    for (_, close) in Iterators.reverse(stack)
        write(io, ')')
        isempty(close) || write(io, close)
    end
    String(take!(io))
end

expr_serialize_highlight(e::Expr; kwargs...) = expr_serialize_highlight(e.buf; kwargs...)

"""
    ez_traverse(z, i=0; io=stdout) → Int

upstream `ExprZipper::traverse` (lib.rs:1457-1483), labelled "Debug traversal" — print the
expression at `loc + i` and return how many bytes it spanned.

Recursive there, iterative here, and it renders like `expr_serialize` (a NewVar as `\$`, a VarRef as
`_N`) rather than like `expr_serialize2`. Unlike `expr_serialize` it goes through `maybe_byte_item`,
so a RESERVED byte prints as its decimal value and counts as one item instead of raising — upstream's
`Err(b) => print!("{}", b as usize)` arm, which is what makes this usable on a malformed buffer.
"""
function ez_traverse(z::ExprZipper, i::Int=0; io::IO=stdout)::Int
    start = z.loc + i
    j = start
    depth = Int[]                      # children remaining at each open Arity
    transient = false
    while j <= length(z.root.buf)
        t = maybe_byte_item(z.root.buf[j])
        if t isa ExprArity
            transient && print(io, ' ')
            print(io, '(')
            transient = false
            push!(depth, Int(t.arity))
            j += 1
        elseif t isa ExprSymbol
            transient && print(io, ' ')
            m = Int(t.size)
            for k in (j + 1):min(j + m, length(z.root.buf))
                write(io, z.root.buf[k])
            end
            j += 1 + m
            transient = true
        elseif t isa ExprNewVar
            transient && print(io, ' ')
            print(io, '$')
            j += 1
            transient = true
        elseif t isa ExprVarRef
            transient && print(io, ' ')
            print(io, "_$(Int(t.idx) + 1)")
            j += 1
            transient = true
        else
            # reserved byte — upstream prints its numeric value and consumes exactly one
            transient && print(io, ' ')
            print(io, Int(z.root.buf[j]))
            j += 1
            transient = true
        end

        while !isempty(depth)
            depth[end] -= 1
            if depth[end] < 0
                pop!(depth)
                print(io, ')')
                transient = true
            else
                break
            end
        end
        isempty(depth) && break        # one expression only, like upstream's single recursion
    end
    j - start
end

# =====================================================================
# ExprEnv — expression with unification scope
# =====================================================================

"""
    ExprVar

Identifies a variable as (source_id, var_index).
Mirrors `ExprVar = (u8, u8)` in mork_expr.
"""
const ExprVar = Tuple{UInt8, UInt8}

"""
    ExprEnv

Expression cursor with source-ID scoping for unification.
Mirrors `ExprEnv { n, v, offset, base }` in mork_expr.
"""
struct ExprEnv
    n::UInt8   # source id (0, 1, ...)
    v::UInt8   # next free var index
    offset::UInt32  # byte offset into base
    base::Expr    # backing expression
end

ExprEnv(n::Integer, base::Expr) = ExprEnv(UInt8(n), UInt8(0), UInt32(0), base)
ExprEnv(n::Integer, base::Vector{UInt8}) = ExprEnv(n, Expr(base))

# ═════════════════════════════════════════════════════════════════════════════════════════════════
# Bindings — a DIRECT-INDEXED SLAB behind the `AbstractDict` interface.
#
# ADOPTED from upstream `Bindings` (`expr/src/lib.rs:1821`), which replaced a `BTreeMap` in two
# steps: `52f5fb7` (flat sorted vec) then `0a41fb9` (direct-indexed slab, stacked on the trail).
# The insight, in upstream's words:
#
#     "The key domain is bounded -- at most 64 conjuncts (an arity byte), each namespace at most 64
#      variables (the parser's cap) -- so (n, v) IS an index: n << 6 | v. A probe is one load with
#      no comparisons, ordering or hashing; insert is a store plus a touched-list push."
#
# 🔑 `ExprVar` IS ALREADY THAT PAIR HERE. Ours is `Tuple{UInt8,UInt8}` = (source_id, var_index),
# mirroring upstream's `(u8, u8)` — so `Dict{ExprVar,ExprEnv}` has been hashing and comparing a key
# that is already an index into a small array.
#
# ⚠️ IT SUBTYPES `AbstractDict` DELIBERATELY, and that is the Julia form of upstream's own strategy
# ("The BTreeMap API subset the engine used is kept, so call sites are unchanged beyond constructor
# literals"). There are 35 `Dict{ExprVar,ExprEnv}` sites across 5 files, and `space_query_multi`'s
# callback hands one to CORE — `PatternMiner.jl` and `core_match_bind` both consume it — so the type
# is PUBLIC CONTRACT. A drop-in keeps every one of those compiling and behaving while the
# representation moves underneath.
#
# 🔴 MEASURED BEFORE ADOPTING, because upstream's justification is a measurement and theirs is not
# ours. Binding counts observed through the query callback on 2026-08-20: clique4 (K40) 91 390
# matches, EVERY ONE with exactly 4 bindings; 3-chain 4; 2-chain 3; single factor 2. Max 4, against
# upstream's observed 0-8. The premise holds with margin.
# ═════════════════════════════════════════════════════════════════════════════════════════════════

"""
    Bindings

Variable bindings as a slab indexed by `(source_id << 6) | var_index`, with a `touched` list giving
iteration order and length. A drop-in for `Dict{ExprVar,ExprEnv}`.

`touched` holds 0-BASED slot indices. `length` is `length(touched)`, so it stays O(1) and cannot
drift from the slab: every occupied slot is in the list exactly once, which the `setindex!`/`delete!`
pair maintains.
"""
mutable struct Bindings <: AbstractDict{ExprVar, ExprEnv}
    slots::Vector{Union{Nothing, ExprEnv}}
    touched::Vector{Int}
end

Bindings() = Bindings(Union{Nothing, ExprEnv}[], Int[])

"""Slot index for `k`, 0-based. `v` is masked to 6 bits — the parser caps variables at 63."""
@inline _bind_idx(k::ExprVar)::Int = (Int(k[1]) << 6) | (Int(k[2]) & 63)

@inline _bind_key(i::Int)::ExprVar = (UInt8(i >> 6), UInt8(i & 63))

@inline function Base.get(b::Bindings, k::ExprVar, default)
    i = _bind_idx(k) + 1
    (i <= length(b.slots) && b.slots[i] !== nothing) ? b.slots[i]::ExprEnv : default
end

@inline Base.haskey(b::Bindings, k::ExprVar)::Bool = begin
    i = _bind_idx(k) + 1
    i <= length(b.slots) && b.slots[i] !== nothing
end

function Base.getindex(b::Bindings, k::ExprVar)::ExprEnv
    v = get(b, k, nothing)
    v === nothing && throw(KeyError(k))
    v::ExprEnv
end

function Base.setindex!(b::Bindings, v::ExprEnv, k::ExprVar)
    i = _bind_idx(k) + 1
    # Grow by a namespace at a time, as upstream does (`resize(i + 64, None)`) — a source id in a
    # join touches 64 consecutive slots, so this amortizes to one growth per namespace.
    if i > length(b.slots)
        # ⚠️ `resize!` LEAVES THE NEW ENTRIES UNDEFINED for a non-isbits element type (`ExprEnv`
        # holds a `Vector`), so they must be written before anything reads them. Reading an
        # undefined slot is not `nothing` — it throws, or worse.
        old_len = length(b.slots)
        resize!(b.slots, i + 63)
        for j in (old_len + 1):length(b.slots)
            b.slots[j] = nothing
        end
    end
    prev = b.slots[i]
    b.slots[i] = v
    prev === nothing && push!(b.touched, i - 1)   # occupied exactly once in `touched`
    v
end

function Base.delete!(b::Bindings, k::ExprVar)
    i = _bind_idx(k) + 1
    if i <= length(b.slots) && b.slots[i] !== nothing
        b.slots[i] = nothing
        # ⚠️ SCAN FROM THE BACK. Upstream: "The join removes by trail unwinding, newest first, so the
        # scan from the back is usually one step." Order is not depended on, so the found entry is
        # swap-removed rather than shifted.
        z = i - 1
        for p in length(b.touched):-1:1
            if b.touched[p] == z
                b.touched[p] = b.touched[end]
                pop!(b.touched)
                break
            end
        end
    end
    b
end

Base.length(b::Bindings)::Int = length(b.touched)
Base.isempty(b::Bindings)::Bool = isempty(b.touched)

function Base.empty!(b::Bindings)
    for z in b.touched
        b.slots[z + 1] = nothing
    end   # only the occupied ones
    empty!(b.touched)
    b
end

function Base.iterate(b::Bindings, state::Int=1)
    state > length(b.touched) && return nothing
    z = b.touched[state]
    (_bind_key(z) => b.slots[z + 1]::ExprEnv, state + 1)
end

"""Copy: one allocation and one memcpy per vector. `ExprEnv` is immutable, so values are shared."""
Base.copy(b::Bindings) = Bindings(copy(b.slots), copy(b.touched))

"""Sub-expression at current offset."""
function ee_subsexpr(ee::ExprEnv)
    Expr(view(ee.base.buf, (Int(ee.offset) + 1):length(ee.base.buf)))
end

"""Variable at current position, or nothing."""
function ee_var_opt(ee::ExprEnv)::Union{Nothing, ExprVar}
    tag = byte_item(ee.base.buf[Int(ee.offset) + 1])
    if tag isa ExprNewVar

        return (ee.n, ee.v)
    elseif tag isa ExprVarRef

        return (ee.n, tag.idx)
    else

        return nothing
    end
end

"""Advance offset past the current expression item."""
function ee_offset(ee::ExprEnv, delta::Integer)
    ExprEnv(ee.n, ee.v, ee.offset + UInt32(delta), ee.base)
end

# =====================================================================
# OwnedSourceItem — owned path key for interning
# =====================================================================

"""
    OwnedSourceItem

Owned byte-string key used as a HashMap key in the interning system.
Mirrors `OwnedSourceItem` in mork_expr.
"""
struct OwnedSourceItem
    bytes::Vector{UInt8}
end

OwnedSourceItem(s::AbstractString) = OwnedSourceItem(collect(UInt8, s))
OwnedSourceItem(b::AbstractVector{UInt8}) = OwnedSourceItem(Vector{UInt8}(b))

Base.:(==)(a::OwnedSourceItem, b::OwnedSourceItem) = a.bytes == b.bytes
Base.hash(a::OwnedSourceItem, h::UInt) = hash(a.bytes, h)

# =====================================================================
# ExtractFailure — expression extraction error enum
# =====================================================================

"""
    ExtractFailure

Reasons an expression extraction (pattern match / destructure) can fail.
Mirrors `ExtractFailure` in mork_expr.
"""
@enum ExtractFailureKind begin
    EF_INTRODUCED_VAR
    EF_RECURRENT_VAR
    EF_REF_MISMATCH
    EF_REF_SYMBOL_EARLY_MISMATCH
    EF_REF_SYMBOL_MISMATCH
    EF_REF_TYPE_MISMATCH
    EF_REF_EXPR_EARLY_MISMATCH
    EF_REF_EXPR_MISMATCH
    EF_EXPR_EARLY_MISMATCH
    EF_SYMBOL_EARLY_MISMATCH
    EF_SYMBOL_MISMATCH
    EF_TYPE_MISMATCH
end

struct ExtractFailure
    kind::ExtractFailureKind
    a::UInt8
    b::UInt8
    sym_a::Vector{UInt8}
    sym_b::Vector{UInt8}
    tag_a::Union{Nothing, ExprTag}
    tag_b::Union{Nothing, ExprTag}
    # `idx` added 2026-07-31 when `expr_extract_data` (ExprAlg.jl) became this type's FIRST consumer.
    # The five `Ref*` variants carry a bound-variable index IN ADDITION to their two payload values —
    # e.g. upstream `RefSymbolEarlyMismatch(u8, u8, u8)` is (index, size, bound_size) — and `a`/`b`
    # alone cannot hold three. Defaults to 0 for the variants that do not use it.
    idx::UInt8
end

# NOTE: there is deliberately NO 1-arg positional `ExtractFailure(k)` here. Julia does not dispatch
# on keyword arguments, so it would share a signature with the keyword form below and precompilation
# fails with "Method definition ... overwritten". The keyword form covers `ExtractFailure(k)`.
ExtractFailure(k::ExtractFailureKind, a::UInt8) =
    ExtractFailure(k, a, 0x00, UInt8[], UInt8[], nothing, nothing, 0x00)
ExtractFailure(k::ExtractFailureKind, a::UInt8, b::UInt8) =
    ExtractFailure(k, a, b, UInt8[], UInt8[], nothing, nothing, 0x00)

"Keyword form — only the fields a variant actually carries need naming."
ExtractFailure(k::ExtractFailureKind; a=0x00, b=0x00, sym_a=UInt8[], sym_b=UInt8[],
    tag_a=nothing, tag_b=nothing, idx=0x00) =
    ExtractFailure(k, UInt8(a), UInt8(b), sym_a, sym_b, tag_a, tag_b, UInt8(idx))

# =====================================================================
# expr_parse_str — compile-time-style string → Expr bytes
# =====================================================================

"""
    expr_parse_str(s) → Expr

Parse a text-format expression string (e.g. `"[2] foo \$"`) into flat byte
encoding.  Mirrors `mork_expr::parse::<N>` const fn (the compile-time parser).

Syntax:
  - `[N]`  → Arity(N)
  - `\$`   → NewVar
  - `_N`   → VarRef(N-1)
  - `word` → Symbol(word)
"""
function expr_parse_str(s::AbstractString)::MORK.Expr
    out = UInt8[]
    i = 1
    n = length(s)
    while i <= n
        # skip spaces
        while i <= n && s[i] == ' '

            i += 1
        end
        i > n && break
        c = s[i]
        if c == '['
            i += 1
            num = UInt8(0)
            while i <= n && isdigit(s[i])
                num = num * 10 + UInt8(s[i] - '0')
                i += 1
            end
            i <= n && s[i] == ']' && (i += 1)
            push!(out, item_byte(ExprArity(num)))
        elseif c == '$'
            i += 1
            push!(out, item_byte(ExprNewVar()))
        elseif c == '_'
            i += 1
            num = UInt8(0)
            while i <= n && isdigit(s[i])
                num = num * 10 + UInt8(s[i] - '0')
                i += 1
            end
            push!(out, item_byte(ExprVarRef(num > 0 ? num - UInt8(1) : UInt8(0))))
        else
            # symbol: read until space
            start = i
            while i <= n && s[i] != ' '
                i += 1
            end
            sym_bytes = Vector{UInt8}(s[start:(i - 1)])
            n_sym = UInt8(length(sym_bytes))
            push!(out, item_byte(ExprSymbol(n_sym)))
            append!(out, sym_bytes)
        end
    end
    MORK.Expr(out)
end

# _derive_prefix — constant prefix of expr up to first NewVar / VarRef.
# Used by `space_metta_calculus_at!` in Space.jl and by HTTP command
# handlers in MorkServer. Originally lived in mork/server/src/commands.rs;
# moved here on 2026-05-30 because it's a pure-Expr byte utility (no
# server state, no HTTP) and the kernel's `space_metta_calculus_at!`
# calls it directly. Keeping it in MorkServer would have made the
# kernel depend on the server layer.
#
# Examples: "a" → full; "(isa)" → full; "(isa $x $y)" → [Arity3, "isa"];
# "$x" → []. Mirrors upstream `derive_prefix_from_expr_slice` +
# `till_constant_to_full` (upstream 83d1276).
function _derive_prefix(expr::Expr)::Vector{UInt8}
    buf = expr.buf
    n = length(buf)
    i = 1
    while i <= n
        b = buf[i]
        tag = byte_item(b)
        if tag isa ExprNewVar || tag isa ExprVarRef
            break
        elseif tag isa ExprSymbol
            i += 1 + Int(tag.size)
        elseif tag isa ExprArity
            i += 1
        else
            break
        end
    end
    buf[1:(i - 1)]
end

# =====================================================================
# Exports
# =====================================================================

export ExprTag, ExprNewVar, ExprVarRef, ExprSymbol, ExprArity
export item_byte, byte_item, _derive_prefix
export Expr, expr_tag_at, expr_span, expr_serialize
export expr_serialize2, expr_serialize_highlight, expr_varname, EXPR_VARNAMES
export ez_traverse
export ExprZipper, ez_tag, ez_item, ez_next!, ez_span, ez_symbol
export Breadcrumb, ez_gnext!, ez_next_skip!, ez_parent!, ez_next_child!, ez_next_descendant!
export ez_ensure!, ez_write_new_var!, ez_write_var_ref!, ez_write_arity!
export ez_patch_arity!, ez_write_symbol!, ez_write_move!, ez_finish_span
export ExprEnv, ExprVar, ee_subsexpr, ee_var_opt, ee_offset
export OwnedSourceItem
export ExtractFailureKind, EF_INTRODUCED_VAR, EF_RECURRENT_VAR, EF_REF_MISMATCH
export EF_REF_SYMBOL_EARLY_MISMATCH, EF_REF_SYMBOL_MISMATCH, EF_REF_TYPE_MISMATCH
export EF_REF_EXPR_EARLY_MISMATCH, EF_REF_EXPR_MISMATCH, EF_EXPR_EARLY_MISMATCH
export EF_SYMBOL_EARLY_MISMATCH, EF_SYMBOL_MISMATCH, EF_TYPE_MISMATCH
export ExtractFailure, expr_parse_str

export maybe_byte_item, ez_tag_str, ez_item_str, expr_compute_length
