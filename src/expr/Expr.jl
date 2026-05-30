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

struct ExprNewVar  <: ExprTag end
struct ExprVarRef  <: ExprTag; idx::UInt8 end   # 0-based back-reference
struct ExprSymbol  <: ExprTag; size::UInt8 end   # 1..63 bytes follow
struct ExprArity   <: ExprTag; arity::UInt8 end  # 0..63 children follow

"""
    item_byte(tag::ExprTag) → UInt8

Encode an ExprTag as a single byte.  Mirrors `item_byte` in mork_expr.
"""
function item_byte(tag::ExprTag) :: UInt8
    if tag isa ExprNewVar;  return 0b11000000
    elseif tag isa ExprVarRef;   return 0b10000000 | (tag.idx & 0x3f)
    elseif tag isa ExprSymbol;   return 0b11000000 | (tag.size & 0x3f)
    elseif tag isa ExprArity;    return 0b00000000 | (tag.arity & 0x3f)
    else; error("Unknown ExprTag"); end
end

"""
    byte_item(b::UInt8) → ExprTag

Decode a byte into an ExprTag.  Mirrors `byte_item` in mork_expr.
"""
function byte_item(b::UInt8) :: ExprTag
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
function expr_span(e::Expr, offset::Int=1)
    i = offset
    depth = 0
    while i <= length(e.buf)
        tag = byte_item(e.buf[i])
        if tag isa ExprSymbol
            i += 1 + Int(tag.size)
            depth == 0 && return view(e.buf, offset:i-1)
        elseif tag isa ExprArity
            i += 1
            tag.arity == 0 && depth == 0 && return view(e.buf, offset:i-1)
            depth += Int(tag.arity)
        else  # NewVar or VarRef — leaf
            i += 1
            depth == 0 && return view(e.buf, offset:i-1)
        end
        depth == 0 && return view(e.buf, offset:i-1)
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
    root ::Expr
    loc  ::Int       # current byte offset (1-based)
end

ExprZipper(e::Expr) = ExprZipper(e, 1)
ExprZipper(bytes::Vector{UInt8}) = ExprZipper(Expr(bytes), 1)

"""Current tag at the zipper's position."""
ez_tag(z::ExprZipper) = expr_tag_at(z.root, z.loc)

"""Current raw byte at the zipper's position."""
ez_item(z::ExprZipper) = z.root.buf[z.loc]

"""Advance the zipper past the current leaf/expression. Returns false if done."""
function ez_next!(z::ExprZipper) :: Bool
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

"""Symbol bytes at current position (only valid if tag is ExprSymbol)."""
function ez_symbol(z::ExprZipper)
    tag = byte_item(z.root.buf[z.loc])
    tag isa ExprSymbol || return UInt8[]
    view(z.root.buf, z.loc+1 : z.loc + Int(tag.size))
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
ez_finish_span(z::ExprZipper) = view(z.root.buf, 1:z.loc-1)

# =====================================================================
# serialize — bytes → human-readable string
# =====================================================================

"""
    expr_serialize(bytes) → String

Convert a flat byte-encoded expression to a human-readable s-expression string.
Mirrors `SerializerTraversal` in mork_expr (produces parenthesized s-expressions).
"""
function expr_serialize(bytes::AbstractVector{UInt8}) :: String
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
            for j in i:min(i+n-1, length(bytes))
                cb = bytes[j]
                (isprint(Char(cb)) && cb != UInt8('\\')) ?
                    write(io, Char(cb)) : write(io, "\\x$(string(cb, base=16, pad=2))")
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
    n      ::UInt8   # source id (0, 1, ...)
    v      ::UInt8   # next free var index
    offset ::UInt32  # byte offset into base
    base   ::Expr    # backing expression
end

ExprEnv(n::Integer, base::Expr) = ExprEnv(UInt8(n), UInt8(0), UInt32(0), base)
ExprEnv(n::Integer, base::Vector{UInt8}) = ExprEnv(n, Expr(base))

"""Sub-expression at current offset."""
function ee_subsexpr(ee::ExprEnv)
    Expr(view(ee.base.buf, Int(ee.offset)+1:length(ee.base.buf)))
end

"""Variable at current position, or nothing."""
function ee_var_opt(ee::ExprEnv) :: Union{Nothing, ExprVar}
    tag = byte_item(ee.base.buf[Int(ee.offset)+1])
    if tag isa ExprNewVar;  return (ee.n, ee.v)
    elseif tag isa ExprVarRef; return (ee.n, tag.idx)
    else; return nothing; end
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
    kind ::ExtractFailureKind
    a    ::UInt8
    b    ::UInt8
    sym_a::Vector{UInt8}
    sym_b::Vector{UInt8}
    tag_a::Union{Nothing, ExprTag}
    tag_b::Union{Nothing, ExprTag}
end

ExtractFailure(k::ExtractFailureKind) =
    ExtractFailure(k, 0x00, 0x00, UInt8[], UInt8[], nothing, nothing)
ExtractFailure(k::ExtractFailureKind, a::UInt8) =
    ExtractFailure(k, a, 0x00, UInt8[], UInt8[], nothing, nothing)
ExtractFailure(k::ExtractFailureKind, a::UInt8, b::UInt8) =
    ExtractFailure(k, a, b, UInt8[], UInt8[], nothing, nothing)

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
function expr_parse_str(s::AbstractString) :: MORK.Expr
    out = UInt8[]
    i   = 1
    n   = length(s)
    while i <= n
        # skip spaces
        while i <= n && s[i] == ' '; i += 1; end
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
            sym_bytes = Vector{UInt8}(s[start:i-1])
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
function _derive_prefix(expr::Expr) :: Vector{UInt8}
    buf = expr.buf
    n   = length(buf)
    i = 1
    while i <= n
        b   = buf[i]
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
    buf[1:i-1]
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
