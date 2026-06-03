# test/integration/pathmap_write.jl — PathMap write zipper tests
# Ports write_zipper_graft_test1 and write_zipper_remove_branches_test
# from PathMap/src/write_zipper.rs
using MORK, PathMap, Test

function make_imap(kvs)
    m = PathMap.PathMap{Int32}()
    for (k, v) in kvs
        set_val_at!(m, Vector{UInt8}(k), Int32(v))
    end
    m
end

@testset "pathmap write — graft_test1" begin
    a = make_imap(["arrow"=>0, "bow"=>1, "cannon"=>2, "roman"=>3, "romane"=>4,
        "romanus"=>5, "romulus"=>6, "rubens"=>7, "ruber"=>8, "rubicon"=>9,
        "rubicundus"=>10, "rom'i"=>11])
    b = make_imap(["ad"=>1000, "d"=>1001, "ll"=>1002, "of"=>1003, "om"=>1004,
        "ot"=>1005, "ugh"=>1006, "und"=>1007])

    wz = write_zipper_at_path(a, b"ro")
    wz_graft_map!(wz, b)

    # Original keys above graft point
    @test get_val_at(a, b"arrow") == Int32(0)
    @test get_val_at(a, b"bow") == Int32(1)
    @test get_val_at(a, b"cannon") == Int32(2)
    # Pruned keys gone
    @test get_val_at(a, b"roman") === nothing
    @test get_val_at(a, b"romulus") === nothing
    @test get_val_at(a, b"rom'i") === nothing
    # Keys above graft point preserved
    @test get_val_at(a, b"rubens") == Int32(7)
    @test get_val_at(a, b"ruber") == Int32(8)
    @test get_val_at(a, b"rubicundus") == Int32(10)
    # Grafted keys
    @test get_val_at(a, b"road") == Int32(1000)
    @test get_val_at(a, b"rod") == Int32(1001)
    @test get_val_at(a, b"roll") == Int32(1002)
    @test get_val_at(a, b"roof") == Int32(1003)
    @test get_val_at(a, b"room") == Int32(1004)
    @test get_val_at(a, b"root") == Int32(1005)
    @test get_val_at(a, b"rough") == Int32(1006)
    @test get_val_at(a, b"round") == Int32(1007)
end

@testset "pathmap write — remove_branches_test" begin
    m = make_imap(["arrow"=>0, "bow"=>1, "cannon"=>2, "roman"=>3, "romane"=>4,
        "romanus"=>5, "romulus"=>6, "rubens"=>7, "ruber"=>8, "rubicon"=>9,
        "rubicundus"=>10, "rom'i"=>11, "abcdefghijklmnopqrstuvwxyz"=>12])

    # Remove branches under "roman"
    wz = write_zipper_at_path(m, b"roman")
    wz_remove_branches!(wz, true)
    @test get_val_at(m, b"arrow") == Int32(0)
    @test get_val_at(m, b"cannon") == Int32(2)
    @test get_val_at(m, b"rom'i") == Int32(11)
    @test get_val_at(m, b"roman") == Int32(3)   # value at roman preserved
    @test get_val_at(m, b"romane") === nothing
    @test get_val_at(m, b"romanus") === nothing

    # Remove branches at "ro"
    wz2 = write_zipper(m)
    wz_descend_to!(wz2, b"ro")
    @test wz_path_exists(wz2)
    wz_remove_branches!(wz2, true)
    @test !wz_path_exists(wz2)

    # Remove branches at long key prefix (data removed correctly)
    wz3 = write_zipper(m)
    wz_descend_to!(wz3, b"abcdefghijklmnopq")
    @test wz_path_exists(wz3)
    wz_remove_branches!(wz3, true)
    @test !wz_path_exists(wz3)
    @test !path_exists_at(m, b"abcdefghijklmnopqrstuvwxyz")
    @test !path_exists_at(m, b"abcdefghijklmnopq")
    # NOTE: Rust preserves prefix_buf path bytes after prune_path_internal
    # (path buffer untouched, only nodes modified). Julia's _wz_prune_path_internal!
    # uses wz_ascend! which modifies prefix_buf — known divergence from upstream.
end
