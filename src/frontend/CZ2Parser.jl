"""
CZ2Parser — 1:1 port of `mork/frontend/src/cz2_parser.rs`.

Experimental S-expression parser that builds a linked-pair tree
(App nodes) via a stack rather than allocating. Variables are
tracked by name in a Vec<String>.

Julia translation notes:
  - Rust `*const Expr` pointers → Julia indices into a Vector
  - Rust `App(*const Expr, *const Expr)` → CZ2App(left_idx, right_idx)
  - Rust `Var(i64)` → CZ2Var(id::Int) where id<0 means VarRef(-id)
  - BufferedIterator → operates on String (in-memory, no file I/O)
  - Parser trait tokenizer → abstract function, default = intern symbol
"""

# =====================================================================
# Expr — mirrors Expr enum in cz2_parser.rs
# =====================================================================

abstract type CZ2Expr end

struct CZ2Var <: CZ2Expr
    id::Int   # 0 = new var, negative = var ref index
end

struct CZ2App <: CZ2Expr
    left::Int   # index into expr heap
    right::Int   # index into expr heap
end

# Heap: all allocated nodes stored here (replaces arena)
# Index 0 = "empty" sentinel (mirrors const empty: i64)
# Index 1 = "singleton" sentinel (mirrors const singleton: i64)
const CZ2_EMPTY = 0
const CZ2_SINGLETON = 1

# =====================================================================
# CZ2Parser state — holds heap + tokenizer function
# =====================================================================

mutable struct CZ2Parser
    heap::Vector{CZ2Expr}   # index 0=empty,1=singleton, 2+ = real nodes
    tokenizer::Function           # String → Int (symbol id)
end

function CZ2Parser(; tokenizer::Function=s -> hash(s) % typemax(Int32))
    heap = CZ2Expr[CZ2Var(0), CZ2Var(1)]  # indices 0,1 are sentinels
    CZ2Parser(heap, tokenizer)
end

function _cz2_alloc!(p::CZ2Parser, expr::CZ2Expr)::Int
    push!(p.heap, expr)
    length(p.heap) - 1
end

# =====================================================================
# BufferedIterator — mirrors BufferedIterator in cz2_parser.rs
# Operates on a String buffer (no file I/O needed for in-memory use).
# =====================================================================

mutable struct CZ2Iter
    data::Vector{UInt8}
    cursor::Int
end

CZ2Iter(s::String) = CZ2Iter(Vector{UInt8}(s), 1)

_cz2_has_next(it::CZ2Iter) = it.cursor <= length(it.data)
_cz2_head(it::CZ2Iter) = _cz2_has_next(it) ? Char(it.data[it.cursor]) : '\0'
function _cz2_next!(it::CZ2Iter)::Char
    c = Char(it.data[it.cursor])
    it.cursor += 1
    c
end

_cz2_is_whitespace(c::Char) = c == ' ' || c == '\t' || c == '\n'
_cz2_is_digit(c::Char) = '0' <= c <= '9'

# =====================================================================
# indexOf — mirrors indexOf in cz2_parser.rs
# =====================================================================

function _cz2_index_of(vars::Vector{String}, name::String)::Int
    for (i, v) in enumerate(vars)
        v == name && return i - 1   # 0-based like Rust
    end
    -1
end

# =====================================================================
# sexprUnsafe — mirrors Parser::sexprUnsafe in cz2_parser.rs
# Returns heap index of parsed expression.
# =====================================================================

function cz2_sexpr!(p::CZ2Parser, it::CZ2Iter,
    vars::Vector{String},
    stack::Vector{Tuple{Int, Int}})::Int
    while _cz2_has_next(it)
        c = _cz2_head(it)

        if c == ';'
            while _cz2_has_next(it) && _cz2_next!(it) != '\n'
                ;
            end

        elseif _cz2_is_whitespace(c)
            _cz2_next!(it)

        elseif c == '$'
            _cz2_next!(it)   # consume '$'
            sb = IOBuffer()
            while _cz2_has_next(it)
                h = _cz2_head(it)
                (h == '(' || h == ')' || _cz2_is_whitespace(h)) && break
                write(sb, _cz2_next!(it))
            end
            id_str = String(take!(sb))
            ind = _cz2_index_of(vars, id_str)
            if ind == -1
                push!(vars, id_str)
                return CZ2_EMPTY   # new var → 0
            else
                return -ind        # var ref → negative index
            end

        elseif c == '('
            _cz2_next!(it)   # consume '('
            res = CZ2_EMPTY
            while _cz2_has_next(it) && _cz2_head(it) != ')'
                h = _cz2_head(it)
                if _cz2_is_whitespace(h)
                    _cz2_next!(it)
                else
                    res = cz2_sexpr!(p, it, vars, stack)
                    if _cz2_has_next(it) && _cz2_head(it) == ')'
                        # single child
                        l = length(stack)
                        push!(stack, (CZ2_SINGLETON, res))
                        res = l   # index into stack (as pointer)
                    else
                        # multiple children
                        while _cz2_has_next(it) && _cz2_head(it) != ')'
                            h2 = _cz2_head(it)
                            if _cz2_is_whitespace(h2)
                                _cz2_next!(it)
                            else
                                cont = cz2_sexpr!(p, it, vars, stack)
                                l = length(stack)
                                push!(stack, (res, cont))
                                res = l
                            end
                        end
                    end
                end
            end
            _cz2_has_next(it) && _cz2_next!(it)   # consume ')'
            return res

        elseif c == ')'
            error("Unexpected right bracket")

        else
            # Read symbol (quoted or plain)
            sym_str = if _cz2_has_next(it) && _cz2_head(it) == '"'
                _cz2_next!(it)   # consume '"'
                sb = IOBuffer();
                write(sb, '"')
                cont = true
                while _cz2_has_next(it) && cont
                    ch = _cz2_next!(it)
                    if ch == '"'
                        ;
                        write(sb, '"');
                        cont = false
                    elseif ch == '\\'
                        _cz2_has_next(it) || error("Escaping sequence is not finished")
                        write(sb, _cz2_next!(it))
                    else
                        ;
                        write(sb, ch);
                    end
                end
                String(take!(sb))
            else
                sb = IOBuffer()
                while _cz2_has_next(it)
                    h = _cz2_head(it)
                    (h == '(' || h == ')' || _cz2_is_whitespace(h)) && break
                    write(sb, _cz2_next!(it))
                end
                String(take!(sb))
            end
            return p.tokenizer(sym_str)
        end
    end
    -1   # null pointer equivalent
end

export CZ2Expr, CZ2Var, CZ2App, CZ2Parser, CZ2Iter
export CZ2_EMPTY, CZ2_SINGLETON
export cz2_sexpr!
