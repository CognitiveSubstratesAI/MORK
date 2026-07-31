"""
Pure — port of `mork/kernel/src/pure.rs`.

Numeric primitive operations for the MORK evaluation engine.
Covers u8/u16/u32/u64/i8/i16/i32/i64/f32/f64 arithmetic, bitwise,
transcendental, and conversion operations.

All operations follow the convention:
  - Arguments are Vector{UInt8} (big-endian encoded numeric values)
  - Results are Vector{UInt8} (big-endian encoded)
  - The dispatch table `PURE_OPS` maps name → julia_lambda

Julia translation notes
========================
  - Rust `extern "C" fn name(ExprSource, ExprSink)` →
    Julia `(args::Vector{Vector{UInt8}}) → number` (wrapped by _be_bytes)
  - Rust `expr.consume::<T>()` → `_read_T(arg_bytes[i])`
  - Rust `sink.write(SourceItem::Symbol(bytes))` → return `_be_bytes(result)`
  - eval_ffi not needed — just pure numeric lambdas
"""

# =====================================================================
# Big-endian read/write helpers
# =====================================================================

_be_bytes(x::UInt8) = [x]
_be_bytes(x::UInt16) = collect(reinterpret(UInt8, [hton(x)]))
_be_bytes(x::UInt32) = collect(reinterpret(UInt8, [hton(x)]))
_be_bytes(x::UInt64) = collect(reinterpret(UInt8, [hton(x)]))
_be_bytes(x::Int8) = [reinterpret(UInt8, x)]
_be_bytes(x::Int16) = collect(reinterpret(UInt8, [hton(x)]))
_be_bytes(x::Int32) = collect(reinterpret(UInt8, [hton(x)]))
_be_bytes(x::Int64) = collect(reinterpret(UInt8, [hton(x)]))
_be_bytes(x::UInt128) = collect(reinterpret(UInt8, [hton(x)]))   # 16 BE bytes
_be_bytes(x::Int128) = collect(reinterpret(UInt8, [hton(x)]))   # 16 BE bytes
_be_bytes(x::Float32) = collect(reinterpret(UInt8, [hton(x)]))
_be_bytes(x::Float64) = collect(reinterpret(UInt8, [hton(x)]))
_be_bytes(x::AbstractVector{UInt8}) = collect(x)  # passthrough for string ops

_read_u8(b) = b[1]
_read_u16(b) = ntoh(only(reinterpret(UInt16, b[1:2])))
_read_u32(b) = ntoh(only(reinterpret(UInt32, b[1:4])))
_read_u64(b) = ntoh(only(reinterpret(UInt64, b[1:8])))
_read_i8(b) = reinterpret(Int8, b[1])
_read_i16(b) = ntoh(only(reinterpret(Int16, b[1:2])))
_read_i32(b) = ntoh(only(reinterpret(Int32, b[1:4])))
_read_i64(b) = ntoh(only(reinterpret(Int64, b[1:8])))
# 128-bit: Rust `consume::<u128/i128>()` reads 16 BE bytes — Julia has native
# UInt128/Int128, so no truncation needed (the i128 ops below used _read_i64 → bug).
_read_u128(b) = ntoh(only(reinterpret(UInt128, b[1:16])))
_read_i128(b) = ntoh(only(reinterpret(Int128, b[1:16])))
_read_f32(b) = ntoh(only(reinterpret(Float32, b[1:4])))

"""
    _rust_float_as_int(T, x) -> T

Rust's `x as iN` for a FLOAT source. Since Rust 1.45 this cast is **saturating**, not UB and not
checked: NaN → 0, below-range → `typemin`, above-range → `typemax`, otherwise truncate toward zero.

Julia's `IntN(x)` is a CHECKED conversion that THROWS on a fractional or out-of-range value —
`Int8(2.5)` is an InexactError. Inside a pure sink that throw is SWALLOWED and the op emits
nothing, so the divergence is silent: upstream writes a value, we write no atom at all.

⚠️ THIS IS THE SAME DEFECT AS THE INT→INT `as` FAMILY (fixed in `3973455`, see the comment on
`i128_as_i8` below), which was fixed instance-by-instance while the TEN float→int ops right beside
it kept the checked form. Found by a per-op differential against the upstream binary; the
conformance corpus covered 18 of 360 pure ops, and none of these.
"""
function _rust_float_as_int(::Type{T}, x::AbstractFloat) where {T <: Integer}
    isnan(x) && return zero(T)
    # Compare in the FLOAT domain. `typemin/typemax` for the wide types are not exactly
    # representable, so `<=`/`>=` against the rounded bound is what keeps the boundary saturating
    # rather than overflowing in the `trunc` below.
    x <= float(typemin(T)) && return typemin(T)
    x >= float(typemax(T)) && return typemax(T)
    trunc(T, x)
end

"""
    _rust_domain(f, x) -> typeof(x)

Rust's float math returns **NaN** outside a function's domain; Julia THROWS DomainError. Inside a
pure sink that throw is swallowed and the op emits NO atom, where upstream writes a NaN — so the
divergence is silent and total, not a wrong digit. Same meta-class as `_rust_float_as_int`:
Julia raises where Rust produces a value.

Found by the per-op differential: `acos_f32/f64`, `asin_f32/f64` and `atanh_f32/f64` produced
nothing for an out-of-domain input while upstream emitted a NaN bit pattern.
"""
@inline function _rust_domain(f::F, x::T) where {F, T <: AbstractFloat}
    try
        f(x)
    catch
        T(NaN)
    end
end

# ⚠️ TWO EXPLICIT METHODS, NOT A DEFAULT ARGUMENT. Writing this as
# `_rust_domain(f::F, x::T, nan::T = T(NaN)) where {F, T <: AbstractFloat}` compiles but the
# TWO-ARG form then returns GARBAGE — measured `_rust_domain(acos, 2.5f0)` = `90ee1e60` instead of
# the NaN `7fc00000`, while the three-arg form was correct. A default that constructs a value from
# a `where`-bound type parameter is not safe here; spelling both methods out is.
@inline function _rust_domain(f::F, x::T, nan::T) where {F, T <: AbstractFloat}
    try
        f(x)
    catch
        nan
    end
end

"""
    _rust_domain_neg(f, x) -> typeof(x)

Same contract as `_rust_domain`, but yields a **NEGATIVE** quiet NaN.

🔴 THE NaN SIGN IS NOT UNIFORM ACROSS OPS, and it is not derivable — it falls out of how each libm
routine computes the out-of-domain case, so it has to be MEASURED per op. Pinned from the release
binary (2026-07-30), f32 and f64 agreeing in every case:

| op                                  | out-of-domain result |
|-------------------------------------|----------------------|
| `asin` `acos` `log10`               | `7fc00000` / `7ff8…` — **POSITIVE** NaN |
| `ln` `log2` `sqrt` `acosh` `sin` `cos` `tan` `atanh` | `ffc00000` / `fff8…` — **NEGATIVE** NaN |

`log10` sitting on the opposite side from `ln` and `log2` is the reason this is a table and not a
rule: a "logs give -NaN" generalisation would have been wrong for one of the three.

⚠️ The sign is constructed INSIDE this function rather than threaded in as an argument. The existing
note on `atanh` records that passing a non-default NaN through the 3-arg `_rust_domain` produced a
wrong encoding at that call site, so this avoids the parameter entirely.

WHY A WHOLE FAMILY NEEDED THIS. `_rust_domain` already existed for `asin`/`acos`, and `atanh` was
spelled out beside it — the rule "Julia RAISES where Rust returns a value, and inside a pure sink a
raise means NO ATOM AT ALL" was derived, then applied to three ops and not swept. The widened
differential found it still open on eight more: 48 of 56 divergences, one cause.
[[feedback_recurring_defect_derive_the_rule]]
"""
@inline function _rust_domain_neg(f::F, x::T) where {F, T <: AbstractFloat}
    try
        f(x)
    catch
        -T(NaN)
    end
end

"""
    _rust_parse_float(T, s) -> T

Rust's `str::parse::<fN>()` grammar (std docs for `f64::from_str`):

    Float  ::= Sign? ( 'inf' | 'infinity' | 'nan' | Number )     -- those three case-INSENSITIVE
    Number ::= ( Digit+ | Digit+ '.' Digit* | Digit* '.' Digit+ ) Exp?
    Exp    ::= [eE] Sign? Digit+

Julia's `parse(Float64, s)` additionally accepts **hex float literals**: `parse(Float64, "0x10")` is
`16.0` where Rust returns `Err`. Measured against the binary — we emitted `4030000000000000` for
`(f64_from_string 0x10)` and upstream emitted nothing.

⚠️ THIS CORRECTS A CLAIM I MADE EARLIER THE SAME DAY. On the narrower probe set I wrote that floats
were "Rust-compatible as-is and NOT narrowed by the guard" for the integers, because `NaN`, `inf`,
`infinity` and `1e3` all agreed. They do — the hex form was simply not in that probe set. A parser
agreeing on ten accepted inputs says nothing about what it wrongly accepts; only the REJECT cases
test strictness.
"""
const _RUST_FLOAT_RE =
    r"^[+-]?(?:(?i:inf(?:inity)?|nan)|(?:[0-9]+|[0-9]+\.[0-9]*|[0-9]*\.[0-9]+)(?:[eE][+-]?[0-9]+)?)$"

function _rust_parse_float(::Type{T}, s::AbstractString) where {T <: AbstractFloat}
    occursin(_RUST_FLOAT_RE, s) || error("not a Rust float literal: $s")
    parse(T, s)
end
_read_f64(b) = ntoh(only(reinterpret(Float64, b[1:8])))
_read_u32s(b) = _read_u32(b)   # shift amount is u32 (4 bytes): upstream shl/shr all take `y: u32`
                               # (pure.rs, e.g. u8_shr(x: u8, y: u32)). Was _read_u64 (8 bytes), which
                               # BoundsError'd on the 4-byte shift ip_sudoku passes (sub_i32 → i32).

# General 3-input bitwise LUT (x86 vpternlog) — the result bit for each bit position
# is bit ((x<<2)|(y<<1)|z) of the selector `s`. Computed via the 8 minterms, which is
# equivalent to (and replaces) the upstream 256-case `match s` table
# (main:kernel/src/pure.rs `ternary_table`, :113-370).
#
# ✅ EQUIVALENCE PROVEN FOR ALL 256 SELECTORS, not spot-checked (2026-07-30; the previous comment
# claimed only s = 0,1,2,4,6). Method — bit-slicing, which turns the whole table into one identity:
# feed x=0xF0, y=0xCC, z=0xAA, so that bit j of the operand triple encodes the input combination
# (x<<2)|(y<<1)|z == j. Under those inputs a correct arm for selector `s` must evaluate to exactly
# `s`. Every one of upstream's 256 arms does (test/integration/pure_ternarylogic_table.jl), and so
# does this function, so the two agree pointwise on the whole selector domain.
# (The *_ternarylogic ops previously ignored x, y, AND the selector — they just rebuilt z — audit P-2.)
function _ternarylogic(x::T, y::T, z::T, s::UInt8)::T where {T <: Base.BitUnsigned}
    r = zero(T)
    for j in 0:7
        ((s >> j) & 0x1) == 0x1 || continue
        mx = ((j >> 2) & 1) != 0 ? x : ~x
        my = ((j >> 1) & 1) != 0 ? y : ~y
        mz = (j & 1) != 0 ? z : ~z
        r |= mx & my & mz
    end
    r
end

# =====================================================================
# Rust-compatible float rendering
# =====================================================================

"""
    _f64_rust_string(x) → String

Render a float the way Rust's `impl Display for f64` / `f64::to_string()` does, which is NOT what
Julia's `string(::Float64)` produces. Verified against the upstream release binary (2026-07-26):

| value            | Rust / upstream           | Julia `string`            |
|------------------|---------------------------|---------------------------|
| -3.0             | `-3`                      | `-3.0`   (trailing .0)    |
| 1e20             | `100000000000000000000`   | `1.0e20` (exponent form)  |
| 3.0000000000000004e-5 | `0.000030000000000000004` | `3.0000000000000004e-5` |
| 0.30000000000000004   | `0.30000000000000004`     | same                  |

Three rules: shortest round-trip digits (same as Julia), **never** exponent notation (always the full
decimal expansion), and integral values carry **no** `.0` suffix. We reuse Julia's shortest-round-trip
digits and re-place the decimal point, so precision is identical — only the presentation changes.

Used by the float reduction sinks and by the `f32_to_string`/`f64_to_string` pure ops, all of which
previously emitted Julia-formatted floats that diverged from upstream byte-for-byte.
"""
function _f64_rust_string(x::Real)::String
    xf = Float64(x)
    isnan(xf) && return "NaN"
    isinf(xf) && return xf > 0 ? "inf" : "-inf"
    xf == 0.0 && return signbit(xf) ? "-0" : "0"

    s = string(xf)                      # Julia's shortest round-trip form (may use e-notation)
    neg = startswith(s, "-")
    neg && (s = s[2:end])
    mant, ex = s, 0
    i = findfirst(==('e'), s)
    if i !== nothing
        mant = s[1:(i - 1)]
        ex = parse(Int, s[(i + 1):end])
    end
    j = findfirst(==('.'), mant)
    ip, fp = j === nothing ? (mant, "") : (mant[1:(j - 1)], mant[(j + 1):end])

    digits = ip * fp
    point = length(ip) + ex             # decimal-point position within `digits`
    out = if point <= 0
        "0." * "0"^(-point) * digits
    elseif point >= length(digits)
        digits * "0"^(point - length(digits))
    else
        digits[1:point] * "." * digits[(point + 1):end]
    end
    if occursin('.', out)               # Rust never renders a trailing .0
        out = rstrip(rstrip(out, '0'), '.')
        isempty(out) && (out = "0")
    end
    (neg ? "-" : "") * out
end

# base64url (RFC 4648 §5): the URL-safe alphabet substitutes `-` for `+` and `_` for `/`, and upstream
# uses the NO_PAD engine, so trailing `=` is omitted. Julia's Base64 stdlib only offers the standard
# padded alphabet, so translate on the way out and undo it on the way in.
function _b64url_encode(bytes)::String
    s = base64encode(bytes)
    rstrip(replace(s, '+' => '-', '/' => '_'), '=')
end

function _b64url_decode(s::AbstractString)::Vector{UInt8}
    t = replace(String(s), '-' => '+', '_' => '/')
    r = length(t) % 4                       # restore the padding Julia's decoder requires
    r != 0 && (t *= "="^(4 - r))
    base64decode(t)
end

"""
    _rust_debug_float(x) → String

Render a float the way Rust's `{:?}` (**Debug**) does — which is NOT the same as `{}` (Display), and
NOT the same as Julia's `string`. Upstream's `*_to_string` pure ops use Debug specifically:
`write!(&mut cur, "{:?}", x)` at kernel/src/pure.rs:107.

The two Rust traits genuinely differ, and this port needs BOTH:

| value | `{}` Display (`_f64_rust_string`) | `{:?}` Debug (here) |
|-------|----------------------------------|---------------------|
| 61.0  | `61`                             | `61.0`              |
| 1e20  | `100000000000000000000`          | `1e20`              |
| 1e-7  | `0.0000001`                      | `1e-7`              |
| -0.0  | `-0`                             | `-0.0`              |

Display is what the FLOAT REDUCTION SINKS use (`total.to_string()`, sinks.rs:1024/1061 — verified
against `fsum` output); Debug is what the `to_string` OPS use. Applying one formatter to both was a
mistake made and caught on 2026-07-26: it left 4 of 6 pinned values wrong for the ops.

Rust's rule (`core::fmt::float_to_general_debug`): use positional notation when `x == 0` or
`1e-4 <= |x| < 1e16`, ALWAYS with at least one fractional digit; otherwise exponential with the
mantissa's trailing `.0` dropped. Verified against every value pinned from the upstream binary in the
`g4_tostring` probe: 61.0 · 1e20 · 1e-7 · -0.0 · inf · NaN.

Formats at the ARGUMENT's own precision — `string(::Float32)` gives Float32 shortest-round-trip digits,
so `0.1f0` renders `0.1` and not Float64's `0.10000000149011612`.
"""
function _rust_debug_float(x::Union{Float32, Float64})::String
    isnan(x) && return "NaN"
    isinf(x) && return x > 0 ? "inf" : "-inf"
    a = abs(Float64(x))
    if x == 0 || (a >= 1e-4 && a < 1e16)
        # Positional, and Debug ALWAYS keeps at least one fractional digit.
        s = _expand_to_decimal(string(x))
        return occursin('.', s) ? s : s * ".0"
    end
    # Exponential. Julia writes Float32 exponents with `f` (`1.0f20`); normalise to `e`, then drop the
    # mantissa's trailing `.0` as Rust does (`1.0e20` -> `1e20`).
    s = replace(string(x), 'f' => 'e')
    i = findfirst(==('e'), s)
    i === nothing && return s
    mant, ex = s[1:(i - 1)], s[(i + 1):end]
    endswith(mant, ".0") && (mant = mant[1:(end - 2)])
    mant * "e" * ex
end

# Expand a Julia shortest-round-trip float repr (possibly `1.0e20` / `1.0f-7`) to full positional
# decimal, dropping any trailing `.0`. Shared by the Display and Debug renderers so both keep the
# ARGUMENT's own digits.
function _expand_to_decimal(s0::AbstractString)::String
    s = replace(String(s0), 'f' => 'e')
    neg = startswith(s, "-")
    neg && (s = s[2:end])
    mant, ex = s, 0
    i = findfirst(==('e'), s)
    if i !== nothing
        mant = s[1:(i - 1)]
        ex = parse(Int, s[(i + 1):end])
    end
    j = findfirst(==('.'), mant)
    ip, fp = j === nothing ? (mant, "") : (mant[1:(j - 1)], mant[(j + 1):end])
    digits = ip * fp
    point = length(ip) + ex
    out = if point <= 0
        "0." * "0"^(-point) * digits
    elseif point >= length(digits)
        digits * "0"^(point - length(digits))
    else
        digits[1:point] * "." * digits[(point + 1):end]
    end
    if occursin('.', out)
        out = rstrip(rstrip(out, '0'), '.')
        isempty(out) && (out = "0")
    end
    (neg ? "-" : "") * out
end

# =====================================================================
# Rust-semantics helpers — the behaviour that lives in the `op!` MACRO ARMS
# =====================================================================
#
# 🔴 These exist because we ported the macro's EXPANSION and not the macro. Everything below is a
# semantic that `op!` supplies once, in the arm, and that a hand-written per-op transcription has to
# re-remember 5-14 times. Each one had already drifted. See the generated block at the end of
# PURE_OPS for the ops themselves.

"""
    _nary_fold(f, rd, seed, a) → accumulator

`op!(num nary NAME(\$initial, t: T, x: T) => \$e)` (pure.rs:11-24) expands to

    let items = expr.consume_head_check(...)?;
    let mut t: T = \$initial;
    for _ in 0..items { let x = expr.consume::<T>()?; t = \$e; }
    sink.write(SourceItem::Symbol((t).to_be_bytes()[..].into()))?;

so it folds over **every** consumed item from a CONSTANT seed and has **no arity check at all**:
zero args emits the seed, N args folds all N. We had transcribed these as BINARY ops reading `a[1]`
and `a[2]`, which silently ignored args 3+ and threw on 0 or 1 arg.
"""
function _nary_fold(f::F, rd::R, seed::T, a::Vector{Vector{UInt8}})::T where {F, R, T}
    t = seed
    for buf in a
        t = f(t, rd(buf))
    end
    t
end

# Rust's `f32::max`/`f64::max` IGNORE NaN and return the other operand (LLVM `maxnum`); Julia's `max`
# PROPAGATES it. Likewise min.
# ⚠️ This rule was already found and applied INLINE in the FloatReduction sink on 2026-07-26
# (Sinks.jl, `op === :min ? ... isnan ...`) and never swept to the pure ops sitting beside it. It now
# lives in ONE place that both call, so the next float reduction cannot miss it.
#
# SIGNED ZERO, measured 2026-07-30. `f*::min`/`f*::max` do not specify which operand they return when
# the two compare EQUAL, and on this platform both return the SECOND. Folding `[-0.0, +0.0]`:
#     min: min(+Inf,-0.0) = -0.0, then min(-0.0,+0.0) -> +0.0   (upstream 0000…, ours was 8000… )
#     max: max(-Inf,-0.0) = -0.0, then max(-0.0,+0.0) -> +0.0   (upstream 0000…)
# Julia's `min` returns the FIRST on a signed-zero tie, so `min_f32`/`min_f64` emitted -0.0. Julia's
# `max` happened to return +0.0 and therefore AGREED — by coincidence of Julia's tie-break, not
# because our code encoded the rule. Both now state it explicitly, so max's agreement is principled
# rather than accidental. `x == y` is the right test: it is true for ±0.0 and false for NaN.
_rust_fmax(x::T, y::T) where {T <: AbstractFloat} =
    isnan(x) ? y : isnan(y) ? x : x == y ? y : max(x, y)
_rust_fmin(x::T, y::T) where {T <: AbstractFloat} =
    isnan(x) ? y : isnan(y) ? x : x == y ? y : min(x, y)

# `f32::signum`/`f64::signum` are a SIGN-BIT test, not a three-way compare:
#     if self.is_nan() { Self::NAN } else { 1.0.copysign(self) }
# so -0.0 => -1.0 and +0.0 => +1.0, and NaN returns a POSITIVE quiet NaN (`Self::NAN`), not `self`.
# Julia's `sign` returns zero for zero, which is right for the INTEGER signum ops and wrong here.
_rust_signum(x::T) where {T <: AbstractFloat} = isnan(x) ? T(NaN) : copysign(one(T), x)

# Rust `as u32` on a signed integer sign-extends to at least 32 bits then keeps the low 32. Julia's
# `%(x, UInt32)` is exactly that modular reinterpretation: `Int8(-1) % UInt32 === 0xffffffff`, which
# is the exponent `pow_i8(x, -1)` actually raises `x` to upstream.
_as_u32(x::Integer) = x % UInt32

"""
    _rust_pow(x, exp::UInt32)

`i*::pow` — exponentiation by squaring with WRAPPING multiplies (release builds have
overflow-checks off, and Julia's integer `*` wraps identically).

Upstream is `op!(num binary pow_i8(x: i8, exp: i8) => x.pow(exp as u32))`: the cast to `u32` happens
BEFORE the call, so a negative exponent becomes a huge unsigned one and this still terminates. We had
used Julia's `^`, which throws `DomainError` on a negative exponent — emitting nothing where upstream
emits a wrapped value.
"""
function _rust_pow(x::T, exp::UInt32)::T where {T <: Integer}
    exp == 0 && return one(T)
    base, acc, e = x, one(T), exp
    while true
        if isodd(e)
            acc *= base
            e == 1 && return acc          # e > 0 always holds, so the low bit is reached at e == 1
        end
        e >>= 1
        base *= base
    end
end

# `u*_shl`/`u*_shr` are `x.checked_shl(y).ok_or(EvalError::from("shl overflow"))?` (pure.rs:387-390,
# :410-411, :432-433, :453-454, :474-475). `checked_shl` returns None once `y >= BITS`, so upstream
# returns Err and its caller SKIPS the atom (sinks.rs:1167 `Err(er) => { trace!; continue }`).
# Julia's `<<` is TOTAL — `UInt8(1) << 8` is 0 — so without this guard we FABRICATE an atom upstream
# never emits. That is the dangerous direction: a value existing only in our engine can seed a
# fixpoint upstream never reaches.
# NOTE the shift operand is `u32` at EVERY width (`u8_shl(x: u8, y: u32)`), never the operand width.
_checked_shl(x::T, y::UInt32) where {T <: Unsigned} =
    y >= 8 * sizeof(T) ? error("shl overflow") : x << y
_checked_shr(x::T, y::UInt32) where {T <: Unsigned} =
    y >= 8 * sizeof(T) ? error("shr overflow") : x >> y

"""
    _rust_parse_int(T, s) → T

Rust's `str::parse::<iN>()` grammar is **exactly** `[+-]?[0-9]+` — no `0x`/`0b`/`0o` prefix, no
digit separators, no surrounding whitespace. Julia's `parse(T, s)` is LAXER on all three counts, so
`(i64_from_string 0x10)` returned 16 here and `Err` upstream: we FABRICATED an atom upstream never
emits, which is the dangerous direction (a value existing only in our engine can seed a fixpoint
upstream never reaches).

Measured against the binary 2026-07-30: upstream rejects `0x10` and `0b101` (we accepted both) and
also rejects `1_000` and `5abc` (we already agreed on those two).

`base = 10` alone is not enough — the explicit character guard is what rejects whitespace. Overflow
needs no special handling: Rust returns `Err` and Julia throws, and both end in the atom being
skipped.
"""
function _rust_parse_int(::Type{T}, s::AbstractString) where {T <: Integer}
    isempty(s) && error("empty integer literal")
    i = firstindex(s)
    (s[i] == '+' || s[i] == '-') && (i = nextind(s, i))
    i > lastindex(s) && error("sign with no digits")
    for c in SubString(s, i)
        ('0' <= c <= '9') || error("not a Rust integer literal: $s")
    end
    parse(T, s; base = 10)
end

"""
    _rust_powi(x, n::Int32) → typeof(x)

`f32::powi`/`f64::powi` lower to `llvm.powi`, i.e. compiler-rt's `__powi{s,d}f2` — binary
exponentiation by REPEATED MULTIPLICATION:

    double __powidf2(double a, int b) {
      const int recip = b < 0;
      double r = 1;
      while (1) { if (b & 1) r *= a;  b /= 2;  if (b == 0) break;  a *= a; }
      return recip ? 1/r : r;
    }

Julia's `x^n::Integer` for floats routes to libm `pow`, which is more accurate — so it disagrees in
the last bit. Measured: `powi_f64(1.1, 10)` gave `4004bffc0c03023e` here vs `…3d` upstream.
**A more accurate answer is still a divergence**; `powi` is a specified multiply chain, not `pow`.

Note this is NOT the same helper as `_rust_pow` (the INTEGER `i*::pow`): that one takes an already
`as u32`-cast exponent and wraps, this one takes a signed `i32` and reciprocates. `b /= 2` truncates
toward zero and `b & 1` is 1 for odd negatives, so the loop is sign-agnostic and `recip` does the
work — which is why `n = typemin(Int32)` needs no special case (unlike an `abs`-based formulation).
"""
function _rust_powi(x::T, n::Int32)::T where {T <: AbstractFloat}
    r, a, b = one(T), x, n
    while true
        isodd(b) && (r *= a)
        b = div(b, Int32(2))          # C's `/` truncates toward zero, as does Julia's `div`
        b == 0 && break
        a *= a
    end
    n < 0 ? one(T) / r : r
end

"""
    _rust_clamp(x, lo, hi)

`Ord::clamp` and `f64::clamp` both contain `assert!(min <= max)`, so an inverted range PANICS — and a
panic inside `extern "C"` ABORTS THE WHOLE PROCESS, so upstream produces no output file at all.

⚠️ **DELIBERATE DEVIATION, recorded so a future "match upstream" sweep cannot reintroduce an abort.**
We must never abort mid-saturation, so we raise and the atom is skipped. Skipping is strictly closer
to upstream than Julia's total `clamp`, which INVENTS a value (it returns `hi` when `lo > hi`) that
upstream never produces. A NaN bound also fails `lo <= hi`, matching the assert.
"""
_rust_clamp(x::T, lo::T, hi::T) where {T <: Real} =
    lo <= hi ? clamp(x, lo, hi) : error("clamp: min > max")

# =====================================================================
# pure_apply — main entry point
# =====================================================================

"""
    pure_apply(name, arg_bufs) → Vector{UInt8}

Apply numeric primitive `name` to big-endian byte argument vectors.
Returns the big-endian byte result, throws on unknown name.
"""
# ⚠️ TEST-ONLY, AND FOR TEN NAMES IT DOES NOT EXERCISE WHAT RUNS. `pure_apply` dispatches through
# `PURE_OPS`, i.e. the byte-level bodies that `pure_register!` wraps in `op_skeleton`. But that
# registration checks `PURE_NATIVE_OPS` FIRST (:1385), so for the ten hand-written names —
# encode_hex, decode_hex, encode_base64url, decode_base64url, hash_expr, reverse_symbol,
# collapse_symbol, explode_symbol, ifnz, tuple — the NATIVE `(ExprSource, ExprSink)` function is what
# gets installed and what the sinks call. Their `PURE_OPS` entries are unreachable at runtime.
#
# Nine of those ten still have a PURE_OPS entry, and it is kept DELIBERATELY: it is the only thing
# `pure_handwritten_fns.jl` can call, since `pure_apply` takes and returns raw byte payloads while
# the natives take a source and a sink. Discovered by deleting them — the file named for the
# hand-written functions went red with "Unknown pure op", which is the proof that it has been
# measuring the byte-level bodies rather than the functions it is named after.
#
# The natives are NOT untested: the 2792-point pure-op differential and the conformance corpus run
# real MM2 through the registered scope, which is the native path. What is missing is unit coverage
# at this layer. Closing it means teaching `pure_apply` to build `(name arg…)` and go through
# `scope_eval!(PURE_SCOPE, …)`, which changes its return shape from a payload to an encoded
# expression and so touches every assertion in five test files. Left as a scoped follow-up rather
# than done badly at the end of a long session.
function pure_apply(name::String, arg_bufs::Vector{Vector{UInt8}})::Vector{UInt8}
    f = get(PURE_OPS, name, nothing)
    f === nothing && error("Unknown pure op: $name")
    _be_bytes(f(arg_bufs))
end

"""
    pure_apply_native(name, args) → Vector{UInt8}

Apply a pure op THROUGH THE REGISTERED SCOPE — the path the sinks actually take.

Unlike [`pure_apply`], which dispatches into `PURE_OPS`, this builds the expression `(name arg…)` and
hands it to `scope_eval!(PURE_SCOPE, …)`. So for the ten hand-written names it reaches the NATIVE
`(ExprSource, ExprSink)` function that `pure_register!` installs (Pure.jl:1385), and for every other
op it reaches the `op_skeleton`-wrapped body — in both cases whatever is actually registered.

Two consequences for callers, both from going through the evaluator rather than a table lookup:

  * each ARG must be a complete EXPRESSION, not a raw payload (wrap bytes with a SymbolSize tag)
  * the RESULT is the encoded result expression, not a bare payload — a symbol result carries its
    SymbolSize header

`pure_apply` is kept for the ops whose registration genuinely goes through `PURE_OPS`; it is the
right oracle there and its raw-payload contract is more convenient.
"""
function pure_apply_native(name::String, args::Vector{Vector{UInt8}})::Vector{UInt8}
    buf = UInt8[item_byte(ExprArity(UInt8(1 + length(args)))),
                item_byte(ExprSymbol(UInt8(length(name))))]
    append!(buf, Vector{UInt8}(name))
    for a in args
        append!(buf, a)
    end
    scope_eval!(PURE_SCOPE, ExprSource(buf, 1))
end


"""
    PURE_SPECIAL_FORMS

Op names upstream registers in `EvalScope` that CANNOT live in `PURE_OPS`, because they control the
evaluation of their own arguments and a table-dispatched op receives them already evaluated.

`_pure_eval_formula` (Sinks.jl) intercepts each of these BEFORE dispatch:
  * `ifnz` — `scope.add_func("ifnz", ifnz, FuncType::Pure)` (pure.rs:911). Eagerly evaluating both
    branches would defeat the entire point of a conditional.
  * `'` (quote) — pre-registered in `EvalScope::new` (`experiments/eval/src/lib.rs:56`) and then
    special-cased by identity in `push_eval` (`if func == quote`), i.e. upstream also refuses to
    dispatch it normally.

🔴 WHY THIS SET IS EXPLICIT RATHER THAN IMPLICIT IN AN `if`-CHAIN. Removing a dead, divergent
`PURE_OPS["ifnz"]` entry on 2026-07-30 made the port-inventory ratchet report `ifnz` ABSENT — correctly,
since it asks the live registries and `ifnz` is in none of them. "Implemented as a special form" was
knowledge that existed only inside a conditional in another file, so no instrument could see it. Now an
absence claim about a control-flow op has somewhere truthful to look.

⚠️ Membership here is NOT a licence to skip the op. It asserts the op is implemented in the EVALUATOR.
If you add a name, point at the interception site in the same commit.
"""
const PURE_SPECIAL_FORMS = Set{String}(["ifnz", "'"])

# =====================================================================
# PURE_OPS dispatch table
# =====================================================================

const PURE_OPS = Dict{String, Function}(

    # ── u8 ──────────────────────────────────────────────────────────
    "u8_zeros" => (a) -> UInt8(0),
    "u8_ones" => (a) -> ~UInt8(0),
    "u8_not" => (a) -> ~_read_u8(a[1]),
    "u8_swap_bytes" => (a) -> _read_u8(a[1]),
    # count/leading/trailing bit-ops return u32 for EVERY integer width in Rust (x.count_ones() :: u32),
    # so upstream emits 4 bytes; our port emitted the INPUT width (1 byte for u8), which cascaded into
    # u32_eq/ifnz failing on the width mismatch (ip_sudoku 71 vs 102 fixpoint). Fixed 2026-07-23 to u32.
    "u8_leading_zeros" => (a) -> UInt32(leading_zeros(_read_u8(a[1]))),
    "u8_leading_ones" => (a) -> UInt32(leading_ones(_read_u8(a[1]))),
    "u8_count_zeros" => (a) -> UInt32(count_zeros(_read_u8(a[1]))),
    "u8_count_ones" => (a) -> UInt32(count_ones(_read_u8(a[1]))),
    "u8_reverse_bits" => (a) -> bitreverse(_read_u8(a[1])),
    "u8_nand" => (a) -> ~(_read_u8(a[1]) & _read_u8(a[2])),
    "u8_andn" => (a) -> _read_u8(a[1]) & ~_read_u8(a[2]),
    "u8_nor" => (a) -> ~(_read_u8(a[1]) | _read_u8(a[2])),
    "u8_xor" => (a) -> xor(_read_u8(a[1]), _read_u8(a[2])),
    "u8_xnor" => (a) -> ~xor(_read_u8(a[1]), _read_u8(a[2])),
    # u8_shl / u8_shr are GENERATED at the end of this file (upstream uses checked_shl/checked_shr).
    "u8_and" => (a) -> reduce(&, [_read_u8(x) for x in a]; init=(~UInt8(0))),
    "u8_or" => (a) -> reduce(|, [_read_u8(x) for x in a]; init=UInt8(0)),
    "u8_parity" => (a) -> reduce(xor, [_read_u8(x) for x in a]; init=UInt8(0)),

    # ── u16 ─────────────────────────────────────────────────────────
    "u16_zeros" => (a) -> UInt16(0),
    "u16_ones" => (a) -> ~UInt16(0),
    "u16_not" => (a) -> ~_read_u16(a[1]),
    "u16_swap_bytes" => (a) -> bswap(_read_u16(a[1])),
    "u16_leading_zeros" => (a) -> UInt32(leading_zeros(_read_u16(a[1]))),
    "u16_leading_ones" => (a) -> UInt32(leading_ones(_read_u16(a[1]))),
    "u16_count_zeros" => (a) -> UInt32(count_zeros(_read_u16(a[1]))),
    "u16_count_ones" => (a) -> UInt32(count_ones(_read_u16(a[1]))),
    "u16_reverse_bits" => (a) -> bitreverse(_read_u16(a[1])),
    "u16_nand" => (a) -> ~(_read_u16(a[1]) & _read_u16(a[2])),
    "u16_andn" => (a) -> _read_u16(a[1]) & ~_read_u16(a[2]),
    "u16_nor" => (a) -> ~(_read_u16(a[1]) | _read_u16(a[2])),
    "u16_xor" => (a) -> xor(_read_u16(a[1]), _read_u16(a[2])),
    "u16_xnor" => (a) -> ~xor(_read_u16(a[1]), _read_u16(a[2])),
    # u16_shl / u16_shr are GENERATED at the end of this file (upstream uses checked_shl/checked_shr).
    "u16_and" => (a) -> reduce(&, [_read_u16(x) for x in a]; init=(~UInt16(0))),
    "u16_or" => (a) -> reduce(|, [_read_u16(x) for x in a]; init=UInt16(0)),
    "u16_parity" => (a) -> reduce(xor, [_read_u16(x) for x in a]; init=UInt16(0)),

    # ── u32 ─────────────────────────────────────────────────────────
    "u32_zeros" => (a) -> UInt32(0),
    "u32_ones" => (a) -> ~UInt32(0),
    "u32_not" => (a) -> ~_read_u32(a[1]),
    "u32_swap_bytes" => (a) -> bswap(_read_u32(a[1])),
    "u32_leading_zeros" => (a) -> UInt32(leading_zeros(_read_u32(a[1]))),
    "u32_leading_ones" => (a) -> UInt32(leading_ones(_read_u32(a[1]))),
    "u32_count_zeros" => (a) -> UInt32(count_zeros(_read_u32(a[1]))),
    "u32_count_ones" => (a) -> UInt32(count_ones(_read_u32(a[1]))),
    "u32_reverse_bits" => (a) -> bitreverse(_read_u32(a[1])),
    "u32_nand" => (a) -> ~(_read_u32(a[1]) & _read_u32(a[2])),
    "u32_andn" => (a) -> _read_u32(a[1]) & ~_read_u32(a[2]),
    "u32_nor" => (a) -> ~(_read_u32(a[1]) | _read_u32(a[2])),
    "u32_xor" => (a) -> xor(_read_u32(a[1]), _read_u32(a[2])),
    "u32_xnor" => (a) -> ~xor(_read_u32(a[1]), _read_u32(a[2])),
    # u32_shl / u32_shr are GENERATED at the end of this file (upstream uses checked_shl/checked_shr).
    "u32_and" => (a) -> reduce(&, [_read_u32(x) for x in a]; init=(~UInt32(0))),
    "u32_or" => (a) -> reduce(|, [_read_u32(x) for x in a]; init=UInt32(0)),
    "u32_parity" => (a) -> reduce(xor, [_read_u32(x) for x in a]; init=UInt32(0)),

    # ── u64 ─────────────────────────────────────────────────────────
    "u64_zeros" => (a) -> UInt64(0),
    "u64_ones" => (a) -> ~UInt64(0),
    "u64_not" => (a) -> ~_read_u64(a[1]),
    "u64_swap_bytes" => (a) -> bswap(_read_u64(a[1])),
    "u64_leading_zeros" => (a) -> UInt32(leading_zeros(_read_u64(a[1]))),
    "u64_leading_ones" => (a) -> UInt32(leading_ones(_read_u64(a[1]))),
    "u64_count_zeros" => (a) -> UInt32(count_zeros(_read_u64(a[1]))),
    "u64_count_ones" => (a) -> UInt32(count_ones(_read_u64(a[1]))),
    "u64_reverse_bits" => (a) -> bitreverse(_read_u64(a[1])),
    "u64_nand" => (a) -> ~(_read_u64(a[1]) & _read_u64(a[2])),
    "u64_andn" => (a) -> _read_u64(a[1]) & ~_read_u64(a[2]),
    "u64_nor" => (a) -> ~(_read_u64(a[1]) | _read_u64(a[2])),
    "u64_xor" => (a) -> xor(_read_u64(a[1]), _read_u64(a[2])),
    "u64_xnor" => (a) -> ~xor(_read_u64(a[1]), _read_u64(a[2])),
    # u64_shl / u64_shr are GENERATED at the end of this file (upstream uses checked_shl/checked_shr).
    "u64_and" => (a) -> reduce(&, [_read_u64(x) for x in a]; init=(~UInt64(0))),
    "u64_or" => (a) -> reduce(|, [_read_u64(x) for x in a]; init=UInt64(0)),
    "u64_parity" => (a) -> reduce(xor, [_read_u64(x) for x in a]; init=UInt64(0)),








    # ── string conversions ────────────────────────────────────────────
    # STRICT `[+-]?[0-9]+` — Julia's bare `parse` accepts `0x10`/`0b101` (and whitespace), Rust's
    # `str::parse` does not, so we emitted values upstream never produces. See `_rust_parse_int`.
    # The u* ops are OURS (upstream has no unsigned from_string) but follow the same rule.
    "i8_from_string" => (a) -> _rust_parse_int(Int8, String(a[1])),
    "i16_from_string" => (a) -> _rust_parse_int(Int16, String(a[1])),
    "i32_from_string" => (a) -> _rust_parse_int(Int32, String(a[1])),
    "i64_from_string" => (a) -> _rust_parse_int(Int64, String(a[1])),
    "f32_from_string" => (a) -> _rust_parse_float(Float32, String(a[1])),
    "f64_from_string" => (a) -> _rust_parse_float(Float64, String(a[1])),
    "i8_to_string" => (a) -> Vector{UInt8}(string(_read_i8(a[1]))),
    "i16_to_string" => (a) -> Vector{UInt8}(string(_read_i16(a[1]))),
    "i32_to_string" => (a) -> Vector{UInt8}(string(_read_i32(a[1]))),
    "i64_to_string" => (a) -> Vector{UInt8}(string(_read_i64(a[1]))),
    # Rust **Debug** (`{:?}`), not Display and not Julia `string` — upstream's to_string macro writes
    # `write!(&mut cur, "{:?}", x)` (pure.rs:107). The reduction SINKS use Display instead; the two are
    # different traits and this port needs both. See `_rust_debug_float`.
    "f32_to_string" => (a) -> Vector{UInt8}(_rust_debug_float(_read_f32(a[1]))),
    "f64_to_string" => (a) -> Vector{UInt8}(_rust_debug_float(_read_f64(a[1]))),

    # ── i8/i16/i32/i64/i128 arithmetic (missing from original port) ──
    "sub_i8" => (a) -> _read_i8(a[1]) - _read_i8(a[2]),
    "sub_i16" => (a) -> _read_i16(a[1]) - _read_i16(a[2]),
    "sub_i32" => (a) -> _read_i32(a[1]) - _read_i32(a[2]),
    "sub_i64" => (a) -> _read_i64(a[1]) - _read_i64(a[2]),
    "div_i8" => (a) -> div(_read_i8(a[1]), _read_i8(a[2])),
    "div_i16" => (a) -> div(_read_i16(a[1]), _read_i16(a[2])),
    "div_i32" => (a) -> div(_read_i32(a[1]), _read_i32(a[2])),
    "div_i64" => (a) -> div(_read_i64(a[1]), _read_i64(a[2])),
    "mod_i8" => (a) -> rem(_read_i8(a[1]), _read_i8(a[2])),
    "mod_i16" => (a) -> rem(_read_i16(a[1]), _read_i16(a[2])),
    "mod_i32" => (a) -> rem(_read_i32(a[1]), _read_i32(a[2])),
    "mod_i64" => (a) -> rem(_read_i64(a[1]), _read_i64(a[2])),
    # pow_i8..pow_i128 are GENERATED at the end of this file (the exponent is cast `as u32` FIRST,
    # so a negative one wraps rather than throwing).
    "neg_i8" => (a) -> -_read_i8(a[1]),
    "neg_i16" => (a) -> -_read_i16(a[1]),
    "neg_i32" => (a) -> -_read_i32(a[1]),
    "neg_i64" => (a) -> -_read_i64(a[1]),
    "abs_i8" => (a) -> abs(_read_i8(a[1])),
    "abs_i16" => (a) -> abs(_read_i16(a[1])),
    "abs_i32" => (a) -> abs(_read_i32(a[1])),
    "abs_i64" => (a) -> abs(_read_i64(a[1])),
    "signum_i8" => (a) -> Int8(sign(_read_i8(a[1]))),
    "signum_i16" => (a) -> Int16(sign(_read_i16(a[1]))),
    "signum_i32" => (a) -> Int32(sign(_read_i32(a[1]))),
    "signum_i64" => (a) -> Int64(sign(_read_i64(a[1]))),
    # min_/max_/clamp_/sum_/product_ i8..i64 are GENERATED at the end of this file, from the macro
    # arms rather than from their expansion — see "NARY / shift / pow / signum / clamp families".
    "i8_one" => (_) -> Int8(1),
    "i16_one" => (_) -> Int16(1),
    "i32_one" => (_) -> Int32(1),
    "i64_one" => (_) -> Int64(1),

    # ── i128 (native Int128 — were truncating to Int64 via _read_i64, audit P-1) ──
    "abs_i128" => (a) -> abs(_read_i128(a[1])),
    "neg_i128" => (a) -> -_read_i128(a[1]),
    "signum_i128" => (a) -> Int128(sign(_read_i128(a[1]))),
    # min_i128/max_i128/clamp_i128/sum_i128/product_i128 are GENERATED at the end of this file.
    # D-P1 fix (audit 2026-06-04): these read via _read_i64 / returned Int64/Int8 — only
    # the low 8 of the 16 i128 bytes, silently wrong for |x| ≥ 2^63. Now _read_i128 (full
    # 16 BE bytes) and return Int128 so _be_bytes(::Int128) emits 16 bytes. (abs/neg/min/
    # max/clamp/sum/product were already _read_i128 — this completes the family.)
    "mod_i128" => (a) -> rem(_read_i128(a[1]), _read_i128(a[2])),
    "i128_one" => (_) -> Int128(1),
    "i128_from_string" => (a) -> _rust_parse_int(Int128, String(a[1])),
    "i128_to_string" => (a) -> Vector{UInt8}(string(_read_i128(a[1]))),
    "sub_i128" => (a) -> _read_i128(a[1]) - _read_i128(a[2]),
    "div_i128" => (a) -> div(_read_i128(a[1]), _read_i128(a[2])),
    # Rust `x as iN` on integers TRUNCATES (modular); Julia's `IntN(x)` is a CHECKED
    # conversion that THROWS InexactError. Every narrowing op here used the checked form, so
    # e.g. `i128_as_i64` of a 128-bit hash threw instead of taking the low 64 bits — the pure
    # sink swallowed the error and emitted NOTHING. That is why `hash_expr` produced no output
    # at all: the failure was one op DOWNSTREAM of it. `%` is Julia's modular conversion and
    # matches Rust `as` for both narrowing and (sign-extending) widening.
    "i128_as_i8" => (a) -> _read_i128(a[1]) % Int8,
    "i128_as_i16" => (a) -> _read_i128(a[1]) % Int16,
    "i128_as_i32" => (a) -> _read_i128(a[1]) % Int32,
    "i128_as_i64" => (a) -> _read_i128(a[1]) % Int64,
    "i128_as_f32" => (a) -> Float32(_read_i128(a[1])),
    "i128_as_f64" => (a) -> Float64(_read_i128(a[1])),

    # ── type conversions ─────────────────────────────────────────────
    "i8_as_i16" => (a) -> _read_i8(a[1]) % Int16,
    "i8_as_i32" => (a) -> _read_i8(a[1]) % Int32,
    "i8_as_i64" => (a) -> _read_i8(a[1]) % Int64,
    "i8_as_i128" => (a) -> _read_i8(a[1]) % Int128,
    "i8_as_f32" => (a) -> Float32(_read_i8(a[1])),
    "i8_as_f64" => (a) -> Float64(_read_i8(a[1])),
    "i16_as_i8" => (a) -> _read_i16(a[1]) % Int8,
    "i16_as_i32" => (a) -> _read_i16(a[1]) % Int32,
    "i16_as_i64" => (a) -> _read_i16(a[1]) % Int64,
    "i16_as_i128" => (a) -> _read_i16(a[1]) % Int128,
    "i16_as_f32" => (a) -> Float32(_read_i16(a[1])),
    "i16_as_f64" => (a) -> Float64(_read_i16(a[1])),
    "i32_as_i8" => (a) -> _read_i32(a[1]) % Int8,
    "i32_as_i16" => (a) -> _read_i32(a[1]) % Int16,
    "i32_as_i64" => (a) -> _read_i32(a[1]) % Int64,
    "i32_as_i128" => (a) -> _read_i32(a[1]) % Int128,
    "i32_as_f32" => (a) -> Float32(_read_i32(a[1])),
    "i32_as_f64" => (a) -> Float64(_read_i32(a[1])),
    "i64_as_i8" => (a) -> _read_i64(a[1]) % Int8,
    "i64_as_i16" => (a) -> _read_i64(a[1]) % Int16,
    "i64_as_i32" => (a) -> _read_i64(a[1]) % Int32,
    "i64_as_i128" => (a) -> _read_i64(a[1]) % Int128,
    "i64_as_f32" => (a) -> Float32(_read_i64(a[1])),
    "i64_as_f64" => (a) -> Float64(_read_i64(a[1])),
    "f32_as_i8" => (a) -> _rust_float_as_int(Int8, _read_f32(a[1])),
    "f32_as_i16" => (a) -> _rust_float_as_int(Int16, _read_f32(a[1])),
    "f32_as_i32" => (a) -> _rust_float_as_int(Int32, _read_f32(a[1])),
    "f32_as_i64" => (a) -> _rust_float_as_int(Int64, _read_f32(a[1])),
    "f32_as_i128" => (a) -> _rust_float_as_int(Int128, _read_f32(a[1])),
    "f32_as_f64" => (a) -> Float64(_read_f32(a[1])),
    "f64_as_i8" => (a) -> _rust_float_as_int(Int8, _read_f64(a[1])),
    "f64_as_i16" => (a) -> _rust_float_as_int(Int16, _read_f64(a[1])),
    "f64_as_i32" => (a) -> _rust_float_as_int(Int32, _read_f64(a[1])),
    "f64_as_i64" => (a) -> _rust_float_as_int(Int64, _read_f64(a[1])),
    "f64_as_i128" => (a) -> _rust_float_as_int(Int128, _read_f64(a[1])),
    "f64_as_f32" => (a) -> Float32(_read_f64(a[1])),

    # ── f32/f64 arithmetic ────────────────────────────────────────────
    "sub_f32" => (a) -> _read_f32(a[1]) - _read_f32(a[2]),
    "sub_f64" => (a) -> _read_f64(a[1]) - _read_f64(a[2]),
    "div_f32" => (a) -> _read_f32(a[1]) / _read_f32(a[2]),
    "div_f64" => (a) -> _read_f64(a[1]) / _read_f64(a[2]),
    "neg_f32" => (a) -> -_read_f32(a[1]),
    "neg_f64" => (a) -> -_read_f64(a[1]),
    "abs_f32" => (a) -> abs(_read_f32(a[1])),
    "abs_f64" => (a) -> abs(_read_f64(a[1])),
    # signum_f32/f64, min_/max_/clamp_/sum_/product_ f32/f64 are GENERATED at the end of this file.
    "recip_f32" => (a) -> 1.0f0 / _read_f32(a[1]),
    "recip_f64" => (a) -> 1.0 / _read_f64(a[1]),
    "fract_f32" => (a) -> _read_f32(a[1]) - trunc(_read_f32(a[1])),
    "fract_f64" => (a) -> _read_f64(a[1]) - trunc(_read_f64(a[1])),
    "trunc_f32" => (a) -> trunc(Float32, _read_f32(a[1])),
    "trunc_f64" => (a) -> trunc(Float64, _read_f64(a[1])),
    "floor_f32" => (a) -> floor(Float32, _read_f32(a[1])),
    "floor_f64" => (a) -> floor(Float64, _read_f64(a[1])),
    "ceil_f32" => (a) -> ceil(Float32, _read_f32(a[1])),
    "ceil_f64" => (a) -> ceil(Float64, _read_f64(a[1])),
    # Rust's `f32::round`/`f64::round` round half AWAY FROM ZERO; Julia's `round` defaults to
    # RoundNearest, which is ties-to-EVEN. So `round(2.5)` is 3 upstream and was 2 here.
    # Pinned against the binary on all four sign/parity combinations:
    #   2.5 -> 3 (40400000)   -2.5 -> -3 (c0400000)   3.5 -> 4   -3.5 -> -4
    # `trunc`/`floor`/`ceil` need no mode — they are unambiguous and already matched.
    "round_f32" => (a) -> round(Float32, _read_f32(a[1]), RoundNearestTiesAway),
    "round_f64" => (a) -> round(Float64, _read_f64(a[1]), RoundNearestTiesAway),
    "copysign_f32" => (a) -> copysign(_read_f32(a[1]), _read_f32(a[2])),
    "copysign_f64" => (a) -> copysign(_read_f64(a[1]), _read_f64(a[2])),
    "powf_f32" => (a) -> _read_f32(a[1]) ^ _read_f32(a[2]),
    "powf_f64" => (a) -> _read_f64(a[1]) ^ _read_f64(a[2]),
    # `powi` is a MULTIPLY CHAIN (llvm.powi / __powi{s,d}f2), not libm `pow`. Julia's `^` uses `pow`
    # and is MORE accurate, which still diverges: `powi_f64(1.1, 10)` was `4004bffc0c03023e` here vs
    # `…3d` upstream. See `_rust_powi`.
    "powi_f32" => (a) -> _rust_powi(_read_f32(a[1]), _read_i32(a[2])),
    "powi_f64" => (a) -> _rust_powi(_read_f64(a[1]), _read_i32(a[2])),
    "hypot_f32" => (a) -> hypot(_read_f32(a[1]), _read_f32(a[2])),
    "hypot_f64" => (a) -> hypot(_read_f64(a[1]), _read_f64(a[2])),
    "sqrt_f32" => (a) -> _rust_domain_neg(sqrt, _read_f32(a[1])),
    "sqrt_f64" => (a) -> _rust_domain_neg(sqrt, _read_f64(a[1])),
    "cbrt_f32" => (a) -> cbrt(_read_f32(a[1])),
    "cbrt_f64" => (a) -> cbrt(_read_f64(a[1])),
    "exp_f32" => (a) -> exp(_read_f32(a[1])),
    "exp_f64" => (a) -> exp(_read_f64(a[1])),
    "exp2_f32" => (a) -> exp2(_read_f32(a[1])),
    "exp2_f64" => (a) -> exp2(_read_f64(a[1])),
    "ln_f32" => (a) -> _rust_domain_neg(log, _read_f32(a[1])),
    "ln_f64" => (a) -> _rust_domain_neg(log, _read_f64(a[1])),
    "log2_f32" => (a) -> _rust_domain_neg(log2, _read_f32(a[1])),
    "log2_f64" => (a) -> _rust_domain_neg(log2, _read_f64(a[1])),
    "log10_f32" => (a) -> _rust_domain(log10, _read_f32(a[1])),
    "log10_f64" => (a) -> _rust_domain(log10, _read_f64(a[1])),
    "sin_f32" => (a) -> _rust_domain_neg(sin, _read_f32(a[1])),
    "sin_f64" => (a) -> _rust_domain_neg(sin, _read_f64(a[1])),
    "cos_f32" => (a) -> _rust_domain_neg(cos, _read_f32(a[1])),
    "cos_f64" => (a) -> _rust_domain_neg(cos, _read_f64(a[1])),
    "tan_f32" => (a) -> _rust_domain_neg(tan, _read_f32(a[1])),
    "tan_f64" => (a) -> _rust_domain_neg(tan, _read_f64(a[1])),
    "asin_f32" => (a) -> _rust_domain(asin, _read_f32(a[1])),
    "asin_f64" => (a) -> _rust_domain(asin, _read_f64(a[1])),
    "acos_f32" => (a) -> _rust_domain(acos, _read_f32(a[1])),
    "acos_f64" => (a) -> _rust_domain(acos, _read_f64(a[1])),
    "atan_f32" => (a) -> atan(_read_f32(a[1])),
    "atan_f64" => (a) -> atan(_read_f64(a[1])),
    "atan2_f32" => (a) -> atan(_read_f32(a[1]), _read_f32(a[2])),
    "atan2_f64" => (a) -> atan(_read_f64(a[1]), _read_f64(a[2])),
    "sinh_f32" => (a) -> sinh(_read_f32(a[1])),
    "sinh_f64" => (a) -> sinh(_read_f64(a[1])),
    "cosh_f32" => (a) -> cosh(_read_f32(a[1])),
    "cosh_f64" => (a) -> cosh(_read_f64(a[1])),
    "tanh_f32" => (a) -> tanh(_read_f32(a[1])),
    "tanh_f64" => (a) -> tanh(_read_f64(a[1])),
    "asinh_f32" => (a) -> asinh(_read_f32(a[1])),
    "asinh_f64" => (a) -> asinh(_read_f64(a[1])),
    "acosh_f32" => (a) -> _rust_domain_neg(acosh, _read_f32(a[1])),
    "acosh_f64" => (a) -> _rust_domain_neg(acosh, _read_f64(a[1])),
    # ⚠️ NaN SIGN IS NOT UNIFORM. Rust's `atanh` returns a NEGATIVE NaN outside the domain
    # (ffc00000 / fff8000000000000) while `acos`/`asin` return a POSITIVE one (7fc00000) — because
    # atanh is computed through a log of a negative quantity, whose libm result carries the sign.
    # Verified against the binary for BOTH signs of input (2.5 and -2.5 both give -NaN).
    # Spelled out rather than routed through `_rust_domain`: the NaN here must be NEGATIVE, and
    # threading a non-default NaN through the helper produced a wrong encoding at this call site.
    # Rust computes atanh via a log of a negative quantity out of domain, so libm's result carries
    # the sign — verified against the binary for BOTH input signs (2.5 and -2.5 give -NaN), whereas
    # `acos`/`asin` give +NaN. `atanh(±1)` is `±Inf` in Julia and does not throw, so only |x| > 1
    # is redirected.
    "atanh_f32" => (a) -> (let x = _read_f32(a[1])
        abs(x) > 1.0f0 ? -Float32(NaN) : atanh(x)
    end),
    "atanh_f64" => (a) -> (let x = _read_f64(a[1])
        abs(x) > 1.0 ? -Float64(NaN) : atanh(x)
    end),
    "to_radians_f32" => (a) -> deg2rad(_read_f32(a[1])),
    "to_radians_f64" => (a) -> deg2rad(_read_f64(a[1])),
    # Rust's `f32::to_degrees` multiplies by a PRECOMPUTED f32 constant, i.e. the ratio is formed
    # in full precision and rounded once. Julia's `rad2deg(z) = z * (180 / oftype(z, pi))` performs
    # the DIVISION in Float32, which rounds twice and lands 1 ULP low:
    #     rad2deg(2.5f0)            = 430f3d4c        (was ours)
    #     2.5f0 * Float32(180/pi)   = 430f3d4d        (upstream)
    # `to_degrees_f64` and both `to_radians` already agree — f64 forms the ratio in double on both
    # sides, and Julia's `deg2rad` constant already matches Rust's — so only this one changes.
    "to_degrees_f32" => (a) -> _read_f32(a[1]) * 57.2957795130823208767981548141051703f0,
    "to_degrees_f64" => (a) -> rad2deg(_read_f64(a[1])),

    # ── f32/f64 constants ─────────────────────────────────────────────
    "pi_f32" => (_) -> Float32(π),
    "pi_f64" => (_) -> Float64(π),
    "tau_f32" => (_) -> Float32(2π),
    "tau_f64" => (_) -> Float64(2π),
    "e_f32" => (_) -> Float32(ℯ),
    "e_f64" => (_) -> Float64(ℯ),
    "phi_f32" => (_) -> Float32((1 + sqrt(5)) / 2),
    "phi_f64" => (_) -> Float64((1 + sqrt(5)) / 2),
    "inf_f32" => (_) -> Inf32,
    "inf_f64" => (_) -> Inf,
    "neginf_f32" => (_) -> -Inf32,
    "neginf_f64" => (_) -> -Inf,

    # ── u128 bitwise (full 128-bit width — mirrors u64 family + pure.rs:460-479) ──
    # and/or/parity are N-ary folds (pure.rs:477-479: u128_and(!0,t,x)=>t&x etc),
    # NOT binary; everything reads the full 16 BE bytes via _read_u128 (the prior
    # impl truncated inputs to the low 64 bits — silently wrong for values ≥ 2^64).
    "u128_and" => (a) -> reduce(&, [_read_u128(x) for x in a]; init=(~UInt128(0))),
    "u128_or" => (a) -> reduce(|, [_read_u128(x) for x in a]; init=UInt128(0)),
    "u128_parity" => (a) -> reduce(xor, [_read_u128(x) for x in a]; init=UInt128(0)),
    "u128_xor" => (a) -> xor(_read_u128(a[1]), _read_u128(a[2])),
    "u128_not" => (a) -> ~_read_u128(a[1]),
    "u128_nand" => (a) -> ~(_read_u128(a[1]) & _read_u128(a[2])),
    "u128_nor" => (a) -> ~(_read_u128(a[1]) | _read_u128(a[2])),
    "u128_xnor" => (a) -> ~xor(_read_u128(a[1]), _read_u128(a[2])),
    "u128_andn" => (a) -> _read_u128(a[1]) & ~_read_u128(a[2]),
    # u128_shl / u128_shr are GENERATED at the end of this file (upstream uses checked_shl/checked_shr).
    "u128_swap_bytes" => (a) -> bswap(_read_u128(a[1])),
    "u128_reverse_bits" => (a) -> bitreverse(_read_u128(a[1])),
    "u128_leading_zeros" => (a) -> UInt32(leading_zeros(_read_u128(a[1]))),
    "u128_leading_ones" => (a) -> UInt32(leading_ones(_read_u128(a[1]))),
    "u128_count_zeros" => (a) -> UInt32(count_zeros(_read_u128(a[1]))),
    "u128_count_ones" => (a) -> UInt32(count_ones(_read_u128(a[1]))),
    "u128_ones" => (_) -> ~UInt128(0),
    "u128_zeros" => (_) -> UInt128(0),
    "u128_ternarylogic" =>
        (a) -> _ternarylogic(
            _read_u128(a[1]), _read_u128(a[2]), _read_u128(a[3]), _read_u8(a[4])
        ),

    # ── u32 eq + ternary logic (P-2: now reads the selector + all 3 inputs) ──
    "u32_eq" => (a) -> UInt8(_read_u32(a[1]) == _read_u32(a[2]) ? 1 : 0),   # bool = 1 byte (upstream 1u8/0u8)
    "u32_ternarylogic" =>
        (a) -> _ternarylogic(
            _read_u32(a[1]), _read_u32(a[2]), _read_u32(a[3]), _read_u8(a[4])
        ),
    "u16_ternarylogic" =>
        (a) -> _ternarylogic(
            _read_u16(a[1]), _read_u16(a[2]), _read_u16(a[3]), _read_u8(a[4])
        ),
    "u64_ternarylogic" =>
        (a) -> _ternarylogic(
            _read_u64(a[1]), _read_u64(a[2]), _read_u64(a[3]), _read_u8(a[4])
        ),
    "u8_ternarylogic" =>
        (a) ->
            _ternarylogic(_read_u8(a[1]), _read_u8(a[2]), _read_u8(a[3]), _read_u8(a[4])),

    # ── symbol ops ───────────────────────────────────────────────────
    "reverse_symbol" => (a) -> reverse(a[1]),
    # collapse_symbol: takes ONE argument (raw payload from _pure_strip_header).
    # Arg may be arity expression bytes (from explode_symbol or quote) or plain bytes.
    # Mirrors collapse_symbol in pure.rs: reads arity-N expression, extracts symbol payloads.
    # 🔴 EVERY EXIT PATH HERE USED TO BE PERMISSIVE, AND ONE OF THEM COULD KILL THE WHOLE RUN.
    # Upstream (pure.rs:825-843) has exactly three failure modes, all `Err` ⇒ the atom is skipped:
    #   1. the argument is not `Tag::Arity`             -> "argument should be an expression"
    #   2. any element is not `SourceItem::Symbol`      -> "can only concat symbols in collapse"
    #   3. `i + symbol.len() >= 64`                     -> "new symbol can not be larger than 63 bytes"
    # We had: (1) fall through to `reduce(vcat, a)`, concatenating the raw argument — `(collapse_symbol
    # foo)` returned "foo" where upstream errors; (2) `break`, returning the PARTIAL prefix collected
    # so far — `(collapse_symbol ('(a (b c))))` returned "a"; (3) no cap at all.
    #
    # (3) was the severe one, and it was NOT a wrong value. Our Expr layer asserts the Rule of 64 when
    # the oversized result is WRITTEN, one layer above this op, so the throw escaped the pure sink's
    # per-atom error handling as a TaskFailedException and **aborted the entire exec run** — measured:
    # one 64-byte `collapse_symbol` took down all 9 probes in its file. Upstream skips one atom and
    # keeps going. Raising INSIDE the op is what converts a run-killing assertion into a skipped atom.
    #
    # The 63-byte limit is `>=` in upstream, so 63 bytes is the maximum TOTAL, not 64.
    "collapse_symbol" => function (a)
        buf = a[1]
        _bad = () -> error("collapse_symbol: argument should be an expression")
        isempty(buf) && _bad()
        tag = try
            byte_item(buf[1])
        catch
            _bad()
        end
        tag isa ExprArity || _bad()
        result = UInt8[]
        off = 2
        for _ in 1:Int(tag.arity)
            off <= length(buf) || error("collapse_symbol: truncated expression")
            st = try
                byte_item(buf[off])
            catch
                error("collapse_symbol: can only concat symbols in collapse")
            end
            st isa ExprSymbol || error("collapse_symbol: can only concat symbols in collapse")
            n = Int(st.size)
            length(result) + n >= 64 &&
                error("collapse_symbol: new symbol can not be larger than 63 bytes")
            off + n <= length(buf) || error("collapse_symbol: truncated symbol payload")
            append!(result, buf[(off + 1):(off + n)])
            off += 1 + n
        end
        result
    end,
    # explode_symbol: takes ONE symbol payload, returns MORK arity-N expression.
    # Mirrors explode_symbol in pure.rs. Called by _pure_eval_formula's MORK_EXPR path.
    "explode_symbol" => function (a)
        payload = a[1]
        n = length(payload)
        n == 0 && return UInt8[item_byte(ExprArity(UInt8(0)))]
        result = UInt8[item_byte(ExprArity(UInt8(n)))]
        for b in payload
            push!(result, item_byte(ExprSymbol(UInt8(1))))
            push!(result, b)
        end
        result
    end,
    # tuple: N complete sub-expressions → one MORK arity-N expression, each element SPLICED VERBATIM.
    #
    # Upstream (pure.rs:898-908):
    #     sink.write(SourceItem::Tag(Tag::Arity(items as _)))?;
    #     for i in 0..items {
    #         let f: mork_expr::Expr = expr.consume()?;
    #         sink.extend_from_slice(unsafe { f.span().as_ref().unwrap() })?;
    #     }
    # `f.span()` is the element's WHOLE serialized expression, tag byte included, so a nested
    # expression stays nested.
    #
    # 🔴 THIS PREVIOUSLY RE-TAGGED EVERY ELEMENT AS A SYMBOL — `ExprSymbol(length(payload))` over the
    # STRIPPED payload — which flattened `(tuple (a b) c)` into a symbol whose bytes happened to be
    # `[arity 2][a][b]`. Structure destroyed, and the tag byte lied about what followed. It also threw
    # InexactError for any element over 255 bytes.
    # It is the SAME defect as `hash_expr`, fixed in the same file for the same reason: an op that
    # consumes an EXPR must be handed the unstripped span (see the `arg_raw` comment in
    # Sinks.jl `_pure_eval_formula`). That rule was derived for `hash_expr` and not swept to here.
    #
    # ⚠️ `Tag::Arity` carries only 6 bits (0x00-0x3F). Upstream's `items as _` silently truncates past
    # 63; we raise instead, so the atom is skipped rather than emitted with a lying tag.
    "tuple" => function (a)
        n = length(a)
        n <= 63 || error("tuple: arity $n exceeds the 6-bit Arity tag")
        result = UInt8[item_byte(ExprArity(UInt8(n)))]
        for span in a
            append!(result, span)          # VERBATIM — no re-tagging
        end
        result
    end,

    # ── hash / encode / decode ────────────────────────────────────────
    # Upstream (kernel/src/pure.rs:800-810):
    #     let h = e.hash(); let buf = h.to_le_bytes(); sink.write(SourceItem::Symbol(&buf))?;
    # i.e. ONE symbol of 16 LITTLE-endian bytes of a u128. `Expr::hash()` (expr/src/lib.rs:310) is
    # `gxhash::gxhash128(span, 0)` — but `#[cfg(gxhash)]` is a BARE cfg with no build.rs and no
    # rustflag setting it anywhere in that workspace, so it is OFF and the live function is the stub
    # at expr/src/lib.rs:76 forwarding to `xxhash_rust::const_xxh3::xxh3_128`. Verified by compiling
    # a probe against the crate ("cfg(gxhash) = OFF"). So this is XXH3-128, default secret, seed 0 —
    # NOT gxhash, and no AES-NI is involved. See src/kernel/XXH3.jl (1:1 port of const_xxh3.rs).
    # This previously used Julia's builtin 64-bit `hash`, big-endian, 8 bytes — wrong algorithm,
    # wrong width, wrong byte order — so `hash_expr` emitted a symbol upstream never produces.
    "hash_expr" => (a) -> collect(reinterpret(UInt8, [htol(xxh3_128(a[1]))])),
    "encode_hex" => (a) -> Vector{UInt8}(bytes2hex(a[1])),
    "decode_hex" => (a) -> hex2bytes(String(a[1])),
    # URL-SAFE, UNPADDED — upstream uses `base64::engine::general_purpose::URL_SAFE_NO_PAD` for BOTH
    # directions (pure.rs:781 decode, :794 encode). Julia's `base64encode` is the STANDARD alphabet
    # WITH padding, so we emitted `+/8=` where upstream gives `-_8`, and `YWJjZA==` for `YWJjZA`
    # (fixed 2026-07-26). The op is literally named base64**url**; URL-safe unpadded is its spec.
    "encode_base64url" => (a) -> Vector{UInt8}(_b64url_encode(a[1])),
    "decode_base64url" => (a) -> _b64url_decode(String(a[1])),

    # 🔴 `"ifnz"` USED TO BE A TABLE ENTRY HERE AND IT WAS BOTH DEAD AND WRONG. Dead because
    # `_pure_eval_formula` (Sinks.jl) intercepts `ifnz` before dispatch — it MUST, since the whole
    # point is to NOT evaluate the untaken branch. Wrong because it read the condition as a `u64`
    # (`_read_u64(a[1]) != 0`), which BoundsErrors on a narrower condition, where the live
    # implementation tests `!all(==(0x00), payload)` at any width. A dead duplicate of a
    # control-flow op is the worst kind of dead code: it looks like the specification.
    # `"then"` / `"else"` were also removed — upstream registers NEITHER (only `ifnz` and `tuple`,
    # pure.rs:911-912); they are keyword SYMBOLS in ifnz's shape, validated by `_ifnz_kw`, never ops.

)

# =====================================================================
# Comparison ops — `lt/gt/lte/gte/eq/ne` × {i8,i16,i32,i64,i128,f32,f64}
# =====================================================================
#
# Ported 2026-07-26. These 42 ops were the ONLY gap in the pure-op table (a name-level diff against
# upstream's `op!` macro invocations showed 371 upstream ops, all present except this one family).
# Upstream spells each as `op!(num binary lt_i32(x: i32, y: i32) => (x < y) as i8)` — pure.rs:556-561
# (ints) and :676-681 (floats) — so the result is a 1-BYTE SIGNED int, 0 or 1, NOT the operand width.
#
# Note the family is deliberately signed-and-float only: upstream defines NO unsigned comparisons
# (no `lt_u8` etc.), so neither do we.
#
# Why this matters beyond conformance: MM2's join layer has no ordering at all (`<`/`<=` panic as
# sources), and the documented workaround is that ordering is DERIVABLE in the pure-sink layer via
# these comparisons plus `ifnz`. Without them that derivability story was false for every type —
# `(gte_i32 ...)` simply errored as an unknown op.
for (suffix, rd) in (("i8", _read_i8), ("i16", _read_i16), ("i32", _read_i32),
                     ("i64", _read_i64), ("i128", _read_i128),
                     ("f32", _read_f32), ("f64", _read_f64))
    for (name, cmp) in (("lt", <), ("gt", >), ("lte", <=), ("gte", >=), ("eq", ==), ("ne", !=))
        # `let` binds the loop vars per-iteration so each closure captures its own reader/comparator.
        PURE_OPS["$(name)_$(suffix)"] = let rd = rd, cmp = cmp
            (a) -> Int8(cmp(rd(a[1]), rd(a[2])))
        end
    end
end

# =====================================================================
# NARY / shift / pow / signum / clamp families — GENERATED FROM THE MACRO ARMS
# =====================================================================
#
# 🔴 WHY GENERATED RATHER THAN WRITTEN OUT (2026-07-30). All 52 of these ops were hand-transcribed
# from the EXPANSION of upstream's `op!` macro, and every single family drifted from the arm that
# produced it — because the arm holds the semantics ONCE while a transcription has to re-remember it
# 5-14 times:
#
#   * `min_/max_/sum_/product_` × 7 types (28) were written BINARY, reading `a[1]` and `a[2]`. The
#     `nary` arm folds over ALL items from a constant seed with NO arity check, so args 3+ were
#     SILENTLY IGNORED and 0 args threw: `(max_i32 1 4 9)` gave 4 where upstream gives 9, and
#     `(max_i32)` gave nothing where upstream gives `i32::MIN`.
#   * `min_/max_ f32/f64` additionally propagated NaN where Rust's `f64::max` ignores it.
#   * `u*_shl/shr` (10) dropped `checked_shl`, FABRICATING a 0 where upstream emits nothing.
#   * `pow_i*` (5) used Julia `^`, which throws on the negative exponent upstream casts to `u32`.
#   * `signum_f32/f64` (2) used Julia `sign`, which returns 0 for ±0.0 where Rust tests the sign bit.
#   * `clamp_*` (7) used Julia's total `clamp`, inventing a value for an inverted range.
#
# ⚠️ NONE of this was visible to the per-op differential, which probes every op at ONE input point
# and feeds nary ops exactly TWO arguments (`gen_pure_probes.py`: `FEED` is a single literal per type,
# `feed_types = [types[-1]] * 2`). All 52 were reported AGREEING. The inventory diff also reported
# them present. Two green gates, one uninspected input domain.
#
# These loops ARE the arms, so a type can no longer be fixed in one place and missed in six.

# `nary` families + `clamp`. Seeds are upstream's `$initial` (pure.rs:496-499 i8, :552-555 i32,
# :672-675 f64, :735-738 f32): 0/1 for sum/product, and the fold IDENTITY for min/max — typemin and
# typemax for integers, ∓Inf for floats.
for (suffix, rd, T) in (("i8", _read_i8, Int8), ("i16", _read_i16, Int16),
                        ("i32", _read_i32, Int32), ("i64", _read_i64, Int64),
                        ("i128", _read_i128, Int128),
                        ("f32", _read_f32, Float32), ("f64", _read_f64, Float64))
    isflt = T <: AbstractFloat
    seed_max = isflt ? T(-Inf) : typemin(T)
    seed_min = isflt ? T(Inf)  : typemax(T)
    fmax = isflt ? _rust_fmax : max      # Rust's float max/min IGNORE NaN; the integer ones are plain
    fmin = isflt ? _rust_fmin : min
    PURE_OPS["sum_$(suffix)"]     = let rd = rd, z = zero(T); (a) -> _nary_fold(+, rd, z, a) end
    PURE_OPS["product_$(suffix)"] = let rd = rd, o = one(T);  (a) -> _nary_fold(*, rd, o, a) end
    PURE_OPS["max_$(suffix)"] = let rd = rd, s = seed_max, f = fmax; (a) -> _nary_fold(f, rd, s, a) end
    PURE_OPS["min_$(suffix)"] = let rd = rd, s = seed_min, f = fmin; (a) -> _nary_fold(f, rd, s, a) end
    PURE_OPS["clamp_$(suffix)"] = let rd = rd
        (a) -> _rust_clamp(rd(a[1]), rd(a[2]), rd(a[3]))
    end
end

# `pow_i*` — integers only; upstream defines no float `pow` in this family (`powf_f64` is separate).
for (suffix, rd) in (("i8", _read_i8), ("i16", _read_i16), ("i32", _read_i32),
                     ("i64", _read_i64), ("i128", _read_i128))
    PURE_OPS["pow_$(suffix)"] = let rd = rd
        (a) -> _rust_pow(rd(a[1]), _as_u32(rd(a[2])))
    end
end

# `signum_f32/f64` — sign-bit test. The integer `signum_i*` stay as written: Rust's integer signum
# DOES return 0 for 0, so Julia's `sign` is correct there. Only the float pair diverged.
PURE_OPS["signum_f32"] = (a) -> _rust_signum(_read_f32(a[1]))
PURE_OPS["signum_f64"] = (a) -> _rust_signum(_read_f64(a[1]))

# `u*_shl/shr` — the shift operand is `u32` at every width, and the shift is CHECKED.
for (suffix, rd) in (("u8", _read_u8), ("u16", _read_u16), ("u32", _read_u32),
                     ("u64", _read_u64), ("u128", _read_u128))
    PURE_OPS["$(suffix)_shl"] = let rd = rd
        (a) -> _checked_shl(rd(a[1]), _read_u32s(a[2]))
    end
    PURE_OPS["$(suffix)_shr"] = let rd = rd
        (a) -> _checked_shr(rd(a[1]), _read_u32s(a[2]))
    end
end

# =====================================================================
# The TEN HAND-WRITTEN ops — native `(ExprSource, ExprSink)`, as upstream writes them
# =====================================================================
#
# `pure.rs` is 360 `op!` invocations plus TEN functions written out by hand
# (`:748-908`), every one `pub extern "C" fn NAME(expr: *mut ExprSource, sink: *mut ExprSink)`.
# They are hand-written for a reason: each CONSUMES or PRODUCES an EXPRESSION rather than a scalar
# symbol, which the macro cannot express.
#
# 🔴 WHY THEY CANNOT GO THROUGH `op_skeleton`. That skeleton demands every argument be a
# `SourceSymbol` and always writes its result AS a symbol — right for the 360 numeric ops, wrong
# here. Measured in test/test_eval.jl before this block existed: `collapse_symbol` and `hash_expr`
# threw on an Arity-tagged argument, and `tuple`'s expression result came back flattened into a
# symbol payload. Forcing 370 ops through one skeleton was the mistake; mirroring upstream's own
# 360/10 split is the fix.
#
# These are registered DIRECTLY (not wrapped) by `pure_register!` below. The `PURE_OPS` entries of
# the same names remain for now because `_pure_eval_formula` (Sinks.jl) is still the live evaluator;
# they retire with that migration.

"upstream `reverse_symbol` (pure.rs:812-823) — one SYMBOL in, its bytes reversed out."
function _nat_reverse_symbol(src::ExprSource, snk::ExprSink)
    items = source_consume_head_check!(src, "reverse_symbol")
    items == 1 || throw(EvalError("only takes one argument"))
    sym = source_read!(src)
    sym isa SourceSymbol || throw(EvalError("only reverses symbols"))
    sink_write!(snk, SourceSymbol(reverse((sym::SourceSymbol).bytes)))
    nothing
end

"upstream `collapse_symbol` (pure.rs:825-843) — an EXPRESSION of symbols concatenated into one."
function _nat_collapse_symbol(src::ExprSource, snk::ExprSink)
    items = source_consume_head_check!(src, "collapse_symbol")
    items == 1 || throw(EvalError("only takes one argument (an expression of symbols)"))
    head = source_read!(src)
    (head isa SourceTag && (head::SourceTag).tag isa ExprArity) ||
        throw(EvalError("argument should be an expression"))
    a = Int(((head::SourceTag).tag::ExprArity).arity)
    out = UInt8[]
    for _ in 1:a
        it = source_read!(src)
        it isa SourceSymbol || throw(EvalError("can only concat symbols in collapse"))
        b = (it::SourceSymbol).bytes
        # upstream `if i + symbol.len() >= 64 { Err }` — 63 bytes is the maximum TOTAL, not 64.
        length(out) + length(b) >= 64 &&
            throw(EvalError("new symbol can not be larger than 63 bytes"))
        append!(out, b)
    end
    sink_write!(snk, SourceSymbol(out))
    nothing
end

"upstream `explode_symbol` (pure.rs:845-856) — one SYMBOL out to an expression of 1-byte symbols."
function _nat_explode_symbol(src::ExprSource, snk::ExprSink)
    items = source_consume_head_check!(src, "explode_symbol")
    items == 1 || throw(EvalError("only takes one argument (a symbol)"))
    sym = source_read!(src)
    sym isa SourceSymbol || throw(EvalError("arguments needs to be a symbol"))
    b = (sym::SourceSymbol).bytes
    sink_write!(snk, SourceTag(ExprArity(UInt8(length(b)))))
    for x in b
        sink_write!(snk, SourceSymbol(UInt8[x]))
    end
    nothing
end

"upstream `hash_expr` (pure.rs:800-810) — consumes an EXPR; 16 LITTLE-endian bytes of xxh3_128."
function _nat_hash_expr(src::ExprSource, snk::ExprSink)
    items = source_consume_head_check!(src, "hash_expr")
    items == 1 || throw(EvalError("only takes one argument"))
    span = source_consume_expr!(src)          # the WHOLE span, tag byte included — not a payload
    sink_write!(snk, SourceSymbol(collect(reinterpret(UInt8, [htol(xxh3_128(span))]))))
    nothing
end

"upstream `encode_hex` (pure.rs:748-759). ⚠️ upstream ABORTS above 32 bytes; we do not — see below."
function _nat_encode_hex(src::ExprSource, snk::ExprSink)
    items = source_consume_head_check!(src, "encode_hex")
    items == 1 || throw(EvalError("only takes one argument"))
    sym = source_read!(src)
    sym isa SourceSymbol || throw(EvalError("only parses symbols"))
    # ⚠️ DELIBERATE DEVIATION. Upstream writes into a `[0u8; 64]` at `buf[..2*len]`, so a 32-byte
    # input emits a Rule-of-64-violating 64-byte symbol and a 33-byte input PANICS — a non-unwinding
    # ABORT that kills the process and writes no output at all. We never abort mid-saturation, so the
    # oversized case raises here and the atom is skipped (sink_write! enforces the 63-byte limit).
    sink_write!(snk, SourceSymbol(Vector{UInt8}(bytes2hex((sym::SourceSymbol).bytes))))
    nothing
end

"upstream `decode_hex` (pure.rs:761-772)."
function _nat_decode_hex(src::ExprSource, snk::ExprSink)
    items = source_consume_head_check!(src, "decode_hex")
    items == 1 || throw(EvalError("only takes one argument"))
    sym = source_read!(src)
    sym isa SourceSymbol || throw(EvalError("only parses symbols"))
    out = try
        hex2bytes(String(copy((sym::SourceSymbol).bytes)))
    catch
        throw(EvalError("string not a valid type in decode_hex"))
    end
    sink_write!(snk, SourceSymbol(out))
    nothing
end

"upstream `encode_base64url` (pure.rs:787-798) — URL_SAFE_NO_PAD."
function _nat_encode_base64url(src::ExprSource, snk::ExprSink)
    items = source_consume_head_check!(src, "encode_base64url")
    items == 1 || throw(EvalError("only takes one argument"))
    sym = source_read!(src)
    sym isa SourceSymbol || throw(EvalError("only parses symbols"))
    sink_write!(snk, SourceSymbol(Vector{UInt8}(_b64url_encode((sym::SourceSymbol).bytes))))
    nothing
end

"upstream `decode_base64url` (pure.rs:774-785) — URL_SAFE_NO_PAD."
function _nat_decode_base64url(src::ExprSource, snk::ExprSink)
    items = source_consume_head_check!(src, "decode_base64url")
    items == 1 || throw(EvalError("only takes one argument"))
    sym = source_read!(src)
    sym isa SourceSymbol || throw(EvalError("only parses symbols"))
    out = try
        _b64url_decode(String(copy((sym::SourceSymbol).bytes)))
    catch
        throw(EvalError("string not a valid type in decode_base64url"))
    end
    sink_write!(snk, SourceSymbol(out))
    nothing
end

"""
upstream `tuple` (pure.rs:898-908) — `Arity(items)` then each element's WHOLE span spliced verbatim,
so nesting survives. NO arity check: upstream declares none.
"""
function _nat_tuple(src::ExprSource, snk::ExprSink)
    items = source_consume_head_check!(src, "tuple")
    # `Tag::Arity` carries 6 bits; upstream's `items as _` silently truncates past 63, we refuse.
    items <= 63 || throw(EvalError("tuple: arity $items exceeds the 6-bit Arity tag"))
    sink_write!(snk, SourceTag(ExprArity(UInt8(items))))
    for _ in 1:items
        sink_extend!(snk, source_consume_expr!(src))
    end
    nothing
end

"""
upstream `ifnz` (pure.rs:874-896) — `(ifnz <symbol> then <expr> [else <expr>])`.

By the time this runs the stack machine has ALREADY EVALUATED both branches into this frame's sink,
which is what makes `ifnz` eager; it only SELECTS. The condition is false only when every byte of the
condition symbol is zero.
"""
function _nat_ifnz(src::ExprSource, snk::ExprSink)
    items = source_consume_head_check!(src, "ifnz")
    (items == 3 || items == 5) || throw(EvalError(
        "shaped either (ifnz <symbol> then <nonzero expr>) or (ifnz <symbol> then <nonzero expr> else <zero expr>)"))
    cond = source_read!(src)
    cond isa SourceSymbol || throw(EvalError("condition needs to be a symbol"))
    is_nz = !all(==(0x00), (cond::SourceSymbol).bytes)

    kw = source_read!(src)
    (kw isa SourceSymbol && String(copy((kw::SourceSymbol).bytes)) == "then") ||
        throw(EvalError("expected then symbol"))
    then_span = source_consume_expr!(src)

    if is_nz
        sink_extend!(snk, then_span)
        return nothing
    end
    items == 5 || throw(EvalError("ifnz no else branch"))
    kw2 = source_read!(src)
    (kw2 isa SourceSymbol && String(copy((kw2::SourceSymbol).bytes)) == "else") ||
        throw(EvalError("expected else symbol"))
    sink_extend!(snk, source_consume_expr!(src))
    nothing
end

"The ten, by upstream name. Registered DIRECTLY — never through `op_skeleton`."
const PURE_NATIVE_OPS = Dict{String, Function}(
    "encode_hex" => _nat_encode_hex,
    "decode_hex" => _nat_decode_hex,
    "encode_base64url" => _nat_encode_base64url,
    "decode_base64url" => _nat_decode_base64url,
    "hash_expr" => _nat_hash_expr,
    "reverse_symbol" => _nat_reverse_symbol,
    "collapse_symbol" => _nat_collapse_symbol,
    "explode_symbol" => _nat_explode_symbol,
    "ifnz" => _nat_ifnz,
    "tuple" => _nat_tuple,
)

# =====================================================================
# `pub fn register(scope: &mut EvalScope)` — pure.rs:910-1300
# =====================================================================
#
# THE LAST THING IN THIS FILE, exactly as it is the last thing in pure.rs.
#
# 🔴 IT USED TO LIVE IN Eval.jl (then named EvalScope.jl), AND THAT WAS WRONG (user-identified, 2026-07-30). The
# justification on record was "it mutates an `EvalScope`, which upstream keeps in another crate" —
# but upstream's `register` mutates that other crate's type from INSIDE pure.rs. What decides a
# function's home is the file that DEFINES it, not the type it touches. Having it elsewhere also
# forced the include order backwards: `pure.rs:6` is `use eval::{EvalScope, FuncType}`, so pure.rs
# DEPENDS ON eval and eval is built first — MORK.jl now includes EvalFfi.jl + Eval.jl before Pure.jl, which
# is both upstream's dependency direction and what lets this function sit here.
#
# Source order, upstream's own name list, and `FuncPure` for every one: all **370** registrations are
# `FuncType::Pure` — NONE are Macro. `ifnz` included, even though it controls its own argument
# evaluation; upstream classifies it Pure and so do we.
#
# ⚠️ 370, NOT 371. `pure.rs` holds 371 `scope.add_func` lines, but one is the commented-out generator
# template `// scope.add_func("$1", $1, FuncType::Pure);` (:927) — the same artifact `rust_symbols`
# in tools/port_inventory.jl deletes, for the same reason, and the one that once yielded a bogus
# `"$1"` op (a hard ParseError in Julia). Verified LIVE rather than read off the source: 370 in
# `PURE_REGISTER`, 370 live, 0 unregistered, 0 missing an implementation, 370 FuncPure / 0 FuncMacro,
# 325 carrying an arity check.
function pure_register!()
    for name in PURE_REGISTER
        arity = get(PURE_OP_ARITY, name, nothing)
        native = get(PURE_NATIVE_OPS, name, nothing)
        body = get(PURE_OPS, name, nothing)
        if native !== nothing
            # The TEN hand-written ops. Registered AS-IS: they already have upstream's
            # `(ExprSource, ExprSink)` signature and do their own arity checks, exactly as the
            # `extern "C" fn`s in pure.rs do. Wrapping them in `op_skeleton` would force their
            # EXPRESSION arguments and results through a symbol-only path and corrupt them.
            add_func!(PURE_SCOPE, name, native, FuncPure, arity)
        elseif body !== nothing
            add_func!(PURE_SCOPE, name, op_skeleton(name, body, arity), FuncPure, arity)
        elseif name in PURE_SPECIAL_FORMS
            # Implemented in the EVALUATOR, not the table — `_pure_eval_formula` intercepts it before
            # dispatch. Registered so the name resolves and the classification is truthful; the body
            # is a sentinel that names the real site rather than silently doing the wrong thing.
            add_func!(PURE_SCOPE, name,
                      (::ExprSource, ::ExprSink) -> throw(EvalError(
                          "$name is a special form; _pure_eval_formula handles it before dispatch")),
                      FuncPure, arity)
        else
            push!(PURE_SCOPE_UNREGISTERED, name)
        end
    end
    # ── ops we carry beyond upstream's list ──
    upstream = Set(PURE_REGISTER)
    for (name, body) in PURE_OPS
        name in upstream && continue
        push!(PURE_SCOPE_EXTRA, name)
        add_func!(PURE_SCOPE, name, op_skeleton(name, body, get(PURE_OP_ARITY, name, nothing)),
                  FuncPure, get(PURE_OP_ARITY, name, nothing))
    end
    sort!(PURE_SCOPE_UNREGISTERED); sort!(PURE_SCOPE_EXTRA)
    nothing
end
pure_register!()

# =====================================================================
# Exports
# =====================================================================

export PURE_OPS, pure_apply, pure_apply_native
