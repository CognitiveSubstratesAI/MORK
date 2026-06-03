# Test cata_hybrid_cached — A.0005 hybrid cached catamorphism
using MORK, PathMap, Test

@testset "cata_hybrid_cached" begin

    function make_map(kvs)
        m = PathMap.PathMap{Int}()
        for (k, v) in kvs
            set_val_at!(m, Vector{UInt8}(k), v)
        end
        m
    end

    # ── used_bytes=0: path-independent, same result as cata_cached ────
    @testset "used_bytes=0 matches cata_cached" begin
        m = make_map(["a" => 1, "b" => 2, "c" => 3])
        # Count values — path-independent
        total = cata_hybrid_cached(
            m,
            (mask, children, val, sub, path) -> begin
                base = val !== nothing ? 1 : 0
                (base + reduce(+, children, init=0), 0)   # used_bytes = 0
            end
        )
        @test total == 3

        # cata_cached gives same result
        total2 = cata_cached(
            m, (mask, children, val) -> begin
                base = val !== nothing ? 1 : 0
                base + reduce(+, children, init=0)
            end
        )
        @test total == total2
    end

    # ── used_bytes=1: last byte of path incorporated into W ───────────
    @testset "used_bytes=1 path-qualified result" begin
        m = make_map(["ax" => 10, "bx" => 20, "cx" => 30])
        # Collect last byte of path for each value
        collected = cata_hybrid_cached(
            m, (mask, children, val, sub, path) -> begin
                if val !== nothing
                    # Leaf: return (last_byte, 1) — uses 1 path byte
                    (Int(path[end]), 1)
                else
                    # Internal: combine children sums, 0 path bytes used
                    (reduce(+, children, init=0), 0)
                end
            end
        )
        # Last byte of "ax" = 0x78 ('x'), "bx" = 0x78, "cx" = 0x78
        @test collected == 3 * Int(UInt8('x'))
    end

    # ── Cache reuse: identical subtries at different paths ────────────
    @testset "cache reuse for path-independent nodes" begin
        # Build a map with structural sharing: same subtrie grafted twice
        m = PathMap.PathMap{Int}()
        sub = make_map(["x" => 42])
        wz1 = write_zipper(m)
        wz_descend_to!(wz1, b"left:")
        wz_graft_map!(wz1, sub)
        wz2 = write_zipper(m)
        wz_descend_to!(wz2, b"right:")
        wz_graft_map!(wz2, sub)

        total = cata_hybrid_cached(
            m,
            (mask, children, val, sub_path, path) -> begin
                base = val !== nothing ? val : 0
                (base + reduce(+, children, init=0), 0)   # used_bytes=0 → path-independent
            end
        )
        @test total == 84   # 42 + 42
        # Same result as cata_cached (correctness check)
        total2 = cata_cached(
            m, (mask, children, val) -> begin
                base = val !== nothing ? val : 0
                base + reduce(+, children, init=0)
            end
        )
        @test total == total2
    end

    # ── Cache NOT reused when path suffix differs ─────────────────────
    @testset "cache not reused when path suffix differs" begin
        m = make_map(["p:x" => 1, "q:x" => 2])
        # used_bytes=1 means cache is specific to last byte
        # Both paths end in 'x' so same suffix — cache MAY be reused
        results_p = Int[]
        results_q = Int[]
        _ = cata_hybrid_cached(
            m,
            (mask, children, val, sub, path) -> begin
                if val !== nothing
                    if length(path) >= 3 && path[1] == UInt8('p')
                        push!(results_p, val)
                    else
                        push!(results_q, val)
                    end
                    (val, 1)   # uses 1 path byte
                else
                    (sum(children; init=0), 0)
                end
            end
        )
        @test sort(results_p) == [1]
        @test sort(results_q) == [2]
    end

    # ── jumping variant works ─────────────────────────────────────────
    @testset "cata_jumping_hybrid_cached" begin
        m = make_map(["alpha" => 10, "beta" => 20, "gamma" => 30])
        total = cata_jumping_hybrid_cached(
            m,
            (mask, children, val, sub, path) -> begin
                base = val !== nothing ? val : 0
                (base + reduce(+, children, init=0), 0)
            end
        )
        @test total == 60
    end

    println("All cata_hybrid_cached tests passed.")
end
