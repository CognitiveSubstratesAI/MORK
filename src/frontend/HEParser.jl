# PROVENANCE: upstream MORK `server` branch @ 2d6730b (2026-05-08) — this file's upstream source
# DOES NOT EXIST on `main`. Verified 2026-07-30: `git cat-file -e main:frontend/src/he_parser.rs` fails,
# `server:frontend/src/he_parser.rs` succeeds.
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
HEParser — 1:1 port of `mork/frontend/src/he_parser.rs`.

Hyperon-Experimental MeTTa S-expression parser.  Produces `HEAtom` trees
(Symbol/Expression/Variable/Grounded) from MeTTa source text.

Julia translation notes:
  - Rust `Rc<AtomConstr>` → Julia `Function`
  - Rust `Peekable<CharIndices>` → Julia index + peekable iteration
  - Rust `'static` lifetime → Julia String ownership (no issue)
  - Rust `Box<dyn GroundedAtom>` → Julia `Any` value
  - Rust `Range<usize>` → Julia `UnitRange{Int}`
"""

using Base: Iterators

# =====================================================================
# SymbolAtom — mirrors SymbolAtom in he_parser.rs
# =====================================================================

struct HESymbolAtom
    name::String
end

he_sym_name(s::HESymbolAtom) = s.name
Base.show(io::IO, s::HESymbolAtom) = print(io, s.name)

# =====================================================================
# ExpressionAtom — mirrors ExpressionAtom in he_parser.rs
# =====================================================================

struct HEExpressionAtom
    children::Vector{Any}   # Vector of HEAtom (forward ref via Any)
end

he_expr_children(e::HEExpressionAtom) = e.children
he_expr_is_plain(e::HEExpressionAtom) = !any(c -> c isa HEExpressionAtom, e.children)

function Base.show(io::IO, e::HEExpressionAtom)
    print(io, "(")
    for (i, child) in enumerate(e.children)
        i > 1 && print(io, " ")
        print(io, child)
    end
    print(io, ")")
end

# =====================================================================
# VariableAtom — mirrors VariableAtom in he_parser.rs
# =====================================================================

const _HE_NEXT_VAR_ID = Ref{Int}(1)

mutable struct HEVariableAtom
    name::String
    id::Int
end

HEVariableAtom(name::String) = HEVariableAtom(name, 0)

function he_var_name(v::HEVariableAtom)::String
    v.id == 0 ? v.name : "$(v.name)#$(v.id)"
end

function he_var_make_unique!(v::HEVariableAtom)::HEVariableAtom
    HEVariableAtom(v.name, _HE_NEXT_VAR_ID[] += 1)
end

Base.show(io::IO, v::HEVariableAtom) = print(io, "\$", he_var_name(v))

# =====================================================================
# HEAtom — mirrors Atom enum in he_parser.rs
# =====================================================================

# Atom is one of: HESymbolAtom, HEExpressionAtom, HEVariableAtom, or Any (Grounded)
const HEAtom = Any

he_atom_sym(name::String) = HESymbolAtom(name)
he_atom_var(name::String) = HEVariableAtom(name)
he_atom_expr(children::Vector) = HEExpressionAtom(children)
he_atom_gnd(val) = val   # grounded = any value

# =====================================================================
# Tokenizer — mirrors Tokenizer in he_parser.rs
# =====================================================================

"""
    HETokenizer

Maps regex patterns to atom constructor functions.
Mirrors `Tokenizer` in he_parser.rs.
Tokens are tried in reverse order (last registered = highest priority).
"""
mutable struct HETokenizer
    tokens::Vector{Tuple{Regex, Function}}   # (regex, token → HEAtom)
end

HETokenizer() = HETokenizer(Tuple{Regex, Function}[])

function he_tok_register!(t::HETokenizer, regex::Regex, constr::Function)
    push!(t.tokens, (regex, constr))
end

function he_tok_register_str!(t::HETokenizer, regex_str::String, constr::Function)
    he_tok_register!(t, Regex(regex_str), constr)
end

function he_tok_find(t::HETokenizer, token::String)::Union{Function, Nothing}
    # Try in reverse order (last = highest priority, mirrors rfind in Rust)
    for i in length(t.tokens):-1:1
        (regex, constr) = t.tokens[i]
        m = match(regex, token)
        if m !== nothing && m.offset == 1 && length(m.match) == length(token)
            return constr
        end
    end
    nothing
end

# =====================================================================
# SyntaxNodeType — mirrors SyntaxNodeType in he_parser.rs
# =====================================================================

@enum HESyntaxNodeType begin
    HE_COMMENT
    HE_VARIABLE_TOKEN
    HE_STRING_TOKEN
    HE_WORD_TOKEN
    HE_OPEN_PAREN
    HE_CLOSE_PAREN
    HE_WHITESPACE
    HE_LEFTOVER_TEXT
    HE_EXPRESSION_GROUP
    HE_ERROR_GROUP
end

function he_node_is_leaf(t::HESyntaxNodeType)::Bool
    !(t == HE_EXPRESSION_GROUP || t == HE_ERROR_GROUP)
end

# =====================================================================
# SyntaxNode — mirrors SyntaxNode in he_parser.rs
# =====================================================================

mutable struct HESyntaxNode
    node_type::HESyntaxNodeType
    src_range::UnitRange{Int}
    sub_nodes::Vector{HESyntaxNode}
    parsed_text::Union{String, Nothing}
    message::Union{String, Nothing}
    is_complete::Bool
end

function HESyntaxNode(
    node_type::HESyntaxNodeType, src_range::UnitRange{Int}, sub_nodes::Vector{HESyntaxNode}
)
    HESyntaxNode(node_type, src_range, sub_nodes, nothing, nothing, true)
end

function _he_node_token(
    node_type::HESyntaxNodeType, src_range::UnitRange{Int}, text::String
)::HESyntaxNode
    n = HESyntaxNode(node_type, src_range, HESyntaxNode[])
    n.parsed_text = text
    n
end

function _he_node_incomplete(node_type::HESyntaxNodeType, src_range::UnitRange{Int},
    sub_nodes::Vector{HESyntaxNode}, message::String)::HESyntaxNode
    n = HESyntaxNode(node_type, src_range, sub_nodes)
    n.message = message
    n.is_complete = false
    n
end

function _he_node_error_group(
    src_range::UnitRange{Int}, sub_nodes::Vector{HESyntaxNode}
)::HESyntaxNode
    msg = isempty(sub_nodes) ? nothing : sub_nodes[end].message
    n = HESyntaxNode(HE_ERROR_GROUP, src_range, sub_nodes)
    n.message = msg
    n.is_complete = false
    n
end

# SyntaxNode::as_atom — convert syntax tree node → HEAtom using tokenizer
function he_node_as_atom(
    node::HESyntaxNode, tok::HETokenizer
)::Union{HEAtom, Nothing, String}
    # Returns: HEAtom, nothing (skip), or String (error message)
    !node.is_complete && return node.message

    if node.node_type == HE_COMMENT || node.node_type == HE_WHITESPACE ||
        node.node_type == HE_OPEN_PAREN || node.node_type == HE_CLOSE_PAREN
        return nothing

    elseif node.node_type == HE_VARIABLE_TOKEN
        return he_atom_var(node.parsed_text)

    elseif node.node_type == HE_STRING_TOKEN || node.node_type == HE_WORD_TOKEN
        text = node.parsed_text
        constr = he_tok_find(tok, text)
        if constr !== nothing
            try
                ;
                return constr(text)
            catch e
                ;
                return "byte range = ($(node.src_range)) | $e";
            end
        else
            return he_atom_sym(text)
        end

    elseif node.node_type == HE_EXPRESSION_GROUP
        children = HEAtom[]
        for sub in node.sub_nodes
            result = he_node_as_atom(sub, tok)
            result isa String && return result   # error propagates up
            result !== nothing && push!(children, result)
        end
        return he_atom_expr(children)

    else  # LEFTOVER_TEXT, ERROR_GROUP
        error("unreachable: $(node.node_type)")
    end
end

function he_node_visit_depth_first(node::HESyntaxNode, f::Function)
    for sub in node.sub_nodes
        he_node_visit_depth_first(sub, f)
    end
    f(node)
end

# =====================================================================
# SExprParser — mirrors SExprParser<'a> in he_parser.rs
# =====================================================================

"""
    HESExprParser

Character-level MeTTa S-expression parser.
Mirrors `SExprParser<'a>` in he_parser.rs.
"""
mutable struct HESExprParser
    text::String
    pos::Int         # current byte position (1-based Julia index)
end

HESExprParser(text::String) = HESExprParser(text, 1)

# Peek at current char without consuming. Returns (byte_idx, char) or nothing.
function _hep_peek(p::HESExprParser)::Union{Tuple{Int, Char}, Nothing}
    p.pos > ncodeunits(p.text) && return nothing
    idx = p.pos
    c = p.text[idx]
    (idx - 1, c)   # return 0-based index to match Rust CharIndices
end

# Consume and return current char
function _hep_next!(p::HESExprParser)::Union{Tuple{Int, Char}, Nothing}
    p.pos > ncodeunits(p.text) && return nothing
    idx = p.pos
    c = p.text[idx]
    p.pos = nextind(p.text, idx)
    (idx - 1, c)
end

# Current byte offset (0-based, matches Rust cur_idx)
function _hep_cur_idx(p::HESExprParser)::Int
    p.pos - 1
end

# parse_comment: read to next \n
function _hep_parse_comment!(p::HESExprParser)::HESyntaxNode
    start = _hep_cur_idx(p)
    while (pk = _hep_peek(p)) !== nothing
        _, c = pk
        c == '\n' && break
        _hep_next!(p)
    end
    HESyntaxNode(HE_COMMENT, start:_hep_cur_idx(p), HESyntaxNode[])
end

# parse_leftovers: consume all remaining chars, return incomplete node
function _hep_parse_leftovers!(p::HESExprParser, message::String)::HESyntaxNode
    start = _hep_cur_idx(p)
    while _hep_next!(p) !== nothing
        ;
    end
    _he_node_incomplete(HE_LEFTOVER_TEXT, start:_hep_cur_idx(p), HESyntaxNode[], message)
end

# parse_word: read non-whitespace, non-paren chars
function _hep_parse_word!(p::HESExprParser)::HESyntaxNode
    token = IOBuffer()
    start = _hep_cur_idx(p)
    while (pk = _hep_peek(p)) !== nothing
        _, c = pk
        (isspace(c) || c == '(' || c == ')') && break
        write(token, c)
        _hep_next!(p)
    end
    _he_node_token(HE_WORD_TOKEN, start:_hep_cur_idx(p), String(take!(token)))
end

# parse_variable: consume $ then read word (no # allowed)
function _hep_parse_variable!(p::HESExprParser)::HESyntaxNode
    start, _ = _hep_peek(p)
    save_pos = p.pos
    _hep_next!(p)   # consume '$'
    token = IOBuffer()
    while (pk = _hep_peek(p)) !== nothing
        _, c = pk
        (isspace(c) || c == '(' || c == ')') && break
        if c == '#'
            p.pos = save_pos
            return _hep_parse_leftovers!(p, "'#' char is reserved for internal usage")
        end
        write(token, c)
        _hep_next!(p)
    end
    _he_node_token(HE_VARIABLE_TOKEN, start:_hep_cur_idx(p), String(take!(token)))
end

# parse_2_digit_radix_value: hex escape \xNN
function _hep_parse_2digit_radix!(p::HESExprParser, radix::Int)::Union{UInt8, Nothing}
    r1 = _hep_next!(p);
    r1 === nothing && return nothing
    _, d1 = r1
    isdigit(d1) || (radix == 16 && d1 in 'a':'f') || (radix == 16 && d1 in 'A':'F') ||
        return nothing
    r2 = _hep_next!(p);
    r2 === nothing && return nothing
    _, d2 = r2
    isdigit(d2) || (radix == 16 && d2 in 'a':'f') || (radix == 16 && d2 in 'A':'F') ||
        return nothing
    val = parse(UInt8, string(d1, d2); base=radix)
    val <= 0x7F ? val : nothing
end

# parse_string: read "..." with escape sequences
function _hep_parse_string!(p::HESExprParser)::HESyntaxNode
    token = IOBuffer()
    start = _hep_cur_idx(p)
    r = _hep_next!(p)  # consume opening '"'
    (r === nothing || r[2] != '"') && return _he_node_incomplete(
        HE_LEFTOVER_TEXT, start:_hep_cur_idx(p), HESyntaxNode[], "Double quote expected"
    )
    write(token, '"')

    while (r = _hep_next!(p)) !== nothing
        char_idx, c = r
        if c == '"'
            write(token, '"')
            return _he_node_token(
                HE_STRING_TOKEN, start:_hep_cur_idx(p), String(take!(token))
            )
        end
        if c == '\\'
            esc = _hep_next!(p)
            esc === nothing && return _he_node_incomplete(
                HE_STRING_TOKEN, start:_hep_cur_idx(p), HESyntaxNode[],
                "Escaping sequence is not finished")
            _, ec = esc
            val = if ec == '\'' || ec == '"' || ec == '\\'
                ec
            elseif ec == 'n'
                ;
                '\n'
            elseif ec == 'r'
                ;
                '\r'
            elseif ec == 't'
                ;
                '\t'
            elseif ec == 'x'
                code = _hep_parse_2digit_radix!(p, 16)
                code === nothing && return _he_node_incomplete(
                    HE_STRING_TOKEN, char_idx:_hep_cur_idx(p), HESyntaxNode[],
                    "Invalid escape sequence")
                Char(code)
            else
                return _he_node_incomplete(
                    HE_STRING_TOKEN, char_idx:_hep_cur_idx(p), HESyntaxNode[],
                    "Invalid escape sequence")
            end
            write(token, val)
        else
            write(token, c)
        end
    end
    _he_node_incomplete(
        HE_STRING_TOKEN, start:_hep_cur_idx(p), HESyntaxNode[], "Unclosed String Literal"
    )
end

# parse_token: dispatch on first char
function _hep_parse_token!(p::HESExprParser)::Union{HESyntaxNode, Nothing}
    pk = _hep_peek(p)
    pk === nothing && return nothing
    _, c = pk
    if c == '"'
        ;
        return _hep_parse_string!(p)
    else
        ;
        return _hep_parse_word!(p)
    end
end

# parse_expr: read ( ... ) recursively
function _hep_parse_expr!(p::HESExprParser)::HESyntaxNode
    start = _hep_cur_idx(p)
    child_nodes = HESyntaxNode[]
    push!(child_nodes, HESyntaxNode(HE_OPEN_PAREN, start:(start + 1), HESyntaxNode[]))
    _hep_next!(p)   # consume '('

    while (pk = _hep_peek(p)) !== nothing
        idx, c = pk
        if c == ';'
            push!(child_nodes, _hep_parse_comment!(p))
        elseif isspace(c)
            push!(child_nodes, HESyntaxNode(HE_WHITESPACE, idx:(idx + 1), HESyntaxNode[]))
            _hep_next!(p)
        elseif c == ')'
            push!(child_nodes, HESyntaxNode(HE_CLOSE_PAREN, idx:(idx + 1), HESyntaxNode[]))
            _hep_next!(p)
            return HESyntaxNode(HE_EXPRESSION_GROUP, start:_hep_cur_idx(p), child_nodes)
        else
            node = _hep_parse_to_syntax_tree!(p)
            if node !== nothing
                is_err = !node.is_complete
                push!(child_nodes, node)
                is_err && return _he_node_error_group(start:_hep_cur_idx(p), child_nodes)
            else
                return _he_node_incomplete(HE_ERROR_GROUP, start:_hep_cur_idx(p),
                    child_nodes, "Unexpected end of expression member")
            end
        end
    end
    _he_node_incomplete(
        HE_ERROR_GROUP, start:_hep_cur_idx(p), child_nodes, "Unexpected end of expression"
    )
end

# parse_to_syntax_tree: main dispatch, mirrors parse_to_syntax_tree in Rust
function _hep_parse_to_syntax_tree!(p::HESExprParser)::Union{HESyntaxNode, Nothing}
    pk = _hep_peek(p)
    pk === nothing && return nothing
    idx, c = pk
    if c == ';'
        return _hep_parse_comment!(p)
    elseif isspace(c)
        n = HESyntaxNode(HE_WHITESPACE, idx:(idx + 1), HESyntaxNode[])
        _hep_next!(p)
        return n
    elseif c == '$'
        return _hep_parse_variable!(p)
    elseif c == '('
        return _hep_parse_expr!(p)
    elseif c == ')'
        close_node = HESyntaxNode(HE_CLOSE_PAREN, idx:(idx + 1), HESyntaxNode[])
        _hep_next!(p)
        leftover = _hep_parse_leftovers!(p, "Unexpected right bracket")
        return _he_node_error_group(idx:_hep_cur_idx(p), [close_node, leftover])
    else
        return _hep_parse_token!(p)
    end
end

# parse: loop until a real atom is produced, mirrors SExprParser::parse
function he_sexpr_parse!(p::HESExprParser, tok::HETokenizer)::Union{HEAtom, Nothing, String}
    while true
        node = _hep_parse_to_syntax_tree!(p)
        node === nothing && return nothing
        result = he_node_as_atom(node, tok)
        result isa String && return result  # error
        result !== nothing && return result  # real atom
        # else: whitespace/comment — loop
    end
end

# =====================================================================
# OwnedSExprParser — mirrors OwnedSExprParser in he_parser.rs
# =====================================================================

"""
    HEOwnedSExprParser

Owned version of HESExprParser — holds the text string itself.
Mirrors `OwnedSExprParser` in he_parser.rs.
"""
mutable struct HEOwnedSExprParser
    text::String
    last_pos::Int     # byte position (1-based)
end

HEOwnedSExprParser(text::String) = HEOwnedSExprParser(text, 1)

function he_owned_next_atom!(
    p::HEOwnedSExprParser, tok::HETokenizer
)::Union{HEAtom, Nothing, String}
    p.last_pos > ncodeunits(p.text) && return nothing
    slice = p.text[p.last_pos:end]
    parser = HESExprParser(slice)
    result = he_sexpr_parse!(parser, tok)
    p.last_pos += _hep_cur_idx(parser)
    result
end

# =====================================================================
# Exports
# =====================================================================

export HESymbolAtom, HEExpressionAtom, HEVariableAtom, HEAtom
export he_sym_name, he_expr_children, he_expr_is_plain
export he_var_name, he_var_make_unique!
export he_atom_sym, he_atom_var, he_atom_expr, he_atom_gnd
export HETokenizer, he_tok_register!, he_tok_register_str!, he_tok_find
export HESyntaxNodeType, HESyntaxNode
export HE_COMMENT, HE_VARIABLE_TOKEN, HE_STRING_TOKEN, HE_WORD_TOKEN
export HE_OPEN_PAREN, HE_CLOSE_PAREN, HE_WHITESPACE, HE_LEFTOVER_TEXT
export HE_EXPRESSION_GROUP, HE_ERROR_GROUP
export he_node_is_leaf, he_node_as_atom, he_node_visit_depth_first
export HESExprParser, he_sexpr_parse!
export HEOwnedSExprParser, he_owned_next_atom!
