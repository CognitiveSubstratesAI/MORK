# unit_xxh3.jl — XXH3-128 differential vs the xxhash-rust crate.
#
# Ground truth in test/fixtures/xxh3/xxh3_128_vectors.tsv was generated from
# xxhash-rust 0.8.15 `const_xxh3::xxh3_128` — the exact function upstream MORK's
# `Expr::hash()` resolves to in this workspace (cfg(gxhash) OFF => the stub at
# mork/expr/src/lib.rs:76 forwards to it). Columns:
#   label <TAB> input_hex <TAB> xxh3_128_hex <TAB> le_bytes_hex
#
# Coverage spans every len-class the algorithm dispatches on: 0 | 1-3 | 4-8 |
# 9-16 | 17-128 | 129-240 | 241+.
#
# Run standalone: tools/run_tests.sh test/unit_xxh3.jl
# Run via runtests.jl: included automatically

using Test
using MORK

@testset "XXH3-128 vectors (differential vs xxhash-rust 0.8.15 const_xxh3)" begin
    tsv = joinpath(@__DIR__, "fixtures", "xxh3", "xxh3_128_vectors.tsv")
    @test isfile(tsv)

    nvec = 0
    for line in eachline(tsv)
        startswith(line, "#") && continue
        isempty(strip(line)) && continue
        parts = split(line, '\t')
        @test length(parts) >= 4
        length(parts) >= 4 || continue

        label = String(parts[1])
        ihex = strip(parts[2])
        data = isempty(ihex) ? UInt8[] : hex2bytes(String(ihex))

        got = MORK.xxh3_128(data)
        @test (label, got) == (label, parse(UInt128, strip(parts[3]), base=16))

        # le_bytes_hex is what `hash_expr` actually writes (`h.to_le_bytes()`).
        gotle = bytes2hex(reinterpret(UInt8, [htol(got)]))
        @test (label, gotle) == (label, String(strip(parts[4])))

        nvec += 1
    end

    # Guard the oracle itself: a truncated/missing fixture must fail loudly rather
    # than vacuously pass with zero assertions.
    @test nvec == 31

    # The 31 primary vectors top out at len 1024 == block_len, so nb_blocks =
    # (1024-1)/1024 = 0 and the multi-block + `scramble_acc` branch of
    # hash_long_internal_loop is NEVER entered by them. These close that hole
    # (1025..10000 => nb_blocks 1..9), generated from the same crate.
    long_tsv = joinpath(@__DIR__, "fixtures", "xxh3", "xxh3_128_long_vectors.tsv")
    nlong = 0
    for line in eachline(long_tsv)
        (startswith(line, "#") || isempty(strip(line))) && continue
        parts = split(line, '\t')
        label = String(parts[1])
        got = MORK.xxh3_128(hex2bytes(String(strip(parts[2]))))
        @test (label, got) == (label, parse(UInt128, strip(parts[3]), base=16))
        nlong += 1
    end
    @test nlong == 10

    # Seeded dispatch: `xxh3_128` always seeds 0, but xxh3_128_with_seed's nonzero
    # path (incl. const_custom_default_secret for 241+) is otherwise unexercised.
    seed_tsv = joinpath(@__DIR__, "fixtures", "xxh3", "xxh3_128_seeded_vectors.tsv")
    nseed = 0
    for line in eachline(seed_tsv)
        (startswith(line, "#") || isempty(strip(line))) && continue
        parts = split(line, '\t')
        label = String(parts[1])
        seed = parse(UInt64, strip(parts[2]))
        ihex = strip(parts[3])
        data = isempty(ihex) ? UInt8[] : hex2bytes(String(ihex))
        got = MORK.xxh3_128_with_seed(data, seed)
        @test (label, got) == (label, parse(UInt128, strip(parts[4]), base=16))
        nseed += 1
    end
    @test nseed == 36

    # Len-class boundary sanity: every dispatch arm must be reachable and distinct.
    dat(n) = UInt8[UInt8((i * 37 + 11) & 0xFF) for i in 0:(n - 1)]
    hs = [
        MORK.xxh3_128(dat(n)) for
        n in (0, 1, 3, 4, 8, 9, 16, 17, 128, 129, 240, 241, 1024, 2048)
    ]
    @test length(unique(hs)) == length(hs)

    # A view / non-1-based-offset input must hash identically to the owned copy
    # (the port indexes via `firstindex`, not a hardcoded 1).
    buf = dat(300)
    @test MORK.xxh3_128(view(buf, 21:120)) == MORK.xxh3_128(collect(buf[21:120]))
end
