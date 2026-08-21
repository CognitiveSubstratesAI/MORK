"""
Space — port of `mork/kernel/src/space.rs`.

The `Space` struct is the central data structure of the MORK kernel: a
`PathMap{UnitVal}` (set-trie of flat byte-encoded expressions) coupled with
a `SharedMappingHandle` for symbol interning.

Julia translation notes
========================
  - `PathMap<()>` → `PathMap{UnitVal}` (unit-value set-trie)
  - `#[cfg(feature="interning")]` path → raw-bytes (no-interning) variant
    (symbols stored as raw UTF-8 truncated to 63 bytes, matching the
    `#[cfg(not(feature="interning"))]` code path in upstream)
  - `coreferential_transition` (DFS) → IMPLEMENTED (`_coreferential_transition!` +
    `space_query_coref`, single- and multi-source; ports upstream e551924). `query_multi`
    additionally has the `#[cfg(feature="no_search")]` ProductZipper + unify fast path.
    (SP-4 fix 2026-06-04: header previously called the coref DFS "deferred" — stale.)
  - `setjmp`/`longjmp` early-exit → Julia `throw`/`catch` (BreakQuery)
  - `subprocess::Popen` (Z3 integration) → stubbed
  - `memmap2::Mmap` (ACT memory-mapped files) → stubbed
"""

# =====================================================================
# Bitmask constants (mirrors SIZES/ARITIES/VARS in space.rs)
# =====================================================================

"""
Byte → category bitmask mapping for expression byte tags.
`SPACE_SIZES[((b & 0xC0) >> 6) + 1]` has bit `(b & 0x3F)` set iff `b` encodes
a SymbolSize tag.  Same structure for SPACE_ARITIES and SPACE_VARS.
"""
function _build_space_mask(predicate::Function)
    result = zeros(UInt64, 4)
    for b_int in 0:255
        b = UInt8(b_int)
        tag = try
            byte_item(b)
        catch
            ;
            continue
        end   # skip reserved bytes
        if predicate(tag)
            bucket = Int((b & 0xC0) >> 6) + 1
            bit = Int(b & 0x3F)
            result[bucket] |= UInt64(1) << bit
        end
    end
    NTuple{4, UInt64}(result)
end

const SPACE_SIZES = _build_space_mask(t -> t isa ExprSymbol)
const SPACE_ARITIES = _build_space_mask(t -> t isa ExprArity)
const SPACE_VARS = _build_space_mask(t -> t isa ExprNewVar || t isa ExprVarRef)

# =====================================================================
# Fix 3: task-local ReadZipperCore pool — eliminates per-query heap alloc
# =====================================================================
#
# Each call to _space_query_multi_inner! previously allocated fresh
# ReadZipperCore objects for secondary factors via read_zipper_at_path.
# The pool stores up to 8 reusable zippers per task.  On checkout the
# zipper is reinitialized from the current btm root; on return it is
# handed back to the pool (no reset needed — reinit is always full).
#
# Uses Julia's built-in task_local_storage so it is task-safe by
# construction and does not require any external packages.

const _ZIPPER_POOL_KEY = :_mork_zipper_pool

@inline function _zipper_pool_get!()::Vector{Any}
    get!(task_local_storage(), _ZIPPER_POOL_KEY, Any[])::Vector{Any}
end

@inline function _pool_checkout!(pool::Vector{Any})
    isempty(pool) ? nothing : pop!(pool)
end

@inline function _pool_return!(pool::Vector{Any}, z)
    length(pool) < 8 && push!(pool, z)
    nothing
end

"""
    _reinit_zipper_from_btm!(z, btm::PathMap{UnitVal})

Reset a pooled ReadZipperCore to point at the root of `btm`.
Reuses the existing prefix_buf and ancestors vectors (just resizes them)
so the only allocation is the node reference update — no heap alloc.
"""
@inline function _reinit_zipper_from_btm!(z, btm::PathMap{UnitVal})
    _ensure_root!(btm)   # exported from PathMap, in scope via `using PathMap`
    root_rc = btm.root::TrieNodeODRc{UnitVal, GlobalAlloc}
    z.root_node = root_rc
    z.root_val = btm.root_val
    z.alloc = btm.alloc
    z.root_key_start = 0
    z.origin_path_len = 0
    resize!(z.prefix_buf, 0)
    empty!(z.ancestors)
    z.focus_node = root_rc.node
    z.focus_iter_token = NODE_ITER_INVALID   # exported from PathMap
    nothing
end

# =====================================================================
# SpaceParser — tokenizer without interning (mirrors ParDataParser, no-intern)
# =====================================================================

"""
    SpaceParser

`MorkParser` whose `fe_tokenizer` truncates symbols to 63 bytes.
Mirrors `ParDataParser` with `cfg(not(feature="interning"))` in space.rs.
"""
# Faithful port of upstream `ParDataParser` (mork/kernel/src/space.rs:220 `count: u64` mutated via
# `&mut self`): a MUTABLE struct with a CONCRETE `count::Int`, matching sibling `SpaceTranscriber`.
# WAS `struct` + `count::Ref{Int}` — but `Ref` is an ABSTRACT type, so `p.count[]` was a runtime
# `::Any` (JET-detected on the parse hot path). Upstream has no such abstraction; this was a
# Julia-port idiom bug, not present in the Rust.
mutable struct SpaceParser <: MorkParser
    count::Int
    SpaceParser() = new(0)
end

function fe_tokenizer(p::SpaceParser, s::AbstractVector{UInt8})::Vector{UInt8}
    p.count += 1
    n = min(length(s), 63)
    Vector{UInt8}(s[1:n])
end

# =====================================================================
# Space struct
# =====================================================================

"""
    Space

Central MORK data structure: a `PathMap{UnitVal}` set-trie of flat byte-encoded
expressions plus a symbol intern table.
Mirrors `Space` in mork/kernel/src/space.rs.
"""
mutable struct Space
    btm::PathMap{UnitVal, GlobalAlloc}
    sm::SharedMappingHandle
    timing::Bool
    mmaps::Dict{String, ArenaCompactTree}   # ACT file cache (mirrors mmaps in Space)
end

"""    new_space() → Space

Create an empty Space.  Mirrors `Space::new`.
"""
new_space() = Space(
    PathMap{UnitVal}(), SharedMappingHandle(), false, Dict{String, ArenaCompactTree}()
)

# Prevent Julia's default struct show from dumping raw PathMap bytes to stdout.
# Upstream equivalent: Space::statistics() prints "val count N".
Base.show(io::IO, s::Space) =
    print(io, "Space($(space_val_count(s)) atoms)")

"""    space_val_count(s) → Int

Return the number of expressions stored in the Space.
"""
space_val_count(s::Space) = val_count(s.btm)

"""    space_statistics(s)

Print basic statistics.  Mirrors `Space::statistics`.
"""
function space_statistics(s::Space)
    println("val count ", space_val_count(s))
end

# =====================================================================
# space_add_all_sexpr! / space_remove_all_sexpr! / load_all_sexpr_impl!
# =====================================================================

"""
    space_add_all_sexpr!(s, src) → Int

Parse multiple whitespace-separated s-expressions from `src` and add each
to the Space.  Mirrors `Space::add_all_sexpr`.
"""
space_add_all_sexpr!(s::Space, src) = _space_load_all_sexpr_impl!(s, src, true)

"""
    space_remove_all_sexpr!(s, src) → Int

Remove each parsed s-expression from the Space.
Mirrors `Space::remove_all_sexpr`.
"""
space_remove_all_sexpr!(s::Space, src) = _space_load_all_sexpr_impl!(s, src, false)

function _space_load_all_sexpr_impl!(s::Space, src, add::Bool)::Int
    bv = src isa Vector{UInt8} ? src : Vector{UInt8}(src)
    ctx = SexprContext(bv)
    parser = SpaceParser()
    i = 0
    # ── SCRATCH BUFFER, ALLOCATED ONCE — this loop used to allocate it PER EXPRESSION ────────────
    # The old comment read "Fresh buffer per expression (mirrors stack[] in Rust)". It does NOT
    # mirror Rust: `space.rs:839-841` allocates `stack` ONCE, above the loop, and each iteration
    # rebuilds only the zipper over it (`:845`). Ours reallocated `2 * length(entire input)` bytes on
    # every expression, so parsing N expressions out of one input of length L allocated O(N·L).
    #
    # MEASURED 2026-08-07, `(inc k)` facts through `space_add_all_sexpr!`:
    #     N=100  0.3 MB      N=1000  20.9 MB      N=10000  2098.9 MB
    # ~70x then ~100x per 10x N — quadratic. At N=10000 that was 93% of the compiled lane's total
    # allocation, and it is why the lane looked more memory-hungry than the interpreter. Saturation
    # itself is LINEAR over the same range (1.6 -> 16.2 -> 168.6 MB) and was never the cost.
    #
    # SAFE TO REUSE: the parsed bytes are COPIED OUT below — `data = z.root.buf[1:(z.loc - 1)]` is a
    # slice-index, which allocates a fresh Vector — and that copy is what `set_val_at!` stores. The
    # trie never retains the buffer, so the next expression may overwrite it.
    #
    # Size still tracks the input instead of Rust's fixed `1 << 32` (4 GiB of lazily-mapped virtual
    # address space): one expression cannot exceed its own input, so `2L` stays a safe upper bound.
    buf = Vector{UInt8}(undef, max(length(bv) * 2, 64))
    while true
        z = ExprZipper(MORK.Expr(buf), 1)
        try
            sexpr_parse!(parser, ctx, z)
        catch e
            if e isa SexprException && e.err == SERR_INPUT_FINISHED
                break
            end
            rethrow()
        end
        data = z.root.buf[1:(z.loc - 1)]
        if add
            set_val_at!(s.btm, data, UNIT_VAL)
        else
            remove_val_at!(s.btm, data)
        end
        empty!(ctx.variables)   # clear variable bindings between expressions
        i += 1
    end
    i
end

# =====================================================================
# space_dump_all_sexpr
# =====================================================================

"""
    space_dump_all_sexpr(s, io) → Int

Write all stored expressions to `io`, one per line, in s-expression text form.
Mirrors `Space::dump_all_sexpr` (no-interning path).
"""
function space_dump_all_sexpr(s::Space, io::IO)::Int
    # Upstream makes this the FIRST statement of `dump_all_sexpr` (space.rs:955), and serialization
    # is the right hook: it is where a space becomes something someone reasons about, so it is where
    # "the two engines will not agree on this space" needs saying. Ported 2026-08-21 — and wired in
    # the SAME commit, because the previous three layers of this port were written, tested, and
    # called by nothing. [[feedback_parses_is_not_fires]]
    warn_top_level_variable(s)
    rz = read_zipper(s.btm)
    i = 0
    while zipper_to_next_val!(rz)
        path = collect(zipper_path(rz))
        # upstream dump_all_sexpr uses serialize2 (space.rs:903) with VARNAMES, so variables print
        # as `\$a`/`\$b` and a binder shares its name with every back-reference to it. Ours printed
        # `\$`/`_N` (plain `serialize`) until 2026-07-31 — verified against the release binary:
        # `(twice \$y \$y)` dumps as `(twice \$a \$a)` upstream and printed `(twice \$ _1)` here.
        println(io, expr_serialize2(path))
        i += 1
    end
    i
end

space_dump_all_sexpr(s::Space) =
    (io=IOBuffer(); space_dump_all_sexpr(s, io); String(take!(io)))

# =====================================================================
# space_load_json! — JSON → PathMap (mirrors Space::load_json)
# =====================================================================

"""
    SpaceTranscriber

`JSONTranscriber` that writes parsed JSON tokens into a `WriteZipperCore`.
Mirrors `SpaceTranscriber` in space.rs.
"""
mutable struct SpaceTranscriber <: JSONTranscriber
    count::Int
    wz::WriteZipperCore
    parser::SpaceParser
end

function SpaceTranscriber(wz::WriteZipperCore)
    SpaceTranscriber(0, wz, SpaceParser())
end

function _st_write!(t::SpaceTranscriber, bytes::AbstractVector{UInt8})
    tok = fe_tokenizer(t.parser, bytes)
    path = vcat(UInt8[item_byte(ExprSymbol(UInt8(length(tok))))], tok)
    wz_descend_to!(t.wz, path)
    wz_set_val!(t.wz, UNIT_VAL)
    wz_ascend!(t.wz, length(path))
    t.count += 1
end

jt_begin!(t::SpaceTranscriber) = nothing
jt_end!(t::SpaceTranscriber) = nothing
jt_write_empty_array!(t::SpaceTranscriber) = _st_write!(t, Vector{UInt8}("[]"))
jt_write_empty_object!(t::SpaceTranscriber) = _st_write!(t, Vector{UInt8}("{}"))
jt_write_true!(t::SpaceTranscriber) = _st_write!(t, Vector{UInt8}("true"))
jt_write_false!(t::SpaceTranscriber) = _st_write!(t, Vector{UInt8}("false"))
jt_write_null!(t::SpaceTranscriber) = _st_write!(t, Vector{UInt8}("null"))
jt_write_string!(t::SpaceTranscriber, s::String) = _st_write!(t, Vector{UInt8}(s))

function jt_write_number!(t::SpaceTranscriber, neg::Bool, m::UInt64, e::Int16)
    s = neg ? "-$(m)" : "$(m)"
    e != 0 && (s *= "e$(e)")
    _st_write!(t, Vector{UInt8}(s))
end

function jt_descend_index!(t::SpaceTranscriber, i::Int, first::Bool)
    first && wz_descend_to!(t.wz, UInt8[item_byte(ExprArity(UInt8(2)))])
    tok = fe_tokenizer(t.parser, Vector{UInt8}(string(i)))
    path = vcat(UInt8[item_byte(ExprSymbol(UInt8(length(tok))))], tok)
    wz_descend_to!(t.wz, path)
end

function jt_ascend_index!(t::SpaceTranscriber, i::Int, last::Bool)
    tok = fe_tokenizer(t.parser, Vector{UInt8}(string(i)))
    wz_ascend!(t.wz, length(tok) + 1)
    last && wz_ascend!(t.wz, 1)
end

function jt_descend_key!(t::SpaceTranscriber, k::String, first::Bool)
    first && wz_descend_to!(t.wz, UInt8[item_byte(ExprArity(UInt8(2)))])
    tok = fe_tokenizer(t.parser, Vector{UInt8}(k))
    path = vcat(UInt8[item_byte(ExprSymbol(UInt8(length(tok))))], tok)
    wz_descend_to!(t.wz, path)
end

function jt_ascend_key!(t::SpaceTranscriber, k::String, last::Bool)
    tok = fe_tokenizer(t.parser, Vector{UInt8}(k))
    wz_ascend!(t.wz, length(tok) + 1)
    last && wz_ascend!(t.wz, 1)
end

# =====================================================================
# ASpaceTranscriber + json_to_paths / jsonl_to_paths
# Mirrors ASpaceTranscriber (space.rs:318) and Space::json_to_paths / jsonl_to_paths (:564/:583)
# =====================================================================

"""
    ASpaceTranscriber

upstream `ASpaceTranscriber` (kernel/src/space.rs:318-326) — `SpaceTranscriber` with the write
zipper replaced by a plain PATH BUFFER: it appends the same bytes, hands the completed path to
`emit`, then truncates back. Nothing is inserted into a trie, which is the whole point of the
`*_to_paths` entry points: serialize a JSON document straight to a `.paths` stream without ever
materialising it as a PathMap.

Upstream's `write` is a Rust generator --- `push; yield &wz[..]; truncate` (space.rs:321-326). Julia's
equivalent of yielding to a consumer is either a callback or a `Channel`; the struct takes a
callback and the streaming is arranged by the caller, see [`space_json_to_paths`].
"""
mutable struct ASpaceTranscriber <: JSONTranscriber
    count::Int
    buf::Vector{UInt8}
    parser::SpaceParser
    emit::Function
end

ASpaceTranscriber(emit::Function; buf::Vector{UInt8} = UInt8[], parser::SpaceParser = SpaceParser()) =
    ASpaceTranscriber(0, buf, parser, emit)

function _ast_write!(t::ASpaceTranscriber, bytes::AbstractVector{UInt8})
    tok = fe_tokenizer(t.parser, bytes)
    push!(t.buf, item_byte(ExprSymbol(UInt8(length(tok)))))
    append!(t.buf, tok)
    t.emit(t.buf)                                  # upstream `yield &self.wz[..]`
    resize!(t.buf, length(t.buf) - (length(tok) + 1))
    t.count += 1
end

jt_begin!(t::ASpaceTranscriber) = nothing
jt_end!(t::ASpaceTranscriber) = nothing
jt_write_empty_array!(t::ASpaceTranscriber) = _ast_write!(t, Vector{UInt8}("[]"))
jt_write_empty_object!(t::ASpaceTranscriber) = _ast_write!(t, Vector{UInt8}("{}"))
jt_write_true!(t::ASpaceTranscriber) = _ast_write!(t, Vector{UInt8}("true"))
jt_write_false!(t::ASpaceTranscriber) = _ast_write!(t, Vector{UInt8}("false"))
jt_write_null!(t::ASpaceTranscriber) = _ast_write!(t, Vector{UInt8}("null"))
jt_write_string!(t::ASpaceTranscriber, str::String) = _ast_write!(t, Vector{UInt8}(str))

function jt_write_number!(t::ASpaceTranscriber, neg::Bool, m::UInt64, e::Int16)
    str = neg ? "-$(m)" : "$(m)"
    e != 0 && (str *= "e$(e)")
    _ast_write!(t, Vector{UInt8}(str))
end

function jt_descend_index!(t::ASpaceTranscriber, i::Int, first::Bool)
    first && push!(t.buf, item_byte(ExprArity(UInt8(2))))
    tok = fe_tokenizer(t.parser, Vector{UInt8}(string(i)))
    push!(t.buf, item_byte(ExprSymbol(UInt8(length(tok)))))
    append!(t.buf, tok)
end

function jt_ascend_index!(t::ASpaceTranscriber, i::Int, last::Bool)
    tok = fe_tokenizer(t.parser, Vector{UInt8}(string(i)))
    resize!(t.buf, length(t.buf) - (length(tok) + 1))
    last && resize!(t.buf, length(t.buf) - 1)
end

function jt_descend_key!(t::ASpaceTranscriber, k::String, first::Bool)
    first && push!(t.buf, item_byte(ExprArity(UInt8(2))))
    tok = fe_tokenizer(t.parser, Vector{UInt8}(k))
    push!(t.buf, item_byte(ExprSymbol(UInt8(length(tok)))))
    append!(t.buf, tok)
end

function jt_ascend_key!(t::ASpaceTranscriber, k::String, last::Bool)
    tok = fe_tokenizer(t.parser, Vector{UInt8}(k))
    resize!(t.buf, length(t.buf) - (length(tok) + 1))
    last && resize!(t.buf, length(t.buf) - 1)
end

# THIS IS THE PORT OF `Parser::parse_stream` (frontend/src/json_parser.rs:874), which has no separate
# function here and does not need one. Upstream's `parse_stream` is `parse` rewritten as a coroutine
# so it can YIELD each path to a consumer; its only two call sites in the entire tree are
# `json_to_paths` (space.rs:571) and `jsonl_to_paths` (:600), both below. Our `json_parse!` already
# drives the transcriber synchronously, and a transcriber whose `emit` is `put!(channel, …)`
# suspends the producing task at exactly the point Rust yields. Same streaming, no second parser.
#
# Bridge a PUSH-based producer (the transcriber calls `emit` per path) to PathMap's PULL-based
# `serialize_paths_from_funcs(target, advance_f, path_f)`. Upstream inverts this with two Rust
# coroutines resumed against each other; a `Channel` is Julia's own coroutine and does the same job,
# streaming path-by-path rather than buffering the document. `take!` on a closed, drained Channel
# throws InvalidStateException — that is the "no more paths" signal.
function _paths_stream_to(target::IO, produce!::Function)::Int
    produced = Ref(0)
    ch = Channel{Vector{UInt8}}(256) do c
        produced[] = produce!(p -> put!(c, copy(p)))
    end
    cur = Ref(UInt8[])
    serialize_paths_from_funcs(target,
        function ()
            try
                cur[] = take!(ch)
                true
            catch err
                err isa InvalidStateException && return false
                rethrow()
            end
        end,
        () -> cur[])
    produced[]
end

"""
    space_json_to_paths(s, src, target) → Int

upstream `Space::json_to_paths` (kernel/src/space.rs:564-581) — parse JSON and write every resulting
path straight into `target` as a zlib `.paths` stream, WITHOUT building a trie. Returns the number of
paths written.

The `.paths` bytes are produced by PathMap's `serialize_paths_from_funcs`, the same deflate-level-7
engine `serialize_paths` uses, so the output is the ordinary `.paths` format.
"""
function space_json_to_paths(s::Space, src, target::IO)::Int
    bv = src isa Vector{UInt8} ? src : Vector{UInt8}(src)
    _paths_stream_to(target, function (emit)
        st = ASpaceTranscriber(emit)
        json_parse!(JSONParser(bv), st)
        st.count
    end)
end

"""
    space_jsonl_to_paths(s, src, target) → (lines, count)

upstream `Space::jsonl_to_paths` (kernel/src/space.rs:583-616) — one JSON document per line, each
filed under a `(JSONL <line-index-as-8-BE-bytes> …)` prefix, streamed to `target` as `.paths`.

The prefix is built ONCE and only the 8 index bytes are rewritten per line (upstream pushes them,
parses, then `wz.truncate(wz.len() - 8)`), so the arity/symbol header is shared by every line.
"""
function space_jsonl_to_paths(s::Space, src, target::IO)::Tuple{Int, Int}
    bv = src isa Vector{UInt8} ? src : Vector{UInt8}(src)
    lines = Ref(0)
    parser = SpaceParser()

    # (JSONL <8-byte index> <document>) — the constant head, built once
    jsonl_tok = fe_tokenizer(parser, Vector{UInt8}("JSONL"))
    head = UInt8[item_byte(ExprArity(UInt8(3))),
                 item_byte(ExprSymbol(UInt8(length(jsonl_tok))))]
    append!(head, jsonl_tok)
    push!(head, item_byte(ExprSymbol(UInt8(8))))

    count = _paths_stream_to(target, function (emit)
        total = 0
        buf = copy(head)
        for line in split(String(copy(bv)), '\n')
            isempty(line) && continue
            append!(buf, reinterpret(UInt8, [hton(UInt64(lines[]))]))   # 8 bytes, big-endian
            st = ASpaceTranscriber(emit; buf = buf, parser = parser)
            json_parse!(JSONParser(Vector{UInt8}(line)), st)
            resize!(buf, length(buf) - 8)                                # upstream's truncate(len-8)
            lines[] += 1
            total += st.count
        end
        total
    end)
    (lines[], count)
end

"""
    space_load_json!(s, src) → Int

Parse JSON `src` and insert the resulting expression tree into the Space.
Mirrors `Space::load_json`.
"""
function space_load_json!(s::Space, src)::Int
    bv = src isa Vector{UInt8} ? src : Vector{UInt8}(src)
    wz = write_zipper(s.btm)
    st = SpaceTranscriber(wz)
    p = JSONParser(bv)
    json_parse!(p, st)
    st.count
end

"""
    space_load_jsonl!(s, src) → (lines, count)

upstream `Space::load_jsonl` (kernel/src/space.rs:619-641) — load JSON **Lines**: one JSON document
per input line, each filed under `(JSONL <line-index> …)`.

Upstream builds the shared prefix ONCE — `Arity(3)`, then the `JSONL` symbol — descends to it, and
then per line descends 8 more bytes of big-endian line index, transcribes that line, and ascends
those 8 bytes again:

    let spo_symbol = pdp.tokenizer("JSONL".as_bytes());
    let mut path = vec![item_byte(Tag::Arity(3)), item_byte(Tag::SymbolSize(spo_symbol.len() as u8))];
    path.extend_from_slice(spo_symbol);
    wz.descend_to(&path[..]);
    for line in ….lines() {
        wz.descend_to(lines.to_be_bytes());
        … transcribe …
        wz.ascend(8);
    }

The `Arity(3)` is upstream's, not a typo: the prefix contributes the head symbol and the line index,
and the transcribed document supplies the third slot.

⚠️ The tokenizer call is what applies the 63-byte symbol cap, so `JSONL` goes through `SpaceParser`
(≡ `ParDataParser`) rather than being spliced raw — the same distinction that made
`space_sexpr_to_expr` wrong.
"""
function space_load_jsonl!(s::Space, src)::Tuple{Int, Int}
    bv = src isa Vector{UInt8} ? src : Vector{UInt8}(src)
    wz = write_zipper(s.btm)
    tok = fe_tokenizer(SpaceParser(), Vector{UInt8}("JSONL"))
    prefix = vcat(UInt8[item_byte(ExprArity(UInt8(3))), item_byte(ExprSymbol(UInt8(length(tok))))], tok)
    wz_descend_to!(wz, prefix)
    lines = 0
    count = 0
    for line in split(String(copy(bv)), '\n')
        isempty(line) && continue                      # `str::lines()` yields no trailing empty line
        wz_descend_to!(wz, collect(reinterpret(UInt8, [hton(UInt64(lines))])))
        st = SpaceTranscriber(wz)
        json_parse!(JSONParser(Vector{UInt8}(line)), st)
        count += st.count
        lines += 1
        wz_ascend!(wz, 8)
    end
    (lines, count)
end

"""
    space_load_json_!(s, src, pattern, template) → count

upstream `Space::load_json_` (kernel/src/space.rs:643-651) — load one JSON document beneath the
template's CONSTANT PREFIX rather than at the trie root:

    let constant_template_prefix = template.prefix().unwrap_or_else(|_| template.span());
    let mut wz = self.btm.write_zipper_at_path(constant_template_prefix);

⚠️ `pattern` IS UNUSED UPSTREAM. It appears in the signature and never in the body — the document is
transcribed wholesale under the template prefix, with no matching against `pattern` at all. Kept in
our signature to mirror the upstream API rather than silently dropping a parameter, and flagged here
so nobody "implements" a filter upstream does not have.
"""
function space_load_json_!(s::Space, src, pattern::MORK.Expr, template::MORK.Expr)::Int
    bv = src isa Vector{UInt8} ? src : Vector{UInt8}(src)
    prefix = try
        _derive_prefix(template)
    catch
        expr_span(template)                            # upstream `unwrap_or_else(|_| template.span())`
    end
    wz = write_zipper_at_path(s.btm, prefix)
    st = SpaceTranscriber(wz)
    json_parse!(JSONParser(bv), st)
    st.count
end

# =====================================================================
# space_query_multi — pattern matching (no_search / ProductZipper + unify)
# =====================================================================

"""
    BreakQuery

Exception used to implement early termination of a query (mirrors `longjmp`
in the Rust implementation).
"""
struct BreakQuery <: Exception end

"""
    space_query_multi(btm, pat_expr, effect) → Int

Iterate all expressions in `btm` that unify with the pattern encoded in
`pat_expr`, calling `effect(bindings, expr_bytes) -> Bool` on each match.
Return the total number of candidates examined.

`pat_expr` must be an arity node: first child is the "add" expression,
remaining children are the sources (patterns to unify against).
Matches iterate via `ProductZipper` (the `#[cfg(feature="no_search")]` path).

The `bindings` Dict passed to `effect` is a fresh allocation per match — safe
to retain across calls.  (Internal path uses a scratch Dict + copy-on-yield to
eliminate per-failed-unify allocations while preserving this contract.)

Mirrors `Space::query_multi` in space.rs.
"""
function space_query_multi(btm::PathMap{UnitVal}, pat_expr::MORK.Expr,
    pat_v::UInt8, effect::Function)::Int
    pat_tag = byte_item(pat_expr.buf[1])
    pat_tag isa ExprArity || error("pat_expr must be an Arity node")
    n_factors = Int(pat_tag.arity)
    n_factors > 0 || error("pat_expr arity must be > 0")

    if n_factors == 1
        effect(Bindings(), pat_expr.buf)
        return 1
    end

    _bindings_scratch = Bindings()
    _pairs_scratch = Tuple{ExprEnv, ExprEnv}[]

    _space_query_multi_inner!(btm, pat_expr, pat_v, n_factors, effect,
        _bindings_scratch, _pairs_scratch)
end

# Compat wrapper with pat_v=0
space_query_multi(btm::PathMap{UnitVal}, pat_expr::MORK.Expr, effect::Function) =
    space_query_multi(btm, pat_expr, UInt8(0), effect)

"""
    space_query_multi_at(btm, prefix, pat_expr, [pat_v], effect) → Int

Prefix-anchored variant of `space_query_multi`.  All factor zippers anchor
at `prefix` (rather than root), so the query operates on the subtrie under
`prefix`.  The combined path passed to `effect` is the FULL path including
`prefix` — callers that want path bytes relative to the prefix should strip
the leading `length(prefix)` bytes themselves.

Use case: Core's "spaces as prefixes" model (Stage 1 of single-node
convergence) where `common:/`, `app/games:/`, etc. are sibling byte-regions
in one shared trie.  Routing a query under one space's prefix limits its
results to that space without scanning the whole trie.

Upstream parity note: upstream MORK has commented-out experiments at this
shape (kernel/src/space.rs:1883, 2117) but no shipped public API.  This
function is the Julia kernel filling that gap — follows the existing `_at!`
pattern from `space_metta_calculus_at!`.
"""
function space_query_multi_at(btm::PathMap{UnitVal}, prefix::Vector{UInt8},
    pat_expr::MORK.Expr, pat_v::UInt8, effect::Function)::Int
    isempty(prefix) && return space_query_multi(btm, pat_expr, pat_v, effect)

    pat_tag = byte_item(pat_expr.buf[1])
    pat_tag isa ExprArity || error("pat_expr must be an Arity node")
    n_factors = Int(pat_tag.arity)
    n_factors > 0 || error("pat_expr arity must be > 0")

    if n_factors == 1
        effect(Bindings(), pat_expr.buf)
        return 1
    end

    _bindings_scratch = Bindings()
    _pairs_scratch = Tuple{ExprEnv, ExprEnv}[]

    _space_query_multi_inner!(btm, pat_expr, pat_v, n_factors, effect,
        _bindings_scratch, _pairs_scratch; prefix=prefix)
end

space_query_multi_at(btm::PathMap{UnitVal}, prefix::Vector{UInt8},
    pat_expr::MORK.Expr, effect::Function) =
    space_query_multi_at(btm, prefix, pat_expr, UInt8(0), effect)

# =====================================================================
# space_query_multi_i — I-pattern query using ASource dispatch
# Mirrors Space::query_multi_i (no_source=false path) in space.rs.
#
# For each argument of the I-pattern, calls asource_new() to dispatch:
#   CompatSource / BTMSource → plain read zipper (same as comma pattern)
#   CmpSource (== / !=)      → PrefixZipper<DependentZipper> via source_factor
#
# All factors are combined in a ProductZipperG, then iterated like
# query_multi_raw: focus must be on the last factor before yielding.
# origin_path (including any prefix from CmpSource) is used as the
# expression for unification, with factor_paths adjusted by prefix length.
# =====================================================================

function space_query_multi_i(btm::PathMap{UnitVal}, pat_expr::MORK.Expr,
    pat_v::UInt8, effect::Function;
    mmaps::Dict{String, ArenaCompactTree}=Dict{String, ArenaCompactTree}())::Int
    pat_tag = byte_item(pat_expr.buf[1])
    pat_tag isa ExprArity || return 0
    n_factors = Int(pat_tag.arity)
    n_factors > 0 || return 0

    if n_factors == 1
        effect(Bindings(), pat_expr.buf)
        return 1
    end

    pat_args = ExprEnv[]
    ee_args!(ExprEnv(UInt8(0), pat_v, UInt32(0), pat_expr), pat_args)
    sources = pat_args[2:end]   # ExprEnv for each sub-pattern

    # Separate grounded sources from trie sources.
    # GroundedSources are evaluated AFTER trie sources match, using bound variables.
    src_types = ASource[]
    trie_idxs = Int[]    # indices into sources[] of trie (non-grounded) sources
    grnd_idxs = Int[]    # indices into sources[] of grounded sources
    for (k, ee) in enumerate(sources)
        span = expr_span(ee.base, Int(ee.offset) + 1)
        sub = MORK.Expr(Vector{UInt8}(span))
        src = asource_new(sub)
        push!(src_types, src)
        src isa GroundedSource ? push!(grnd_idxs, k) : push!(trie_idxs, k)
    end

    candidate = 0
    bindings_scratch = Bindings()
    pairs_scratch = Tuple{ExprEnv, ExprEnv}[]

    # ── Case 1: all sources are grounded (no trie query needed) ──────
    if isempty(trie_idxs)
        for k in grnd_idxs
            src = src_types[k]::GroundedSource
            results = _grounded_call_no_args(src)
            for path in results
                candidate += 1
                effect(Bindings(), path) || return candidate
            end
        end
        return candidate
    end

    # ── Case 2: mixed or trie-only — build ProductZipperG for trie sources ──
    trie_ees = sources[trie_idxs]
    trie_srcs = src_types[trie_idxs]
    # Build the source factors with their RUNTIME element type — NOT `Any[]`. A Vector{Any} here
    # erased the zipper types into `ProductZipperG`'s (formerly Any) fields, so every descent step
    # boxed + dynamically dispatched the `_zpg_*` ops (438M allocs wedged ip_sudoku). `trie_srcs` has
    # an abstract eltype so the comprehension can't be statically narrow; `identity.(…)` re-infers the
    # eltype from the actual factors — concrete when the query's sources are homogeneous (the common
    # case), a small union otherwise, which the parameterized ProductZipperG union-splits.
    factors = identity.([src isa ACTSource ? source_factor(src, btm, mmaps) : source_factor(src, btm)
                         for src in trie_srcs])

    primary = popfirst!(factors)
    prz = ProductZipperG(primary, factors)
    prefix_len = pzg_root_prefix_len(prz)

    # Per-complete-match processing, shared by the naive enumerator AND the coreferential DFS. Returns
    # false ⇒ early-terminate the query. Factored out of the old inline `while` so the SOURCE path can
    # route through `_coreferential_transition!` (the coref-source-join port, 2026-07-23): upstream runs
    # the SAME coref DFS over ProductZipperG (space.rs query_multi_i:1150 + 1227), which PRUNES the naive
    # cross-product explosion (ip_sudoku's higher-order meta-exec). `candidate` is captured + mutated
    # (boxed) so both drivers share the count. The old naive filters (focus_factor / child_count) are
    # preserved verbatim so coref and naive produce identical results — coref just prunes the traversal.
    process_match = function (loc)
        combined = collect(pzg_origin_path(loc))
        fps = pzg_factor_paths(loc)
        boundaries = vcat(0, [fp + prefix_len for fp in fps], length(combined))

        empty!(pairs_scratch)
        all_sliced = true
        for (i, ee) in enumerate(trie_ees)
            lo = boundaries[i] + 1
            hi = boundaries[i + 1]
            if lo > hi || lo > length(combined)
                all_sliced = false;
                break
            end
            expr = MORK.Expr(combined[lo:hi])
            push!(pairs_scratch, (ee, ExprEnv(UInt8(i), UInt8(0), UInt32(0), expr)))
        end
        all_sliced || return true

        pzg_child_count(loc) != 0 && (empty!(bindings_scratch); return true)

        # SP-1 fix (audit 2026-06-04): was `try …unify… catch; nothing end`, which
        # swallowed EVERY exception as a benign no-match. `_expr_unify_inplace!` returns
        # its failure as a VALUE (≠ true) on genuine non-unification and only THROWS on a
        # real bug (malformed expr / BoundsError) — so the catch could only hide bugs.
        result = _expr_unify_inplace!(pairs_scratch, bindings_scratch)
        if result !== true
            empty!(bindings_scratch)
            return true
        end

        # Apply bindings to each grounded source and call the function
        trie_bindings = copy(bindings_scratch)
        empty!(bindings_scratch)

        if isempty(grnd_idxs)
            candidate += 1
            return effect(trie_bindings, combined)
        else
            for k in grnd_idxs
                src = src_types[k]::GroundedSource
                result_paths = _grounded_call_with_bindings(src, trie_bindings)
                isempty(result_paths) && break
                for rpath in result_paths
                    candidate += 1
                    merged = vcat(combined, rpath)
                    effect(trie_bindings, merged) || return false
                end
            end
            return true
        end
    end

    if _USE_COREF_JOIN[]
        # Coreferential DFS over the ProductZipperG — THE coref-source-join fix. Binds higher-order
        # vars structurally (O(depth)), pruning the Cartesian product the naive enumerator explodes on
        # (ip_sudoku / dtl). Mirrors the non-source `_space_query_multi_inner!` coref branch: sticky
        # large-stack Task (deep bc recursion), BreakQuery early-exit. cstack = trie source patterns
        # reversed (LIFO pop → in-order); grounded sources are NOT in the DFS (applied per match above).
        cstack = collect(reverse(trie_ees))
        crefs = Int[]
        _coref_work = function ()
            try
                _coreferential_transition!(prz, cstack, crefs, function (loc)
                    process_match(loc) || throw(BreakQuery())
                    nothing
                end)
            catch e
                e isa BreakQuery || rethrow()
            end
        end
        _t = Task(_coref_work, _COREF_STACK_SIZE)
        _t.sticky = true
        schedule(_t)
        fetch(_t)
    else
        while pzg_to_next_val!(prz)
            pzg_focus_factor(prz) != pzg_factor_count(prz) - 1 && continue
            process_match(prz) || break
        end
    end

    candidate
end

# ── Grounded call helpers ─────────────────────────────────────────────

"""Call a GroundedSource with no variable arguments (all-grounded case)."""
function _grounded_call_no_args(src::GroundedSource)::Vector{Vector{UInt8}}
    f = get(GROUNDED_REGISTRY, src.name, nothing)
    f === nothing && return Vector{UInt8}[]
    args = _grounded_decode_args(src.expr)
    raw = try
        f(args)
    catch e
        ;
        @warn "GroundedSource $(src.name): $e";
        nothing
    end
    _grounded_encode_results(raw)
end

"""Call a GroundedSource after substituting trie-matched variable bindings."""
function _grounded_call_with_bindings(src::GroundedSource,
    bindings::Bindings)::Vector{Vector{UInt8}}
    f = get(GROUNDED_REGISTRY, src.name, nothing)
    f === nothing && return Vector{UInt8}[]
    # Apply bindings to each argument before decoding
    raw_args = _grounded_decode_args(src.expr)
    bound_args = map(raw_args) do a
        # Re-encode the arg string, apply bindings, re-decode
        try
            e = sexpr_to_expr(a)
            applied = _expr_apply_bindings(e, bindings)
            expr_serialize(applied.buf)
        catch
            a  # fallback: pass as-is
        end
    end
    raw = try
        f(bound_args)
    catch e
        ;
        @warn "GroundedSource $(src.name): $e";
        nothing
    end
    _grounded_encode_results(raw)
end

"""Apply variable bindings to an Expr, returning a new Expr with variables replaced."""
function _expr_apply_bindings(e::MORK.Expr, bindings::Bindings)::MORK.Expr
    isempty(bindings) && return e
    # Walk bytes and substitute NewVar/VarRef bytes with bound expression bytes
    out = UInt8[]
    buf = e.buf
    i = 1
    var_idx = UInt8(0)
    while i <= length(buf)
        b = buf[i]
        t = byte_item(b)
        if t isa ExprNewVar
            binding = get(bindings, (var_idx, UInt8(0)), nothing)
            if binding !== nothing
                span = expr_span(binding.base, Int(binding.offset) + 1)
                append!(out, span)
            else
                push!(out, b)
            end
            var_idx += UInt8(1)
            i += 1
        elseif t isa ExprVarRef
            binding = get(bindings, (UInt8(0), t.index), nothing)
            if binding !== nothing
                span = expr_span(binding.base, Int(binding.offset) + 1)
                append!(out, span)
            else
                push!(out, b)
            end
            i += 1
        elseif t isa ExprSymbol
            n = Int(t.size)
            append!(out, buf[i:(i + n)])
            i += n + 1
        elseif t isa ExprArity
            push!(out, b)
            i += 1
        else
            push!(out, b);
            i += 1
        end
    end
    MORK.Expr(out)
end

space_query_multi_i(btm::PathMap{UnitVal}, pat_expr::MORK.Expr, effect::Function) =
    space_query_multi_i(btm, pat_expr, UInt8(0), effect)

# Internal hot path — takes pre-allocated scratch buffers so the
# per-unify-attempt Dict allocation is eliminated.
#
# `prefix` kwarg (default empty = root) anchors all factor zippers at the
# given byte-prefix.  Empty prefix preserves the original root-anchored
# behavior — no overhead for the common case.
function _space_query_multi_inner!(btm::PathMap{UnitVal},
    pat_expr::MORK.Expr,
    pat_v::UInt8,
    n_factors::Int,
    effect::Function,
    bindings_scratch::Bindings,
    pairs_scratch::Vector{Tuple{ExprEnv, ExprEnv}};
    prefix::Vector{UInt8}=UInt8[])::Int
    # Rule of 64: warn if pattern exceeds practical source limit.
    # ProductZipper with N>2 factors iterates N^M paths (M=trie depth) and
    # becomes intractable beyond 2 secondary factors in practice.
    n_factors > 4 &&
        @warn "query_multi: $(n_factors) sources (>4) may be slow — Rule of 64 boundary"

    pat_args = ExprEnv[]
    ee0 = ExprEnv(UInt8(0), pat_v, UInt32(0), pat_expr)
    ee_args!(ee0, pat_args)
    sources = pat_args[2:end]

    # ADR-056 P1b: empty-tail trie-join fast path (root queries only). When every factor
    # is `(sym $v)` sharing ONE variable, compute the join as a trie meet (`pmeet`) of the
    # relations' arg-value subtries instead of the naive ProductZipper (N^k). Any other
    # shape, or an anchored (non-empty prefix) query, falls through UNCHANGED below.
    # Defined in kernel/TrieJoin.jl; validated ≡ ProductZipper (test/integration/trie_join.jl).
    # ⚠️ EVERY fast path below is guarded by `_any_relation_has_var_atom`. A stored atom carrying a
    # variable is a higher-order pattern that upstream matches by UNIFICATION — its coref DFS descends
    # into data-side variable bytes (`vs!`, space.rs:94-111) so `(p $x)` acts as a WILDCARD. Exact-byte
    # trie keying cannot express that and SILENTLY UNDER-GENERATES, so these paths must DECLINE on
    # var-bearing data and let the coref DFS below handle it (see `_relation_has_var_atom` for the
    # measured evidence: the probe corpus went 33/41 → 40/41 once the fast paths stopped firing here).
    # The scan is LAZY and memoised: `_tj_safe()` runs `_any_factor_relation_has_var_atom` at most
    # ONCE per query, and only after some `_classify_*` has already matched the query SHAPE. Ordering
    # matters — an eager check before the classifies made EVERY query pay a relation scan, including
    # the majority that match no fast path at all, which cost ~31% of total suite time (measured
    # 2m30 -> 3m17 across two runs each side). The classifies are pattern-only and cheap; the scan
    # touches data, so it must come second.
    _tj_var_safe = Ref{Union{Nothing, Bool}}(nothing)
    _tj_safe() = (_tj_var_safe[] === nothing &&
                      (_tj_var_safe[] = !_any_factor_relation_has_var_atom(btm, sources));
                  _tj_var_safe[]::Bool)
    if isempty(prefix) && _TRIE_JOIN_ENABLED[]
        _tj_ok, _tj_hps = _classify_empty_tail(sources)
        if _tj_ok && _tj_safe()
            return _trie_join_emit!(btm, sources, _tj_hps, effect, bindings_scratch, pairs_scratch)
        end
        # P2: general binary join (e.g. (edge $x $y)(edge $y $z)) via key-rotation.
        _bj_ok, _bj_k1, _bj_k2, _bj_h1, _bj_h2 = _classify_binary_join(sources)
        if _bj_ok && _tj_safe()
            return _binary_join_emit!(btm, sources, _bj_k1, _bj_k2, _bj_h1, _bj_h2,
                                            effect, bindings_scratch, pairs_scratch)
        end
        # P2c: compound-arg binary join — shared var NESTED in a compound argument,
        # e.g. ((join ($ctx case/0)) $a)(eval ($a) -> $b). Tried only after the
        # top-level P2 fails. Defined in kernel/TrieJoin.jl.
        _nbj_ok, _nlp1, _nvp1, _nlp2, _nvp2 = _classify_binary_join_nested(sources)
        if _nbj_ok && _tj_safe()
            _nh, _nc = _nested_binary_join_emit!(btm, sources, _nlp1, _nvp1, _nlp2, _nvp2,
                                            effect, bindings_scratch, pairs_scratch)
            _nh && return _nc      # else: stored higher-order key — fall through to ProductZipper
        end
        # P3: strict k≥3 chain join (e.g. (edge $x $y)(edge $y $z)(edge $z $w)) via
        # recursive streaming. Non-chain k≥3 shapes fall through to ProductZipper.
        _ch_ok, _ch_hps = _classify_chain(sources)
        if _ch_ok && _tj_safe()
            return _chain_join_emit!(btm, sources, _ch_hps, effect, bindings_scratch, pairs_scratch)
        end
        # P5: pipelined hash join for any CONNECTED k≥3 conjunction the chain rejects
        # (e.g. going-wide (0 join) case/2 = k-way star + eval consumer). Defined in
        # kernel/TrieJoin.jl. Bails to ProductZipper on a higher-order (var) key.
        _cn_ok, _cn_ord, _cn_occ, _cn_lps = _classify_connected(sources)
        if _cn_ok && _tj_safe()
            _cnh, _cnc = _connected_join_emit!(btm, sources, _cn_ord, _cn_occ, _cn_lps,
                                           effect, bindings_scratch, pairs_scratch)
            _cnh && return _cnc
        end
    end

    candidate = 0
    # Fix 3: checkout secondary zippers from the task-local pool instead of
    # allocating fresh ReadZipperCore objects on every call.  The primary is
    # still freshly allocated (ProductZipper mutates it as its cursor).
    # Pooled zippers are reinitialized from btm before use and returned after
    # ProductZipper is constructed (constructor only reads root_node/root_val/alloc).
    n_secondaries = n_factors - 2
    # Build the product zipper.  Two anchoring regimes:
    #   • empty prefix (root query, the hot path): pooled secondary zippers,
    #     unchanged from the original implementation.
    #   • non-empty prefix: the anchored ProductZipper(btm, prefix, k) which
    #     roots ALL k = n_factors-1 factors at the prefix-subtrie node (a true
    #     O(subtrie) view).  This replaces the old read_zipper_at_path(btm,
    #     prefix) approach, whose anchor the base ProductZipper discarded —
    #     producing absolute paths whose raw prefix bytes crashed expr decode.
    prz = if isempty(prefix)
        pool = _zipper_pool_get!()
        secondaries_pooled = Vector{Any}(undef, n_secondaries)
        primary = read_zipper_at_path(btm, prefix)
        for i in 1:n_secondaries
            z = _pool_checkout!(pool)
            if z === nothing
                z = read_zipper_at_path(btm, prefix)
            else
                _reinit_zipper_from_btm!(z, btm)
            end
            secondaries_pooled[i] = z
        end
        p = ProductZipper(primary, secondaries_pooled)
        for i in 1:n_secondaries
            _pool_return!(pool, secondaries_pooled[i])   # ProductZipper extracted root refs
        end
        p
    else
        ProductZipper(btm, prefix, n_factors - 1)
    end

    # Per-complete-match processing shared by BOTH drivers. The ProductZipper encodes
    # all factor paths in ONE combined path; factor_paths marks the byte boundary where
    # factor i ends / i+1 begins. Slice per source, value-gate (the matched factor must
    # be a REAL stored atom — not a dangling node left by a non-pruning remove_val_at!,
    # which restores the value-presence invariant upstream's path_exists() gate relies on),
    # unify, and dispatch to `effect`. Returns false ⇒ early-terminate.
    process_combined = function (combined::Vector{UInt8}, fps)
        empty!(pairs_scratch)
        boundaries = vcat(0, fps, length(combined))
        all_valued = true
        for (k, src) in enumerate(sources)
            lo = boundaries[k] + 1
            hi = boundaries[k + 1]
            (lo > hi || lo > length(combined)) && break
            subpath = combined[lo:hi]
            lookup = isempty(prefix) ? subpath : vcat(prefix, subpath)
            if get_val_at(btm, lookup) === nothing
                all_valued = false
                break
            end
            expr = MORK.Expr(subpath)
            push!(pairs_scratch, (src, ExprEnv(UInt8(k), UInt8(0), UInt32(0), expr)))
        end
        if !all_valued || length(pairs_scratch) < length(sources)
            empty!(bindings_scratch)
            return true
        end
        result = _expr_unify_inplace!(pairs_scratch, bindings_scratch)
        if result === true
            candidate += 1
            bindings_out = copy(bindings_scratch)   # fresh Dict (effect may retain it)
            empty!(bindings_scratch)
            effect(bindings_out, MORK.Expr(combined))
        else
            empty!(bindings_scratch)
            return true
        end
    end

    if _USE_COREF_JOIN[]
        # Coreferential DFS over the ProductZipper — upstream's DEFAULT query_multi_raw
        # path: prunes inconsistent branches structurally (binds higher-order vars in
        # O(depth), not by enumerating the subtrie) instead of the full Cartesian product.
        # stack = all sources reversed (LIFO pop → in-order); references tracks De Bruijn binds.
        cstack = collect(reverse(sources))
        crefs = Int[]
        _coref_work = function ()
            try
                _coreferential_transition!(prz, cstack, crefs, function (loc)
                    process_combined(collect(pz_path(loc)), loc.factor_paths) || throw(BreakQuery())
                    nothing
                end)
            catch e
                e isa BreakQuery || rethrow()
            end
        end
        # Large-stack task so deep (backward-chaining) recursion doesn't overflow. sticky=true
        # keeps it on the current thread (no cross-thread zipper access). fetch propagates errors.
        _t = Task(_coref_work, _COREF_STACK_SIZE)
        _t.sticky = true
        schedule(_t)
        fetch(_t)
    else
        # Naive ProductZipper enumeration (the `#[cfg(feature="no_search")]` path).
        try
            while pz_to_next_val!(prz)
                pz_focus_factor(prz) != pz_factor_count(prz) - 1 && continue
                process_combined(collect(pz_path(prz)), prz.factor_paths) || throw(BreakQuery())
            end
        catch e
            e isa BreakQuery || rethrow()
        end
    end

    candidate
end

space_query_multi(s::Space, pat::MORK.Expr, f::Function) =
    space_query_multi(s.btm, pat, f)

# =====================================================================
# coreferential_transition — DFS query (the no_search=false path)
# =====================================================================
#
# Mirrors `coreferential_transition` in space.rs (lines 92–212).
#
# This is the alternative to ProductZipper for multi-source queries.
# Instead of generating the full Cartesian product then filtering via
# unify, this DFS tracks variable bindings DURING trie traversal:
#
#   ProductZipper (current):  O(K^N) candidates → filter → O(M) matches
#   Coreferential DFS:        O(M × depth) — explores only consistent paths
#
# When the same variable appears in multiple sources, the DFS records
# the trie path length at first binding (references[i]) and on VarRef
# descends directly to that sub-path — skipping all inconsistent branches.
#
# Algorithm (mirrors Rust recursive DFS):
#   stack  — remaining ExprEnv items to match (popped LIFO)
#   references — path-length offsets for De Bruijn NewVar bindings
#   When stack is empty, f(loc) is called (a match has been found).

# ── Zipper-type-agnostic helpers for _coreferential_transition! ───────────────
# These dispatch on both ReadZipperCore (single-source) and ProductZipper
# (multi-source), allowing one DFS implementation for both paths.

@inline _coref_child_mask(loc::ReadZipperCore) = zipper_child_mask(loc)
@inline _coref_child_mask(loc::ProductZipper) = pz_child_mask(loc)

@inline _coref_path(loc::ReadZipperCore) = zipper_path(loc)
@inline _coref_path(loc::ProductZipper) = pz_path(loc)

# Zero-alloc length of _coref_path — mirrors upstream `loc.path().len()` (space.rs:129). Avoids
# building a SubArray via _coref_path just to take its length. (prefix_buf.len - origin_path_len =
# the same UnitRange length the view would report; origin<=len invariant keeps it non-negative.)
@inline _coref_path_length(loc::ReadZipperCore) = length(loc.prefix_buf) - loc.origin_path_len
@inline _coref_path_length(loc::ProductZipper) = _coref_path_length(loc.z)

# The live path buffer + its origin, for a zero-COPY bound-VarRef alias — mirrors upstream's raw
# `loc.path().as_ptr().offset(ref)` (space.rs:176). We alias the whole Array object and bake the
# offset into ExprEnv.offset. Julia holds the Array OBJECT (follows the current data pointer on each
# read, survives realloc) — strictly safer than a raw pointer. Safe because the recorded value lies
# BELOW the VarRef descent frontier and the balanced DFS never ascends below it (nor rewrites
# committed bytes: prefix_buf is mutated tail-only via push!/resize!) while the ExprEnv is live.
@inline _coref_path_buf(loc::ReadZipperCore) = (loc.prefix_buf, loc.origin_path_len)
@inline _coref_path_buf(loc::ProductZipper) = _coref_path_buf(loc.z)

# Shared NewVar-sentinel Expr — mirrors upstream's `static nv: u8 = item_byte(Tag::NewVar)`
# (space.rs:155-157, 179-180). A 1-byte read-only buffer reused across all unbound-var placeholders
# (Arity-under-NewVar slots + unbound VarRef 'any'); never mutated on the coref path, so sharing one
# const is byte-identical to the per-call `Expr([nv])` it replaces.
const _COREF_NEWVAR_EXPR = MORK.Expr(UInt8[item_byte(ExprNewVar())])

@inline _coref_descend_byte!(loc::ReadZipperCore, b::UInt8) =
    zipper_descend_to_byte!(loc, b)
@inline _coref_descend_byte!(loc::ProductZipper, b::UInt8) = pz_descend_to_byte!(loc, b)

@inline _coref_ascend_byte!(loc::ReadZipperCore) = zipper_ascend_byte!(loc)
@inline _coref_ascend_byte!(loc::ProductZipper) = pz_ascend_byte!(loc)

@inline _coref_ascend!(loc::ReadZipperCore, n::Int) = zipper_ascend!(loc, n)
@inline _coref_ascend!(loc::ProductZipper, n::Int) = pz_ascend!(loc, n)

@inline function _coref_descend_to_existing_byte!(loc::ReadZipperCore, b::UInt8)
    zipper_descend_to_existing_byte!(loc, b)
end
@inline function _coref_descend_to_existing_byte!(loc::ProductZipper, b::UInt8)
    pz_descend_to_existing_byte!(loc, b)
end

@inline function _coref_descend_to_check!(loc::ReadZipperCore, bytes)
    # ⚠️ CONTRACT NORMALISATION. The three underlying primitives disagree about what they leave
    # descended when the check FAILS:
    #   * `pz_descend_to_check!`  (ProductZipper.jl:345-348) and `pzg_descend_to_check!` RESTORE —
    #     they ascend back whatever they descended.
    #   * `zipper_descend_to_check!` (ReadZipperCore) does NOT: `_descend_to_internal!`
    #     (Zipper.jl:440-442) `append!`s ALL of `k` to the prefix buffer and never undoes it.
    # The coref DFS's SymbolSize branch compensates for the RESTORING contract — on failure it
    # ascends ONE byte (the symbol tag) rather than `size + 1`. Under the non-restoring primitive that
    # UNDER-ascends by `size`, leaving the cursor that many bytes too deep and corrupting every
    # enclosing `vs!` / k-path loop.
    #
    # LATENT, not live: this dispatch is reachable only via `space_query_coref` with n_src == 1, which
    # has ZERO callers workspace-wide — every MM2 path goes through ProductZipper/G. Normalising here,
    # at the dispatch layer where the polymorphism already lives, removes the landmine without
    # touching the verified-faithful DFS or PathMap's shared primitive (whose only caller is this
    # function). Found by the space.rs cross-check, 2026-07-26.
    ok = zipper_descend_to_check!(loc, bytes)
    ok || zipper_ascend!(loc, length(bytes))
    ok
end
@inline function _coref_descend_to_check!(loc::ProductZipper, bytes)
    pz_descend_to_check!(loc, bytes)
end

@inline function _coref_descend_first_k_path!(loc::ReadZipperCore, k::Int)
    zipper_descend_first_k_path!(loc, k)
end
@inline function _coref_descend_first_k_path!(loc::ProductZipper, k::Int)
    pz_descend_first_k_path!(loc, k)
end

@inline function _coref_to_next_k_path!(loc::ReadZipperCore, k::Int)
    zipper_to_next_k_path!(loc, k)
end
@inline function _coref_to_next_k_path!(loc::ProductZipper, k::Int)
    pz_to_next_k_path!(loc, k)
end

# ── ProductZipperG (source-aware) — the coref-source-join port (2026-07-23) ──────────────────────
# Same `_coref_*` interface as ProductZipper, backed by ProductZipperG's coref primitives (PathMap
# ProductZipperG.jl). This lets `_coreferential_transition!` run over the SOURCE query path
# (space_query_multi_i), giving it the same coreferential PRUNING the non-source path has and killing
# the naive cross-product explosion (ip_sudoku). Upstream does exactly this: query_multi_i builds a
# ProductZipperG and calls coreferential_transition over it (space.rs:1150, 1227).
@inline _coref_child_mask(loc::ProductZipperG) = pzg_child_mask(loc)
@inline _coref_path(loc::ProductZipperG) = pzg_path(loc)
@inline _coref_path_length(loc::ProductZipperG) = length(pzg_path(loc))
# Zero-copy bound-VarRef alias: ProductZipperG holds the FULL combined path in its PRIMARY factor
# zipper (descended per byte, mirroring the secondaries), so delegate the buffer chain there.
@inline _coref_path_buf(loc::ProductZipperG) = _coref_path_buf(loc.primary)
@inline _coref_descend_byte!(loc::ProductZipperG, b::UInt8) = pzg_descend_to_byte!(loc, b)
@inline _coref_ascend_byte!(loc::ProductZipperG) = pzg_ascend_byte!(loc)
@inline _coref_ascend!(loc::ProductZipperG, n::Int) = pzg_ascend!(loc, n)
@inline _coref_descend_to_existing_byte!(loc::ProductZipperG, b::UInt8) = pzg_descend_to_existing_byte!(loc, b)
@inline _coref_descend_to_check!(loc::ProductZipperG, bytes) = pzg_descend_to_check!(loc, bytes)
@inline _coref_descend_first_k_path!(loc::ProductZipperG, k::Int) = pzg_descend_first_k_path!(loc, k)
@inline _coref_to_next_k_path!(loc::ProductZipperG, k::Int) = pzg_to_next_k_path!(loc, k)

# A DependentZipper (the `!=` source) can BE ProductZipperG's primary; its path bottoms out in a
# ReadZipperCore (dpz_path = rz_path(primary)), so the path-buffer chain terminates there.
@inline _coref_path_buf(loc::DependentZipper) = _coref_path_buf(loc.primary)
@inline _coref_path_length(loc::DependentZipper) = length(dpz_path(loc))

# A PrefixZipper (ACT / prefix-scoped source, and the wrapper ip_sudoku's factors actually use:
# PrefixZipper{DependentZipper{ReadZipper}}) keeps its OWN full absolute-path buffer `pz.path`
# (tail-mutated like ReadZipperCore.prefix_buf: append on descend, resize on ascend), with the first
# `origin_depth` bytes being the root prefix. So the zero-copy VarRef alias uses it directly — no
# further delegation into the wrapped source, since pz.path already holds the whole combined path.
@inline _coref_path_buf(loc::PrefixZipper) = (loc.path, loc.origin_depth)
@inline _coref_path_length(loc::PrefixZipper) = length(loc.path) - loc.origin_depth

# Filtered child lists using precomputed bitmasks — avoids calling byte_item on
# content bytes (0x40-0x7F are reserved and throw; e.g. 'e' = 0x65 from "edge").
# SPACE_VARS/SIZES/ARITIES are NTuple{4,UInt64}: bucket = (b>>6)+1, bit = b&0x3F.
@inline _in_mask(mask::NTuple{4, UInt64}, b::UInt8) =
    ((mask[Int(b >> 6) + 1] >> Int(b & 0x3F)) & UInt64(1)) != UInt64(0)

@inline _var_children(loc) =
    Iterators.filter(b -> _in_mask(SPACE_VARS, b), _coref_child_mask(loc))
@inline _size_children(loc) =
    Iterators.filter(b -> _in_mask(SPACE_SIZES, b), _coref_child_mask(loc))
@inline _arity_children(loc) =
    Iterators.filter(b -> _in_mask(SPACE_ARITIES, b), _coref_child_mask(loc))

"""
    _coreferential_transition!(loc, stack, references, f)

Recursive DFS that explores the trie `loc` matching `stack` of ExprEnvs.
Calls `f(loc)` for each complete match (empty stack).
Mirrors `coreferential_transition` in space.rs.
"""
function _coreferential_transition!(loc,   # ReadZipperCore (single) or ProductZipper (multi)
    stack::Vector{ExprEnv},
    references::Vector{Int},
    f::Function)
    if isempty(stack)
        f(loc)
        return nothing
    end

    e = pop!(stack)
    e_byte = e.base.buf[Int(e.offset) + 1]

    tag = byte_item(e_byte)

    if tag isa ExprNewVar
        # Faithful port: index `references` by the variable's De Bruijn index (e.v), with a
        # -1 "unbound" sentinel (upstream u32::MAX), saving/restoring the prior value on exit.
        # The earlier push!/pop! stack only coincided with e.v for in-order patterns; complex
        # many-var higher-order patterns (bc proofs) need true indexing.
        _nv_idx = -1
        _nv_prev = -1
        if e.n == 0
            _nv_idx = Int(e.v)
            while length(references) <= _nv_idx
                push!(references, -1)
            end
            _nv_prev = references[_nv_idx + 1]
            references[_nv_idx + 1] = _coref_path_length(loc)
        end

        m_vars = _var_children(loc)
        for b in m_vars
            _coref_descend_byte!(loc, b)
            _coreferential_transition!(loc, stack, references, f)
            _coref_ascend_byte!(loc)
        end

        m_sizes = _size_children(loc)
        for b in m_sizes
            tag_s = byte_item(b)
            tag_s isa ExprSymbol || continue
            size = Int(tag_s.size)
            _coref_descend_byte!(loc, b)
            if _coref_descend_first_k_path!(loc, size)
                while true
                    _coreferential_transition!(loc, stack, references, f)
                    _coref_to_next_k_path!(loc, size) || break
                end
            end
            _coref_ascend_byte!(loc)
        end

        m_arities = _arity_children(loc)
        for b in m_arities
            tag_a = byte_item(b)
            tag_a isa ExprArity || continue
            arity = Int(tag_a.arity)
            _coref_descend_byte!(loc, b)
            ol = length(stack)
            for _ in 1:arity
                push!(stack, ExprEnv(UInt8(255), UInt8(0), UInt32(0), _COREF_NEWVAR_EXPR))
            end
            _coreferential_transition!(loc, stack, references, f)
            resize!(stack, ol)
            _coref_ascend_byte!(loc)
        end

        _nv_idx >= 0 && (references[_nv_idx + 1] = _nv_prev)

    elseif tag isa ExprVarRef
        i = Int(tag.idx)   # 0-based De Bruijn index (kept raw; `references` access shifts +1)
        # Faithful port (upstream space.rs:166-188): a back-ref is BOUND iff its index is in
        # range AND not the -1 sentinel — then it resolves to the recorded path offset. An
        # UNBOUND back-ref (sentinel / out of range) is NOT an abort; it matches anything
        # (a fresh NewVar 'any'), exactly as upstream falls to the `else` branch.
        new_ee = if e.n == 0 && i < length(references) && references[i + 1] != -1
            ref_off = references[i + 1]
            # Zero-COPY alias into loc's own live path buffer at the recorded offset (mirrors upstream
            # space.rs:176). Bake the offset into ExprEnv.offset; alias the whole Array object. Reads
            # `base.buf[offset+1] = prefix_buf[origin+ref_off+1]` — the same first value byte the copy
            # `path[ref_off+1]` exposed; consumers walk by self-describing tag structure (not buffer
            # length), so the longer live trailing region is inert. Byte-identical to the old copy.
            pbuf, porigin = _coref_path_buf(loc)
            ExprEnv(UInt8(254), UInt8(0), UInt32(porigin + ref_off), MORK.Expr(pbuf))
        else
            ExprEnv(UInt8(255), UInt8(0), UInt32(0), _COREF_NEWVAR_EXPR)
        end

        # vs!(e, false) — match stored variable children. No sentinel push: the e551924
        # NewVar-sentinel block is commented out in upstream HEAD (space.rs:104-108).
        push!(stack, new_ee)
        m_vars = _var_children(loc)
        for b in m_vars
            _coref_descend_byte!(loc, b)
            _coreferential_transition!(loc, stack, references, f)
            _coref_ascend_byte!(loc)
        end
        _coreferential_transition!(loc, stack, references, f)
        pop!(stack)

    elseif tag isa ExprSymbol
        size = Int(tag.size)
        # vs!(e, false) — match stored variable children; upstream HEAD (revert of e551924)
        # pushes NO typemax sentinel here (that block is commented out in space.rs:104-108).
        m_vars = _var_children(loc)
        for b in m_vars
            _coref_descend_byte!(loc, b)
            _coreferential_transition!(loc, stack, references, f)
            _coref_ascend_byte!(loc)
        end
        if _coref_descend_to_existing_byte!(loc, e_byte)
            sym_bytes = @view e.base.buf[(Int(e.offset) + 2):(Int(e.offset) + 1 + size)]
            if _coref_descend_to_check!(loc, sym_bytes)
                # check SUCCEEDED → descended 1 (sym byte) + size (payload); undo both.
                _coreferential_transition!(loc, stack, references, f)
                _coref_ascend!(loc, size + 1)
            else
                # check FAILED → pz_descend_to_check! restored its own partial descent,
                # so only the 1 sym byte remains descended. Ascending size+1 here would
                # OVER-ascend by `size`, corrupting the caller's k-path cursor (drops
                # coreference matches in 3+ factor joins). Undo only the 1 byte.
                _coref_ascend_byte!(loc)
            end
        end

    elseif tag isa ExprArity
        arity = Int(tag.arity)
        # vs!(e, false) — match stored variable children; no typemax sentinel
        # (upstream HEAD = revert of e551924; space.rs:104-108 commented out).
        m_vars = _var_children(loc)
        for b in m_vars
            _coref_descend_byte!(loc, b)
            _coreferential_transition!(loc, stack, references, f)
            _coref_ascend_byte!(loc)
        end
        if _coref_descend_to_existing_byte!(loc, e_byte)
            ol = length(stack)
            ee_args!(e, stack)
            reverse!(view(stack, (ol + 1):length(stack)))
            _coreferential_transition!(loc, stack, references, f)
            resize!(stack, ol)
            _coref_ascend_byte!(loc)
        end
    end

    push!(stack, e)
end

"""
    space_query_coref(btm, pat_expr, pat_v, effect) → Int

Coreferential query.

- **Single source**: `_coreferential_transition!` DFS on a `ReadZipperCore`.
- **Multi-source**: DELEGATES to `space_query_multi` (the correct ProductZipper path).
  The native multi-source DFS port was buggy (missed matches; not stack-safe) and had
  no callers, so it was retired 2026-06-28. See ADR-056 "Deviation from upstream".

NOTE: `effect` here takes a single argument. For multi-source it receives the matched
`combined` Expr (bridged from `space_query_multi`'s `(bindings, combined)` contract).
"""
function space_query_coref(btm::PathMap{UnitVal},
    pat_expr::MORK.Expr,
    pat_v::UInt8,
    effect::Function)::Int
    pat_tag = byte_item(pat_expr.buf[1])
    pat_tag isa ExprArity || return 0
    n_factors = Int(pat_tag.arity)
    n_factors > 0 || return 0

    if n_factors == 1
        effect(nothing)
        return 1
    end

    pat_args = ExprEnv[]
    ee_args!(ExprEnv(UInt8(0), pat_v, UInt32(0), pat_expr), pat_args)
    sources = pat_args[2:end]   # one ExprEnv per source pattern

    n_src = length(sources)

    if n_src == 1
        # Single source: plain ReadZipperCore DFS
        stack = [sources[1]]
        references = Int[]
        count = Ref(0)
        loc = read_zipper(btm)
        _coreferential_transition!(loc, stack, references, function (z)
            count[] += 1
            effect(z)
        end)
        return count[]
    end

    # Multi-source: the coreferential DFS port (`_coreferential_transition!` over a
    # ProductZipper) is BUGGY — it MISSES matches (e.g. returns 0 for a 4-factor
    # conjunction the ProductZipper matches; verified 2026-06-28) and is not stack-safe
    # (recursive; overflows on deep data). It was never wired in production (ZERO callers
    # in the workspace) and was never validated for multi-source. Delegate to the correct
    # ProductZipper-based `space_query_multi` (matching this function's test name
    # "multi-source falls back to ProductZipper"). See ADR-056 "Deviation from upstream".
    #
    # Contract bridge: `space_query_multi`'s effect is `(bindings, combined)`, whereas the
    # coref effect contract is `effect(loc)`. We pass the matched `combined` Expr to the
    # single-arg effect. No production caller depends on the old `loc`-based contract.
    return space_query_multi(btm, pat_expr, pat_v,
        (_bindings, combined) -> (effect(combined); true))
end

space_query_coref(btm::PathMap{UnitVal}, pat::MORK.Expr, f::Function) =
    space_query_coref(btm, pat, UInt8(0), f)

space_query_coref(s::Space, pat::MORK.Expr, f::Function) =
    space_query_coref(s.btm, pat, UInt8(0), f)

# Space-level overloads that pass mmaps for ACT file caching
space_query_multi_i(s::Space, pat::MORK.Expr, f::Function) =
    space_query_multi_i(s.btm, pat, UInt8(0), f; mmaps=s.mmaps)
space_query_multi_i(s::Space, pat::MORK.Expr, pat_v::UInt8, f::Function) =
    space_query_multi_i(s.btm, pat, pat_v, f; mmaps=s.mmaps)

# =====================================================================
# _pat_overlaps_exec_prefix — can any CONJUNCT of the pattern match an `(exec …)` atom?
# =====================================================================
#
# The driver removes each exec from s.btm BEFORE interpreting it (space.rs `metta_calculus`,
# line ~1704, does the same). Upstream then matches the pattern over a COPY of the space with the
# exec RE-INSERTED UNCONDITIONALLY (space.rs `transform_multi_multi_io`, line 1585:
# `read_copy.insert(add.span())`). We keep the fast path — matching s.btm directly, skipping the
# ~12KB/step re-insert — ONLY when the pattern provably cannot match the removed exec; otherwise the
# caller re-inserts it (line ~1339) so semantics equal upstream's. So the question this answers is
# exactly: could a conjunct `c` of `(, c1 … ck)` unify with an `(exec …)` atom? Yes iff
#     (a) c is a bare VARIABLE  ($x)                  — matches ANY atom, incl. exec
#     (b) c is compound with a VARIABLE HEAD  (($h …)) — the head could bind the symbol `exec`
#     (c) c is compound with the literal head `exec`   ((exec …)) — an explicit meta-rule
# A conjunct with a concrete non-`exec` head can never unify with `(exec …)`, so a pure data rule
# (the overwhelmingly common case) returns false and keeps the fast path.
#
# BUG THIS REPLACES (found 2026-07-23, differential vs the built upstream binary — Control_02/03,
# up=4/our=0): the old body was a flat structural byte-scan for the literal `_EXEC_PREFIX`, catching
# ONLY case (c). A bare-variable conjunct `(, $x)` — which upstream matches against the exec itself
# at bootstrap, when it is the only atom present — has no literal `exec` bytes, so the scan returned
# false, the fast path hid the removed exec, and the whole exec-chaining program produced NOTHING.
# Silent narrowing: "could this pattern match an exec?" was under-approximated as "does it literally
# contain 'exec'?". Verified by execution: forcing the fixed cases through the re-insert path yields
# Control_02→{0,1,2,3}, Control_03→{0}, and the exec-self-match line, byte-identical to upstream
# modulo De Bruijn var rendering; all 84 substitution programs + the data-rule fast path unchanged.
#
# Only the `,` conjunction gets this factor analysis. `I` sources, a variable functor, or any other
# shape fall through to a conservative TRUE — upstream re-inserts unconditionally, so extra exec
# visibility is never WRONG; we merely forgo the ~12KB skip for those rare shapes.
# Conjunct subtrees are skipped with `_expr_end_offset` (kernel/Sinks.jl), so the walk stops exactly
# at the pattern's end and never reads into the template that shares this buffer — preserving the old
# "scan only the first expression" property that kept a template-spawned `(exec …)` from resurrecting.
@inline function _pat_overlaps_exec_prefix(pat_expr::MORK.Expr)::Bool
    buf = pat_expr.buf
    n = length(buf)
    n >= 4 || return true                              # malformed/short → conservative
    t0 = byte_item(buf[1])
    (t0 isa ExprArity) || return true                  # not (functor …) → conservative
    nfac = Int(t0.arity) - 1                            # arity counts the functor + nfac conjuncts
    nfac >= 1 || return false                           # empty pattern — interpret rejects it anyway
    tf = byte_item(buf[2])
    @inbounds (tf isa ExprSymbol && Int(tf.size) == 1 && buf[3] == UInt8(',')) || return true
    i = 4                                               # past [Arity][Sym1][','] → first conjunct
    @inbounds for _ in 1:nfac
        i <= n || break
        th = byte_item(buf[i])
        if th isa ExprNewVar || th isa ExprVarRef
            return true                                 # (a) bare-variable conjunct
        elseif th isa ExprArity && i + 1 <= n
            hh = byte_item(buf[i+1])
            if (hh isa ExprNewVar || hh isa ExprVarRef) && Int(th.arity) == 4
                # (b) variable head AND exec's arity (`(exec loc pat tpl)` == 4) → could bind the
                # exec. Arity is REQUIRED: a var-head conjunct of a different arity (e.g. `($x $y)`,
                # arity 2) can never unify with the arity-4 exec atom, so it keeps the fast path.
                return true
            elseif hh isa ExprSymbol && Int(hh.size) == 4 && i + 5 <= n &&
                   buf[i+2] == 0x65 && buf[i+3] == 0x78 && buf[i+4] == 0x65 && buf[i+5] == 0x63
                return true                             # (c) literal (exec …) head
            end
        end
        i = _expr_end_offset(buf, i)                    # skip this conjunct subtree → next
    end
    false
end

# =====================================================================
# space_transform_multi_multi! — rewrite rule application
# =====================================================================

"""
    space_transform_multi_multi!(s, pat_expr, tpl_expr, add_expr) → (touched, any_new)

For each match of `pat_expr` in the Space, apply `tpl_expr` to produce new
expressions and insert them.  `add_expr` is also inserted unconditionally.

Simplified port of `Space::transform_multi_multi_` — uses our `expr_apply`
instead of `apply_e`.

Returns `(touched, any_new)` where `touched` is match count and `any_new`
indicates whether at least one new expression was added.
"""
# Returns true if the O-template raw bytes indicate an accumulating sink.
# Accumulating sinks must be created ONCE before the query and finalized ONCE after.
# Recognized: AU, count, fsum, fmin, fmax, fprod, sum, head, tail
# NB head/tail keep the top/bottom-N across ALL matches — they MUST accumulate;
# treated as immediate (fresh-per-match) they never cap (HeadSink's old test was
# vacuous, kept 0/N). Added with TailSink (mirrors upstream HeadTailSink).
function _is_accumulating_sink(raw_bytes::Vector{UInt8})::Bool
    length(raw_bytes) < 4 && return false
    t1 = byte_item(raw_bytes[1])
    t1 isa ExprArity || return false
    t2 = byte_item(raw_bytes[2])
    t2 isa ExprSymbol || return false
    sz = Int(t2.size)
    3 + sz > length(raw_bytes) && return false
    name = String(raw_bytes[3:(3 + sz - 1)])
    name in ("AU", "count", "fsum", "fmin", "fmax", "fprod", "sum", "head", "tail") && return true
    # "and" (AndSink) MUST accumulate: it groups matched entries by <result> key and bitwise-ANDs
    # their values ACROSS all matches of the query (e.g. ip_sudoku narrows each cell's candidate
    # bitmask by AND-ing the current cell value with every incoming message for that cell). Treated
    # as immediate (fresh sink per match, finalize per match) it saw ONE entry per finalize → no
    # cross-match grouping → the AND never happened → constraint narrowing was lost and cells got
    # removed (by the paired `-`) faster than correctly re-added (ip_sudoku stalled at 12 steps /
    # 4 of 16 cells vs upstream's 34 / 16). Mirrors upstream's AndSink.finalize (sinks.rs:741),
    # which reduces the whole accumulated `unique` PathMap once. Fix 2026-07-25.
    name == "and" && return true
    # "-" (RemoveSink) MUST also accumulate. In an O-sink the removes have to be
    # collected across ALL matches and subtracted AFTER every immediate add — otherwise
    # an atom added by one match and removed by another survives or dies depending on
    # match ORDER. That is the set-difference bug: Set_Ops_05 {a,b,c}\{b,c,d} upstream
    # = {a}, but our per-match immediate path gave {a,c}. Deferring removes to finalize
    # (after the adds) = upstream's "collect paths, subtract_into on finalize" → removes
    # win, result is order-independent. The struct already collects into `s.remove`; it
    # just was never marked accumulating, so it was created fresh-per-match.
    name == "-" && return true
    # "U" / "hash" / "ACT" — the SAME omission as "and" and "-" above, found 2026-07-26 by cross-check.
    # The rule is mechanical: a sink belongs here iff its `sink_apply!` stores into SINK STATE that
    # `sink_finalize!` later consumes, rather than writing to `btm` immediately. Treated as immediate,
    # such a sink is rebuilt fresh per match and finalized per match, so it only ever sees ONE entry:
    #   * USink   accumulates a running MGU in `s.buf`, unifying each match into it. Per-match it
    #             emitted one atom PER MATCH instead of a single unified result — `(u (f a b))`
    #             upstream vs our `(u (f $a b))` + `(u (f a $b))` — and conflicting matches, which
    #             upstream resolves to NOTHING, each produced their own atom.
    #   * HashSink accumulates matched paths in `s.unique` and hashes the set.
    #   * ACTSink  accumulates paths in `s.tmp` and writes the .act file on finalize; per-match each
    #             finalize OVERWROTE the file, so only the LAST match survived (6 matches -> 1 atom).
    (name == "U" || name == "hash" || name == "ACT") && return true
    false
end

# Ports transform_multi_multi_io (space.rs:1569) — upstream's GENERAL form, taking the two axes as
# runtime flags.
#
# 🔴 THE OTHER THREE ARE DELIBERATELY NOT PORTED, and that is "port the generator, not its
# expansion" applied literally. Upstream has four functions over the same algorithm:
#
#     transform_multi_multi_    (`,` source, `,` sink)   cfg(feature="specialize_io")
#     transform_multi_multi_i   (`I` source, `,` sink)   cfg(feature="specialize_io")
#     transform_multi_multi_o   (`,` source, `O` sink)   cfg(feature="specialize_io")
#     transform_multi_multi_io  both axes as ARGUMENTS   always compiled
#
# The first three are what `specialize_io` (a DEFAULT feature) monomorphizes out of the fourth so
# Rust can drop the runtime branches. Julia has no equivalent win from three copies of one function,
# and the copies would be three places to keep correct. Verified structurally, not assumed: diffing
# `_` against `_o` shows the only differences are the sink axis (plain write zippers +
# prefix_subsumption vs ASink + prefix_subsumption_resources + write_handler) and the source axis.
# Both sink branches are live below, so this function already covers `_` and `_o`.
#
# What is genuinely missing is ONE capability shared by all four: `no_source=false`, the `I`
# external ACT/Z3 source. That is an infrastructure gap (mmaps/z3s), not a gap that porting the
# specializations would close.
#
# Signature note: upstream (pat_expr, tpl_expr, add, no_source, no_sink)
# no_source=true  → pattern is `,`  (query the trie — compat path)
# no_source=false → pattern is `I`  (external ACT/Z3 source via query_multi_i;
#                                    not ported — requires mmaps/z3s infrastructure.
#                                    Falls back to trie query for now.)
# no_sink=true    → template is `,` (direct set_val_at!)
# no_sink=false   → template is `O` (dispatch through sink machinery)
function space_transform_multi_multi!(s::Space, pat_expr::MORK.Expr, pat_v::UInt8,
    tpl_expr::MORK.Expr, tpl_v::UInt8,
    add_expr::MORK.Expr;
    no_source::Bool=true,
    no_sink::Bool=true,
    prefix::Vector{UInt8}=UInt8[])::Tuple{Int, Bool}
    # `prefix` (default empty = root, behaviour unchanged) scopes a prefixed-
    # region exec.  Reads anchor under `prefix` (space_query_multi_at); writes
    # land under `prefix` — directly (no_sink: `prefix ++ result`) or via the
    # PrefixBtm wrapper handed to O-sinks (no_sink=false), which redirects their
    # btm touches into the region while leaving their internal accumulators raw.
    # Covers comma/comma (Stage A) + comma/O O-sinks (Stage B).  I-source (`I`)
    # under a non-empty prefix is still guarded in space_interpret! (its ASource
    # read path doesn't thread `prefix` yet).
    sink_btm = isempty(prefix) ? s.btm : PrefixBtm(s.btm, prefix)
    tpl_args = ExprEnv[]
    ee_tpl = ExprEnv(UInt8(0), tpl_v, UInt32(0), tpl_expr)
    ee_args!(ee_tpl, tpl_args)
    template_ees = tpl_args[2:end]

    any_new = Ref(false)

    # Pre-create persistent (accumulating) sinks for O-templates.
    # CountSink accumulates sources across all matches before finalizing once.
    # Other sinks are created fresh per match (persistent_sinks[k] = nothing).
    # ⚠️ ELEMENT TYPE STATED AT CONSTRUCTION. `map` here yields `asink_new(...)` (declared
    # `::AbstractSink`) or `nothing`, and the two `::Vector` assertions further down then DISCARDED
    # whatever inference had — a bare `Vector` means element type `Any`, so every `sink_finalize!`
    # became a runtime dispatch. JET named it directly (`report_opt` on the exec path:
    # "runtime dispatch detected: sink_finalize!(%1231::Any, ...)" and
    # "(A::Vector)[i::Int64]::Any"). Naming the union costs nothing and is what our own standing
    # rule against `Any` in code means in practice.
    persistent_sinks = if no_sink
        nothing
    else
        out = Union{Nothing, AbstractSink}[]
        sizehint!(out, length(template_ees))
        for ee in template_ees
            tpl_span = expr_span(ee.base, Int(ee.offset) + 1)
            raw_bytes = Vector{UInt8}(tpl_span)
            push!(out, _is_accumulating_sink(raw_bytes) ? asink_new(MORK.Expr(raw_bytes)) : nothing)
        end
        out
    end

    # ADR-056 P4-B projection pushdown: a set-sink (`,`) exec whose pattern is a strict chain
    # (k≥3) and whose template(s) project to the chain ENDPOINTS (x0, xk) computes the W²
    # distinct endpoint pairs by composition instead of enumerating the W^k paths. Returns
    # early when it fires; ANY other shape falls through to the normal per-match path below
    # UNCHANGED. Defined in kernel/TrieJoin.jl; validated ≡ the full exec (P4-B probe).
    if no_sink && isempty(prefix)
        _pb = _try_chain_projection!(s, pat_expr, pat_v, template_ees)
        _pb !== nothing && return _pb
    end

    # Build read_btm.
    #
    # BUG (found via DTL decision-tree-learning investigation, confirmed by trace: a
    # single-conjunct rule wrote 976 facts from 56 legitimate matches): the comment that
    # used to justify `read_btm = s.btm` directly ("ReadZipperCore captures root_node as
    # an Rc snapshot at construction") is FALSE — `read_zipper`/`write_zipper` both alias
    # `m.root` without ever calling `copy` on it (no refcount bump), so `refcount(root_rc)`
    # stays 1 and `_wz_ensure_write_unique!` mutates the SAME node object the query is
    # scanning, instead of COW-forking away from it. When a write's output shape can
    # re-match the read pattern (e.g. a written "leaf" fact has the same functor/arity as
    # the query, as in STEP(1,11)'s `total_gini_impurity_choice`), the newly written fact
    # feeds back into the SAME ongoing scan and cascades.
    #
    # Upstream (space.rs:1582, `transform_multi_multi_io`) ALWAYS isolates the read side:
    # `let mut read_copy = self.btm.clone();` — a cheap Arc-bump PathMap clone, unconditional
    # for every transform, not gated on pattern shape. Mirror that here: bump the root's
    # refcount so a same-scan write is forced to COW-fork instead of mutating in place. This
    # is a single TrieNodeODRc refcount bump (no pjoin, no singleton materialization), so the
    # non-meta fast path stays cheap — just no longer unsound.
    #
    # Meta-patterns (can match `(exec ...)` atoms) still need the pjoin path below: the
    # driver already removed this exec fact from s.btm, so a self-referential rule needs it
    # re-inserted into the isolated read_btm to see its own just-popped fact.
    read_btm = if !_pat_overlaps_exec_prefix(pat_expr)
        _ensure_root!(s.btm)   # exported from PathMap, in scope via `using PathMap`
        PathMap{UnitVal, GlobalAlloc}(copy(s.btm.root::TrieNodeODRc{UnitVal, GlobalAlloc}), s.btm.root_val, s.btm.alloc)
    else
        # Meta-pattern: re-insert exec atom into an isolated read_btm so the
        # pattern can see it without the driver re-selecting it.
        _exec_singleton = PathMap{UnitVal}()
        set_val_at!(_exec_singleton, add_expr.buf, UNIT_VAL)
        pjoin(s.btm, _exec_singleton).value
    end

    # Pre-allocate per-template scratch buffers outside the match closure.
    # Mirrors upstream space.rs: ass/astack/buffer pre-allocated before query_multi,
    # cleared between iterations with ass.clear() / astack.clear() / buffer.clear().
    # Saves 5+ heap allocs per (match × template): template copy, output buf, result
    # slice, rename dict, free/new var vecs.
    n_tpl = length(template_ees)
    tpl_exprs = Vector{MORK.Expr}(undef, n_tpl)    # template Expr per ee
    out_bufs = Vector{Vector{UInt8}}(undef, n_tpl) # reusable output buffers
    tpl_ezs = Vector{ExprZipper}(undef, n_tpl)    # read zippers (reset loc=1 each call)
    tpl_ozs = Vector{ExprZipper}(undef, n_tpl)    # write zippers (reset loc=1 each call)
    tpl_rdicts = [Dict{ExprVar, UInt8}() for _ in 1:n_tpl]  # rename maps (empty! each call)
    tpl_fvecs = [ExprVar[] for _ in 1:n_tpl]              # free_vars  (empty! each call)
    tpl_nvecs = [ExprVar[] for _ in 1:n_tpl]              # new_vars   (empty! each call)
    for (k, ee) in enumerate(template_ees)
        tpl_span = expr_span(ee.base, Int(ee.offset) + 1)
        tpl_exprs[k] = MORK.Expr(Vector{UInt8}(tpl_span))
        out_bufs[k] = Vector{UInt8}(undef, max(length(tpl_span) * 4, 64))
        tpl_ezs[k] = ExprZipper(tpl_exprs[k], 1)
        tpl_ozs[k] = ExprZipper(MORK.Expr(out_bufs[k]), 1)
    end

    # Two-phase apply scratch (oi = pattern var-intro count; new_intros=0 for templates).
    discard_buf = Vector{UInt8}(undef, 1 << 16)
    pat_apply_ez = ExprZipper(pat_expr, 1)
    pat_apply_oz = ExprZipper(MORK.Expr(discard_buf), 1)
    pat_cyc = Dict{ExprVar, UInt8}()
    pat_stk = ExprVar[]
    pat_asn = ExprVar[]

    # ADR-056 projection pushdown (variant A): a set-sink (`,`) exec whose template projects
    # away some pattern vars makes many matches produce the SAME output atom (e.g.
    # `(reach3 $x $w)` over a path enumeration → W⁴ matches but W² distinct atoms). Dedup by
    # output bytes to skip the redundant idempotent `set_val_at!` for repeats. ALWAYS correct
    # (set/idempotent semantics — never changes the atom set). The projection "gate" is pure
    # perf: ADAPTIVE — if no duplicate appears in the first DD_PROBE matches the workload isn't
    # projecting, so disable + free the set → zero overhead on the common (non-projecting) path.
    dd_seen = Set{Vector{UInt8}}()
    dd_active = Ref(no_sink)
    dd_matches = Ref(0)
    dd_hits = Ref(0)
    DD_PROBE = 512

    # space_query_multi_i uses s.mmaps for ACT file caching (I-pattern)
    # no_source path uses space_query_multi_at so a non-empty `prefix` anchors
    # the pattern read to the prefix-subtrie (delegates to space_query_multi
    # when prefix is empty — the root path is byte-identical to before).
    query_fn = if no_source
        # ── LEAPFROG DISPATCH ────────────────────────────────────────────────────────────────────
        # 🔑 EXACTLY ONE CALL SITE DISPATCHES, and this is it — the `,`-source space-to-space
        # transform, matching upstream, which routes `transform_multi_multi_` and leaves
        # `transform_multi_multi_o` and the pattern-directed dumps on the stock path. Upstream's
        # stated reason is not performance: "the pattern-directed dumps keep the stock path and its
        # ENUMERATION ORDER." The join visits in a different order, which is invisible for a
        # transform that adds to a space (set semantics) and observable in a dump.
        #
        # ⚠️ THREE PRECONDITIONS, none of them optional:
        #   · `no_source`      — the `,` source. The `I` source reads ACT files via a different path.
        #   · `isempty(prefix)`— a prefix anchors the read to a subtrie; the join opens each factor's
        #                        cursor at its OWN relation prefix from the root and cannot honour it.
        #   · `pat_v == 0`     — the join numbers query variables from 0. A non-zero base would
        #                        silently join on the wrong variables, which is a WRONG ANSWER, not
        #                        an error.
        # A `nothing` return means the body is not routable (not a conjunction, or an encoding the
        # parse rejects) and the stock path answers it — `nothing` is NOT "no matches".
        #
        # 🔴 OFF BY DEFAULT. Upstream makes this a COMPILE-TIME feature; a runtime flag is the honest
        # Julia analogue and is strictly better for us — it lets the differential run the SAME corpus
        # both ways in one process, which a cfg cannot. [[feedback_parity_vs_opt_in]]
        # ⚠️ ONE CLOSURE, WITH THE DECISION INSIDE IT — NOT A CHOICE BETWEEN CLOSURES. Selecting
        # among closures here makes `query_fn` a union of THREE distinct types, so every call
        # through it becomes a RUNTIME DISPATCH. The first version of this did exactly that and
        # `test/integration/jet_dispatch_ratchet.jl` caught it: 113 sites against a pin of 104.
        # That is the ratchet doing its job, and the fix is structural rather than an annotation.
        # [[feedback_perf_diagnosis_typeinstability_first]]
        (btm, pat, v, f) -> begin
            if LEAPFROG_DISPATCH[] && isempty(prefix) && v == UInt8(0)
                r = space_query_multi_leapfrog(btm, pat, f)
                if r !== nothing
                    LEAPFROG_ROUTED[] += 1
                    return r::Int
                end
                # Counted, not silent: upstream PANICS here rather than detouring. See
                # `LEAPFROG_DECLINED` for why this branch is on probation.
                LEAPFROG_DECLINED[] += 1
            end
            space_query_multi_at(btm, prefix, pat, v, f)
        end
    else
        (btm, pat, v, f) -> space_query_multi_i(btm, pat, v, f; mmaps=s.mmaps)
    end
    touched = query_fn(
        read_btm,
        pat_expr,
        pat_v,
        (bindings, loc_expr) -> begin
            # oi = the pattern's introduced-var count, counted BOUNDED to the pattern's own span
            # (_ee_traverseh stops at the expr boundary — NOT a full-buffer walk, which would run
            # past the pattern into the template and over-count). Template NewVars then number from
            # oi so they don't collide with pattern-bound vars at key (0, k<oi).
            (pat_nv, _, _) = _ee_traverseh(UInt8(0), ExprEnv(UInt8(0), pat_v, UInt32(0), pat_expr),
                (h, o) -> (h + UInt8(1), nothing), (h, o, r) -> (h, nothing),
                (h, o, sl) -> (h, nothing), (h, o, a) -> (h, nothing),
                (h, o, x, y) -> (h, nothing), (h, o, acc) -> (h, acc))
            oi = pat_v + pat_nv
            if no_sink
                # `,` template functor — apply each template and insert result directly
                for (k, ee) in enumerate(template_ees)
                    ez = tpl_ezs[k];
                    ez.loc = 1          # reset read position
                    oz = tpl_ozs[k];
                    oz.loc = 1          # reset write position (≡ buffer.clear())
                    empty!(tpl_rdicts[k]);
                    empty!(tpl_fvecs[k]);
                    empty!(tpl_nvecs[k])
                    (toi, _) = expr_apply(UInt8(0), oi, UInt8(0), ez, bindings, oz,
                        tpl_rdicts[k], tpl_fvecs[k], tpl_nvecs[k])
                    oi = toi
                    result_view = @view out_bufs[k][1:(oz.loc - 1)]   # zero-copy view (no slice alloc)
                    # projection-pushdown dedup: skip the redundant insert for a repeated output
                    if dd_active[]
                        ddkey = Vector{UInt8}(result_view)
                        if ddkey in dd_seen
                            dd_hits[] += 1
                            continue              # duplicate atom — already inserted this firing
                        end
                        push!(dd_seen, ddkey)
                    end
                    # Prefixed-region write: outputs land under `prefix` so a
                    # prefix-scoped exec stays inside its region.  Empty prefix →
                    # write the bare result view (zero-copy, unchanged root path).
                    wpath = isempty(prefix) ? result_view : vcat(prefix, result_view)
                    old = get_val_at(s.btm, wpath)
                    set_val_at!(s.btm, wpath, UNIT_VAL)
                    old === nothing && (any_new[] = true)
                end
            else
                # `O` template functor — apply each template then dispatch to sink.
                # Accumulating sinks (CountSink) use persistent_sinks created before query.
                ps = persistent_sinks::Vector{Union{Nothing, AbstractSink}}
                for (k, ee) in enumerate(template_ees)
                    ez = tpl_ezs[k];
                    ez.loc = 1
                    oz = tpl_ozs[k];
                    oz.loc = 1
                    empty!(tpl_rdicts[k]);
                    empty!(tpl_fvecs[k]);
                    empty!(tpl_nvecs[k])
                    (toi, _) = expr_apply(UInt8(0), oi, UInt8(0), ez, bindings, oz,
                        tpl_rdicts[k], tpl_fvecs[k], tpl_nvecs[k])
                    oi = toi
                    result_expr = MORK.Expr(out_bufs[k][1:(oz.loc - 1)]) # copy needed: sink stores ref
                    if ps[k] !== nothing
                        # Accumulating sink: apply but don't finalize yet
                        sink_apply!(ps[k], bindings, result_expr.buf, sink_btm)
                    else
                        # Immediate sink: create fresh, apply, finalize.
                        # Pass the RAW (pre-substitution) template too: `sink_request` must compute
                        # its root from it, matching upstream's once-per-clause `Sink::new(e)`.
                        # Only PureSink reads it; every other sink ignores the argument.
                        raw_tpl_bytes = Vector{UInt8}(expr_span(ee.base, Int(ee.offset) + 1))
                        sink = asink_new(result_expr, raw_tpl_bytes)
                        sink_apply!(sink, bindings, result_expr.buf, sink_btm)
                        changed = sink_finalize!(sink, sink_btm)
                        changed && (any_new[] = true)
                    end
                end
            end
            # adaptive projection-dedup gate: disable + free if no dups seen early (not projecting)
            if dd_active[]
                dd_matches[] += 1
                if dd_matches[] >= DD_PROBE && dd_hits[] == 0
                    dd_active[] = false; empty!(dd_seen)
                end
            end
            true
        end
    )

    # Finalize accumulating sinks (CountSink etc.) once after all matches
    if !no_sink && persistent_sinks !== nothing
        for sink in persistent_sinks::Vector{Union{Nothing, AbstractSink}}
            sink === nothing && continue
            changed = sink_finalize!(sink, sink_btm)
            changed && (any_new[] = true)
        end
    end

    (touched, any_new[])
end

# Compat wrapper for callers without v parameters (v defaults to 0)
space_transform_multi_multi!(s::Space, pat_expr::MORK.Expr, tpl_expr::MORK.Expr,
    add_expr::MORK.Expr) =
    space_transform_multi_multi!(s, pat_expr, UInt8(0), tpl_expr, UInt8(0), add_expr)

# ── specialize_io named variants (mirrors #[cfg(feature="specialize_io")] in Rust) ─────
#
# In Rust, specialize_io creates separate function bodies to avoid runtime flag checks
# and let the compiler eliminate dead branches.  In Julia, JIT specializes on Bool
# constants anyway, but named dispatch makes the intent clear and matches upstream.
#
# (`,`, `,`) — most common: trie query + direct write
"""
    space_transform_comma_comma!(s, pat, tpl, add) — `,` source, `,` sink.
Mirrors `transform_multi_multi_` (the most common, fastest path).
Uses ProductZipper trie query + direct set_val_at! (no sink object overhead).
"""
space_transform_comma_comma!(s::Space, pat::MORK.Expr, tpl::MORK.Expr, add::MORK.Expr;
    prefix::Vector{UInt8}=UInt8[]) =
    space_transform_multi_multi!(s, pat, UInt8(0), tpl, UInt8(0), add;
        no_source=true, no_sink=true, prefix=prefix)

# (`I`, `,`) — external ASource + direct write
"""
    space_transform_i_comma!(s, pat, tpl, add) — `I` source, `,` sink.
Mirrors `transform_multi_multi_i`. Uses ASource dispatch (BTM/CmpSource/ACTSource)
for the source, direct set_val_at! for output.
"""
space_transform_i_comma!(s::Space, pat::MORK.Expr, tpl::MORK.Expr, add::MORK.Expr) =
    space_transform_multi_multi!(s, pat, UInt8(0), tpl, UInt8(0), add;
        no_source=false, no_sink=true)

# (`,`, `O`) — trie query + sink dispatch
"""
    space_transform_comma_o!(s, pat, tpl, add) — `,` source, `O` sink.
Mirrors `transform_multi_multi_o`. Uses ProductZipper trie query; routes output
through ASink machinery (CountSink, FloatReductionSink, PureSink, etc.).
"""
space_transform_comma_o!(s::Space, pat::MORK.Expr, tpl::MORK.Expr, add::MORK.Expr) =
    space_transform_multi_multi!(s, pat, UInt8(0), tpl, UInt8(0), add;
        no_source=true, no_sink=false)

# (`I`, `O`) — external ASource + sink dispatch (the fully general path)
"""
    space_transform_i_o!(s, pat, tpl, add) — `I` source, `O` sink.
Mirrors `transform_multi_multi_io`. Fully general: ASource dispatch + ASink dispatch.
"""
space_transform_i_o!(s::Space, pat::MORK.Expr, tpl::MORK.Expr, add::MORK.Expr) =
    space_transform_multi_multi!(s, pat, UInt8(0), tpl, UInt8(0), add;
        no_source=false, no_sink=false)

# =====================================================================
# ExecError — mirrors ExecError<S> enum in space.rs (server branch)
# All 10 variants. Permission variants carry a message string (Julia
# has no generic PermissionErr type parameter).
# =====================================================================

struct ExecError
    kind::Symbol
    message::String
end
ExecError(kind::Symbol) = ExecError(kind, "")
Base.show(io::IO, e::ExecError) = print(io, "ExecError($(e.kind)): $(e.message)")

_exec_err_arity4(msg) = ExecError(:ExpectedArity4, msg)
_exec_err_keyword(msg) = ExecError(:ExpectedExecKeyword, msg)
_exec_err_thread_pair(msg) = ExecError(:ExpectedThreadIdPair, msg)
_exec_err_comma_pat(msg) = ExecError(:ExpectedCommaListPatterns, msg)
_exec_err_comma_tpl(msg) = ExecError(:ExpectedCommaListTemplates, msg)
_exec_err_ground_priority(msg) = ExecError(:ExpectedGroundPriority, msg)
_exec_err_other(msg) = ExecError(:OtherFmtErr, msg)
_exec_err_system_perm(msg) = ExecError(:SystemPermissionErr, msg)
_exec_err_user_perm(msg) = ExecError(:UserPermissionErr, msg)
_exec_err_retry_limit(msg) = ExecError(:RetryLimit, msg)

is_user_perm_err(e::ExecError) = e.kind === :UserPermissionErr
exec_error_message(e::ExecError) = "$(e.kind): $(e.message)"

# =====================================================================
# space_interpret! / space_metta_calculus! — rule evaluation engine
# =====================================================================

# exec prefix: [4] exec  (6 bytes)
const _EXEC_PREFIX = UInt8[
    item_byte(ExprArity(UInt8(4))),
    item_byte(ExprSymbol(UInt8(4))),
    UInt8('e'), UInt8('x'), UInt8('e'), UInt8('c')
]

"""
    space_interpret!(s, rt) → Union{Nothing, ExecError}

Execute one `(exec (thread_id priority) (, src...) (, tpl...))` atom.
Mirrors `interpret_impl` in space.rs (server branch).

Returns `nothing` on success, an `ExecError` on any format violation
or permission conflict. `UserPermissionErr` → caller should re-insert
and retry; all other errors → halt.
"""
function space_interpret!(s::Space, rt::MORK.Expr;
    prefix::Vector{UInt8}=UInt8[])::Union{Nothing, ExecError}
    buf = rt.buf
    # Safe serialisation — expr_serialize throws on reserved bytes; fall back to hex.
    dbg = () -> try
        expr_serialize(buf)
    catch
        ;
        bytes2hex(buf)
    end

    # ── Overall shape: arity-4 + "exec" keyword ───────────────────────
    length(buf) < 6 && return _exec_err_arity4(dbg())
    t1 = byte_item(buf[1])
    (t1 isa ExprArity && t1.arity == 4) || return _exec_err_arity4(dbg())
    t2 = byte_item(buf[2])
    (t2 isa ExprSymbol && t2.size == 4) || return _exec_err_keyword(dbg())
    buf[3:6] == UInt8[UInt8('e'), UInt8('x'), UInt8('e'), UInt8('c')] ||
        return _exec_err_keyword(dbg())

    # Decompose top-level args: [1]="exec", [2]=(thread_id priority), [3]=patterns, [4]=templates
    ee_rt = ExprEnv(UInt8(0), UInt8(0), UInt32(0), rt)
    args = ExprEnv[]
    ee_args!(ee_rt, args)
    length(args) < 4 && return _exec_err_arity4(dbg())

    # ── Validate loc arg ─────────────────────────────────────────────
    # Upstream's ONLY loc check is `debug_assert!(loc.variables() == 0)` (space.rs:1666) — a DEBUG
    # assertion, ELIDED IN RELEASE. Since the release binary is our differential oracle, a var-bearing
    # loc must NOT be rejected. We previously read that debug_assert as a runtime contract and returned
    # an error for a variable in either the thread_id or the priority slot, which silently dropped
    # every such exec (7 probes in the space.rs sweep produced NOTHING where upstream produced output).
    #
    # Behaviour MEASURED against the release binary rather than inferred (2026-07-26):
    #   (exec (0 $j)  …)  var priority  -> RUNS, emits (out1 $a)
    #   (exec ($t 0)  …)  var thread    -> RUNS, emits (out2 $a)
    #   (exec ($t $j) …)  both var      -> RUNS, emits (out4 $a)
    #   (exec $L      …)  BARE var loc  -> does NOT run
    # So an arity-2 loc runs regardless of variables, and only a bare-variable loc is skipped — which
    # is the one check we keep.
    loc_ee = args[2]
    loc_buf = loc_ee.base.buf
    loc_off = Int(loc_ee.offset)
    if length(loc_buf) > loc_off
        lt = byte_item(loc_buf[loc_off + 1])
        if lt isa ExprNewVar || lt isa ExprVarRef
            return _exec_err_thread_pair(dbg())
        end
    end

    # ── Validate pattern list: must start with "," ────────────────────
    pat_ee = args[3]
    pat_buf = pat_ee.base.buf
    pat_off = Int(pat_ee.offset)
    length(pat_buf) <= pat_off && return _exec_err_comma_pat(dbg())
    pt = byte_item(pat_buf[pat_off + 1])
    (pt isa ExprArity && pt.arity > 0) || return _exec_err_comma_pat(dbg())
    length(pat_buf) <= pat_off + 1 && return _exec_err_comma_pat(dbg())
    pt2 = byte_item(pat_buf[pat_off + 2])
    (pt2 isa ExprSymbol && pt2.size == 1) || return _exec_err_comma_pat(dbg())
    pat_buf[pat_off + 3] == UInt8(',') || pat_buf[pat_off + 3] == UInt8('I') ||
        return _exec_err_comma_pat(dbg())

    # ── Validate template list: must start with "," or "O" ───────────
    # These guards MIRROR the pattern-side ones above, and upstream's :1670-1671. Only the ARITY check
    # was ported here; the `SymbolSize(1)` head check was not — so `tpl_buf[tpl_off + 3]` below read
    # past the buffer for any template whose head is not a 1-char symbol. `(exec 0 (, (fact $x)) ($x))`
    # — an arity-1 template holding just a variable — CRASHED the whole calculus with a BoundsError,
    # where upstream returns a clean Err, drops that exec, and carries on running the others
    # (verified against the binary: it still emits `(out a)` from the following exec). A crash here is
    # strictly worse than a wrong answer: it takes down every unrelated exec in the same run.
    tpl_ee = args[4]
    tpl_buf = tpl_ee.base.buf
    tpl_off = Int(tpl_ee.offset)
    length(tpl_buf) <= tpl_off && return _exec_err_comma_tpl(dbg())
    tt = byte_item(tpl_buf[tpl_off + 1])
    (tt isa ExprArity && tt.arity > 0) || return _exec_err_comma_tpl(dbg())
    length(tpl_buf) <= tpl_off + 1 && return _exec_err_comma_tpl(dbg())
    tt2 = byte_item(tpl_buf[tpl_off + 2])
    (tt2 isa ExprSymbol && tt2.size == 1) || return _exec_err_comma_tpl(dbg())
    length(tpl_buf) <= tpl_off + 2 && return _exec_err_comma_tpl(dbg())

    pat_expr = MORK.Expr(pat_buf[(pat_off + 1):end])
    tpl_expr = MORK.Expr(tpl_buf[(tpl_off + 1):end])

    pat_functor = pat_buf[pat_off + 3]
    tpl_functor = tpl_buf[tpl_off + 3]

    comma = UInt8(',');
    i_src = UInt8('I');
    o_snk = UInt8('O')

    # Prefix-scoped exec covers comma source with comma OR O-sink templates:
    #   - comma/comma: read via space_query_multi_at, write `prefix ++ result`.
    #   - comma/O    : O-sinks write through the PrefixBtm wrapper (Stage B).
    # I-source (`I`) under a prefix is still guarded — its ASource read path
    # (space_query_multi_i) doesn't thread `prefix` yet, so it would read across
    # regions.  Guard rather than silently mis-scope.
    if !isempty(prefix) && pat_functor == i_src
        return _exec_err_other(
            "prefix-scoped exec does not yet support I-source patterns; " *
            "got pat=$(Char(pat_functor)) tpl=$(Char(tpl_functor)) (I-source under a prefix is future work)"
        )
    end

    if pat_functor == comma && tpl_functor == comma
        space_transform_comma_comma!(s, pat_expr, tpl_expr, rt; prefix=prefix)
    # ── pat_v / tpl_v are ALWAYS 0. Upstream builds every pattern and template env with
    # `ExprEnv::new(0, expr)` (expr/src/lib.rs:1756-1763, whose body hardcodes `v: 0`), uniformly at
    # space.rs:1023 :1131 (query_multi / query_multi_i) and :1338 :1413 :1488 :1574 (all four
    # transform_multi_multi_* template decompositions). It never threads a loc-relative offset here.
    #
    # We passed `pat_ee.v` / `tpl_ee.v` — the WHOLE-EXEC-relative offset, which counts variables in
    # the exec's `loc` arg. With a var-free loc that offset is 0 and the two agree, which is why this
    # hid: every ground-loc probe passes either way. With a var in `loc` (e.g. `(exec (0 $j) ...)`)
    # the pattern's NewVar keys got counted from the shifted base, so they lined up with the
    # template's VarRef indices and we GROUNDED a variable upstream leaves free.
    #
    # The `,`/`,` arm was already right — `space_transform_comma_comma!` hardcodes 0. So did the
    # three named wrappers `space_transform_i_comma!` / `space_transform_comma_o!` /
    # `space_transform_i_o!` added by ba34df5 (2026-05-01) — but the dispatcher was never rewired to
    # call them and kept the pre-refactor inline calls. A correct fix that nothing invokes is
    # indistinguishable from no fix.
    elseif pat_functor == i_src && tpl_functor == comma
        space_transform_multi_multi!(s, pat_expr, UInt8(0), tpl_expr, UInt8(0), rt;
            no_source=false, no_sink=true)
    elseif pat_functor == comma && tpl_functor == o_snk
        space_transform_multi_multi!(s, pat_expr, UInt8(0), tpl_expr, UInt8(0), rt;
            no_source=true, no_sink=false, prefix=prefix)
    elseif pat_functor == i_src && tpl_functor == o_snk
        space_transform_multi_multi!(s, pat_expr, UInt8(0), tpl_expr, UInt8(0), rt;
            no_source=false, no_sink=false)
    else
        return _exec_err_other(
            "unknown functor combination: pat=$(Char(pat_functor)) tpl=$(Char(tpl_functor))"
        )
    end
    nothing
end

"""
    space_metta_calculus!(s, steps=∞) → Int

Repeatedly find `(exec ...)` atoms, remove and execute them. Returns steps executed.

PROVENANCE — this function draws from BOTH upstream branches, deliberately (audited 2026-07-30):

  - **`main` @ `5464713` (`kernel/src/space.rs:1695` `metta_calculus`) is the anchor**, because the
    RELEASE BINARY our 277-probe differential grades us against is built from main. Its error path is
    `if let Err(e) = self.interpret(xe) { debug!(…) }` — log and CONTINUE — and `done` increments once
    per iteration regardless of the result. We match both; see the `else` branch below for why halting
    was wrong.
  - **`server` @ `2d6730b` (`metta_calculus_impl`) supplies ONLY the permission retry**: on
    `UserPermissionErr` re-insert the atom and retry up to `_METTA_CALCULUS_MAX_RETRIES` with a 1 ms
    sleep. `main` has NO retry or sleep here at all, so a naive diff against main makes this look
    fabricated. It is not — see the inline note at the `sleep` call.

⚠️ An earlier version of this docstring said "on any other error logs and HALTS". That was stale: the
code logs and CONTINUES, which is main's behaviour and the whole point of the fix recorded in the
`else` branch. Corrected 2026-07-30.

⚠️ NOT PORTED — main's `timing` instrumentation (`space.rs:1710`). When `self.timing` is set, upstream
inserts a `("timing" <exec> <done> <nanos>)` atom **into the space** for every step. We declare the
`timing::Bool` field (line 145) to match upstream's struct, but nothing reads it, so setting it does
nothing. It is default-false on both sides and our probes never enable it, so there is no differential
exposure — but the field is a trap as it stands: it looks like a switch and is not one. Either wire it
or drop the field; do not leave it half-present.
"""
const _METTA_CALCULUS_MAX_RETRIES = 2000

# Encode one string as a MORK Symbol item: [SymbolSize(n)] followed by n payload bytes. Used only by
# the `timing` instrumentation below. `SymbolSize` is a 6-bit tag field, so a payload must be 1..63
# bytes — "timing" is 6, and the decimal renderings of a step count and a nanosecond duration are far
# short of 63, so this cannot overflow in practice. Asserted rather than assumed, because a silent
# truncation here would corrupt the trie rather than fail.
function _timing_sym(str::AbstractString)::Vector{UInt8}
    b = codeunits(str)
    1 <= length(b) <= 63 || error("_timing_sym: payload must be 1..63 bytes, got $(length(b))")
    out = UInt8[item_byte(ExprSymbol(UInt8(length(b))))]
    append!(out, b)
    out
end

# Multi-source join driver for the FALLTHROUGH path (shapes the trie-join fast paths P1-P5
# don't classify — i.e. higher-order / multi-source conjunctions). true (DEFAULT) = coreferential
# DFS over the ProductZipper (O(M*depth); prunes inconsistent branches during descent) — this
# is UPSTREAM's default `query_multi_raw`, and our port is faithful to upstream's current coref
# (post-#29 indexed-restore + VarRef bounds guard + break-true; revert of e551924). false =
# the naive ProductZipper (O(K^N), upstream's `no_search` cfg variant) — kept as an opt-out for
# A/B benchmarking. THE DEFAULT WAS FLIPPED false→true (2026-07-06) after a differential audit
# vs the built upstream binary: the naive default EXPLODED on higher-order joins (counter-machine
# step 2 >2M transitions vs upstream ~1k; going-wide; lte self-spawn) while coref ≡ upstream
# byte-for-byte on every workload measured, with NO correctness regression across the join-heavy
# suite (trie_join 44/44, mm2_corpus_differential 30/1, wiki 17/17, conformance 6/1). The naive
# default was a wrong-cross-check-target blunder — we validated against upstream's `no_search`
# feature path, not its default. See docs/tracking/session-log.md §9b-d.
const _USE_COREF_JOIN = Ref(true)
# The coreferential DFS recurses to trie/proof depth; backward-chaining proofs overflow
# Julia's default ~handler-task stack (its frames are large). Run it on a task with a
# generous reserved stack (mirrors the large fixed C stack upstream's recursive
# coreferential_transition relies on). Reserved virtual memory; committed on use.
const _COREF_STACK_SIZE = 512 * 1024 * 1024

function space_metta_calculus!(s::Space, steps::Int=typemax(Int))::Int
    done = 0
    retry = false
    retry_cnt = _METTA_CALCULUS_MAX_RETRIES
    # Reused scratch buffer — wires the Rust buffer: Vec<u8> reset-to-prefix pattern.
    # Eliminates collect(zipper_path) + vcat(_EXEC_PREFIX, rel_path) each iteration.
    path_buf = UInt8[]

    # 🔴 DO-WHILE, NOT TEST-FIRST — this is `while { BODY; done < steps } { done += 1 }`
    # (space.rs:1945-1969). Upstream evaluates the BODY INSIDE the loop CONDITION and puts
    # `done += 1` in the while-BODY, so the work runs before the bound is ever tested and the LAST
    # interpret is never counted: `metta_calculus(N)` performs N+1 interprets and reports N.
    # Ours was `while done < steps` and performed exactly N. FIXED 2026-08-19 — see the `done`
    # increment below, which is where the ordering actually lives.
    while true
        rz = read_zipper_at_path(s.btm, _EXEC_PREFIX)
        found = zipper_to_next_val!(rz)

        if !found
            if retry && retry_cnt > 0
                retry_cnt -= 1
                # 1 ms — mirrors `std::thread::sleep(Duration::from_millis(1))` in
                # `metta_calculus_impl`, kernel/src/space.rs:1088 ON THE `server` BRANCH.
                # NOT on `main`: main's `metta_calculus` has no retry/sleep at all, and
                # `grep thread::sleep` over a main checkout returns nothing — so diffing this
                # against main makes it look fabricated. It is not. See the docstring above.
                sleep(0.001)
                continue
            end
            break  # all execs consumed
        end

        empty!(path_buf)
        append!(path_buf, _EXEC_PREFIX)
        append!(path_buf, zipper_path(rz))   # view → bytes copied in; no collect, no vcat
        remove_val_at!(s.btm, path_buf)

        rt = MORK.Expr(copy(path_buf))      # independent copy for space_interpret!
        t0 = time_ns()                      # mirrors `let start = Instant::now()` (space.rs:1703)
        err = space_interpret!(s, rt)

        # ── main's `timing` instrumentation (space.rs:1710-1718) ───────────────────────────────────
        # Was UNPORTED until 2026-07-30: we declared the `timing::Bool` field to match upstream's
        # struct (space.rs:44) but nothing read it, so setting it silently did nothing — a switch that
        # was not one. Wired rather than dropped, because dropping the field would diverge from
        # upstream's struct while leaving the same trap for the next reader.
        #
        # Upstream builds `construct!("timing" xe done_str start_str)`, i.e.
        #     [Arity(4)] [Sym "timing"] <exec bytes, spliced as ONE element> [Sym done] [Sym nanos]
        # and inserts it into the trie. Three details that are easy to get wrong:
        #   * `done` is the PRE-increment count — upstream's `done += 1` runs in the while-BODY, after
        #     this block, so the first step records 0.
        #   * `xe` is spliced RAW, not wrapped in its own arity byte.
        #   * this WRITES TO THE SPACE, so it changes what a dump returns. It cannot collide with the
        #     exec scan: `_EXEC_PREFIX` is [Arity(4)][SymbolSize(4)]exec and this is
        #     [Arity(4)][SymbolSize(6)]timing — they diverge at byte 2, so no re-execution loop.
        # Default-false on both sides and no probe enables it, so there is no differential exposure.
        if s.timing
            tbuf = UInt8[item_byte(ExprArity(UInt8(4)))]
            append!(tbuf, _timing_sym("timing"))
            append!(tbuf, path_buf)                       # the exec expression, spliced raw
            append!(tbuf, _timing_sym(string(done)))      # PRE-increment, as upstream
            append!(tbuf, _timing_sym(string(time_ns() - t0)))
            set_val_at!(s.btm, tbuf, UNIT_VAL)
        end

        if err === nothing
            retry = false
            retry_cnt = _METTA_CALCULUS_MAX_RETRIES
            # ⚠️ THE TEST COMES BEFORE THE INCREMENT, AND THAT ORDER IS THE WHOLE FIX.
            # Upstream's condition block ends `done < steps` and its while-BODY is `done += 1`, so a
            # run that has just done its Nth interpret exits WITHOUT counting it. Reporting is
            # therefore unchanged by this fix — `metta_calculus(N)` still returns N — while one more
            # exec is now interpreted, which is what the space dump shows.
            # 🔑 INVISIBLE AT FIXPOINT: when the execs run out, both engines leave through the
            # `!found` arm above and neither reaches here, so every caller whose cap is generous
            # enough to reach a fixpoint is completely unaffected. That is why this survived every
            # gate we had until upstream's own corpus pinned two BOUNDED runs
            # (`workflows/mork_gold_corpus.sh`: unify/large_statement @steps 0, programs/bc0
            # @steps 50 — ours at cap+1 reproduced both golds byte for byte).
            done < steps || break
            done += 1
        elseif is_user_perm_err(err)
            # Re-insert using the intact path_buf (not modified between remove and here)
            set_val_at!(s.btm, path_buf, UNIT_VAL)
            retry = true
            if retry_cnt <= 0
                @warn "space_metta_calculus!: retry limit exceeded — $(exec_error_message(err))"
                break
            end
            retry_cnt -= 1
            sleep(0.001)
        else
            # Upstream LOGS AND CONTINUES — `if let Err(e) = self.interpret(xe) { debug!(…) }`
            # (space.rs:1707-1709) — and still counts the step, because `done` increments once per
            # iteration regardless of the result. The exec was already REMOVED unconditionally before
            # interpretation (space.rs:1704 ≡ our :1907) and is NOT re-inserted here, so proceeding
            # simply moves on to the next exec.
            #
            # We used to `break`. That made ONE malformed exec silently abort every REMAINING exec in
            # the run: `(exec 0 (, (fact $x)) ($x))` followed by a perfectly good exec produced only
            # `(fact a)`, where upstream drops the bad exec and still emits `(out a)`. Logged at debug
            # (not warn) to match upstream's level — these are malformed USER programs, not engine
            # faults, and a halting warn is exactly the behaviour being removed.
            @debug "space_metta_calculus!: $(exec_error_message(err))"
            done += 1
        end
    end
    done
end

# =====================================================================
# prefix_subsumption — group prefixes by longest shared prefix
# Mirrors Space::prefix_subsumption in space.rs (line 1278)
# =====================================================================

function space_prefix_subsumption(prefixes::Vector{Vector{UInt8}})::Vector{Int}
    n = length(prefixes)
    out = Vector{Int}(undef, n)
    for i in 1:n
        cur = prefixes[i]
        best_idx = i
        best_len = length(cur)
        for j in 1:n
            cand = prefixes[j]
            # cand is a prefix of cur iff cand == cur[1:length(cand)]
            cl = length(cand)
            if cl <= length(cur) && cur[1:cl] == cand
                if cl < best_len || (cl == best_len && j < best_idx)
                    best_idx = j
                    best_len = cl
                end
            end
        end
        out[i] = best_idx
    end
    out
end

# =====================================================================
# space_token_bfs — BFS from token prefix, return unifiable matches
# Mirrors Space::token_bfs in space.rs (line 1750)
# =====================================================================

function space_token_bfs(
    s::Space, token::Vector{UInt8}, pattern::MORK.Expr
)::Vector{Tuple{Vector{UInt8}, MORK.Expr, Int}}
    rz = read_zipper_at_path(s.btm, token)
    zipper_descend_until!(rz)
    res = Tuple{Vector{UInt8}, MORK.Expr, Int}[]
    cm = zipper_child_mask(rz)
    # General case: visit all subtries below the branch.
    for b in cm
        zipper_descend_to_byte!(rz, b)
        # Get representative expression for this byte position:
        # - If already at a value (single-byte key is a leaf value), use current position.
        # - Otherwise advance rzc to the first value in the subtrie via to_next_val!.
        # NOTE: iter_token_for_path starts AFTER the current key, so zipper_to_next_val!
        # on a value position would skip it and return the wrong expression.
        origin = if zipper_is_val(rz)
            copy(rz.prefix_buf)
        else
            rzc = deepcopy(rz)
            zipper_to_next_val!(rzc) || (zipper_ascend_byte!(rz); continue)
            copy(rzc.prefix_buf)
        end
        e = MORK.Expr(origin)
        expr_path_len = length(origin)   # used for child_count branch (dbf9d50)
        # expr_unifiable: attempt unification, return true if succeeds
        pairs = Tuple{ExprEnv, ExprEnv}[
            (ExprEnv(UInt8(0), UInt8(0), UInt32(0), e),
            ExprEnv(UInt8(1), UInt8(0), UInt32(0), pattern))
        ]
        scratch = Bindings()
        if _expr_unify_inplace!(pairs, scratch) === true
            # Port of upstream MORK dbf9d50: compute child_count so the client
            # can decide whether further exploration from this token is fruitful.
            # Walk: descend_until + count children of the resulting node, then
            # ascend back to where we were so the outer loop's next iteration
            # sees the same state.
            path_len_before = length(zipper_path(rz))
            zipper_descend_until!(rz)
            cur_path_total = rz.origin_path_len + length(zipper_path(rz))
            child_count = if expr_path_len > cur_path_total
                # The matched expr extends beyond where descend_until landed —
                # there's a true branching node below us; count its children.
                sum(1 for _ in zipper_child_mask(rz); init=0)
            else
                # descend_until reached the end of the matched expr — there's
                # exactly one concrete atom below.
                1
            end
            zipper_ascend!(rz, length(zipper_path(rz)) - path_len_before)
            push!(
                res,
                (
                    copy(rz.prefix_buf[1:(rz.origin_path_len + length(zipper_path(rz)))]),
                    e,
                    child_count
                )
            )
        end
        zipper_ascend_byte!(rz)
    end
    # Port of upstream MORK b95e2f7: special case for a single concrete atom.
    # When the general loop produces no results AND the focus token is non-empty,
    # there may be exactly one atom below the pattern that the child-mask
    # iteration missed (e.g. the subtrie is a single concrete value, not a
    # branching node).  Fork the zipper, advance to that value, check
    # unification, and emit with an EMPTY token — no further exploration from
    # this point is fruitful.  child_count = 0 (matches upstream).
    if isempty(res) && length(zipper_path(rz)) > 0
        rzc = deepcopy(rz)
        if zipper_to_next_val!(rzc)
            e = MORK.Expr(copy(rzc.prefix_buf))
            pairs = Tuple{ExprEnv, ExprEnv}[
                (ExprEnv(UInt8(0), UInt8(0), UInt32(0), e),
                ExprEnv(UInt8(1), UInt8(0), UInt32(0), pattern))
            ]
            scratch = Bindings()
            if _expr_unify_inplace!(pairs, scratch) === true
                push!(res, (UInt8[], e, 0))
            end
        end
    end
    res
end

# =====================================================================
# space_load_csv! — load CSV rows as expressions via pattern/template
# Mirrors Space::load_csv in space.rs (line 509)
# =====================================================================

function space_load_csv!(s::Space, src, pattern::MORK.Expr, template::MORK.Expr,
    separator::UInt8=UInt8(','))::Int
    bytes = src isa Vector{UInt8} ? src : Vector{UInt8}(src)
    count = 0
    for (i, line) in enumerate(split(String(bytes), '\n'))
        isempty(line) && continue
        fields = split(line, Char(separator))
        # Build expr: (arity+1 row_index field1 field2 ...)
        # row_index = i-1 as decimal string symbol, matching Rust i.to_string()
        row_sym = string(i - 1)
        parts = vcat([row_sym], String.(fields))
        arity = length(parts)
        buf = UInt8[]
        push!(buf, item_byte(ExprArity(UInt8(arity))))
        for p in parts
            pb = Vector{UInt8}(p)
            push!(buf, item_byte(ExprSymbol(UInt8(length(pb)))))
            append!(buf, pb)
        end
        data_expr = MORK.Expr(buf)

        # upstream space.rs:542 — `data.transformData(pattern, template, &mut oz)`, skipping the row
        # on any failure. See the note on `_space_load_sexpr_impl!` for why this is transformData
        # (a one-directional MATCH) and not unify+apply.
        out_buf = Vector{UInt8}(undef, max(length(template.buf) * 4, 256))
        oz = ExprZipper(MORK.Expr(out_buf), 1)
        expr_transform_data(data_expr, pattern, template, oz) === nothing || continue
        set_val_at!(s.btm, oz.root.buf[1:(oz.loc - 1)], UNIT_VAL)
        count += 1
    end
    count
end

# =====================================================================
# space_add_sexpr! / space_remove_sexpr! — pattern+template variants
# Mirrors Space::add_sexpr / remove_sexpr / load_sexpr_impl in space.rs
# =====================================================================

function space_add_sexpr!(s::Space, src, pattern::MORK.Expr, template::MORK.Expr)::Int
    _space_load_sexpr_impl!(s, src, pattern, template, true)
end

function space_remove_sexpr!(s::Space, src, pattern::MORK.Expr, template::MORK.Expr)::Int
    _space_load_sexpr_impl!(s, src, pattern, template, false)
end

function _space_load_sexpr_impl!(
    s::Space, src, pattern::MORK.Expr, template::MORK.Expr, add::Bool
)::Int
    bytes = src isa Vector{UInt8} ? src : Vector{UInt8}(src)
    ctx = SexprContext(bytes)
    parser = SpaceParser()
    count = 0
    while true
        buf = Vector{UInt8}(undef, max(length(bytes) * 2, 64))
        z = ExprZipper(MORK.Expr(buf), 1)
        try
            sexpr_parse!(parser, ctx, z)
        catch e
            e isa SexprException && e.err == SERR_INPUT_FINISHED && break
            rethrow()
        end
        data_expr = MORK.Expr(z.root.buf[1:(z.loc - 1)])
        empty!(ctx.variables)

        # upstream space.rs:879 — `data.transformData(pattern, template, &mut oz)`, `continue` on Err.
        #
        # ⚠️ This was unify + expr_apply until 2026-07-31, which is NOT the same operation, and the
        # difference is observable — settled by running both (probe, this repo):
        #
        #     pattern `(parser $)`  data `($ foo)`   upstream FAILS (IntroducedVar)   ours ADDED (parser foo)
        #     pattern `(foo bar)`   data `(foo $)`   upstream FAILS (IntroducedVar)   ours ADDED done
        #
        # transformData MATCHES one-directionally: a variable on the DATA side is an error
        # (`EF_INTRODUCED_VAR` / `EF_RECURRENT_VAR`), because the data is meant to be ground. Unify
        # is bidirectional and happily binds the data's variable to the pattern's constant, so we
        # were ADDING rows upstream SKIPS — and returning a larger count for the same input.
        #
        # It stayed hidden because every upstream call site loads with the IDENTITY transform
        # (`$` -> `_1`, main.rs:215/253/300/346/486/511/536/904), where a lone NewVar pattern binds
        # the whole datum in one step and never inspects inside it. Both routes agree there — which
        # is exactly why "it has no consumers / it passes today" is not evidence of parity.
        out_buf = Vector{UInt8}(undef, max(length(template.buf) * 4, 256))
        oz = ExprZipper(MORK.Expr(out_buf), 1)
        expr_transform_data(data_expr, pattern, template, oz) === nothing || continue
        result_bytes = oz.root.buf[1:(oz.loc - 1)]
        if add
            ;
            set_val_at!(s.btm, result_bytes, UNIT_VAL)
        else
            ;
            remove_val_at!(s.btm, result_bytes);
        end
        count += 1
    end
    count
end

# =====================================================================
# space_dump_sexpr — dump matching expressions via pattern/template
# Mirrors Space::dump_sexpr in space.rs
# =====================================================================

function space_dump_sexpr(s::Space, pattern::MORK.Expr, template::MORK.Expr, io::IO)::Int
    # Wrap pattern in comma functor: (, pattern) so query_multi can process it
    pat_wrap_buf = vcat(
        item_byte(ExprArity(UInt8(2))),
        item_byte(ExprSymbol(UInt8(1))), UInt8(','),
        pattern.buf
    )
    pat_wrapped = MORK.Expr(pat_wrap_buf)

    count = Ref(0)
    space_query_multi(
        s.btm,
        pat_wrapped,
        UInt8(0),
        (bindings, _loc_buf) -> begin
            out_buf = Vector{UInt8}(undef, max(length(template.buf) * 4, 256))
            ez_tpl = ExprZipper(template, 1)
            oz = ExprZipper(MORK.Expr(out_buf), 1)
            expr_apply(UInt8(0), UInt8(0), UInt8(0), ez_tpl, bindings, oz,
                Dict{ExprVar, UInt8}(), ExprVar[], ExprVar[])
            result_bytes = oz.root.buf[1:(oz.loc - 1)]
            println(io, expr_serialize2(result_bytes))   # upstream dump_sexpr, space.rs:952
            count[] += 1
            true
        end
    )
    count[]
end

space_dump_sexpr(s::Space, pattern::MORK.Expr, template::MORK.Expr) =
    space_dump_sexpr(s, pattern, template, stdout)

# =====================================================================
# Persistence — backup/restore tree and paths
# Mirrors Space::backup_tree/restore_tree/backup_paths/restore_paths
# backup_symbols/restore_symbols are no-ops (no interning in this port)
# =====================================================================

function space_backup_tree(s::Space, path::AbstractString)
    # Upstream Space::backup_tree = ArenaCompactTree::dump_from_zipper — an ACT-format file that
    # `(ACT …)` sources mmap-read. The prior port used serialize_paths (that's backup_PATHS), so
    # ACT reads of a backup_tree file crashed with "Invalid ACTree magic". Mirror upstream: write
    # the ArenaCompactTree via the same act_from_zipper/act_save the ACTSink uses.
    act_save(act_from_zipper(s.btm, _ -> UInt64(0)), path)
end

function space_restore_tree!(s::Space, path::AbstractString)
    # Upstream Space::restore_tree = open_mmap + insert each path. Mirrors backup_tree's ACT format.
    tree = act_open_mmap(path)
    rz = ACTZipper(tree)
    while zipper_to_next_val!(rz)
        set_val_at!(s.btm, collect(zipper_path(rz)), UNIT_VAL)
    end
end

function space_backup_paths(s::Space, path::AbstractString)
    open(path, "w") do io
        ;
        serialize_paths(s.btm, io);
    end
end

function space_restore_paths!(s::Space, path::AbstractString)
    open(path, "r") do io
        ;
        deserialize_paths(s.btm, io, UNIT_VAL);
    end
end

space_backup_symbols(::Space, ::AbstractString) = nothing  # no interning in this port
space_restore_symbols!(::Space, ::AbstractString) = nothing

# =====================================================================
# Exports
# =====================================================================

export SPACE_SIZES, SPACE_ARITIES, SPACE_VARS
export SpaceParser
export Space, new_space, space_val_count, space_statistics
export space_add_all_sexpr!, space_remove_all_sexpr!
export space_add_sexpr!, space_remove_sexpr!
export ASpaceTranscriber, space_json_to_paths, space_jsonl_to_paths
export space_dump_all_sexpr, space_dump_sexpr, space_load_json!, space_load_jsonl!, space_load_json_!
export space_backup_tree, space_restore_tree!
export space_backup_paths, space_restore_paths!
# =====================================================================
# space_sexpr_to_expr — server-branch addition
# Mirrors sexpr_to_path / Space::sexpr_to_expr in space_temporary.rs
# =====================================================================

"""
    space_sexpr_to_expr(s, sexpr) → Expr

upstream `Space::parse_sexpr` (kernel/src/space.rs:451-456):

    let mut it = Context::new(r);
    let mut parser = ParDataParser::new(&self.sm);
    let mut ez = ExprZipper::new(Expr{ ptr: buf });
    parser.sexpr(&mut it, &mut ez).map(|_| (Expr{ ptr: buf }, ez.loc))

🔴 THIS USED TO IGNORE `s` ENTIRELY and call `sexpr_to_expr(sexpr)`, which parses with
`DefaultParser`. The two tokenizers are NOT the same:

  * `ParDataParser` (ours: `SpaceParser`) truncates a symbol to 63 bytes and counts the truncation —
    `if l > 63 { self.truncated += 1; l = 63 }` (space.rs:239-243, the
    `#[cfg(not(feature="interning"))]` branch, which IS the default build).
  * `DefaultParser` falls through to `fe_tokenizer(::MorkParser, bytes) = bytes` — identity, NO cap.

So a symbol over 63 bytes was passed through whole, producing an expression that violates the Rule
of 64 and trips `item_byte`'s assertion, where upstream silently truncates and keeps going. We lost
an atom upstream would have kept.

⚠️ CORRECTS THE RECORDED CLAIM. CODEMAP said this "ignores the Space", implying a symbol-mapping
bug. It is NOT that: in the default build `ParDataParser::tokenizer` never touches `self.sm` at all
(the `write_permit` is used only under `#[cfg(feature="interning")]`, and `interning` is not in
`kernel/Cargo.toml`'s `default = ["grounding", "specialize_io"]`). The defect was the WRONG PARSER,
and its only observable consequence is the missing 63-byte cap.
"""
function space_sexpr_to_expr(s::Space, sexpr::AbstractString)::MORK.Expr
    bv = sexpr isa Vector{UInt8} ? sexpr : Vector{UInt8}(sexpr)
    ctx = SexprContext(bv)
    buf = Vector{UInt8}(undef, max(length(bv) * 2, 64))
    z = ExprZipper(MORK.Expr(buf), 1)
    sexpr_parse!(SpaceParser(), ctx, z)      # ≡ ParDataParser::new(&self.sm) in the default build
    MORK.Expr(z.root.buf[1:(z.loc - 1)])
end

# =====================================================================
# space_metta_calculus_at! — server-branch addition
# Mirrors Space::metta_calculus(thread_id_sexpr_str, ...) in space_temporary.rs
# Runs metta_calculus consuming only (exec (<location> $priority) ...) atoms.
# =====================================================================

function space_metta_calculus_at!(s::Space, location_sexpr::AbstractString,
    max_steps::Int=typemax(Int))::Int
    # Build the exec prefix for this location: (exec (<location> $) $ $)
    # Mirrors upstream metta_calculus_impl (kernel/src/space.rs:1035):
    # prefix_e = format!("(exec ({} $) $ $)", thread_id)
    prefix_str = "(exec ($location_sexpr \$) \$ \$)"
    try
        prefix_expr = sexpr_to_expr(prefix_str)
        prefix_bytes = _derive_prefix(prefix_expr)
        return _space_metta_calculus_inner!(s, prefix_bytes, max_steps, location_sexpr)
    catch e
        @warn "space_metta_calculus_at!: $e"
        0
    end
end

"""
    space_metta_calculus_at!(s::Space, anchor_bytes::Vector{UInt8}, max_steps) :: Int

Raw-bytes variant — Julia-specific extension (no upstream Rust equivalent;
upstream's `metta_calculus_impl` only takes `thread_id_sexpr_str: &str`).
Unlike the `AbstractString` overload (which wraps the location in
`(exec (loc \$) \$ \$)` and derives a prefix from that), this variant takes
a pre-computed byte-anchor and walks the calculus directly under it.

For the "run all exec atoms in a named space" use case (Stage 1 multi-space),
prefer `space_metta_calculus_in_prefix!` which composes the space prefix
with `_EXEC_PREFIX` internally — that's a cleaner abstraction than
hand-composing bytes.
"""
function space_metta_calculus_at!(s::Space, anchor_bytes::Vector{UInt8},
    max_steps::Int=typemax(Int))::Int
    try
        _space_metta_calculus_inner!(s, anchor_bytes, max_steps, "<bytes>")
    catch e
        @warn "space_metta_calculus_at! (bytes): $e"
        0
    end
end

"""
    space_metta_calculus_in_prefix!(s, space_prefix, max_steps) :: Int

Run the exec-atom calculus for atoms stored under `space_prefix ++
_EXEC_PREFIX` — the canonical entry point for "run this space's exec
atoms" in Core's prefix-region multi-space model (Stage 1).

`space_prefix == UInt8[]` makes this equivalent to `space_metta_calculus!`
(whole-trie exec processing).  For named spaces with non-empty prefix,
this scopes execution to that space's region only — exec atoms in OTHER
named-space prefixes are NOT touched.

Keeps `_EXEC_PREFIX` private (an internal MORK constant) by composing it
inside the kernel rather than requiring callers to import or reproduce it.
"""
function space_metta_calculus_in_prefix!(s::Space, space_prefix::Vector{UInt8},
    max_steps::Int=typemax(Int))::Int
    isempty(space_prefix) && return space_metta_calculus!(s, max_steps)
    try
        anchor = vcat(space_prefix, _EXEC_PREFIX)
        _space_metta_calculus_inner!(s, anchor, max_steps, "<space-prefix>";
            space_prefix=space_prefix)
    catch e
        @warn "space_metta_calculus_in_prefix!: $e"
        0
    end
end

# Internal: walks exec atoms under `prefix_bytes`, executes each.  Extracted
# from `space_metta_calculus_at!` so both the string-form (which builds an
# `(exec (loc $) $ $)` prefix) and the byte-form (raw anchor) share one loop.
function _space_metta_calculus_inner!(s::Space, prefix_bytes::Vector{UInt8},
    max_steps::Int, loc_label::AbstractString;
    space_prefix::Vector{UInt8}=UInt8[])::Int
    # `space_prefix` (default empty) is the byte-region anchor for a prefixed
    # multi-space.  The exec atom lives in the trie at the FULL path
    # `prefix_bytes ++ rel` (where prefix_bytes = space_prefix ++ _EXEC_PREFIX),
    # so we walk + remove + re-insert at that full path.  But the EXEC EXPRESSION
    # handed to space_interpret! must omit `space_prefix` — it has to start with
    # the exec arity tag (_EXEC_PREFIX ++ body), not the raw region bytes, or the
    # decoder rejects them as reserved.  `prefix=space_prefix` then scopes the
    # exec's reads + writes back into the region.
    done = 0
    retry = false
    retry_cnt = _METTA_CALCULUS_MAX_RETRIES
    path_buf = UInt8[]   # reused scratch — same pattern as space_metta_calculus!
    sp_len = length(space_prefix)

    while done < max_steps
        rz = read_zipper_at_path(s.btm, prefix_bytes)
        found = zipper_to_next_val!(rz)
        if !found
            if retry && retry_cnt > 0
                retry_cnt -= 1
                sleep(0.001)
                continue
            end
            break
        end

        empty!(path_buf)
        append!(path_buf, prefix_bytes)
        append!(path_buf, zipper_path(rz))
        remove_val_at!(s.btm, path_buf)

        # Exec expr omits the space_prefix region bytes (must begin with the
        # exec arity tag).  sp_len==0 → full path_buf (root, unchanged).
        rt = MORK.Expr(path_buf[(sp_len + 1):end])
        err = space_interpret!(s, rt; prefix=space_prefix)

        if err === nothing
            retry = false
            retry_cnt = _METTA_CALCULUS_MAX_RETRIES
            done += 1
        elseif is_user_perm_err(err)
            set_val_at!(s.btm, path_buf, UNIT_VAL)
            retry = true
            if retry_cnt > 0
                (retry_cnt -= 1; sleep(0.001))
            else
                (@warn "space_metta_calculus_at!: retry limit at $loc_label"; break)
            end
        else
            @warn "space_metta_calculus_at!: $(exec_error_message(err))"
            break
        end
    end
    done
end

# =====================================================================
# space_acquire_transform_permissions — server-branch addition
# Mirrors Space::acquire_transform_permissions in space_temporary.rs.
# Returns (read_map, template_prefixes, writer_paths) where:
#   read_map          = PathMap copy of all pattern subtries
#   template_prefixes = Vector{Tuple{Int,Int}} (incremental_start, writer_idx)
#   writer_paths      = Vector{Vector{UInt8}} (one path per unique writer slot)
# =====================================================================

"""
    space_acquire_transform_permissions(s, patterns, templates)
      → (read_map, template_prefixes, writer_slots)

Mirrors `Space::acquire_transform_permissions` in space_temporary.rs.

1. Compute constant prefix for each template (bytes up to first variable).
2. Sort template prefixes shortest-first; find minimal writer slots via
   prefix subsumption (a longer prefix is subsumed by a shorter one that
   is a prefix of it — they share one write lock).
3. Copy each pattern's subtrie into `read_map` (a local PathMap snapshot).
4. Return:
   - `read_map`          — PathMap containing all pattern atoms
   - `template_prefixes` — Vector of (incremental_start::Int, slot_idx::Int)
   - `writer_slots`      — Vector{Vector{UInt8}} (one path per unique slot)
"""
function space_acquire_transform_permissions(s::Space,
    patterns::Vector{MORK.Expr},
    templates::Vector{MORK.Expr})
    # Constant prefix: bytes up to first variable byte (NewVar 0xC0 or VarRef 0x80-0xBF)
    function _const_prefix(e::MORK.Expr)
        buf = e.buf
        i = 1
        while i <= length(buf)
            b = buf[i]
            t = byte_item(b)
            if t isa ExprNewVar || t isa ExprVarRef
                break
            elseif t isa ExprSymbol
                i += 1 + Int(t.size)
            elseif t isa ExprArity
                i += 1
            else
                break
            end
        end
        buf[1:(i - 1)]
    end

    # ── Writer slot subsumption (mirrors template_path_table sort + loop) ──
    # Table: (path, original_template_idx, writer_slot_idx)
    tpl_table = [(copy(_const_prefix(templates[i])), i, 0) for i in eachindex(templates)]
    sort!(tpl_table; by=t -> length(t[1]))   # shortest-first

    writer_slots = Vector{UInt8}[]
    slot_of = zeros(Int, length(templates))   # template_idx → slot_idx

    for k in eachindex(tpl_table)
        path, orig_idx, _ = tpl_table[k]
        subsumed = false
        for (slot_idx, slot_path) in enumerate(writer_slots)
            # slot_path is a prefix of path iff path starts with slot_path
            if length(slot_path) <= length(path) &&
                path[1:length(slot_path)] == slot_path
                slot_of[orig_idx] = slot_idx
                tpl_table[k] = (path, orig_idx, slot_idx)
                subsumed = true
                break
            end
        end
        if !subsumed
            push!(writer_slots, path)
            new_slot = length(writer_slots)
            slot_of[orig_idx] = new_slot
            tpl_table[k] = (path, orig_idx, new_slot)
        end
    end

    # template_prefixes[i] = (incremental_start, slot_idx)
    # incremental_start = length of the writer slot path (bytes already
    # implied by the slot prefix; template path bytes beyond that are
    # "incremental" relative to the slot zipper position).
    template_prefixes = [
        (length(writer_slots[slot_of[i]]), slot_of[i])
        for i in eachindex(templates)
    ]

    # ── Build read_map: snapshot all pattern subtries ──────────────────
    read_map = PathMap{UnitVal}()
    for pat in patterns
        prefix = _const_prefix(pat)
        rz = read_zipper_at_path(s.btm, prefix)
        while zipper_to_next_val!(rz)
            p = vcat(prefix, collect(zipper_path(rz)))
            set_val_at!(read_map, p, UNIT_VAL)
        end
    end

    (read_map, template_prefixes, writer_slots)
end

export space_backup_symbols, space_restore_symbols!
export space_prefix_subsumption, space_token_bfs, space_load_csv!
export BreakQuery, space_query_multi, space_query_multi_i, _space_query_multi_inner!
export space_query_coref, _coreferential_transition!
export _var_children, _size_children, _arity_children
export space_transform_multi_multi!
export space_transform_comma_comma!, space_transform_i_comma!
export space_transform_comma_o!, space_transform_i_o!
export ExecError, is_user_perm_err, exec_error_message
export space_interpret!, space_metta_calculus!, _METTA_CALCULUS_MAX_RETRIES
export _grounded_call_no_args,
    _grounded_call_with_bindings, _grounded_decode_args, _grounded_encode_results
export space_sexpr_to_expr, space_metta_calculus_at!, space_acquire_transform_permissions
export space_metta_calculus_in_prefix!, space_query_multi_at

# Precompile hot-path method specializations so JIT fires at package load,
# not on first user call. Mirrors upstream's statically-compiled hot paths.
precompile(space_metta_calculus!, (Space, Int))
precompile(space_interpret!, (Space, MORK.Expr))
precompile(space_add_all_sexpr!, (Space, String))
precompile(space_dump_all_sexpr, (Space,))
precompile(
    _space_query_multi_inner!,
    (
        PathMap{UnitVal},
        MORK.Expr,
        Int,
        Function,
        Bindings,
        Vector{Tuple{ExprEnv, ExprEnv}}
    )
)
