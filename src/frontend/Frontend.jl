"""
Frontend — port of `mork/frontend/src/bytestring_parser.rs`
                  + `mork/frontend/src/json_parser.rs`.

Two parsers that produce flat byte-encoded expressions via ExprZipper:

1. `sexpr_parse` — MeTTa-style s-expression parser (bytestring_parser.rs).
2. `json_parse`  — JSON → Transcriber event-driven parser (json_parser.rs).

Julia translation notes
========================
  - Rust `Parser` trait with `tokenizer` callback →
    Julia abstract type `MorkParser` with `fe_tokenizer` method.
  - Rust `context.loc` raw pointer arithmetic → safe indexing on `Vector{UInt8}`.
  - Rust `parse_stream` (coroutines / nightly) → NOT ported (nightly-only feature).
  - Rust `unsafe str::from_utf8_unchecked` → Julia `String(bytes)` (safe).
  - Rust macro `expect_byte!` / `expect_string!` etc. → inlined Julia functions.
"""

# =====================================================================
# ── Part 1: bytestring_parser (MeTTa sexpr) ──────────────────────────
# =====================================================================

# ── Error types ──────────────────────────────────────────────────────

"""
    SexprError

Parse errors from `sexpr_parse`.  Mirrors `ParserError` in bytestring_parser.rs.
"""
@enum SexprError begin
    SERR_TOO_MANY_VARS
    SERR_UNEXPECTED_EOF
    SERR_INPUT_FINISHED
    SERR_NOT_ARITY
    SERR_UNEXPECTED_RIGHT_BRACKET
    SERR_UNFINISHED_ESCAPE
end

struct SexprException <: Exception
    err::SexprError
end
Base.showerror(io::IO, e::SexprException) = print(io, "SexprError: ", e.err)

# ── Context ───────────────────────────────────────────────────────────

"""
    SexprContext

Parsing cursor + variable binding table.
Mirrors `Context<'a>` in bytestring_parser.rs.
"""
mutable struct SexprContext
    src::Vector{UInt8}
    loc::Int              # 1-based current position
    variables::Vector{UnitRange{Int}}   # ranges into src for each seen variable
end

SexprContext(src::Vector{UInt8}) = SexprContext(src, 1, UnitRange{Int}[])
SexprContext(s::AbstractString) = SexprContext(Vector{UInt8}(s))

@inline _ctx_has_next(ctx::SexprContext) = ctx.loc <= length(ctx.src)

@inline function _ctx_peek(ctx::SexprContext)::UInt8
    _ctx_has_next(ctx) || throw(SexprException(SERR_UNEXPECTED_EOF))
    ctx.src[ctx.loc]
end

@inline function _ctx_next!(ctx::SexprContext)::UInt8
    _ctx_has_next(ctx) || throw(SexprException(SERR_UNEXPECTED_EOF))
    b = ctx.src[ctx.loc]
    ctx.loc += 1
    b
end

"""Return the 0-based back-reference index if `var_bytes` seen before; else add and return nothing."""
function _ctx_get_or_put!(ctx::SexprContext, range::UnitRange{Int})::Union{Nothing, UInt8}
    var_bytes = ctx.src[range]
    for (i, vr) in enumerate(ctx.variables)
        ctx.src[vr] == var_bytes && return UInt8(i - 1)
    end
    length(ctx.variables) < 64 || throw(SexprException(SERR_TOO_MANY_VARS))
    push!(ctx.variables, range)
    nothing
end

@inline _is_whitespace(c::UInt8) = c == UInt8(' ') || c == UInt8('\t') || c == UInt8('\n')

# ── MorkParser trait ──────────────────────────────────────────────────

"""
    MorkParser

Abstract type whose subtypes implement `fe_tokenizer(parser, bytes) → Vector{UInt8}`.
Mirrors the `Parser` trait in bytestring_parser.rs.
"""
abstract type MorkParser end

"""
    fe_tokenizer(parser, bytes) → Vector{UInt8}

Transform symbol bytes before encoding (e.g. interning, lowercasing).
Override in concrete subtypes.  Default: identity.
"""
fe_tokenizer(::MorkParser, bytes::AbstractVector{UInt8}) = bytes

# ── sexpr_parse! — main recursive parse ──────────────────────────────

"""
    sexpr_parse!(parser, ctx, target)

Parse one s-expression from `ctx` into `target::ExprZipper`.
Mirrors `Parser::sexpr` in bytestring_parser.rs.
Throws `SexprException` on error.
"""
function sexpr_parse!(parser::MorkParser, ctx::SexprContext, target::ExprZipper)
    while _ctx_has_next(ctx)
        c = _ctx_peek(ctx)

        if c == UInt8(';')
            # comment: skip to end of line
            while _ctx_has_next(ctx) && _ctx_next!(ctx) != UInt8('\n')
                ;
            end
            continue

        elseif _is_whitespace(c)
            _ctx_next!(ctx)
            continue

        elseif c == UInt8('$')
            # Variable: $name
            start = ctx.loc
            _ctx_next!(ctx)   # consume '$'
            id_start = ctx.loc
            while _ctx_has_next(ctx)
                p = _ctx_peek(ctx)
                (p == UInt8('(') || p == UInt8(')') || _is_whitespace(p)) && break
                _ctx_next!(ctx)
            end
            id_range = id_start:(ctx.loc - 1)
            ref_idx = _ctx_get_or_put!(ctx, id_range)
            if ref_idx === nothing
                ez_write_new_var!(target)
            else
                ez_write_var_ref!(target, ref_idx)
            end
            return nothing

        elseif c == UInt8('(')
            # Compound expression: (child1 child2 ...)
            arity_loc = target.loc
            ez_write_arity!(target, UInt8(0))   # placeholder arity
            _ctx_next!(ctx)   # consume '('
            arity_count = 0
            while true
                _ctx_has_next(ctx) || throw(SexprException(SERR_UNEXPECTED_EOF))
                p = _ctx_peek(ctx)
                p == UInt8(')') && break
                if _is_whitespace(p)
                    _ctx_next!(ctx)
                    continue
                end
                sexpr_parse!(parser, ctx, target)
                arity_count += 1
            end
            _ctx_next!(ctx)   # consume ')'
            # Backpatch the arity
            ez_patch_arity!(target, arity_loc, UInt8(arity_count))
            return nothing

        elseif c == UInt8(')')
            throw(SexprException(SERR_UNEXPECTED_RIGHT_BRACKET))

        else
            # Symbol: either "quoted" or unquoted token
            start = ctx.loc
            if _ctx_has_next(ctx) && _ctx_peek(ctx) == UInt8('"')
                _ctx_next!(ctx)   # consume opening "
                while _ctx_has_next(ctx)
                    b = _ctx_next!(ctx)
                    b == UInt8('"') && break
                    if b == UInt8('\\')
                        _ctx_has_next(ctx) || throw(SexprException(SERR_UNFINISHED_ESCAPE))
                        _ctx_next!(ctx)
                    end
                end
                sym_bytes_raw = view(ctx.src, start:(ctx.loc - 1))
                # Guarantee double-quote terminator on truncation (mirrors bytestring_parser.rs 2d6730b).
                # Symbols are capped at 63 bytes by the tag encoding (6-bit size field).
                sym_bytes = if length(sym_bytes_raw) > 63
                    tmp = Vector{UInt8}(sym_bytes_raw[1:63])
                    tmp[63] = UInt8('"')
                    tmp
                else
                    sym_bytes_raw
                end
                tok = fe_tokenizer(parser, sym_bytes)
                ez_write_symbol!(target, tok)
                return nothing
            else
                while _ctx_has_next(ctx)
                    p = _ctx_peek(ctx)
                    (p == UInt8('(') || p == UInt8(')') || _is_whitespace(p)) && break
                    _ctx_next!(ctx)
                end
            end
            sym_bytes = view(ctx.src, start:(ctx.loc - 1))
            tok = fe_tokenizer(parser, sym_bytes)
            ez_write_symbol!(target, tok)
            return nothing
        end
    end
    throw(SexprException(SERR_INPUT_FINISHED))
end

# ── Convenience: parse a string into Expr ─────────────────────────────

"""
    DefaultParser

Identity-tokenizer concrete MorkParser — symbols stored as-is.
"""
struct DefaultParser <: MorkParser end

"""
    sexpr_to_expr(src) → Expr

Parse a MeTTa s-expression string/bytes into a flat-byte `Expr`.
Uses `DefaultParser` (identity tokenizer).
"""
function sexpr_to_expr(src)::MORK.Expr
    bv = src isa Vector{UInt8} ? src : Vector{UInt8}(src)
    ctx = SexprContext(bv)
    buf = Vector{UInt8}(undef, max(length(bv) * 2, 64))
    z = ExprZipper(MORK.Expr(buf), 1)
    sexpr_parse!(DefaultParser(), ctx, z)
    MORK.Expr(z.root.buf[1:(z.loc - 1)])
end

# =====================================================================
# ── Part 2: json_parser (JSON → Transcriber) ─────────────────────────
# =====================================================================

# ── JSON error type ───────────────────────────────────────────────────

"""
    JSONError

Parse error from `json_parse`.  Mirrors `Error` in json_parser.rs.
"""
# `Error::wrong_type` (json_parser.rs:25) is NOT ported as a named constructor, and does not need to
# be: `JSONError(:wrong_type, expected)` expresses it through the generic 2-arg constructor below.
# Upstream never CONSTRUCTS it either — `WrongType` appears only in its own definition and in the
# Display/description arms, and both it and the constructor carry `#[allow(unused)]`.
struct JSONError <: Exception
    kind::Symbol    # :unexpected_char, :unexpected_eof, :depth_limit, :bad_utf8
    ch::Char
    line::Int
    column::Int
    message::String
end

JSONError(kind::Symbol, msg::String) = JSONError(kind, '\0', 0, 0, msg)

function Base.showerror(io::IO, e::JSONError)
    if e.kind === :unexpected_char
        print(io, "JSONError: unexpected '$(e.ch)' at $(e.line):$(e.column)")
    else
        print(io, "JSONError($(e.kind)): $(e.message)")
    end
end

const JSON_MAX_PRECISION = UInt64(576460752303423500)
const JSON_DEPTH_LIMIT = 512

# Character allow-table: true = allowed in raw string content
# control chars (0x00..0x1F), '"' (0x22) and '\' (0x5C) are NOT allowed
const _JSON_ALLOWED = Bool[
    let c = UInt8(i-1)
        !(c < 0x20 || c == UInt8('"') || c == UInt8('\\'))
    end for i in 1:256
]

# ── Transcriber abstract type ─────────────────────────────────────────

"""
    JSONTranscriber

Abstract type for handling JSON parse events.
Mirrors `Transcriber` in json_parser.rs.
Concrete subtypes implement the `jt_*` methods below.
"""
abstract type JSONTranscriber end

jt_begin!(t::JSONTranscriber) = nothing
jt_end!(t::JSONTranscriber) = nothing
jt_descend_index!(t::JSONTranscriber, i::Int, first::Bool) = nothing
jt_ascend_index!(t::JSONTranscriber, i::Int, last::Bool) = nothing
jt_write_empty_array!(t::JSONTranscriber) = nothing
jt_descend_key!(t::JSONTranscriber, k::String, first::Bool) = nothing
jt_ascend_key!(t::JSONTranscriber, k::String, last::Bool) = nothing
jt_write_empty_object!(t::JSONTranscriber) = nothing
jt_write_string!(t::JSONTranscriber, s::String) = nothing
jt_write_number!(t::JSONTranscriber, neg::Bool, mantissa::UInt64, exp::Int16) = nothing
jt_write_true!(t::JSONTranscriber) = nothing
jt_write_false!(t::JSONTranscriber) = nothing
jt_write_null!(t::JSONTranscriber) = nothing

# ── JSONParser struct ─────────────────────────────────────────────────

"""
    JSONParser

State for iterating over a JSON byte source.
Mirrors `Parser<'a>` in json_parser.rs.
"""
mutable struct JSONParser
    source::Vector{UInt8}
    buffer::Vector{UInt8}   # scratch for escaped strings
    index::Int             # 1-based current position
end

JSONParser(src::AbstractString) = JSONParser(Vector{UInt8}(src), UInt8[], 1)
JSONParser(src::AbstractVector{UInt8}) = JSONParser(Vector{UInt8}(src), UInt8[], 1)

@inline _jp_eof(p::JSONParser) = p.index > length(p.source)
@inline _jp_read(p::JSONParser)::UInt8 = p.source[p.index]
@inline _jp_bump!(p::JSONParser) = (p.index += 1; nothing)

function _jp_unexpected!(p::JSONParser)
    at = p.index - 1
    ch_byte = at >= 1 ? p.source[at] : UInt8(' ')
    ch = Char(ch_byte)
    src_str = String(copy(p.source))
    prefix = src_str[1:min(at, length(src_str))]
    lines = split(prefix, '\n')
    lineno = length(lines)
    col = length(lines[end])
    throw(JSONError(:unexpected_char, ch, lineno, col, ""))
end

function _jp_expect_byte!(p::JSONParser)::UInt8
    _jp_eof(p) && throw(JSONError(:unexpected_eof, "Unexpected end of JSON"))
    b = _jp_read(p)
    _jp_bump!(p)
    b
end

function _jp_expect_byte_skip_ws!(p::JSONParser)::UInt8
    ch = _jp_expect_byte!(p)
    while ch in (0x09:0x0D..., UInt8(' '))
        _jp_eof(p) && throw(JSONError(:unexpected_eof, "Unexpected end of JSON"))
        ch = _jp_expect_byte!(p)
    end
    ch
end

function _jp_read_hexdec_digit!(p::JSONParser)::UInt16
    ch = _jp_expect_byte!(p)
    if UInt8('0') <= ch <= UInt8('9')
        ;
        return UInt16(ch - UInt8('0'))
    elseif UInt8('a') <= ch <= UInt8('f')
        ;
        return UInt16(ch - UInt8('a') + 10)
    elseif UInt8('A') <= ch <= UInt8('F')
        ;
        return UInt16(ch - UInt8('A') + 10)
    else
        _jp_unexpected!(p);
        return UInt16(0)
    end
end

function _jp_read_hex4!(p::JSONParser)::UInt16
    (_jp_read_hexdec_digit!(p) << 12) |
    (_jp_read_hexdec_digit!(p) << 8) |
    (_jp_read_hexdec_digit!(p) << 4) |
    _jp_read_hexdec_digit!(p)
end

function _jp_read_codepoint!(p::JSONParser)
    cp = _jp_read_hex4!(p)
    if cp >= 0xD800 && cp <= 0xDBFF
        # surrogate pair
        b1 = _jp_expect_byte!(p);
        b1 == UInt8('\\') || _jp_unexpected!(p)
        b2 = _jp_expect_byte!(p);
        b2 == UInt8('u') || _jp_unexpected!(p)
        low = _jp_read_hex4!(p)
        full = 0x10000 + (UInt32(cp - 0xD800) << 10) + UInt32(low - 0xDC00)
        append!(p.buffer, Vector{UInt8}(string(Char(full))))
    else
        ch = Char(UInt32(cp))
        append!(p.buffer, Vector{UInt8}(string(ch)))
    end
end

function _jp_read_complex_string!(p::JSONParser, start::Int)::String
    buf_start = length(p.buffer)
    append!(p.buffer, p.source[start:(p.index - 2)])   # bytes before the '\'
    ch = UInt8('\\')
    while true
        if _JSON_ALLOWED[Int(ch) + 1]
            push!(p.buffer, ch)
            ch = _jp_expect_byte!(p)
            continue
        end
        if ch == UInt8('"')
            ;
            break;
        end
        if ch == UInt8('\\')
            esc = _jp_expect_byte!(p)
            if esc == UInt8('u')
                _jp_read_codepoint!(p)
            elseif esc == UInt8('"') || esc == UInt8('\\') || esc == UInt8('/')
                push!(p.buffer, esc)
            elseif esc == UInt8('b')
                ;
                push!(p.buffer, 0x08)
            elseif esc == UInt8('f')
                ;
                push!(p.buffer, 0x0C)
            elseif esc == UInt8('t')
                ;
                push!(p.buffer, UInt8('\t'))
            elseif esc == UInt8('r')
                ;
                push!(p.buffer, UInt8('\r'))
            elseif esc == UInt8('n')
                ;
                push!(p.buffer, UInt8('\n'))
            else
                _jp_unexpected!(p)
            end
        else
            _jp_unexpected!(p)
        end
        ch = _jp_expect_byte!(p)
    end
    String(p.buffer[(buf_start + 1):end])
end

function _jp_expect_string!(p::JSONParser)::String
    start = p.index
    while true
        ch = _jp_expect_byte!(p)
        _JSON_ALLOWED[Int(ch) + 1] && continue
        ch == UInt8('"') && return String(p.source[start:(p.index - 2)])
        ch == UInt8('\\') && return _jp_read_complex_string!(p, start)
        _jp_unexpected!(p)
    end
end

function _jp_expect_exponent!(p::JSONParser, exp::Ref{Int16})
    ch = _jp_expect_byte!(p)
    sign = Int16(1)
    if ch == UInt8('-')
        ;
        sign = Int16(-1);
        ch = _jp_expect_byte!(p)
    elseif ch == UInt8('+')
        ;
        ch = _jp_expect_byte!(p)
    end
    UInt8('0') <= ch <= UInt8('9') || _jp_unexpected!(p)
    e = Int16(ch - UInt8('0'))
    while !_jp_eof(p)
        c = _jp_read(p)
        UInt8('0') <= c <= UInt8('9') || break
        _jp_bump!(p)
        e = Int16(clamp(Int(e)*10 + Int(c - UInt8('0')), typemin(Int16), typemax(Int16)))
    end
    exp[] = Int16(clamp(Int(exp[]) + Int(e * sign), typemin(Int16), typemax(Int16)))
end

function _jp_read_number!(p::JSONParser, first::UInt8)::Tuple{UInt64, Int16}
    mantissa = UInt64(first - UInt8('0'))
    exponent = Int16(0)
    while true
        if mantissa >= JSON_MAX_PRECISION
            # big-number path: just keep incrementing exponent
            while !_jp_eof(p)
                c = _jp_read(p)
                if UInt8('0') <= c <= UInt8('9')
                    _jp_bump!(p)
                    m2 = mantissa * UInt64(10)
                    if m2 < mantissa
                        ;
                        exponent += Int16(1)   # overflow
                    else
                        ;
                        mantissa = m2 + UInt64(c - UInt8('0'));
                    end
                elseif c == UInt8('.')
                    _jp_bump!(p)
                    _jp_expect_fraction_update!(p, mantissa, exponent)
                    break
                elseif c == UInt8('e') || c == UInt8('E')
                    _jp_bump!(p)
                    eref = Ref{Int16}(exponent)
                    _jp_expect_exponent!(p, eref)
                    exponent = eref[]
                else
                    break
                end
            end
            break
        end
        _jp_eof(p) && break
        c = _jp_read(p)
        if UInt8('0') <= c <= UInt8('9')
            _jp_bump!(p)
            mantissa = mantissa * UInt64(10) + UInt64(c - UInt8('0'))
        elseif c == UInt8('.')
            _jp_bump!(p)
            d = _jp_expect_byte!(p)
            UInt8('0') <= d <= UInt8('9') || _jp_unexpected!(p)
            if mantissa < JSON_MAX_PRECISION
                mantissa = mantissa * UInt64(10) + UInt64(d - UInt8('0'))
                exponent -= Int16(1)
            end
            while !_jp_eof(p)
                c2 = _jp_read(p)
                if UInt8('0') <= c2 <= UInt8('9')
                    _jp_bump!(p)
                    if mantissa < JSON_MAX_PRECISION
                        m2 = mantissa * UInt64(10) + UInt64(c2 - UInt8('0'))
                        if m2 >= mantissa
                            mantissa = m2;
                            exponent -= Int16(1)
                        end
                    end
                elseif c2 == UInt8('e') || c2 == UInt8('E')
                    _jp_bump!(p)
                    eref = Ref{Int16}(exponent)
                    _jp_expect_exponent!(p, eref)
                    exponent = eref[]
                    break
                else
                    break
                end
            end
            break
        elseif c == UInt8('e') || c == UInt8('E')
            _jp_bump!(p)
            eref = Ref{Int16}(exponent)
            _jp_expect_exponent!(p, eref)
            exponent = eref[]
            break
        else
            break
        end
    end
    (mantissa, exponent)
end

function _jp_expect_fraction_update!(p::JSONParser, mantissa::UInt64, exponent::Int16)
    # Just skip the fractional digits after we're past precision
    while !_jp_eof(p)
        c = _jp_read(p)
        UInt8('0') <= c <= UInt8('9') || break
        _jp_bump!(p)
    end
end

# ── StackBlock (mirrors the enum in json_parser.rs) ───────────────────

abstract type _StackBlock end
mutable struct _SBIndex <: _StackBlock
    ;
    cnt::Int;
end
mutable struct _SBKey <: _StackBlock
    ;
    key::String;
end

# ── json_parse! — main entry point ───────────────────────────────────

"""
    json_parse!(parser, transcriber)

Parse one complete JSON value from `parser`, calling `transcriber` callbacks.
Mirrors `Parser::parse` in json_parser.rs.
Throws `JSONError` on malformed input.
"""
function json_parse!(p::JSONParser, t::JSONTranscriber)
    stack = _StackBlock[]
    ch = _jp_expect_byte_skip_ws!(p)
    jt_begin!(t)

    while true
        # ── value dispatch ────────────────────────────────────────
        if ch == UInt8('[')
            ch2 = _jp_expect_byte_skip_ws!(p)
            if ch2 != UInt8(']')
                length(stack) == JSON_DEPTH_LIMIT &&
                    throw(JSONError(:depth_limit, "Exceeded depth limit"))
                jt_descend_index!(t, 0, true)
                push!(stack, _SBIndex(0))
                ch = ch2
                continue
            end
            jt_write_empty_array!(t)

        elseif ch == UInt8('{')
            ch2 = _jp_expect_byte_skip_ws!(p)
            if ch2 != UInt8('}')
                length(stack) == JSON_DEPTH_LIMIT &&
                    throw(JSONError(:depth_limit, "Exceeded depth limit"))
                ch2 == UInt8('"') || _jp_unexpected!(p)
                k = _jp_expect_string!(p)
                jt_descend_key!(t, k, true)
                # expect ':'
                colon = _jp_expect_byte_skip_ws!(p)
                colon == UInt8(':') || _jp_unexpected!(p)
                push!(stack, _SBKey(k))
                ch = _jp_expect_byte_skip_ws!(p)
                continue
            end
            jt_write_empty_object!(t)

        elseif ch == UInt8('"')
            s = _jp_expect_string!(p)
            jt_write_string!(t, s)

        elseif ch == UInt8('0')
            m, e = _jp_read_number!(p, ch)
            jt_write_number!(t, false, m, e)

        elseif UInt8('1') <= ch <= UInt8('9')
            m, e = _jp_read_number!(p, ch)
            jt_write_number!(t, false, m, e)

        elseif ch == UInt8('-')
            ch2 = _jp_expect_byte!(p)
            if ch2 == UInt8('0')
                m, e = _jp_read_number!(p, ch2)
                jt_write_number!(t, true, m, e)
            elseif UInt8('1') <= ch2 <= UInt8('9')
                m, e = _jp_read_number!(p, ch2)
                jt_write_number!(t, true, m, e)
            else
                _jp_unexpected!(p)
            end

        elseif ch == UInt8('t')
            r = _jp_expect_byte!(p);
            r == UInt8('r') || _jp_unexpected!(p)
            u = _jp_expect_byte!(p);
            u == UInt8('u') || _jp_unexpected!(p)
            e = _jp_expect_byte!(p);
            e == UInt8('e') || _jp_unexpected!(p)
            jt_write_true!(t)

        elseif ch == UInt8('f')
            a = _jp_expect_byte!(p);
            a == UInt8('a') || _jp_unexpected!(p)
            l = _jp_expect_byte!(p);
            l == UInt8('l') || _jp_unexpected!(p)
            s = _jp_expect_byte!(p);
            s == UInt8('s') || _jp_unexpected!(p)
            e = _jp_expect_byte!(p);
            e == UInt8('e') || _jp_unexpected!(p)
            jt_write_false!(t)

        elseif ch == UInt8('n')
            u = _jp_expect_byte!(p);
            u == UInt8('u') || _jp_unexpected!(p)
            l = _jp_expect_byte!(p);
            l == UInt8('l') || _jp_unexpected!(p)
            l2 = _jp_expect_byte!(p);
            l2 == UInt8('l') || _jp_unexpected!(p)
            jt_write_null!(t)

        else
            _jp_unexpected!(p)
        end

        # ── popping loop (ascend / find next sibling) ─────────────
        while true
            if isempty(stack)
                # expect whitespace then EOF
                while !_jp_eof(p)
                    c = _jp_read(p)
                    if c in (0x09:0x0D..., UInt8(' '))
                        _jp_bump!(p)
                    else
                        _jp_bump!(p)
                        _jp_unexpected!(p)
                    end
                end
                jt_end!(t)
                return nothing
            end

            top = last(stack)

            if top isa _SBIndex
                ch = _jp_expect_byte_skip_ws!(p)
                if ch == UInt8(',')
                    ch = _jp_expect_byte_skip_ws!(p)
                    jt_ascend_index!(t, top.cnt, false)
                    top.cnt += 1
                    jt_descend_index!(t, top.cnt, false)
                    break   # continue outer (value dispatch)
                elseif ch == UInt8(']')
                    jt_ascend_index!(t, top.cnt, true)
                    pop!(stack)
                    # continue popping
                else
                    _jp_unexpected!(p)
                end

            elseif top isa _SBKey
                ch = _jp_expect_byte_skip_ws!(p)
                if ch == UInt8(',')
                    jt_ascend_key!(t, top.key, false)
                    quot = _jp_expect_byte_skip_ws!(p)
                    quot == UInt8('"') || _jp_unexpected!(p)
                    k = _jp_expect_string!(p)
                    jt_descend_key!(t, k, false)
                    top.key = k
                    colon = _jp_expect_byte_skip_ws!(p)
                    colon == UInt8(':') || _jp_unexpected!(p)
                    ch = _jp_expect_byte_skip_ws!(p)
                    break   # continue outer (value dispatch)
                elseif ch == UInt8('}')
                    jt_ascend_key!(t, top.key, true)
                    pop!(stack)
                    # continue popping
                else
                    _jp_unexpected!(p)
                end
            end
        end
    end
end

# ── WriteTranscriber — reconstructs JSON text ─────────────────────────

"""
    WriteTranscriber

Concrete `JSONTranscriber` that reconstructs JSON text into an `IOBuffer`.
Mirrors `WriteTranscriber<W: Write>` in json_parser.rs.
"""
mutable struct WriteTranscriber <: JSONTranscriber
    io::IOBuffer
    WriteTranscriber() = new(IOBuffer())
end

jt_begin!(t::WriteTranscriber) = nothing
jt_end!(t::WriteTranscriber) = nothing
jt_descend_index!(t::WriteTranscriber, i::Int, first::Bool) = first && write(t.io, "[")
jt_ascend_index!(t::WriteTranscriber, i::Int, last::Bool) =
    last ? write(t.io, "]") : write(t.io, ", ")
jt_write_empty_array!(t::WriteTranscriber) = write(t.io, "[]")
jt_descend_key!(t::WriteTranscriber, k::String, first::Bool) = begin
    first && write(t.io, "{");
    write(t.io, "\"$k\": ");
end
jt_ascend_key!(t::WriteTranscriber, k::String, last::Bool) =
    last ? write(t.io, "}") : write(t.io, ", ")
jt_write_empty_object!(t::WriteTranscriber) = write(t.io, "{}")
jt_write_string!(t::WriteTranscriber, s::String) = write(t.io, "\"$s\"")
function jt_write_number!(t::WriteTranscriber, neg::Bool, m::UInt64, e::Int16)
    neg && write(t.io, "-")
    write(t.io, string(m))
    e != 0 && write(t.io, "e$(e)")
end
jt_write_true!(t::WriteTranscriber) = write(t.io, "true")
jt_write_false!(t::WriteTranscriber) = write(t.io, "false")
jt_write_null!(t::WriteTranscriber) = write(t.io, "null")
wt_result(t::WriteTranscriber) = String(take!(copy(t.io)))

# =====================================================================
# Exports
# =====================================================================

export SexprError, SexprException, SexprContext, MorkParser, DefaultParser
export fe_tokenizer, sexpr_parse!, sexpr_to_expr

export JSONTranscriber, JSONParser, JSONError
export jt_begin!, jt_end!
export jt_descend_index!, jt_ascend_index!, jt_write_empty_array!
export jt_descend_key!, jt_ascend_key!, jt_write_empty_object!
export jt_write_string!, jt_write_number!, jt_write_true!, jt_write_false!, jt_write_null!
export json_parse!
export WriteTranscriber, wt_result
