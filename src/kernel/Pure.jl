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
_read_f64(b) = ntoh(only(reinterpret(Float64, b[1:8])))
_read_u32s(b) = _read_u32(b)   # shift amount is u32 (4 bytes): upstream shl/shr all take `y: u32`
                               # (pure.rs, e.g. u8_shr(x: u8, y: u32)). Was _read_u64 (8 bytes), which
                               # BoundsError'd on the 4-byte shift ip_sudoku passes (sub_i32 → i32).

# General 3-input bitwise LUT (x86 vpternlog) — the result bit for each bit position
# is bit ((x<<2)|(y<<1)|z) of the selector `s`. Computed via the 8 minterms, which is
# equivalent to (and replaces) the upstream 256-case `match s` table
# (main:kernel/src/pure.rs `ternary_table`), verified against s = 0,1,2,4,6.
# (The *_ternarylogic ops previously ignored x, y, AND the selector — they just
# rebuilt z — audit P-2.)
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
# pure_apply — main entry point
# =====================================================================

"""
    pure_apply(name, arg_bufs) → Vector{UInt8}

Apply numeric primitive `name` to big-endian byte argument vectors.
Returns the big-endian byte result, throws on unknown name.
"""
function pure_apply(name::String, arg_bufs::Vector{Vector{UInt8}})::Vector{UInt8}
    f = get(PURE_OPS, name, nothing)
    f === nothing && error("Unknown pure op: $name")
    _be_bytes(f(arg_bufs))
end

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
    "u8_shl" => (a) -> _read_u8(a[1]) << _read_u32s(a[2]),
    "u8_shr" => (a) -> _read_u8(a[1]) >> _read_u32s(a[2]),
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
    "u16_shl" => (a) -> _read_u16(a[1]) << _read_u32s(a[2]),
    "u16_shr" => (a) -> _read_u16(a[1]) >> _read_u32s(a[2]),
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
    "u32_shl" => (a) -> _read_u32(a[1]) << _read_u32s(a[2]),
    "u32_shr" => (a) -> _read_u32(a[1]) >> _read_u32s(a[2]),
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
    "u64_shl" => (a) -> _read_u64(a[1]) << _read_u32s(a[2]),
    "u64_shr" => (a) -> _read_u64(a[1]) >> _read_u32s(a[2]),
    "u64_and" => (a) -> reduce(&, [_read_u64(x) for x in a]; init=(~UInt64(0))),
    "u64_or" => (a) -> reduce(|, [_read_u64(x) for x in a]; init=UInt64(0)),
    "u64_parity" => (a) -> reduce(xor, [_read_u64(x) for x in a]; init=UInt64(0)),

    # ── i8 ──────────────────────────────────────────────────────────
    "i8_zeros" => (a) -> Int8(0),
    "i8_ones" => (a) -> Int8(-1),
    "i8_not" => (a) -> ~_read_i8(a[1]),
    "i8_neg" => (a) -> -_read_i8(a[1]),
    "i8_abs" => (a) -> abs(_read_i8(a[1])),
    "i8_signum" => (a) -> Int8(sign(_read_i8(a[1]))),
    "i8_add" => (a) -> reduce(+, [_read_i8(x) for x in a]; init=Int8(0)),
    "i8_mul" => (a) -> reduce(*, [_read_i8(x) for x in a]; init=Int8(1)),
    "i8_sub" => (a) -> _read_i8(a[1]) - _read_i8(a[2]),
    "i8_div" => (a) -> div(_read_i8(a[1]), _read_i8(a[2])),
    "i8_rem" => (a) -> rem(_read_i8(a[1]), _read_i8(a[2])),
    "i8_min" => (a) -> min(_read_i8(a[1]), _read_i8(a[2])),
    "i8_max" => (a) -> max(_read_i8(a[1]), _read_i8(a[2])),

    # ── i16 ─────────────────────────────────────────────────────────
    "i16_zeros" => (a) -> Int16(0),
    "i16_ones" => (a) -> Int16(-1),
    "i16_not" => (a) -> ~_read_i16(a[1]),
    "i16_neg" => (a) -> -_read_i16(a[1]),
    "i16_abs" => (a) -> abs(_read_i16(a[1])),
    "i16_signum" => (a) -> Int16(sign(_read_i16(a[1]))),
    "i16_add" => (a) -> reduce(+, [_read_i16(x) for x in a]; init=Int16(0)),
    "i16_mul" => (a) -> reduce(*, [_read_i16(x) for x in a]; init=Int16(1)),
    "i16_sub" => (a) -> _read_i16(a[1]) - _read_i16(a[2]),
    "i16_div" => (a) -> div(_read_i16(a[1]), _read_i16(a[2])),
    "i16_rem" => (a) -> rem(_read_i16(a[1]), _read_i16(a[2])),
    "i16_min" => (a) -> min(_read_i16(a[1]), _read_i16(a[2])),
    "i16_max" => (a) -> max(_read_i16(a[1]), _read_i16(a[2])),

    # ── i32 ─────────────────────────────────────────────────────────
    "i32_zeros" => (a) -> Int32(0),
    "i32_ones" => (a) -> Int32(-1),
    "i32_not" => (a) -> ~_read_i32(a[1]),
    "i32_neg" => (a) -> -_read_i32(a[1]),
    "i32_abs" => (a) -> abs(_read_i32(a[1])),
    "i32_signum" => (a) -> Int32(sign(_read_i32(a[1]))),
    "i32_add" => (a) -> reduce(+, [_read_i32(x) for x in a]; init=Int32(0)),
    "i32_mul" => (a) -> reduce(*, [_read_i32(x) for x in a]; init=Int32(1)),
    "i32_sub" => (a) -> _read_i32(a[1]) - _read_i32(a[2]),
    "i32_div" => (a) -> div(_read_i32(a[1]), _read_i32(a[2])),
    "i32_rem" => (a) -> rem(_read_i32(a[1]), _read_i32(a[2])),
    "i32_min" => (a) -> min(_read_i32(a[1]), _read_i32(a[2])),
    "i32_max" => (a) -> max(_read_i32(a[1]), _read_i32(a[2])),

    # ── i64 ─────────────────────────────────────────────────────────
    "i64_zeros" => (a) -> Int64(0),
    "i64_ones" => (a) -> Int64(-1),
    "i64_not" => (a) -> ~_read_i64(a[1]),
    "i64_neg" => (a) -> -_read_i64(a[1]),
    "i64_abs" => (a) -> abs(_read_i64(a[1])),
    "i64_signum" => (a) -> Int64(sign(_read_i64(a[1]))),
    "i64_add" => (a) -> reduce(+, [_read_i64(x) for x in a]; init=Int64(0)),
    "i64_mul" => (a) -> reduce(*, [_read_i64(x) for x in a]; init=Int64(1)),
    "i64_sub" => (a) -> _read_i64(a[1]) - _read_i64(a[2]),
    "i64_div" => (a) -> div(_read_i64(a[1]), _read_i64(a[2])),
    "i64_rem" => (a) -> rem(_read_i64(a[1]), _read_i64(a[2])),
    "i64_min" => (a) -> min(_read_i64(a[1]), _read_i64(a[2])),
    "i64_max" => (a) -> max(_read_i64(a[1]), _read_i64(a[2])),

    # ── f32 ─────────────────────────────────────────────────────────
    "f32_zeros" => (a) -> Float32(0),
    "f32_ones" => (a) -> Float32(1),
    "f32_nan" => (a) -> Float32(NaN),
    "f32_inf" => (a) -> Float32(Inf),
    "f32_neg_inf" => (a) -> Float32(-Inf),
    "f32_neg" => (a) -> -_read_f32(a[1]),
    "f32_abs" => (a) -> abs(_read_f32(a[1])),
    "f32_sqrt" => (a) -> sqrt(_read_f32(a[1])),
    "f32_cbrt" => (a) -> cbrt(_read_f32(a[1])),
    "f32_ceil" => (a) -> ceil(_read_f32(a[1])),
    "f32_floor" => (a) -> floor(_read_f32(a[1])),
    "f32_round" => (a) -> round(_read_f32(a[1])),
    "f32_trunc" => (a) -> trunc(_read_f32(a[1])),
    "f32_fract" => (a) -> _read_f32(a[1]) - trunc(_read_f32(a[1])),
    "f32_exp" => (a) -> exp(_read_f32(a[1])),
    "f32_exp2" => (a) -> exp2(_read_f32(a[1])),
    "f32_ln" => (a) -> log(_read_f32(a[1])),
    "f32_log2" => (a) -> log2(_read_f32(a[1])),
    "f32_log10" => (a) -> log10(_read_f32(a[1])),
    "f32_sin" => (a) -> sin(_read_f32(a[1])),
    "f32_cos" => (a) -> cos(_read_f32(a[1])),
    "f32_tan" => (a) -> tan(_read_f32(a[1])),
    "f32_asin" => (a) -> asin(_read_f32(a[1])),
    "f32_acos" => (a) -> acos(_read_f32(a[1])),
    "f32_atan" => (a) -> atan(_read_f32(a[1])),
    "f32_add" => (a) -> reduce(+, [_read_f32(x) for x in a]; init=Float32(0)),
    "f32_mul" => (a) -> reduce(*, [_read_f32(x) for x in a]; init=Float32(1)),
    "f32_sub" => (a) -> _read_f32(a[1]) - _read_f32(a[2]),
    "f32_div" => (a) -> _read_f32(a[1]) / _read_f32(a[2]),
    "f32_rem" => (a) -> rem(_read_f32(a[1]), _read_f32(a[2])),
    "f32_pow" => (a) -> _read_f32(a[1])^_read_f32(a[2]),
    "f32_min" => (a) -> min(_read_f32(a[1]), _read_f32(a[2])),
    "f32_max" => (a) -> max(_read_f32(a[1]), _read_f32(a[2])),
    "f32_atan2" => (a) -> atan(_read_f32(a[1]), _read_f32(a[2])),
    "f32_hypot" => (a) -> hypot(_read_f32(a[1]), _read_f32(a[2])),
    "f32_fma" => (a) -> muladd(_read_f32(a[1]), _read_f32(a[2]), _read_f32(a[3])),

    # ── f64 ─────────────────────────────────────────────────────────
    "f64_zeros" => (a) -> Float64(0),
    "f64_ones" => (a) -> Float64(1),
    "f64_nan" => (a) -> Float64(NaN),
    "f64_inf" => (a) -> Float64(Inf),
    "f64_neg_inf" => (a) -> Float64(-Inf),
    "f64_neg" => (a) -> -_read_f64(a[1]),
    "f64_abs" => (a) -> abs(_read_f64(a[1])),
    "f64_sqrt" => (a) -> sqrt(_read_f64(a[1])),
    "f64_cbrt" => (a) -> cbrt(_read_f64(a[1])),
    "f64_ceil" => (a) -> ceil(_read_f64(a[1])),
    "f64_floor" => (a) -> floor(_read_f64(a[1])),
    "f64_round" => (a) -> round(_read_f64(a[1])),
    "f64_trunc" => (a) -> trunc(_read_f64(a[1])),
    "f64_fract" => (a) -> _read_f64(a[1]) - trunc(_read_f64(a[1])),
    "f64_exp" => (a) -> exp(_read_f64(a[1])),
    "f64_exp2" => (a) -> exp2(_read_f64(a[1])),
    "f64_ln" => (a) -> log(_read_f64(a[1])),
    "f64_log2" => (a) -> log2(_read_f64(a[1])),
    "f64_log10" => (a) -> log10(_read_f64(a[1])),
    "f64_sin" => (a) -> sin(_read_f64(a[1])),
    "f64_cos" => (a) -> cos(_read_f64(a[1])),
    "f64_tan" => (a) -> tan(_read_f64(a[1])),
    "f64_asin" => (a) -> asin(_read_f64(a[1])),
    "f64_acos" => (a) -> acos(_read_f64(a[1])),
    "f64_atan" => (a) -> atan(_read_f64(a[1])),
    "f64_add" => (a) -> reduce(+, [_read_f64(x) for x in a]; init=Float64(0)),
    "f64_mul" => (a) -> reduce(*, [_read_f64(x) for x in a]; init=Float64(1)),
    "f64_sub" => (a) -> _read_f64(a[1]) - _read_f64(a[2]),
    "f64_div" => (a) -> _read_f64(a[1]) / _read_f64(a[2]),
    "f64_rem" => (a) -> rem(_read_f64(a[1]), _read_f64(a[2])),
    "f64_pow" => (a) -> _read_f64(a[1])^_read_f64(a[2]),
    "f64_min" => (a) -> min(_read_f64(a[1]), _read_f64(a[2])),
    "f64_max" => (a) -> max(_read_f64(a[1]), _read_f64(a[2])),
    "f64_atan2" => (a) -> atan(_read_f64(a[1]), _read_f64(a[2])),
    "f64_hypot" => (a) -> hypot(_read_f64(a[1]), _read_f64(a[2])),
    "f64_fma" => (a) -> muladd(_read_f64(a[1]), _read_f64(a[2]), _read_f64(a[3])),

    # ── type conversions ─────────────────────────────────────────────
    "u8_to_u16" => (a) -> UInt16(_read_u8(a[1])),
    "u8_to_u32" => (a) -> UInt32(_read_u8(a[1])),
    "u8_to_u64" => (a) -> UInt64(_read_u8(a[1])),
    "u8_to_i8" => (a) -> reinterpret(Int8, _read_u8(a[1])),
    "u8_to_f32" => (a) -> Float32(_read_u8(a[1])),
    "u8_to_f64" => (a) -> Float64(_read_u8(a[1])),
    "u16_to_u8" => (a) -> UInt8(_read_u16(a[1]) & 0xFF),
    "u16_to_u32" => (a) -> UInt32(_read_u16(a[1])),
    "u16_to_u64" => (a) -> UInt64(_read_u16(a[1])),
    "u16_to_i16" => (a) -> reinterpret(Int16, _read_u16(a[1])),
    "u16_to_f32" => (a) -> Float32(_read_u16(a[1])),
    "u16_to_f64" => (a) -> Float64(_read_u16(a[1])),
    "u32_to_u8" => (a) -> UInt8(_read_u32(a[1]) & 0xFF),
    "u32_to_u16" => (a) -> UInt16(_read_u32(a[1]) & 0xFFFF),
    "u32_to_u64" => (a) -> UInt64(_read_u32(a[1])),
    "u32_to_i32" => (a) -> reinterpret(Int32, _read_u32(a[1])),
    "u32_to_f32" => (a) -> reinterpret(Float32, _read_u32(a[1])),
    "u32_to_f64" => (a) -> Float64(_read_u32(a[1])),
    "u64_to_u32" => (a) -> UInt32(_read_u64(a[1]) & 0xFFFFFFFF),
    "u64_to_i64" => (a) -> reinterpret(Int64, _read_u64(a[1])),
    "u64_to_f64" => (a) -> Float64(_read_u64(a[1])),
    "i64_to_u64" => (a) -> reinterpret(UInt64, _read_i64(a[1])),
    "i64_to_f64" => (a) -> Float64(_read_i64(a[1])),
    "f32_to_f64" => (a) -> Float64(_read_f32(a[1])),
    "f64_to_f32" => (a) -> Float32(_read_f64(a[1])),
    "f64_to_i64" => (a) -> Int64(_read_f64(a[1])),
    "f64_to_u64" => (a) -> UInt64(_read_f64(a[1])),

    # ── string conversions ────────────────────────────────────────────
    "u8_from_string" => (a) -> parse(UInt8, String(a[1])),
    "u16_from_string" => (a) -> parse(UInt16, String(a[1])),
    "u32_from_string" => (a) -> parse(UInt32, String(a[1])),
    "u64_from_string" => (a) -> parse(UInt64, String(a[1])),
    "i8_from_string" => (a) -> parse(Int8, String(a[1])),
    "i16_from_string" => (a) -> parse(Int16, String(a[1])),
    "i32_from_string" => (a) -> parse(Int32, String(a[1])),
    "i64_from_string" => (a) -> parse(Int64, String(a[1])),
    "f32_from_string" => (a) -> parse(Float32, String(a[1])),
    "f64_from_string" => (a) -> parse(Float64, String(a[1])),
    "u8_to_string" => (a) -> Vector{UInt8}(string(_read_u8(a[1]))),
    "u16_to_string" => (a) -> Vector{UInt8}(string(_read_u16(a[1]))),
    "u32_to_string" => (a) -> Vector{UInt8}(string(_read_u32(a[1]))),
    "u64_to_string" => (a) -> Vector{UInt8}(string(_read_u64(a[1]))),
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
    "pow_i8" => (a) -> _read_i8(a[1]) ^ Int(_read_i8(a[2])),
    "pow_i16" => (a) -> _read_i16(a[1]) ^ Int(_read_i16(a[2])),
    "pow_i32" => (a) -> _read_i32(a[1]) ^ Int(_read_i32(a[2])),
    "pow_i64" => (a) -> _read_i64(a[1]) ^ Int(_read_i64(a[2])),
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
    "min_i8" => (a) -> min(_read_i8(a[1]), _read_i8(a[2])),
    "min_i16" => (a) -> min(_read_i16(a[1]), _read_i16(a[2])),
    "min_i32" => (a) -> min(_read_i32(a[1]), _read_i32(a[2])),
    "min_i64" => (a) -> min(_read_i64(a[1]), _read_i64(a[2])),
    "max_i8" => (a) -> max(_read_i8(a[1]), _read_i8(a[2])),
    "max_i16" => (a) -> max(_read_i16(a[1]), _read_i16(a[2])),
    "max_i32" => (a) -> max(_read_i32(a[1]), _read_i32(a[2])),
    "max_i64" => (a) -> max(_read_i64(a[1]), _read_i64(a[2])),
    "clamp_i8" => (a) -> clamp(_read_i8(a[1]), _read_i8(a[2]), _read_i8(a[3])),
    "clamp_i16" => (a) -> clamp(_read_i16(a[1]), _read_i16(a[2]), _read_i16(a[3])),
    "clamp_i32" => (a) -> clamp(_read_i32(a[1]), _read_i32(a[2]), _read_i32(a[3])),
    "clamp_i64" => (a) -> clamp(_read_i64(a[1]), _read_i64(a[2]), _read_i64(a[3])),
    "sum_i8" => (a) -> reduce((x, y) -> x + _read_i8(y), a[2:end]; init=_read_i8(a[1])),
    "sum_i16" => (a) -> reduce((x, y) -> x + _read_i16(y), a[2:end]; init=_read_i16(a[1])),
    "sum_i32" => (a) -> reduce((x, y) -> x + _read_i32(y), a[2:end]; init=_read_i32(a[1])),
    "sum_i64" => (a) -> reduce((x, y) -> x + _read_i64(y), a[2:end]; init=_read_i64(a[1])),
    "product_i8" => (a) -> reduce((x, y) -> x * _read_i8(y), a[2:end]; init=_read_i8(a[1])),
    "product_i16" =>
        (a) -> reduce((x, y) -> x * _read_i16(y), a[2:end]; init=_read_i16(a[1])),
    "product_i32" =>
        (a) -> reduce((x, y) -> x * _read_i32(y), a[2:end]; init=_read_i32(a[1])),
    "product_i64" =>
        (a) -> reduce((x, y) -> x * _read_i64(y), a[2:end]; init=_read_i64(a[1])),
    "i8_one" => (_) -> Int8(1),
    "i16_one" => (_) -> Int16(1),
    "i32_one" => (_) -> Int32(1),
    "i64_one" => (_) -> Int64(1),

    # ── i128 (native Int128 — were truncating to Int64 via _read_i64, audit P-1) ──
    "abs_i128" => (a) -> abs(_read_i128(a[1])),
    "neg_i128" => (a) -> -_read_i128(a[1]),
    "signum_i128" => (a) -> Int128(sign(_read_i128(a[1]))),
    "min_i128" => (a) -> min(_read_i128(a[1]), _read_i128(a[2])),
    "max_i128" => (a) -> max(_read_i128(a[1]), _read_i128(a[2])),
    "clamp_i128" => (a) -> clamp(_read_i128(a[1]), _read_i128(a[2]), _read_i128(a[3])),
    "sum_i128" =>
        (a) -> reduce((x, y) -> x + _read_i128(y), a[2:end]; init=_read_i128(a[1])),
    "product_i128" =>
        (a) -> reduce((x, y) -> x * _read_i128(y), a[2:end]; init=_read_i128(a[1])),
    # D-P1 fix (audit 2026-06-04): these read via _read_i64 / returned Int64/Int8 — only
    # the low 8 of the 16 i128 bytes, silently wrong for |x| ≥ 2^63. Now _read_i128 (full
    # 16 BE bytes) and return Int128 so _be_bytes(::Int128) emits 16 bytes. (abs/neg/min/
    # max/clamp/sum/product above were already _read_i128 — this completes the family.)
    "mod_i128" => (a) -> rem(_read_i128(a[1]), _read_i128(a[2])),
    "pow_i128" => (a) -> _read_i128(a[1])^Int(_read_i128(a[2])),
    "i128_one" => (_) -> Int128(1),
    "i128_from_string" => (a) -> parse(Int128, String(a[1])),
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
    "f32_as_i8" => (a) -> Int8(_read_f32(a[1])),
    "f32_as_i16" => (a) -> Int16(_read_f32(a[1])),
    "f32_as_i32" => (a) -> Int32(_read_f32(a[1])),
    "f32_as_i64" => (a) -> Int64(_read_f32(a[1])),
    "f32_as_i128" => (a) -> Int128(_read_f32(a[1])),
    "f32_as_f64" => (a) -> Float64(_read_f32(a[1])),
    "f64_as_i8" => (a) -> Int8(_read_f64(a[1])),
    "f64_as_i16" => (a) -> Int16(_read_f64(a[1])),
    "f64_as_i32" => (a) -> Int32(_read_f64(a[1])),
    "f64_as_i64" => (a) -> Int64(_read_f64(a[1])),
    "f64_as_i128" => (a) -> Int128(_read_f64(a[1])),
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
    "signum_f32" => (a) -> Float32(sign(_read_f32(a[1]))),
    "signum_f64" => (a) -> Float64(sign(_read_f64(a[1]))),
    "min_f32" => (a) -> min(_read_f32(a[1]), _read_f32(a[2])),
    "min_f64" => (a) -> min(_read_f64(a[1]), _read_f64(a[2])),
    "max_f32" => (a) -> max(_read_f32(a[1]), _read_f32(a[2])),
    "max_f64" => (a) -> max(_read_f64(a[1]), _read_f64(a[2])),
    "clamp_f32" => (a) -> clamp(_read_f32(a[1]), _read_f32(a[2]), _read_f32(a[3])),
    "clamp_f64" => (a) -> clamp(_read_f64(a[1]), _read_f64(a[2]), _read_f64(a[3])),
    "sum_f32" => (a) -> reduce((x, y) -> x + _read_f32(y), a[2:end]; init=_read_f32(a[1])),
    "sum_f64" => (a) -> reduce((x, y) -> x + _read_f64(y), a[2:end]; init=_read_f64(a[1])),
    "product_f32" =>
        (a) -> reduce((x, y) -> x * _read_f32(y), a[2:end]; init=_read_f32(a[1])),
    "product_f64" =>
        (a) -> reduce((x, y) -> x * _read_f64(y), a[2:end]; init=_read_f64(a[1])),
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
    "round_f32" => (a) -> round(Float32, _read_f32(a[1])),
    "round_f64" => (a) -> round(Float64, _read_f64(a[1])),
    "copysign_f32" => (a) -> copysign(_read_f32(a[1]), _read_f32(a[2])),
    "copysign_f64" => (a) -> copysign(_read_f64(a[1]), _read_f64(a[2])),
    "powf_f32" => (a) -> _read_f32(a[1]) ^ _read_f32(a[2]),
    "powf_f64" => (a) -> _read_f64(a[1]) ^ _read_f64(a[2]),
    "powi_f32" => (a) -> _read_f32(a[1]) ^ Int32(_read_i32(a[2])),
    "powi_f64" => (a) -> _read_f64(a[1]) ^ Int32(_read_i32(a[2])),
    "hypot_f32" => (a) -> hypot(_read_f32(a[1]), _read_f32(a[2])),
    "hypot_f64" => (a) -> hypot(_read_f64(a[1]), _read_f64(a[2])),
    "sqrt_f32" => (a) -> sqrt(_read_f32(a[1])),
    "sqrt_f64" => (a) -> sqrt(_read_f64(a[1])),
    "cbrt_f32" => (a) -> cbrt(_read_f32(a[1])),
    "cbrt_f64" => (a) -> cbrt(_read_f64(a[1])),
    "exp_f32" => (a) -> exp(_read_f32(a[1])),
    "exp_f64" => (a) -> exp(_read_f64(a[1])),
    "exp2_f32" => (a) -> exp2(_read_f32(a[1])),
    "exp2_f64" => (a) -> exp2(_read_f64(a[1])),
    "ln_f32" => (a) -> log(_read_f32(a[1])),
    "ln_f64" => (a) -> log(_read_f64(a[1])),
    "log2_f32" => (a) -> log2(_read_f32(a[1])),
    "log2_f64" => (a) -> log2(_read_f64(a[1])),
    "log10_f32" => (a) -> log10(_read_f32(a[1])),
    "log10_f64" => (a) -> log10(_read_f64(a[1])),
    "sin_f32" => (a) -> sin(_read_f32(a[1])),
    "sin_f64" => (a) -> sin(_read_f64(a[1])),
    "cos_f32" => (a) -> cos(_read_f32(a[1])),
    "cos_f64" => (a) -> cos(_read_f64(a[1])),
    "tan_f32" => (a) -> tan(_read_f32(a[1])),
    "tan_f64" => (a) -> tan(_read_f64(a[1])),
    "asin_f32" => (a) -> asin(_read_f32(a[1])),
    "asin_f64" => (a) -> asin(_read_f64(a[1])),
    "acos_f32" => (a) -> acos(_read_f32(a[1])),
    "acos_f64" => (a) -> acos(_read_f64(a[1])),
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
    "acosh_f32" => (a) -> acosh(_read_f32(a[1])),
    "acosh_f64" => (a) -> acosh(_read_f64(a[1])),
    "atanh_f32" => (a) -> atanh(_read_f32(a[1])),
    "atanh_f64" => (a) -> atanh(_read_f64(a[1])),
    "to_radians_f32" => (a) -> deg2rad(_read_f32(a[1])),
    "to_radians_f64" => (a) -> deg2rad(_read_f64(a[1])),
    "to_degrees_f32" => (a) -> rad2deg(_read_f32(a[1])),
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
    "u128_shl" => (a) -> _read_u128(a[1]) << _read_u32s(a[2]),
    "u128_shr" => (a) -> _read_u128(a[1]) >> _read_u32s(a[2]),
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
    "collapse_symbol" => function (a)
        buf = a[1]
        isempty(buf) && return UInt8[]
        tag = try
            byte_item(buf[1])
        catch
            ;
            nothing
        end
        if tag isa ExprArity
            result = UInt8[]
            off = 2
            for _ in 1:Int(tag.arity)
                off > length(buf) && break
                st = try
                    byte_item(buf[off])
                catch
                    ;
                    break
                end
                st isa ExprSymbol || break
                n = Int(st.size)
                append!(result, buf[(off + 1):min(off + n, length(buf))])
                off += 1 + n
            end
            return result
        end
        reduce(vcat, a; init=UInt8[])
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
    # tuple: takes N arg payloads, returns MORK arity-N expression.
    # (tuple "0" "1") → [arity(2), sym(1)'0', sym(1)'1']
    # Mirrors tuple in pure.rs. Called by _pure_eval_formula's MORK_EXPR path.
    "tuple" => function (a)
        n = length(a)
        result = UInt8[item_byte(ExprArity(UInt8(n)))]
        for payload in a
            push!(result, item_byte(ExprSymbol(UInt8(length(payload)))))
            append!(result, payload)
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

    # ── control flow ─────────────────────────────────────────────────
    # ifnz is handled specially in _pure_eval_formula (short-circuit), not via pure_apply
    "ifnz" => (a) -> _read_u64(a[1]) != 0 ? a[2] : a[3],
    "then" => (a) -> a[end],
    "else" => (a) -> a[1],

    # ── expr accessors ────────────────────────────────────────────────
    "nth_expr" => (a) -> begin
        idx = Int(_read_u64(a[1]))
        length(a) > idx ? a[idx + 2] : UInt8[]
    end
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
# Exports
# =====================================================================

export PURE_OPS, pure_apply
