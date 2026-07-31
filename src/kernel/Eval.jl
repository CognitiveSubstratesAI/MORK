# Eval — 1:1 port of upstream's `eval` CRATE (`experiments/eval/src/lib.rs`, 151 lines): the registry,
# the frame types, and the STACK MACHINE (`eval` / `push_eval` / `eval_impl`).
#
# NAMED FOR THE CRATE, NOT A TYPE (renamed 2026-07-30, user-identified). This file was `EvalScope.jl`
# — named after one struct inside it — which broke our own convention of mirroring upstream FILE
# boundaries (pure.rs -> Pure.jl, sinks.rs -> Sinks.jl). Upstream's file is `lib.rs`, a crate root
# with no filename worth mirroring, so it maps to the crate: `eval` -> Eval.jl. The `eval-ffi` types it depends on
# live BELOW, not in a file of their own — see the note there for why.
#
# `pure.rs`'s `pub fn register` is NOT here — it is `pure_register!` at the end of Pure.jl, where
# upstream defines it.
#
# ⚠️ STILL OURS, NOT UPSTREAM'S: `op_skeleton` (the `op!` macro skeleton, which upstream expresses as
# a macro in pure.rs) and the global `PURE_SCOPE` (upstream's scope is SINK-OWNED — `PureSink::new`
# builds its own via `EvalScope::new()` + `pure::register`, sinks.rs:1089-1091).

# ── The `eval-ffi` crate's TYPES (upstream `experiments/eval-ffi/src/{lib,source,sink}.rs`) ───────
#
# 🔴 THE "FFI" IS DELIBERATELY NOT PORTED, AND THAT IS WHY THESE LIVE HERE RATHER THAN IN AN
# `EvalFfi.jl`. Upstream splits this crate off for ONE reason: the C ABI. It is `#![no_std]`,
# `ExprSource`/`ExprSink` are `#[repr(C)]`, `FuncPtr` is
# `extern "C" fn(*mut ExprSource, *mut ExprSink) -> Result<(), EvalError>`, and `EvalError::Msg`
# carries `{ ptr: *const u8, len: usize }` because a C-ABI error cannot own a String.
#
# NONE of those reasons exist in a Julia-native port. Our `FuncPtr` is a `Function`; `repr(C)` is
# meaningless; `ExprSource` holds a `Vector{UInt8}` + index, not a raw pointer; `EvalError` owns a
# `String`. We port the ROLES (a read cursor, an append buffer, an error), never the ABI — so the
# crate boundary carries no meaning on our side, and a file named for it would advertise a mechanism
# this project has a STANDING RULE against: the substrate stays Julia-native because zero-copy
# in-memory sharing IS the architecture ([[feedback_no_ffi_substrate_must_be_native]], user, 07-28).
#
# (The one legitimate "talk to Rust" path is the DIFFERENTIAL: we run the upstream BINARY as a
# separate process and compare bytes. That is process-level grading, not FFI — no shared memory, no
# ABI coupling, and it is what proves the port correct.)

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
    # ⚠️ NON-DESTRUCTIVE ON FAILURE, exactly as upstream. `consume_head_check` clones the source,
    # consumes on the CLONE, and only commits `*self = expr2` once the head matches
    # (eval-ffi/src/source.rs:110-118) — so a mismatched head leaves the cursor UNMOVED. We consumed
    # unconditionally, which is invisible while every caller treats the error as fatal and discards
    # the source, and wrong the moment one does not.
    saved = s.position
    items, head = try
        source_consume_head!(s)
    catch
        s.position = saved
        rethrow()
    end
    # `copy` because `String(::Vector{UInt8})` is a DESTRUCTIVE MOVE — it empties the input. Harmless
    # here today (the caller discards `head`), but the identical line without a copy in `_push_eval!`
    # produced a 0-length symbol, so both are made non-destructive rather than left as a trap.
    got = String(copy(head))
    if got != name
        s.position = saved
        throw(EvalError("expected head symbol '$name', got '$got'"))
    end
    items
end

"""
    source_consume_expr!(s) → Vector{UInt8}

upstream `ExprSource::consume::<Expr>()` (eval-ffi/src/source.rs:151-160) — consume ONE COMPLETE
sub-expression and return its whole serialized span, tag byte included, advancing the cursor past it.

Upstream is `self.position += T::advanced(se)`, i.e. it advances by the expression's serialized
length; `_expr_end_offset` computes exactly that. This is what `tuple` and `hash_expr` consume
(`let f: mork_expr::Expr = expr.consume()?`, pure.rs:904 / :805) — NOT a stripped symbol payload.
"""
function source_consume_expr!(s::ExprSource)::Vector{UInt8}
    start = s.position
    start <= length(s.buf) || throw(EvalError("consume: past end of expression"))
    stop = _expr_end_offset(s.buf, start) - 1
    stop <= length(s.buf) || throw(EvalError("consume: truncated sub-expression"))
    s.position = stop + 1
    s.buf[start:stop]
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

`arity` is the SET of counts each `op!` arm's generated check accepts — `[1]`, `[2]`, `[3]`, and
`[3, 5]` for `ifnz`, whose upstream check is `if items != 3 && items != 5` (pure.rs:877). A set, not a
scalar, because upstream's is. `nothing` means the arm emits no check (`nary` folds any count; `tuple`
takes N) — it does NOT mean "unknown". Recording it per op is how the skeleton is restored without
hand-writing 371 checks; the table is vendored in `PureOpArity.jl`.
"""
struct Func
    func::Function
    ty::FuncType
    arity::Union{Vector{Int}, Nothing}
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

"""
    eval_scope_sharing(s) → EvalScope

A scope that SHARES `s`'s function registry but owns FRESH machine state (source cursor, frame
stack, alloc pool).

🔴 WHY THIS EXISTS: upstream's scope is SINK-OWNED. `PureSink::new` builds its own with
`EvalScope::new(); pure::register(&mut scope)` (sinks.rs:1089-1091), so every sink instance has its
own `expr`/`stack`/`alloc_pool`. Ours was a single global `PURE_SCOPE`, and `scope_eval!` MUTATES all
three — under `--threads=4` (which is what `tools/run_tests.sh` runs, deliberately, because the
suite's concurrency tests guard real fixes) two sinks evaluating concurrently would corrupt each
other's stack. Faithfulness and thread-safety happen to want the same thing here.

The `fns` Dict is shared rather than rebuilt because it is READ-ONLY after `pure_register!` runs at
load time; re-registering 371 closures per sink would be upstream's literal behaviour but pure waste.
"""
eval_scope_sharing(s::EvalScope) =
    EvalScope(s.fns, ExprSource(UInt8[], 1), StackFrame[], Vector{UInt8}[])

"upstream `EvalScope::add_func` (lib.rs:64-66). `arity === nothing` = undeclared, see `Func`."
function add_func!(s::EvalScope, name::AbstractString, func::Function, ty::FuncType,
                   arity::Union{Vector{Int}, Nothing} = nothing)
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

# ══ THE STACK MACHINE — upstream `eval` / `push_eval` / `eval_impl` (lib.rs:78-150) ═══════════════
#
# Upstream evaluates by an explicit STACK OF FRAMES, each owning a SINK. Children are evaluated into
# their PARENT's sink; a frame's `func` runs only once every child has landed, reading its arguments
# back out of its own sink as a SOURCE. That is the whole design, and it is why `ifnz` is eager:
# `eval_impl` cannot call a func before `rest == 0`.
#
# ⚠️ `_expr_end_offset` lives in Sinks.jl, which is included AFTER this file. Julia resolves names in
# a function body at CALL time within the module, so this is fine — and it is the same arrangement
# `op_skeleton` already relies on for `_be_bytes` (Pure.jl).

"""
    scope_eval!(s, src) → Vector{UInt8}

upstream `EvalScope::eval` (lib.rs:78-89). Evaluates the expression `src` is positioned at and
returns the resulting serialized bytes.

The bottom frame is a sentinel: `rest = 1`, `func = nothing`, and its sink is where the final result
accumulates. `eval_impl` runs while more than that one frame remains, so the bottom frame's `func` is
never called — upstream relies on the same invariant.

THROWS `EvalError` where upstream returns `Err`. The consumer's contract is identical either way:
`sinks.rs:1165-1168` matches `Err(er) => { trace!; continue 'vals }`, i.e. THE ATOM IS SKIPPED.
"""
function scope_eval!(s::EvalScope, src::ExprSource)::Vector{UInt8}
    s.expr = src
    empty!(s.stack)
    push!(s.stack, StackFrame(ExprSink(get_alloc!(s)), 1, _nothing_func))
    _push_eval!(s)
    _eval_impl!(s)
    top = pop!(s.stack)
    sink_finish(top.sink)
end

"""
    _push_eval!(s)

upstream `EvalScope::push_eval` (lib.rs:90-119). Reads ONE item from the source and either pushes a
frame for it (an expression), splices it (quote), or copies it through (a bare symbol).

A frame's `rest` is `arity - 1` because `arity` counts the head symbol, which is not a child.
"""
function _push_eval!(s::EvalScope)
    item = source_read!(s.expr)

    if item isa SourceSymbol
        # A bare symbol is NOT evaluated — it is written straight into the current frame's sink.
        # This is why `then`/`else` work as ifnz keywords and why `'` alone is just a symbol.
        sink_write!(s.stack[end].sink, item)
        return nothing
    end

    tag = (item::SourceTag).tag
    tag isa ExprArity || throw(EvalError("not a list"))
    arity = Int((tag::ExprArity).arity)

    head = source_read!(s.expr)
    head isa SourceSymbol || throw(EvalError("expected function symbol on the left"))
    # ⚠️ `String(::Vector{UInt8})` is a DESTRUCTIVE MOVE in Julia — it takes ownership and leaves the
    # input EMPTY. Without the copy, `head.bytes` is zeroed here and the `sink_write!` below then
    # emits a 0-length symbol, which trips the Rule-of-64 assertion. Caught by test/test_eval.jl on
    # its first run; the same hazard is on record in this project from the PRIMUS era
    # (`String(copy(blob))`). Never `String(v)` a buffer you still need.
    name = String(copy((head::SourceSymbol).bytes))
    entry = get(s.fns, name, nothing)
    entry === nothing && throw(EvalError("unknown function"))

    if entry.func === _quote_sentinel
        # ── quote: splice the sub-expression VERBATIM into the CURRENT frame's sink ──
        # Upstream builds an `Expr` at the current position and pumps `item_source(e)` into
        # `stack.last_mut().sink` (lib.rs:101-107). Splicing the raw span is equivalent and needs no
        # coroutine: re-serialising the yielded items reproduces exactly these bytes.
        #
        # 🔴 DELIBERATE DEVIATION — WE ADVANCE THE CURSOR, UPSTREAM DOES NOT.
        # Upstream never updates `self.expr.position` here, so the cursor is rewound by exactly one
        # item and every later argument reads one position behind, dropping the final one:
        # `(tuple (' qq) ww zz)` yields `(qq qq ww)` upstream. That is an upstream BUG producing
        # garbage, pinned as ground truth in test/conformance/sinks/g4_quote_position.{mm2,expected}
        # and deliberately NOT in EXPECTED_PASS. Reproducing it would mean duplicating one argument
        # and dropping another; a span-based port has no cursor to alias, so we advance correctly and
        # a quoted argument works in ANY position. Do not "fix" this to match upstream without
        # revisiting that decision.
        start = s.expr.position
        stop = _expr_end_offset(s.expr.buf, start) - 1
        stop >= start || throw(EvalError("quote: empty or truncated sub-expression"))
        sink_extend!(s.stack[end].sink, @view s.expr.buf[start:stop])
        s.expr.position = stop + 1
        return nothing
    end

    frame = StackFrame(ExprSink(get_alloc!(s)), arity - 1, entry.func)
    # The frame's sink is rebuilt as a callable expression: Arity + head, then the children land here.
    sink_write!(frame.sink, SourceTag(ExprArity(UInt8(arity))))
    sink_write!(frame.sink, SourceSymbol((head::SourceSymbol).bytes))
    push!(s.stack, frame)
    nothing
end

"""
    _eval_impl!(s)

upstream `EvalScope::eval_impl` (lib.rs:120-150). Drives frames to completion.

⚠️ THE DECREMENT TARGETS THE FRAME THAT WAS TOP *BEFORE* `_push_eval!`, not whatever is on top after
it. Upstream captures `idx = parent_frames.len()` from `split_last_mut` and does
`self.stack[idx].rest -= 1` (lib.rs:147), so a newly pushed child does not steal its parent's
decrement. Getting this wrong silently mis-counts children.
"""
function _eval_impl!(s::EvalScope)
    while length(s.stack) > 1
        idx = length(s.stack)
        top = s.stack[idx]
        if top.rest == 0
            # Every child has landed: run the func over this frame's own bytes, writing into PARENT.
            data = sink_finish(top.sink)
            parent = s.stack[idx - 1]
            top.func(ExprSource(data, 1), parent.sink)
            pop!(s.stack)
            return_alloc!(s, data)          # safe: source_read! COPIES symbol payloads out
            continue
        end
        _push_eval!(s)
        s.stack[idx].rest -= 1
    end
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
function op_skeleton(name::String, body::Function, arity::Union{Vector{Int}, Nothing})
    (src::ExprSource, snk::ExprSink) -> begin
        items = source_consume_head_check!(src, name)
        if arity !== nothing && !(items in arity)
            throw(EvalError("$name takes $(join(arity, " or ")) argument" *
                            (arity == [1] ? "" : "s") * ", got $items"))
        end
        # upstream reads each operand with `expr.consume::<$tx>()`, whose check is EXACT:
        # `*e.ptr == item_byte(SymbolSize(size_of::<T>()))`. A symbol of any other length is
        # `Err("failed to consume <T>")` and the atom is skipped — never coerced. The widths are
        # vendored from the `op!` invocations; see PureOpArity.jl for why, and for the measured
        # divergence (we used to ACCEPT over-long operands and emit a result upstream skips).
        widths = get(PURE_OP_OPERAND_WIDTHS, name, nothing)
        nary_w = get(PURE_OP_NARY_WIDTH, name, nothing)
        args = Vector{Vector{UInt8}}(undef, items)
        for i in 1:items
            item = source_read!(src)
            item isa SourceSymbol ||
                throw(EvalError("$name: argument $i is not a symbol"))
            bytes = (item::SourceSymbol).bytes
            want = nary_w !== nothing ? nary_w :
                   (widths !== nothing && i <= length(widths)) ? widths[i] : nothing
            want === nothing || length(bytes) == want ||
                throw(EvalError("failed to consume <T> ($name argument $i is \
$(length(bytes)) bytes, expected $want)"))
            args[i] = bytes
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

"""
    PURE_SCOPE_UNREGISTERED

Names in upstream's `register()` that we could NOT register, because no body exists in `PURE_OPS` and
no special form claims them. Empty is the invariant; `test/test_eval.jl` asserts it.

🔴 This list can only exist because registration is now driven by the VENDORED `PURE_REGISTER` rather
than by iterating our own `PURE_OPS`. Iterating our own table meant the registry could never disagree
with itself, so it could never report a missing op — the same self-confirming shape that let a false
"42 ops absent" claim survive three days.
"""
const PURE_SCOPE_UNREGISTERED = String[]

"""
    PURE_SCOPE_EXTRA

Ops WE carry that upstream's `register()` does not. Registered (they have live consumers) but kept
distinguishable, because an op with no upstream counterpart also has no upstream oracle — see
`[[feedback_additions_above_upstream_need_own_oracle]]`.
"""
const PURE_SCOPE_EXTRA = String[]

# ── The registration loop is NOT here. It is `pure_register!` at the END of Pure.jl. ─────────────
#
# Upstream's `pub fn register(scope: &mut EvalScope)` is defined in `kernel/src/pure.rs` (:910-1300),
# not in the eval crate — the eval crate provides `add_func`, and pure.rs calls it. It lived here
# until 2026-07-30, which put a pure.rs function in the file that ports eval/src/lib.rs.
#
# The justification for keeping it here had been "it mutates EvalScope, which is a different crate",
# and that does not survive contact with upstream: pure.rs mutates another crate's type too. What
# decides a function's home is the file that DEFINES it. (User-identified.)
#
# `PURE_SCOPE` above stays here because it is an `EvalScope` INSTANCE, not a pure.rs function —
# though note that upstream has no global one either: `PureSink::new` builds its own
# (`sinks.rs:1090-1091`, `let mut scope = EvalScope::new(); pure::register(&mut scope);`). Making the
# scope sink-owned belongs with the `_pure_eval_formula` -> `scope.eval` migration, not here.

"""
    pure_scope_arity_coverage() → (declared, total)

How many registered ops carry an upstream-derived arity check. Reported rather than assumed, because
"the skeleton is restored" is exactly the kind of claim that rots into a comment nobody re-checks.

Ops without a declaration are either upstream `nary`/`tuple` (no check exists upstream) or OUR
additions above upstream (nothing to honour) — see `PURE_OP_ARITY`.
"""
pure_scope_arity_coverage() =
    (count(f -> f.arity !== nothing, values(PURE_SCOPE.fns)), length(PURE_SCOPE.fns))

export EvalError, SourceItem, SourceTag, SourceSymbol, ExprSource, ExprSink,
       source_read!, source_consume_head!, source_consume_head_check!,
       sink_write!, sink_extend!, sink_finish, source_consume_expr!,
       EvalScope, Func, FuncType, FuncMacro, FuncPure, StackFrame,
       PURE_SCOPE, PURE_SCOPE_UNREGISTERED, PURE_SCOPE_EXTRA,
       add_func!, get_alloc!, return_alloc!, op_skeleton, pure_scope_arity_coverage,
       eval_scope_sharing,
       scope_eval!
