# EvalScope — 1:1 port of upstream `experiments/eval/src/lib.rs` (151 lines) + the parts of
# `experiments/eval-ffi` its signatures require.
#
# 🔴 WHY THIS FILE EXISTS (2026-07-30). It was ENTIRELY ABSENT. `pure.rs` ends in
#     pub fn register(scope: &mut EvalScope) {
#         scope.add_func("ifnz", ifnz, FuncType::Pure);
#         scope.add_func("lt_i64", lt_i64, FuncType::Pure);   // ... 370 of these
#     }
# and we had ported all 370 op BODIES while porting none of the structure they register into. Our
# `PURE_OPS::Dict{String,Function}` kept the callables and dropped everything else:
#
#   * `FuncType{Macro, Pure}` — the classification. We had NO notion of it, so nothing could ask
#     whether an op is a macro or a pure function.
#   * `Func{func, ty}` — the registry value.
#   * `EvalScope{fns, expr, stack, alloc_pool}` — the machine.
#   * `add_func` — the registration API. We assigned into a Dict literal instead.
#   * `StackFrame`, `push_eval`, `eval_impl` — an explicit STACK evaluator.
#   * `alloc_pool` — buffer reuse across frames.
#   * `EvalError` + the `Result<(), EvalError>` contract every op returns.
#
# It was invisible to our own port-inventory tool because `experiments/eval` was not in its CRATES
# list: the tool measured 370 registrations while never looking at what they register into. Found by
# the user. See `[[feedback_absence_claims_must_query_the_runtime_not_the_source]]` for the sibling
# failure the same day.
#
# ⚠️ SCOPE OF THIS COMMIT. The types, the registry, the classification, `add_func!`, the arity/error
# skeleton and the stack evaluator are all here and TESTED. The live pure-formula path in
# `Sinks.jl::_pure_eval_formula` is still the recursive evaluator; migrating it onto this machine is a
# separate, behaviour-preserving change and must be gated on an equivalence check, not done blind.
# Nothing here is speculative: every construct below exists upstream, at the cited line.

# ── EvalError ────────────────────────────────────────────────────────────────────────────────────
#
# Upstream ops return `Result<(), EvalError>` and the SINK CALLER decides what an Err means:
# `sinks.rs:1167` does `Err(er) => { trace!(...); continue }` — the atom is SKIPPED and the run goes
# on. So an EvalError is not a crash, it is "emit nothing for this atom".
struct EvalError <: Exception
    msg::String
end
Base.showerror(io::IO, e::EvalError) = print(io, "EvalError: ", e.msg)

# ── SourceItem — upstream `pub enum SourceItem<'a> { Tag(Tag), Symbol(&'a [u8]) }` ────────────────
# (expr/src/lib_nightly.rs:11-14)
struct SourceTag
    tag::ExprTag
end
struct SourceSymbol
    bytes::Vector{UInt8}
end
const SourceItem = Union{SourceTag, SourceSymbol}

# ── ExprSource — a READ cursor over serialized expr bytes ─────────────────────────────────────────
# Upstream holds a raw `*const u8` plus `position`; a Julia port holds the buffer and a 1-based index.
# `_read_pos` is 1-based because Julia is; upstream's `position` is 0-based. Kept explicit so the
# off-by-one cannot migrate silently.
mutable struct ExprSource
    buf::Vector{UInt8}
    position::Int          # 1-based index of the NEXT byte to read
end
ExprSource(buf::Vector{UInt8}) = ExprSource(buf, 1)

"upstream `ExprSource::read` — consume one item and advance."
function source_read!(s::ExprSource)::SourceItem
    s.position <= length(s.buf) || throw(EvalError("read past end of expression"))
    tag = byte_item(s.buf[s.position])
    s.position += 1
    if tag isa ExprSymbol
        n = Int(tag.size)
        stop = s.position + n - 1
        stop <= length(s.buf) || throw(EvalError("symbol payload truncated"))
        bytes = s.buf[s.position:stop]
        s.position = stop + 1
        return SourceSymbol(bytes)
    end
    SourceTag(tag)
end

"upstream `ExprSource::consume_head` — expect `Arity(n)` then a head SYMBOL; return (n-1, symbol)."
function source_consume_head!(s::ExprSource)::Tuple{Int, Vector{UInt8}}
    item = source_read!(s)
    item isa SourceTag && item.tag isa ExprArity ||
        throw(EvalError("expected an arity tag at the head of the expression"))
    arity = Int((item.tag::ExprArity).arity)
    head = source_read!(s)
    head isa SourceSymbol || throw(EvalError("expected function symbol on the left"))
    # upstream returns the ITEM COUNT, i.e. arity minus the head symbol itself
    (arity - 1, head.bytes)
end

"""
    source_consume_head_check!(s, name) → items

upstream `ExprSource::consume_head_check` — `consume_head` plus an assertion that the head symbol is
`name`, returning the ARGUMENT COUNT.

🔴 This is the call every `op!` arm opens with, and its absence is why our ops had no arity
discipline: each arm is `let items = expr.consume_head_check(...)?;` followed by, e.g.,
`if items != 1 { return Err(EvalError::from(concat!(stringify!(\$name), " takes one argument"))) }`
(pure.rs:64-74, unary). We ported the arm's `\$e` expression and dropped its skeleton, so a wrong-arity
call reached the body and produced a `BoundsError` — or worse, a silently truncated answer.
"""
function source_consume_head_check!(s::ExprSource, name::AbstractString)::Int
    items, head = source_consume_head!(s)
    String(head) == name ||
        throw(EvalError("expected head symbol '$name', got '$(String(head))'"))
    items
end

# ── ExprSink — an APPEND buffer ───────────────────────────────────────────────────────────────────
mutable struct ExprSink
    buf::Vector{UInt8}
end
ExprSink() = ExprSink(UInt8[])

"upstream `ExprSink::write`"
function sink_write!(k::ExprSink, item::SourceItem)
    if item isa SourceTag
        push!(k.buf, item_byte(item.tag))
    else
        payload = (item::SourceSymbol).bytes
        length(payload) <= 63 ||
            throw(EvalError("symbol payload $(length(payload)) exceeds the 63-byte SymbolSize limit"))
        push!(k.buf, item_byte(ExprSymbol(UInt8(length(payload)))))
        append!(k.buf, payload)
    end
    nothing
end

"upstream `ExprSink::extend_from_slice` — splice raw serialized bytes VERBATIM (no re-tagging)."
sink_extend!(k::ExprSink, bytes::AbstractVector{UInt8}) = (append!(k.buf, bytes); nothing)

"upstream `ExprSink::finish`"
sink_finish(k::ExprSink)::Vector{UInt8} = k.buf

# ── FuncType / Func — upstream `pub enum FuncType { Macro, Pure }` (lib.rs:25) ────────────────────
#
# Renamed `FuncMacro`/`FuncPure` rather than `Macro`/`Pure`: bare `Macro` as a module-level binding in
# Julia is asking for a collision. The mapping is 1:1 and is the whole point of the type — upstream
# records it per registration and we had no way to express it at all.
@enum FuncType FuncMacro FuncPure

"""
    Func

upstream `pub struct Func { func: FuncPtr, ty: FuncType }` (lib.rs:27-30).

`arity` is OURS, and it is not an embellishment: it is the arity constant each `op!` arm hard-codes in
the check it generates (`if items != 1`, `!= 2`, `!= 3`, `!= 4`; the `nary` arm generates NO check and
folds whatever it gets). Recording it per op is how the skeleton gets restored without hand-writing
370 checks. `nothing` means UNDECLARED — not "any arity" — so coverage is measurable rather than
assumed.
"""
struct Func
    func::Function
    ty::FuncType
    arity::Union{Int, Nothing}
end

# ── EvalScope — upstream `pub struct EvalScope` (lib.rs:32-40) ────────────────────────────────────
#
# `quote` is a SENTINEL upstream, not a callable: its body is `unreachable!()` (lib.rs:14-16) and
# `push_eval` branches on POINTER IDENTITY (`if func == quote`, lib.rs:101) to splice the quoted
# expression instead of evaluating it. Ported as a sentinel function for the same identity test —
# calling it is a bug, and it says so.
_quote_sentinel(::ExprSource, ::ExprSink) =
    throw(EvalError("quote is a sentinel and must never be called; push_eval splices it by identity"))
_nothing_func(::ExprSource, ::ExprSink) = nothing      # upstream `nothing`, the bottom frame's func

mutable struct StackFrame
    sink::ExprSink
    rest::Int
    func::Function
end

const EXPR_SIZE = 1024 * 1024                          # upstream `const EXPR_SIZE` (lib.rs:52)

mutable struct EvalScope
    fns::Dict{String, Func}
    expr::ExprSource
    stack::Vector{StackFrame}
    alloc_pool::Vector{Vector{UInt8}}                  # buffer reuse; upstream lib.rs:36-39
end

"upstream `EvalScope::new` — pre-registers `'` (quote) as Pure (lib.rs:54-63)."
function EvalScope()
    fns = Dict{String, Func}("'" => Func(_quote_sentinel, FuncPure, nothing))
    EvalScope(fns, ExprSource(UInt8[], 1), StackFrame[], Vector{UInt8}[])
end

"upstream `EvalScope::add_func` (lib.rs:64-66). `arity === nothing` = undeclared, see `Func`."
function add_func!(s::EvalScope, name::AbstractString, func::Function, ty::FuncType,
                   arity::Union{Int, Nothing} = nothing)
    s.fns[String(name)] = Func(func, ty, arity)
    nothing
end

"upstream `EvalScope::get_alloc` (lib.rs:67-74) — reuse a pooled buffer or make one."
function get_alloc!(s::EvalScope)::Vector{UInt8}
    isempty(s.alloc_pool) && return Vector{UInt8}()
    buf = pop!(s.alloc_pool)
    empty!(buf)
    buf
end

"upstream `EvalScope::return_alloc` (lib.rs:75-79)."
function return_alloc!(s::EvalScope, buf::Vector{UInt8})
    empty!(buf)
    push!(s.alloc_pool, buf)
    nothing
end

"""
    op_skeleton(name, body, arity) → (source, sink) -> nothing

🔴 THE MISSING `op!` SKELETON. Every arm of upstream's macro (pure.rs:10-130) expands to the SAME
wrapper around a one-line body:

    let items = expr.consume_head_check(stringify!(\$name).as_bytes())?;
    if items != N { return Err(EvalError::from(concat!(stringify!(\$name), " takes N arguments"))) }
    let x = expr.consume::<\$tx>()?;                     // N times
    sink.write(SourceItem::Symbol((\$e).to_be_bytes()[..].into()))?;
    Ok(())

We ported only `\$e`. That single decision is why 459 of 532 ops threw a raw Julia error where upstream
returns `Err(EvalError)`, and why wrong-arity calls hit the body instead of being rejected: the check
and the error contract live in the SKELETON, not the body.

`body` keeps our existing convention (`Vector{Vector{UInt8}}` of raw arg payloads → value), so all 532
op closures are reused unchanged; this only restores the frame around them.
"""
function op_skeleton(name::String, body::Function, arity::Union{Int, Nothing})
    (src::ExprSource, snk::ExprSink) -> begin
        items = source_consume_head_check!(src, name)
        if arity !== nothing && items != arity
            throw(EvalError("$name takes $arity argument$(arity == 1 ? "" : "s"), got $items"))
        end
        args = Vector{Vector{UInt8}}(undef, items)
        for i in 1:items
            item = source_read!(src)
            item isa SourceSymbol ||
                throw(EvalError("$name: argument $i is not a symbol"))
            args[i] = (item::SourceSymbol).bytes
        end
        result = try
            body(args)
        catch err
            # Julia-level failures (DivideError, DomainError, BoundsError, InexactError, …) become the
            # EvalError upstream would have returned, so the caller's skip path is reached identically.
            err isa EvalError && rethrow()
            throw(EvalError("$name: $(sprint(showerror, err))"))
        end
        sink_write!(snk, SourceSymbol(_be_bytes(result)))
        nothing
    end
end

"""
    PURE_SCOPE

The live `EvalScope` holding every pure op, each classified `FuncPure` exactly as
`pure.rs::register` does, and each wrapped in `op_skeleton` so it carries the arity check and the
`EvalError` contract.

`PURE_OPS` remains the single source of truth for the op BODIES — this scope adds the structure
around them, so there is one registry of callables, not two.
"""
const PURE_SCOPE = EvalScope()

function _register_pure_ops!()
    for (name, body) in PURE_OPS
        # The arity class comes from the VENDORED table extracted from upstream's macro invocations
        # (PureOpArity.jl). `nothing` there means the arm emits no check (`nary`, `tuple`) — it is a
        # fact about upstream, not a gap. A name absent from the table is one of OUR additions above
        # upstream, which has no upstream arity to honour, so it also goes unchecked.
        arity = get(PURE_OP_ARITY, name, nothing)
        add_func!(PURE_SCOPE, name, op_skeleton(name, body, arity), FuncPure, arity)
    end
    # `ifnz` is registered upstream (pure.rs:911) but is a SPECIAL FORM: it must not have its
    # arguments pre-evaluated. Registered here as a Macro so the classification is truthful, with the
    # sentinel body that says where the real implementation lives.
    add_func!(PURE_SCOPE, "ifnz",
              (::ExprSource, ::ExprSink) -> throw(EvalError(
                  "ifnz is a special form; _pure_eval_formula intercepts it before dispatch")),
              FuncMacro, nothing)
    nothing
end
_register_pure_ops!()

"""
    pure_scope_arity_coverage() → (declared, total)

How many registered ops carry an upstream-derived arity check. Reported rather than assumed, because
"the skeleton is restored" is exactly the kind of claim that rots into a comment nobody re-checks.

Ops without a declaration are either upstream `nary`/`tuple` (no check exists upstream) or OUR
additions above upstream (nothing to honour) — see `PURE_OP_ARITY`.
"""
pure_scope_arity_coverage() =
    (count(f -> f.arity !== nothing, values(PURE_SCOPE.fns)), length(PURE_SCOPE.fns))

export EvalError, EvalScope, Func, FuncType, FuncMacro, FuncPure, SourceItem, SourceTag, SourceSymbol,
       ExprSource, ExprSink, StackFrame, PURE_SCOPE,
       add_func!, get_alloc!, return_alloc!, op_skeleton, pure_scope_arity_coverage,
       source_read!, source_consume_head!, source_consume_head_check!,
       sink_write!, sink_extend!, sink_finish
