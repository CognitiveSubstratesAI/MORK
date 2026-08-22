# Bindings — the direct-indexed slab that replaces `Dict{ExprVar,ExprEnv}`.
#
# 🔑 THE ORACLE IS THE TYPE IT REPLACES. `Bindings` claims to be a drop-in, so the test is a
# DIFFERENTIAL: drive the same operation sequence into a real `Dict` and into a `Bindings`, and
# assert they agree after every step. Asserting hand-written expectations would only prove the slab
# matches my model of a Dict; driving both proves it matches the Dict.
#
# ⚠️ THIS TYPE IS PUBLIC CONTRACT. `space_query_multi`'s callback hands one to Core —
# `PatternMiner.jl:40` and `core_match_bind` both consume it — so "drop-in" has to mean the
# AbstractDict surface, not just the three methods the join happens to call.

using MORK, Test

const _BV = MORK.ExprVar
_env(i::Int) = MORK.ExprEnv(UInt8(i % 64), MORK.Expr(UInt8[0xC1, UInt8(0x61 + (i % 26))]))

@testset "Bindings — direct-indexed slab, drop-in for Dict" begin

    @testset "differential against Dict over a random op sequence" begin
        rng = MORK  # no RNG dependency: a fixed deterministic schedule, reproducible on failure
        d = Dict{_BV, MORK.ExprEnv}()
        b = MORK.Bindings()

        # A deliberately awkward schedule: repeats, deletes of absent keys, re-inserts over
        # existing keys, and keys spread across namespaces so the slab has to grow more than once.
        keys_used = _BV[
            (UInt8(n), UInt8(v)) for n in (0, 1, 5, 0, 2) for v in (0, 1, 63, 7)
        ]
        ops = 0
        for round in 1:3, (i, k) in enumerate(keys_used)
            e = _env(i + round)
            # insert (sometimes over an existing key)
            d[k] = e
            b[k] = e
            ops += 1
            @test length(b) == length(d)
            @test haskey(b, k) == haskey(d, k)
            @test b[k] === d[k]

            # delete every third, including some that are already gone
            if i % 3 == 0
                delete!(d, k)
                delete!(b, k)
                ops += 1
                @test length(b) == length(d)
                @test haskey(b, k) == haskey(d, k)
                @test get(b, k, nothing) === get(d, k, nothing)
                # deleting again must be a no-op on both
                delete!(d, k)
                delete!(b, k)
                @test length(b) == length(d)
            end
        end
        @test ops > 0                                   # anti-vacuity for the loop above

        # Same CONTENTS, as sets of pairs. Order is deliberately NOT compared: the slab's `touched`
        # list swap-removes on delete, and upstream states no consumer depends on order.
        @test Set(collect(b)) == Set(collect(d))
        @test Set(keys(b)) == Set(keys(d))
        @test length(b) == length(d)
    end

    @testset "absent keys, and the boundaries of the index" begin
        b = MORK.Bindings()
        @test isempty(b) && length(b) == 0
        @test !haskey(b, (UInt8(0), UInt8(0)))
        @test get(b, (UInt8(3), UInt8(9)), nothing) === nothing
        @test_throws KeyError b[(UInt8(0), UInt8(0))]

        # The index is (n << 6) | v. These are the corners: first slot, last slot of namespace 0,
        # first slot of namespace 1 — a wrong shift or mask collides two of them.
        a = _env(1)
        c = _env(2)
        e = _env(3)
        b[(UInt8(0), UInt8(0))] = a
        b[(UInt8(0), UInt8(63))] = c
        b[(UInt8(1), UInt8(0))] = e
        @test length(b) == 3                            # ⇐ a collision would make this 2
        @test b[(UInt8(0), UInt8(0))] === a
        @test b[(UInt8(0), UInt8(63))] === c
        @test b[(UInt8(1), UInt8(0))] === e
    end

    @testset "growth across namespaces leaves no undefined slot" begin
        # `resize!` leaves new entries UNDEFINED for a non-isbits element type. If they are not
        # written, a later read is an UndefRefError rather than a miss — so jump straight to a high
        # namespace and then probe the gap.
        b = MORK.Bindings()
        b[(UInt8(9), UInt8(5))] = _env(1)
        @test length(b) == 1
        for n in 0:9, v in 0:63
            (n == 9 && v == 5) && continue
            @test !haskey(b, (UInt8(n), UInt8(v)))      # every gap slot must read as absent
            @test get(b, (UInt8(n), UInt8(v)), nothing) === nothing
        end
    end

    @testset "copy is independent, and shares immutable values" begin
        b = MORK.Bindings()
        k1 = (UInt8(0), UInt8(1))
        k2 = (UInt8(2), UInt8(3))
        e1 = _env(1)
        b[k1] = e1
        c = copy(b)
        @test length(c) == 1 && c[k1] === e1            # values shared: ExprEnv is immutable

        c[k2] = _env(2)                                 # mutating the copy must not touch the source
        @test length(c) == 2 && length(b) == 1
        @test !haskey(b, k2)

        delete!(b, k1)                                  # …and vice versa
        @test length(b) == 0 && length(c) == 2 && haskey(c, k1)
    end

    @testset "empty! clears both the slab and the touched list" begin
        b = MORK.Bindings()
        for n in 0:3, v in 0:5
            b[(UInt8(n), UInt8(v))] = _env(n * 6 + v)
        end
        @test length(b) == 24
        empty!(b)
        @test isempty(b) && length(b) == 0
        @test isempty(collect(b))
        # and it is REUSABLE after clearing — a stale touched entry would double-count here
        b[(UInt8(0), UInt8(0))] = _env(1)
        @test length(b) == 1
    end

    @testset "it really is an AbstractDict" begin
        b = MORK.Bindings()
        @test b isa AbstractDict{MORK.ExprVar, MORK.ExprEnv}
        b[(UInt8(1), UInt8(2))] = _env(7)
        # the generic AbstractDict surface Core's consumers rely on
        @test collect(keys(b)) == [(UInt8(1), UInt8(2))]
        @test length(collect(values(b))) == 1
        @test first(b) isa Pair{MORK.ExprVar, MORK.ExprEnv}
        @test [k for (k, _) in b] == [(UInt8(1), UInt8(2))]
    end
end
