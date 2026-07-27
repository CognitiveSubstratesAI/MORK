# XXH3.jl — pure-Julia port of xxhash-rust's `const_xxh3` (128-bit variant).
#
# WHY THIS EXISTS
# ---------------
# Upstream MORK's `Expr::hash()` (mork/expr/src/lib.rs:310) calls
# `gxhash::gxhash128(span, 0)`. In this workspace `cfg(gxhash)` is OFF (bare cfg,
# no build.rs and no rustflags set it), so the live implementation is the stub at
# mork/expr/src/lib.rs:76:
#
#     pub fn gxhash128(data: &[u8], _seed: i64) -> u128 {
#         xxhash_rust::const_xxh3::xxh3_128(data)
#     }
#
# i.e. XXH3-128, DEFAULT secret, seed 0. This file is a 1:1 port of
#   ~/.cargo/registry/src/*/xxhash-rust-0.8.15/src/const_xxh3.rs
# (+ xxh3_common.rs, xxh64_common.rs, xxh32_common.rs), with no dependencies.
#
# Rust `wrapping_add`/`wrapping_mul`/`wrapping_sub` map to Julia's plain `+`/`*`/`-`
# on fixed-width unsigned integers (already modular). Rust slices are 0-based; all
# `cursor`/`offset` arguments below stay 0-based and are translated at the single
# point of indexing (`firstindex(input) + cursor`).

# ── constants ────────────────────────────────────────────────────────────────

# xxh64_common.rs:6-10
const XXH64_PRIME_1 = 0x9E3779B185EBCA87
const XXH64_PRIME_2 = 0xC2B2AE3D27D4EB4F
const XXH64_PRIME_3 = 0x165667B19E3779F9
const XXH64_PRIME_4 = 0x85EBCA77C2B2AE63
const XXH64_PRIME_5 = 0x27D4EB2F165667C5

# xxh32_common.rs:6-10
const XXH32_PRIME_1 = 0x9E3779B1
const XXH32_PRIME_2 = 0x85EBCA77
const XXH32_PRIME_3 = 0xC2B2AE3D
const XXH32_PRIME_4 = 0x27D4EB2F
const XXH32_PRIME_5 = 0x165667B1

# xxh3_common.rs:3-12
const XXH3_STRIPE_LEN = 64
const XXH3_SECRET_CONSUME_RATE = 8
const XXH3_ACC_NB = 8                      # STRIPE_LEN / sizeof(u64)
const XXH3_SECRET_MERGEACCS_START = 11
const XXH3_SECRET_LASTACC_START = 7
const XXH3_MID_SIZE_MAX = 240
const XXH3_SECRET_SIZE_MIN = 136
const XXH3_DEFAULT_SECRET_SIZE = 192

# xxh3_common.rs:13-26 — kSecret
const XXH3_DEFAULT_SECRET = UInt8[
    0xb8, 0xfe, 0x6c, 0x39, 0x23, 0xa4, 0x4b, 0xbe, 0x7c, 0x01, 0x81, 0x2c, 0xf7, 0x21, 0xad, 0x1c,
    0xde, 0xd4, 0x6d, 0xe9, 0x83, 0x90, 0x97, 0xdb, 0x72, 0x40, 0xa4, 0xa4, 0xb7, 0xb3, 0x67, 0x1f,
    0xcb, 0x79, 0xe6, 0x4e, 0xcc, 0xc0, 0xe5, 0x78, 0x82, 0x5a, 0xd0, 0x7d, 0xcc, 0xff, 0x72, 0x21,
    0xb8, 0x08, 0x46, 0x74, 0xf7, 0x43, 0x24, 0x8e, 0xe0, 0x35, 0x90, 0xe6, 0x81, 0x3a, 0x26, 0x4c,
    0x3c, 0x28, 0x52, 0xbb, 0x91, 0xc3, 0x00, 0xcb, 0x88, 0xd0, 0x65, 0x8b, 0x1b, 0x53, 0x2e, 0xa3,
    0x71, 0x64, 0x48, 0x97, 0xa2, 0x0d, 0xf9, 0x4e, 0x38, 0x19, 0xef, 0x46, 0xa9, 0xde, 0xac, 0xd8,
    0xa8, 0xfa, 0x76, 0x3f, 0xe3, 0x9c, 0x34, 0x3f, 0xf9, 0xdc, 0xbb, 0xc7, 0xc7, 0x0b, 0x4f, 0x1d,
    0x8a, 0x51, 0xe0, 0x4b, 0xcd, 0xb4, 0x59, 0x31, 0xc8, 0x9f, 0x7e, 0xc9, 0xd9, 0x78, 0x73, 0x64,
    0xea, 0xc5, 0xac, 0x83, 0x34, 0xd3, 0xeb, 0xc3, 0xc5, 0x81, 0xa0, 0xff, 0xfa, 0x13, 0x63, 0xeb,
    0x17, 0x0d, 0xdd, 0x51, 0xb7, 0xf0, 0xda, 0x49, 0xd3, 0x16, 0x55, 0x26, 0x29, 0xd4, 0x68, 0x9e,
    0x2b, 0x16, 0xbe, 0x58, 0x7d, 0x47, 0xa1, 0xfc, 0x8f, 0xf8, 0xb8, 0xd1, 0x7a, 0xd0, 0x31, 0xce,
    0x45, 0xcb, 0x3a, 0x8f, 0x95, 0x16, 0x04, 0x28, 0xaf, 0xd7, 0xfb, 0xca, 0xbb, 0x4b, 0x40, 0x7e,
]

# const_xxh3.rs:12-15
const XXH3_INITIAL_ACC = UInt64[
    UInt64(XXH32_PRIME_3), XXH64_PRIME_1, XXH64_PRIME_2, XXH64_PRIME_3,
    XXH64_PRIME_4, UInt64(XXH32_PRIME_2), XXH64_PRIME_5, UInt64(XXH32_PRIME_1),
]

# ── primitive reads / mults (const_xxh3.rs:17-38, xxh3_common.rs:28-59) ──────

"""`u32::from_le_bytes` at 0-based `cursor` (const_xxh3.rs:18)."""
@inline function _xxh3_read_u32(input, cursor::Int)::UInt32
    b = firstindex(input) + cursor
    @inbounds UInt32(input[b]) |
              (UInt32(input[b+1]) << 8) |
              (UInt32(input[b+2]) << 16) |
              (UInt32(input[b+3]) << 24)
end

"""`u64::from_le_bytes` at 0-based `cursor` (const_xxh3.rs:24)."""
@inline function _xxh3_read_u64(input, cursor::Int)::UInt64
    b = firstindex(input) + cursor
    @inbounds UInt64(input[b]) |
              (UInt64(input[b+1]) << 8) |
              (UInt64(input[b+2]) << 16) |
              (UInt64(input[b+3]) << 24) |
              (UInt64(input[b+4]) << 32) |
              (UInt64(input[b+5]) << 40) |
              (UInt64(input[b+6]) << 48) |
              (UInt64(input[b+7]) << 56)
end

# const_xxh3.rs:36
@inline _xxh3_mult32_to64(l::UInt32, r::UInt32)::UInt64 = UInt64(l) * UInt64(r)

# xxh3_common.rs:50 — 64x64 -> (low, high)
@inline function _xxh3_mul64_to128(l::UInt64, r::UInt64)
    p = UInt128(l) * UInt128(r)
    (p % UInt64, (p >> 64) % UInt64)
end

# xxh3_common.rs:56
@inline function _xxh3_mul128_fold64(l::UInt64, r::UInt64)::UInt64
    lo, hi = _xxh3_mul64_to128(l, r)
    lo ⊻ hi
end

# xxh3_common.rs:29
@inline _xxh3_xorshift64(v::UInt64, s::Int)::UInt64 = v ⊻ (v >> s)

# xxh3_common.rs:34
@inline function _xxh3_avalanche(v::UInt64)::UInt64
    v = _xxh3_xorshift64(v, 37)
    v = v * 0x165667919E3779F9
    _xxh3_xorshift64(v, 32)
end

# xxh64_common.rs:26
@inline function _xxh64_avalanche(v::UInt64)::UInt64
    v ⊻= v >> 33
    v *= XXH64_PRIME_2
    v ⊻= v >> 29
    v *= XXH64_PRIME_3
    v ⊻= v >> 32
    v
end

# ── mixers (const_xxh3.rs:41-61) ─────────────────────────────────────────────

@inline function _xxh3_mix16_b(input, input_offset::Int, secret, secret_offset::Int, seed::UInt64)::UInt64
    input_lo = _xxh3_read_u64(input, input_offset)
    input_hi = _xxh3_read_u64(input, input_offset + 8)

    input_lo ⊻= _xxh3_read_u64(secret, secret_offset) + seed
    input_hi ⊻= _xxh3_read_u64(secret, secret_offset + 8) - seed

    _xxh3_mul128_fold64(input_lo, input_hi)
end

@inline function _xxh3_mix32_b(acc0::UInt64, acc1::UInt64,
                               input_1, input_1_off::Int,
                               input_2, input_2_off::Int,
                               secret, secret_offset::Int, seed::UInt64)
    acc0 += _xxh3_mix16_b(input_1, input_1_off, secret, secret_offset, seed)
    acc0 ⊻= _xxh3_read_u64(input_2, input_2_off) + _xxh3_read_u64(input_2, input_2_off + 8)

    acc1 += _xxh3_mix16_b(input_2, input_2_off, secret, secret_offset + 16, seed)
    acc1 ⊻= _xxh3_read_u64(input_1, input_1_off) + _xxh3_read_u64(input_1, input_1_off + 8)

    (acc0, acc1)
end

# ── 128-bit length classes ───────────────────────────────────────────────────

# const_xxh3.rs:290
@inline function _xxh3_128_1to3(input, seed::UInt64, secret)::UInt128
    n = length(input)
    o = firstindex(input)
    @inbounds c1 = input[o]
    @inbounds c2 = input[o + (n >> 1)]
    @inbounds c3 = input[o + n - 1]
    input_lo = (UInt32(c1) << 16) | (UInt32(c2) << 24) | UInt32(c3) | (UInt32(n) << 8)
    input_hi = bitrotate(bswap(input_lo), 13)

    flip_lo = (UInt64(_xxh3_read_u32(secret, 0)) ⊻ UInt64(_xxh3_read_u32(secret, 4))) + seed
    flip_hi = (UInt64(_xxh3_read_u32(secret, 8)) ⊻ UInt64(_xxh3_read_u32(secret, 12))) - seed
    keyed_lo = UInt64(input_lo) ⊻ flip_lo
    keyed_hi = UInt64(input_hi) ⊻ flip_hi

    UInt128(_xxh64_avalanche(keyed_lo)) | (UInt128(_xxh64_avalanche(keyed_hi)) << 64)
end

# const_xxh3.rs:306
@inline function _xxh3_128_4to8(input, seed::UInt64, secret)::UInt128
    n = length(input)
    seed ⊻= UInt64(bswap(seed % UInt32)) << 32

    lo32 = _xxh3_read_u32(input, 0)
    hi32 = _xxh3_read_u32(input, n - 4)
    input_64 = UInt64(lo32) + (UInt64(hi32) << 32)

    flip = (_xxh3_read_u64(secret, 16) ⊻ _xxh3_read_u64(secret, 24)) + seed
    keyed = input_64 ⊻ flip

    lo, hi = _xxh3_mul64_to128(keyed, XXH64_PRIME_1 + (UInt64(n) << 2))

    hi = hi + (lo << 1)
    lo ⊻= hi >> 3

    lo = _xxh3_xorshift64(lo, 35) * 0x9FB21C651E98DF25
    lo = _xxh3_xorshift64(lo, 28)
    hi = _xxh3_avalanche(hi)

    UInt128(lo) | (UInt128(hi) << 64)
end

# const_xxh3.rs:329
@inline function _xxh3_128_9to16(input, seed::UInt64, secret)::UInt128
    n = length(input)
    flip_lo = (_xxh3_read_u64(secret, 32) ⊻ _xxh3_read_u64(secret, 40)) - seed
    flip_hi = (_xxh3_read_u64(secret, 48) ⊻ _xxh3_read_u64(secret, 56)) + seed
    input_lo = _xxh3_read_u64(input, 0)
    input_hi = _xxh3_read_u64(input, n - 8)

    mul_low, mul_high = _xxh3_mul64_to128(input_lo ⊻ input_hi ⊻ flip_lo, XXH64_PRIME_1)

    mul_low = mul_low + ((UInt64(n) - UInt64(1)) << 54)
    input_hi ⊻= flip_hi
    mul_high = mul_high + (input_hi + _xxh3_mult32_to64(input_hi % UInt32, XXH32_PRIME_2 - UInt32(1)))

    mul_low ⊻= bswap(mul_high)

    result_low, result_hi = _xxh3_mul64_to128(mul_low, XXH64_PRIME_2)
    result_hi = result_hi + mul_high * XXH64_PRIME_2

    UInt128(_xxh3_avalanche(result_low)) | (UInt128(_xxh3_avalanche(result_hi)) << 64)
end

# const_xxh3.rs:354
@inline function _xxh3_128_0to16(input, seed::UInt64, secret)::UInt128
    n = length(input)
    if n > 8
        _xxh3_128_9to16(input, seed, secret)
    elseif n >= 4
        _xxh3_128_4to8(input, seed, secret)
    elseif n > 0
        _xxh3_128_1to3(input, seed, secret)
    else
        flip_lo = _xxh3_read_u64(secret, 64) ⊻ _xxh3_read_u64(secret, 72)
        flip_hi = _xxh3_read_u64(secret, 80) ⊻ _xxh3_read_u64(secret, 88)
        UInt128(_xxh64_avalanche(seed ⊻ flip_lo)) | (UInt128(_xxh64_avalanche(seed ⊻ flip_hi)) << 64)
    end
end

# const_xxh3.rs:369 — 17..=128
function _xxh3_128_17to128(input, seed::UInt64, secret)::UInt128
    n = length(input)
    acc0 = UInt64(n) * XXH64_PRIME_1
    acc1 = UInt64(0)

    if n > 32
        if n > 64
            if n > 96
                acc0, acc1 = _xxh3_mix32_b(acc0, acc1, input, 48, input, n - 64, secret, 96, seed)
            end
            acc0, acc1 = _xxh3_mix32_b(acc0, acc1, input, 32, input, n - 48, secret, 64, seed)
        end
        acc0, acc1 = _xxh3_mix32_b(acc0, acc1, input, 16, input, n - 32, secret, 32, seed)
    end

    acc0, acc1 = _xxh3_mix32_b(acc0, acc1, input, 0, input, n - 16, secret, 0, seed)

    result_lo = acc0 + acc1
    result_hi = acc0 * XXH64_PRIME_1 + acc1 * XXH64_PRIME_4 + (UInt64(n) - seed) * XXH64_PRIME_2

    UInt128(_xxh3_avalanche(result_lo)) | (UInt128(-_xxh3_avalanche(result_hi)) << 64)
end

# const_xxh3.rs:395 — 129..=240
function _xxh3_128_129to240(input, seed::UInt64, secret)::UInt128
    START_OFFSET = 3
    LAST_OFFSET = 17
    n = length(input)
    nb_rounds = div(n, 32)

    acc0 = UInt64(n) * XXH64_PRIME_1
    acc1 = UInt64(0)

    idx = 0
    while idx < 4
        acc0, acc1 = _xxh3_mix32_b(acc0, acc1, input, 32 * idx, input, 32 * idx + 16,
                                   secret, 32 * idx, seed)
        idx += 1
    end

    acc0 = _xxh3_avalanche(acc0)
    acc1 = _xxh3_avalanche(acc1)

    while idx < nb_rounds
        acc0, acc1 = _xxh3_mix32_b(acc0, acc1, input, 32 * idx, input, 32 * idx + 16,
                                   secret, START_OFFSET + 32 * (idx - 4), seed)
        idx += 1
    end

    acc0, acc1 = _xxh3_mix32_b(acc0, acc1, input, n - 16, input, n - 32,
                               secret, XXH3_SECRET_SIZE_MIN - LAST_OFFSET - 16, -seed)

    result_lo = acc0 + acc1
    result_hi = acc0 * XXH64_PRIME_1 + acc1 * XXH64_PRIME_4 + (UInt64(n) - seed) * XXH64_PRIME_2

    # Rust: `avalanche(lo) as u128 | 0u128.wrapping_sub(avalanche(hi) as u128) << 64`
    # (`<<` binds tighter than `|`); the low 64 bits of the negation are shifted out,
    # leaving the 64-bit wrapping negation in the high half.
    UInt128(_xxh3_avalanche(result_lo)) | ((UInt128(0) - UInt128(_xxh3_avalanche(result_hi))) << 64)
end

# ── long path (241+) — const_xxh3.rs:167-245, 425 ────────────────────────────

# const_xxh3.rs:167
@inline function _xxh3_mix_two_accs(acc::Vector{UInt64}, acc_offset::Int, secret, secret_offset::Int)::UInt64
    @inbounds _xxh3_mul128_fold64(acc[acc_offset + 1] ⊻ _xxh3_read_u64(secret, secret_offset),
                                  acc[acc_offset + 2] ⊻ _xxh3_read_u64(secret, secret_offset + 8))
end

# const_xxh3.rs:173
function _xxh3_merge_accs(acc::Vector{UInt64}, secret, secret_offset::Int, result::UInt64)::UInt64
    for idx in 0:3
        result += _xxh3_mix_two_accs(acc, idx * 2, secret, secret_offset + idx * 16)
    end
    _xxh3_avalanche(result)
end

# const_xxh3.rs:183
function _xxh3_scramble_acc!(acc::Vector{UInt64}, secret, secret_offset::Int)
    for idx in 0:(XXH3_ACC_NB - 1)
        key = _xxh3_read_u64(secret, secret_offset + 8 * idx)
        @inbounds acc_val = _xxh3_xorshift64(acc[idx + 1], 47)
        acc_val ⊻= key
        @inbounds acc[idx + 1] = acc_val * UInt64(XXH32_PRIME_1)
    end
    acc
end

# const_xxh3.rs:198
function _xxh3_accumulate_512!(acc::Vector{UInt64}, input, input_offset::Int, secret, secret_offset::Int)
    for idx in 0:(XXH3_ACC_NB - 1)
        data_val = _xxh3_read_u64(input, input_offset + 8 * idx)
        data_key = data_val ⊻ _xxh3_read_u64(secret, secret_offset + 8 * idx)

        @inbounds acc[(idx ⊻ 1) + 1] = acc[(idx ⊻ 1) + 1] + data_val
        @inbounds acc[idx + 1] = acc[idx + 1] +
            _xxh3_mult32_to64((data_key & 0xFFFFFFFF) % UInt32, (data_key >> 32) % UInt32)
    end
    acc
end

# const_xxh3.rs:214
function _xxh3_accumulate_loop!(acc::Vector{UInt64}, input, input_offset::Int, secret,
                                secret_offset::Int, nb_stripes::Int)
    for idx in 0:(nb_stripes - 1)
        _xxh3_accumulate_512!(acc, input, input_offset + idx * XXH3_STRIPE_LEN,
                              secret, secret_offset + idx * XXH3_SECRET_CONSUME_RATE)
    end
    acc
end

# const_xxh3.rs:226
function _xxh3_hash_long_internal_loop(input, secret)::Vector{UInt64}
    acc = copy(XXH3_INITIAL_ACC)
    n = length(input)
    slen = length(secret)

    nb_stripes = div(slen - XXH3_STRIPE_LEN, XXH3_SECRET_CONSUME_RATE)
    block_len = XXH3_STRIPE_LEN * nb_stripes
    nb_blocks = div(n - 1, block_len)

    for idx in 0:(nb_blocks - 1)
        _xxh3_accumulate_loop!(acc, input, idx * block_len, secret, 0, nb_stripes)
        _xxh3_scramble_acc!(acc, secret, slen - XXH3_STRIPE_LEN)
    end

    nb_stripes2 = div((n - 1) - (block_len * nb_blocks), XXH3_STRIPE_LEN)

    _xxh3_accumulate_loop!(acc, input, nb_blocks * block_len, secret, 0, nb_stripes2)
    _xxh3_accumulate_512!(acc, input, n - XXH3_STRIPE_LEN, secret,
                          slen - XXH3_STRIPE_LEN - XXH3_SECRET_LASTACC_START)
    acc
end

# const_xxh3.rs:425
function _xxh3_128_long_impl(input, secret)::UInt128
    acc = _xxh3_hash_long_internal_loop(input, secret)
    n = UInt64(length(input))
    slen = length(secret)

    lo = _xxh3_merge_accs(acc, secret, XXH3_SECRET_MERGEACCS_START, n * XXH64_PRIME_1)
    hi = _xxh3_merge_accs(acc, secret,
                          slen - XXH3_ACC_NB * 8 - XXH3_SECRET_MERGEACCS_START,
                          ~(n * XXH64_PRIME_2))

    UInt128(lo) | (UInt128(hi) << 64)
end

# const_xxh3.rs:473
function xxh3_const_custom_default_secret(seed::UInt64)::Vector{UInt8}
    seed == 0 && return XXH3_DEFAULT_SECRET

    result = Vector{UInt8}(undef, XXH3_DEFAULT_SECRET_SIZE)
    nb_rounds = div(XXH3_DEFAULT_SECRET_SIZE, 16)
    for idx in 0:(nb_rounds - 1)
        lo = _xxh3_read_u64(XXH3_DEFAULT_SECRET, idx * 16) + seed
        hi = _xxh3_read_u64(XXH3_DEFAULT_SECRET, idx * 16 + 8) - seed
        for k in 0:7
            result[idx * 16 + k + 1] = (lo >> (8 * k)) % UInt8
            result[idx * 16 + 8 + k + 1] = (hi >> (8 * k)) % UInt8
        end
    end
    result
end

# ── public entry points (const_xxh3.rs:438-453) ──────────────────────────────

"""
    xxh3_128_with_seed(data, seed::UInt64) -> UInt128

XXH3-128 with the default secret and an explicit seed. Port of
`xxhash_rust::const_xxh3::xxh3_128_with_seed` (const_xxh3.rs:443).
"""
function xxh3_128_with_seed(input::AbstractVector{UInt8}, seed::UInt64)::UInt128
    n = length(input)
    if n <= 16
        _xxh3_128_0to16(input, seed, XXH3_DEFAULT_SECRET)
    elseif n <= 128
        _xxh3_128_17to128(input, seed, XXH3_DEFAULT_SECRET)
    elseif n <= XXH3_MID_SIZE_MAX
        _xxh3_128_129to240(input, seed, XXH3_DEFAULT_SECRET)
    else
        _xxh3_128_long_impl(input, xxh3_const_custom_default_secret(seed))
    end
end

"""
    xxh3_128(data::AbstractVector{UInt8}) -> UInt128

XXH3-128 (default secret, seed 0). This is exactly what upstream MORK's
`Expr::hash()` computes when `cfg(gxhash)` is off — see the header of this file.
"""
xxh3_128(input::AbstractVector{UInt8})::UInt128 = xxh3_128_with_seed(input, UInt64(0))
