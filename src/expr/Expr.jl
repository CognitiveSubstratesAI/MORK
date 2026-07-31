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
    ;
    idx::UInt8
end   # 0-based back-reference
struct ExprSymbol <: ExprTag
    ;
    size::UInt8
end   # 1..63 bytes follow
struct ExprArity <: ExprTag
    ;
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
        ;
        error("Unknown ExprTag");
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
#     gxhash128 (-> xxh3)        MORK expr ONLY   (lib.rs:312, `Expr::hash`).  ZERO calls in PathMap.
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
# wanted, port `GxHasher` INTO PathMap. Do not relocate XXH3, and do not substitute xxh3 for it.
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
    ExprZipper

Cursor for traversing a flat byte-encoded expression.
Mirrors `ExprZipper` in mork_expr.
"""
mutable struct ExprZipper
    root::Expr
    loc::Int       # current byte offset (1-based)
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

"""Sub-expression at current offset."""
function ee_subsexpr(ee::ExprEnv)
    Expr(view(ee.base.buf, (Int(ee.offset) + 1):length(ee.base.buf)))
end

"""Variable at current position, or nothing."""
function ee_var_opt(ee::ExprEnv)::Union{Nothing, ExprVar}
    tag = byte_item(ee.base.buf[Int(ee.offset) + 1])
    if tag isa ExprNewVar
        ;
        return (ee.n, ee.v)
    elseif tag isa ExprVarRef
        ;
        return (ee.n, tag.idx)
    else
        ;
        return nothing;
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
ExtractFailure(k::ExtractFailureKind; a = 0x00, b = 0x00, sym_a = UInt8[], sym_b = UInt8[],
               tag_a = nothing, tag_b = nothing, idx = 0x00) =
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
            ;
            i += 1;
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
export ExprZipper, ez_tag, ez_item, ez_next!, ez_span, ez_symbol
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
