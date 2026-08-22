# PROVENANCE: upstream MORK `server` branch @ 2d6730b (2026-05-08) — this file's upstream source
# DOES NOT EXIST on `main`. Verified 2026-07-30: `git cat-file -e main:frontend/src/rosetta_parser.rs` fails,
# `server:frontend/src/rosetta_parser.rs` succeeds.
#
# ⚠️ The port-inventory ratchet (test/test_port_inventory.jl) is anchored to MAIN @ 5464713, because
# the release binary the 277-probe differential grades us against is built from main. So for this
# file: its symbols are NOT counted as covered, and an upstream symbol from this subsystem that we
# never ported will NOT show up as a gap. Neither is drift — diff it against `server`, not `main`.
#
# Context: 5 of 6 files in this directory are server-sourced (1365 of 2154 lines, 63%). Their headers
# used to read "port of `mork/frontend/src/...`" with no branch, which is why the inventory reported
# frontend coverage ABOVE 100% — most of our code was not in main's denominator at all.
"""
RosettaParser — 1:1 port of `mork/frontend/src/rosetta_parser.rs`.

A fast S-expression parser supporting f64 literals, lists, and string literals.
Does not allocate arenas (Julia GC handles that). Mirrors all types and
functions from rosetta_parser.rs.
"""

# =====================================================================
# SExp — mirrors SExp<'a> enum in rosetta_parser.rs
# =====================================================================

abstract type RSExp end

struct RSExpF64 <: RSExp
    val::Float64
end

struct RSExpList <: RSExp
    items::Vector{RSExp}
end

struct RSExpStr <: RSExp
    val::String
end

function Base.show(io::IO, s::RSExpF64)
    isfinite(s.val) ? print(io, s.val) : error("NoReprForFloat")
end
function Base.show(io::IO, s::RSExpStr)
    print(io, "\"", s.val, "\"")
end
function Base.show(io::IO, s::RSExpList)
    print(io, "(")
    for (i, item) in enumerate(s.items)
        i > 1 && print(io, " ")
        print(io, item)
    end
    print(io, ")")
end

# buffer_encode — mirrors SExp::buffer_encode
function rs_buffer_encode(s::RSExp)::String
    io = IOBuffer()
    rs_encode(s, io)
    String(take!(io))
end

function rs_encode(s::RSExpF64, io::IO)
    isfinite(s.val) || error("NoReprForFloat")
    print(io, s.val)
end
function rs_encode(s::RSExpStr, io::IO)
    print(io, "\"", s.val, "\"")
end
function rs_encode(s::RSExpList, io::IO)
    print(io, "(")
    for (i, item) in enumerate(s.items)
        i > 1 && print(io, " ")
        rs_encode(item, io)
    end
    print(io, ")")
end

# =====================================================================
# Error — mirrors Error enum in rosetta_parser.rs
# =====================================================================

@enum RSError begin
    RS_NO_REPR_FOR_FLOAT
    RS_UNTERMINATED_STRING
    RS_IO_ERROR
    RS_INCORRECT_CLOSE_DELIMITER
    RS_UNEXPECTED_EOF
    RS_EXPECTED_EOF
end

# =====================================================================
# Token — mirrors Token<'a> enum in rosetta_parser.rs
# =====================================================================

abstract type RSToken end
struct RSListStart <: RSToken end
struct RSListEnd <: RSToken end
struct RSLiteral <: RSToken

    val::RSExp
end
struct RSEof <: RSToken end

# =====================================================================
# Tokens — mirrors Tokens<'a> struct in rosetta_parser.rs
# =====================================================================

"""
    RSTokens

Iterator over a string yielding Token values.
Mirrors `Tokens<'a>` in rosetta_parser.rs.
"""
mutable struct RSTokens
    string::String   # remaining text to parse
end

RSTokens(s::AbstractString) = RSTokens(String(s))

# parse_literal — mirrors parse_literal fn in rosetta_parser.rs
function _rs_parse_literal(s::String)::RSExp
    isempty(s) && return RSExpStr(s)
    b = UInt8(s[1])
    if (b >= UInt8('0') && b <= UInt8('9')) || b == UInt8('-')
        v = tryparse(Float64, s)
        v !== nothing && return RSExpF64(v)
    end
    RSExpStr(s)
end

# next_token — mirrors Tokens::next_token in rosetta_parser.rs
function rs_next_token!(t::RSTokens)::Union{RSToken, RSError}
    while true
        isempty(t.string) && return RSEof()

        c = t.string[1]

        if c == '('
            t.string = t.string[2:end]
            return RSListStart()

        elseif c == ')'
            t.string = t.string[2:end]
            return RSListEnd()

        elseif c == '"'
            rest = t.string[2:end]
            idx = findfirst('"', rest)
            idx === nothing && return RS_UNTERMINATED_STRING
            interior = rest[1:(idx - 1)]
            t.string = rest[(idx + 1):end]
            return RSLiteral(RSExpStr(interior))

        elseif isspace(c)
            t.string = t.string[2:end]
            continue  # skip whitespace, same as loop continue in Rust

        else
            # Plain literal: read until whitespace or paren
            i = 1
            end_ch = nothing
            while i <= ncodeunits(t.string)
                ch = t.string[i]
                if ch == ')' || ch == '('
                    end_ch = ch
                    break
                elseif isspace(ch)
                    break
                end
                i = nextind(t.string, i)
            end
            literal_str = t.string[1:prevind(t.string, i)]
            rest = i <= ncodeunits(t.string) ? t.string[i:end] : ""
            if end_ch !== nothing
                # Next char is '(' or ')' — keep it as first of remaining string
                t.string = rest
            else
                t.string = rest
            end
            return RSLiteral(_rs_parse_literal(literal_str))
        end
    end
end

# =====================================================================
# SExp::parse — mirrors SExp::parse in rosetta_parser.rs
# Uses a stack instead of arena allocation (Julia GC handles memory).
# =====================================================================

function rs_parse(input::String)::Union{RSExp, RSError}
    tokens = RSTokens(input)
    stack = Vector{RSExp}[]

    tok = rs_next_token!(tokens)
    tok isa RSError && return tok

    if tok isa RSListStart
        push!(stack, RSExp[])
    elseif tok isa RSLiteral
        # Single literal — check EOF
        next = rs_next_token!(tokens)
        next isa RSError && return next
        next isa RSEof || return RS_EXPECTED_EOF
        return tok.val
    elseif tok isa RSListEnd
        return RS_INCORRECT_CLOSE_DELIMITER
    elseif tok isa RSEof
        return RS_UNEXPECTED_EOF
    end

    while true
        tok = rs_next_token!(tokens)
        tok isa RSError && return tok

        if tok isa RSListStart
            push!(stack, RSExp[])
        elseif tok isa RSLiteral
            push!(stack[end], tok.val)
        elseif tok isa RSListEnd
            finished = pop!(stack)
            if isempty(stack)
                next = rs_next_token!(tokens)
                next isa RSError && return next
                next isa RSEof || return RS_EXPECTED_EOF
                return RSExpList(finished)
            else
                push!(stack[end], RSExpList(finished))
            end
        elseif tok isa RSEof
            return RS_UNEXPECTED_EOF
        end
    end
end

# SExp::parse_multiple — mirrors SExp::parse_multiple in rosetta_parser.rs
# Parses one s-expression from an existing token stream (no EOF check).
function rs_parse_multiple!(tokens::RSTokens)::Union{RSExp, RSError}
    stack = Vector{RSExp}[]

    tok = rs_next_token!(tokens)
    tok isa RSError && return tok

    if tok isa RSListStart
        push!(stack, RSExp[])
    elseif tok isa RSLiteral
        return tok.val
    elseif tok isa RSListEnd
        return RS_INCORRECT_CLOSE_DELIMITER
    elseif tok isa RSEof
        return RS_EXPECTED_EOF
    end

    while true
        tok = rs_next_token!(tokens)
        tok isa RSError && return tok

        if tok isa RSListStart
            push!(stack, RSExp[])
        elseif tok isa RSLiteral
            push!(stack[end], tok.val)
        elseif tok isa RSListEnd
            finished = pop!(stack)
            if isempty(stack)
                return RSExpList(finished)
            else
                push!(stack[end], RSExpList(finished))
            end
        elseif tok isa RSEof
            return RS_UNEXPECTED_EOF
        end
    end
end

# =====================================================================
# Test constants — mirrors SEXP_STRUCT and SEXP_STRING_IN in rosetta_parser.rs
# =====================================================================

const RS_SEXP_STRING_IN = "((data \"quoted data\" 123 4.5)\n(data (!@# (4.5) \"(more\" \"data)\")))"

# =====================================================================
# Exports
# =====================================================================

export RSExp, RSExpF64, RSExpList, RSExpStr
export RSError, RS_NO_REPR_FOR_FLOAT, RS_UNTERMINATED_STRING
export RS_IO_ERROR, RS_INCORRECT_CLOSE_DELIMITER, RS_UNEXPECTED_EOF, RS_EXPECTED_EOF
export RSToken, RSListStart, RSListEnd, RSLiteral, RSEof
export RSTokens, rs_next_token!
export rs_parse, rs_parse_multiple!, rs_encode, rs_buffer_encode
export RS_SEXP_STRING_IN
