"""
CZ3Parser — 1:1 port of `mork/frontend/src/cz3_parser.rs`.

Experimental S-expression parser that writes directly into a flat
Item array (ExprZipper target), closely mirroring the MORK bytestring
encoding. Intermediate prototype toward the production bytestring parser.

Julia translation notes:
  - Rust `*mut Item` buffer → Julia Vector{CZ3Item}
  - Rust unsafe pointer arithmetic → safe array indexing
  - CZ3ExprZipper.loc = current write position (1-based Julia)
  - Parser trait tokenizer → Function: String → Int64
"""

# =====================================================================
# Item — mirrors Item enum in cz3_parser.rs
# =====================================================================

abstract type CZ3Item end
struct CZ3NewVar <: CZ3Item end
struct CZ3VarRef <: CZ3Item
    ;
    index::UInt8;
end
struct CZ3Symbol <: CZ3Item
    ;
    value::UInt32;
end
struct CZ3Arity <: CZ3Item
    ;
    arity::UInt8;
end

# =====================================================================
# Breadcrumb — mirrors Breadcrumb struct
# =====================================================================

mutable struct CZ3Breadcrumb
    parent::UInt32
    arity::UInt8
    seen::UInt8
end

# =====================================================================
# CZ3Expr + CZ3ExprZipper — mirrors Expr + ExprZipper
# =====================================================================

mutable struct CZ3ExprZipper
    buf::Vector{CZ3Item}   # the flat item buffer
    loc::Int               # current position (1-based)
    trace::Vector{CZ3Breadcrumb}
end

function CZ3ExprZipper(buf::Vector{CZ3Item})
    trace = CZ3Breadcrumb[]
    if !isempty(buf)
        item = buf[1]
        if item isa CZ3Arity
            push!(trace, CZ3Breadcrumb(1, item.arity, 0))
        end
    end
    CZ3ExprZipper(buf, 1, trace)
end

CZ3ExprZipper() = CZ3ExprZipper(CZ3Item[])

function _cz3_write_arity!(z::CZ3ExprZipper, a::UInt8)
    if z.loc > length(z.buf)
        ;
        push!(z.buf, CZ3Arity(a))
    else
        ;
        z.buf[z.loc] = CZ3Arity(a);
    end
end

function _cz3_write_symbol!(z::CZ3ExprZipper, v::UInt32)
    if z.loc > length(z.buf)
        ;
        push!(z.buf, CZ3Symbol(v))
    else
        ;
        z.buf[z.loc] = CZ3Symbol(v);
    end
end

function _cz3_write_new_var!(z::CZ3ExprZipper)
    if z.loc > length(z.buf)
        ;
        push!(z.buf, CZ3NewVar())
    else
        ;
        z.buf[z.loc] = CZ3NewVar();
    end
end

function _cz3_write_var_ref!(z::CZ3ExprZipper, idx::UInt8)
    if z.loc > length(z.buf)
        ;
        push!(z.buf, CZ3VarRef(idx))
    else
        ;
        z.buf[z.loc] = CZ3VarRef(idx);
    end
end

# Update arity at position pos
function _cz3_increment_arity!(z::CZ3ExprZipper, pos::Int)
    item = z.buf[pos]
    item isa CZ3Arity || error("not arity at pos $pos")
    z.buf[pos] = CZ3Arity(item.arity + UInt8(1))
end

# =====================================================================
# Helpers
# =====================================================================

function _cz3_index_of(vars::Vector{String}, name::String)::Int
    for (i, v) in enumerate(vars)
        v == name && return i - 1
    end
    -1
end

_cz3_is_whitespace(c::Char) = c == ' ' || c == '\t' || c == '\n'

# =====================================================================
# BufferedIterator — same as cz2, operates on in-memory String
# =====================================================================

mutable struct CZ3Iter
    data::Vector{UInt8}
    cursor::Int
end

CZ3Iter(s::String) = CZ3Iter(Vector{UInt8}(s), 1)

_cz3_has_next(it::CZ3Iter) = it.cursor <= length(it.data)
_cz3_head(it::CZ3Iter) = _cz3_has_next(it) ? Char(it.data[it.cursor]) : '\0'
function _cz3_next!(it::CZ3Iter)::Char
    c = Char(it.data[it.cursor]);
    it.cursor += 1;
    c
end

# =====================================================================
# CZ3Parser — holds tokenizer function
# =====================================================================

mutable struct CZ3Parser
    tokenizer::Function   # String → Int64 (symbol id)
end

CZ3Parser(; tokenizer::Function=s -> hash(s) % typemax(Int32)) = CZ3Parser(tokenizer)

# =====================================================================
# sexprUnsafe — mirrors Parser::sexprUnsafe in cz3_parser.rs
# Writes parsed expression into target CZ3ExprZipper.
# Returns true if an expression was written, false at EOF.
# =====================================================================

function cz3_sexpr!(p::CZ3Parser, it::CZ3Iter,
    vars::Vector{String},
    target::CZ3ExprZipper)::Bool
    while _cz3_has_next(it)
        c = _cz3_head(it)

        if c == ';'
            while _cz3_has_next(it) && _cz3_next!(it) != '\n'
                ;
            end

        elseif _cz3_is_whitespace(c)
            _cz3_next!(it)

        elseif c == '$'
            _cz3_next!(it)   # consume '$'
            sb = IOBuffer()
            while _cz3_has_next(it)
                h = _cz3_head(it)
                (h == '(' || h == ')' || _cz3_is_whitespace(h)) && break
                write(sb, _cz3_next!(it))
            end
            id_str = String(take!(sb))
            ind = _cz3_index_of(vars, id_str)
            if ind == -1
                push!(vars, id_str)
                _cz3_write_new_var!(target)
                target.loc += 1
                return true
            else
                _cz3_write_var_ref!(target, UInt8(ind))
                target.loc += 1
                return true
            end

        elseif c == '('
            arity_loc = target.loc
            _cz3_write_arity!(target, UInt8(0))
            target.loc += 1
            _cz3_next!(it)   # consume '('
            while _cz3_has_next(it) && _cz3_head(it) != ')'
                h = _cz3_head(it)
                if _cz3_is_whitespace(h)
                    _cz3_next!(it)
                else
                    cz3_sexpr!(p, it, vars, target)
                    _cz3_increment_arity!(target, arity_loc)
                end
            end
            _cz3_has_next(it) && _cz3_next!(it)   # consume ')'
            return true

        elseif c == ')'
            error("Unexpected right bracket")

        else
            sym_str = if _cz3_has_next(it) && _cz3_head(it) == '"'
                _cz3_next!(it)
                sb = IOBuffer();
                write(sb, '"')
                cont = true
                while _cz3_has_next(it) && cont
                    ch = _cz3_next!(it)
                    if ch == '"'
                        ;
                        write(sb, '"');
                        cont = false
                    elseif ch == '\\'
                        _cz3_has_next(it) || error("Escaping sequence is not finished")
                        write(sb, _cz3_next!(it))
                    else
                        ;
                        write(sb, ch);
                    end
                end
                String(take!(sb))
            else
                sb = IOBuffer()
                while _cz3_has_next(it)
                    h = _cz3_head(it)
                    (h == '(' || h == ')' || _cz3_is_whitespace(h)) && break
                    write(sb, _cz3_next!(it))
                end
                String(take!(sb))
            end
            e = p.tokenizer(sym_str)
            _cz3_write_symbol!(target, UInt32(e))
            target.loc += 1
            return true
        end
    end
    false
end

export CZ3Item, CZ3NewVar, CZ3VarRef, CZ3Symbol, CZ3Arity
export CZ3Breadcrumb, CZ3ExprZipper, CZ3Parser, CZ3Iter
export cz3_sexpr!
