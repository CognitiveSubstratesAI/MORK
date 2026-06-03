# Test Policy API (A.0003) — policy-based value merge on PathMap join
using MORK, PathMap, Test

@testset "policy_ops" begin

    function make_map(kvs)
        m = PathMap.PathMap{Float64}()
        for (k, v) in kvs
            set_val_at!(m, Vector{UInt8}(k), Float64(v))
        end
        m
    end

    m1 = make_map(["a" => 10.0, "b" => 20.0, "c" => 30.0])
    m2 = make_map(["b" => 5.0, "c" => 6.0, "d" => 7.0])

    # ── SumPolicy ─────────────────────────────────────────────────────
    @testset "SumPolicy" begin
        r = pjoin_policy(m1, m2, SumPolicy())
        @test get_val_at(r, b"a") == 10.0        # only in m1
        @test get_val_at(r, b"b") == 25.0        # 20 + 5
        @test get_val_at(r, b"c") == 36.0        # 30 + 6
        @test get_val_at(r, b"d") == 7.0        # only in m2
    end

    # ── MaxPolicy ─────────────────────────────────────────────────────
    @testset "MaxPolicy" begin
        r = pjoin_policy(m1, m2, MaxPolicy())
        @test get_val_at(r, b"a") == 10.0
        @test get_val_at(r, b"b") == 20.0        # max(20, 5)
        @test get_val_at(r, b"c") == 30.0        # max(30, 6)
        @test get_val_at(r, b"d") == 7.0
    end

    # ── MinPolicy ─────────────────────────────────────────────────────
    @testset "MinPolicy" begin
        r = pjoin_policy(m1, m2, MinPolicy())
        @test get_val_at(r, b"b") == 5.0         # min(20, 5)
        @test get_val_at(r, b"c") == 6.0         # min(30, 6)
    end

    # ── TakeFirst / TakeLast ──────────────────────────────────────────
    @testset "TakeFirst" begin
        r = pjoin_policy(m1, m2, TakeFirst())
        @test get_val_at(r, b"b") == 20.0        # keep m1's value
        @test get_val_at(r, b"d") == 7.0        # only in m2, inserted
    end

    @testset "TakeLast" begin
        r = pjoin_policy(m1, m2, TakeLast())
        @test get_val_at(r, b"b") == 5.0        # overwrite with m2's value
    end

    # ── MergeWith custom function ─────────────────────────────────────
    @testset "MergeWith custom" begin
        diff = pjoin_policy(m1, m2, MergeWith((a, b) -> abs(a - b)))
        @test get_val_at(diff, b"b") == 15.0     # |20-5|
        @test get_val_at(diff, b"c") == 24.0     # |30-6|
    end

    # ── wz_join_policy! in-place zipper variant ───────────────────────
    @testset "wz_join_policy!" begin
        m_dst = make_map(["x" => 100.0, "y" => 200.0])
        m_src = make_map(["y" => 50.0, "z" => 75.0])
        wz = write_zipper(m_dst)
        wz_join_policy!(wz, m_src, SumPolicy())
        @test get_val_at(m_dst, b"x") == 100.0
        @test get_val_at(m_dst, b"y") == 250.0  # 200 + 50
        @test get_val_at(m_dst, b"z") == 75.0  # inserted
    end

    # ── ProdPolicy ────────────────────────────────────────────────────
    @testset "ProdPolicy" begin
        r = pjoin_policy(m1, m2, ProdPolicy())
        @test get_val_at(r, b"b") == 100.0       # 20 * 5
        @test get_val_at(r, b"c") == 180.0       # 30 * 6
    end

    # ── Source maps unmodified ─────────────────────────────────────────
    @testset "sources unmodified" begin
        _ = pjoin_policy(m1, m2, SumPolicy())
        @test get_val_at(m1, b"b") == 20.0
        @test get_val_at(m2, b"b") == 5.0
    end

    println("All policy_ops tests passed.")
end
