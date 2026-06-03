# Test lazy COW for WriteZipper — validates A.0004 implementation.
# Run from warm REPL: include("/tmp/test_lazy_cow.jl")
using MORK, PathMap, Test

@testset "lazy_cow_writezipper" begin

    # ── Scenario 1: graft_map + write through zipper must not corrupt original ──
    m1 = PathMap.PathMap{UInt32}()
    set_val_at!(m1, b"hello", UInt32(42))
    set_val_at!(m1, b"hello_world", UInt32(7))

    # Graft m1 into m2 under "prefix:"
    m2 = PathMap.PathMap{UInt32}()
    wz2 = write_zipper(m2)
    wz_descend_to!(wz2, b"prefix:")
    wz_graft_map!(wz2, m1)

    # Verify graft is readable
    @test get_val_at(m2, b"prefix:hello") == UInt32(42)
    @test get_val_at(m2, b"prefix:hello_world") == UInt32(7)

    # Now write through m2 — must NOT corrupt m1
    wz3 = write_zipper(m2)
    wz_descend_to!(wz3, b"prefix:hello")
    wz_set_val!(wz3, UInt32(99))

    @test get_val_at(m2, b"prefix:hello") == UInt32(99)   # m2 updated
    @test get_val_at(m1, b"hello") == UInt32(42)  # m1 unchanged

    # ── Scenario 2: second value in shared subtrie also independent ──
    wz4 = write_zipper(m2)
    wz_descend_to!(wz4, b"prefix:hello_world")
    wz_set_val!(wz4, UInt32(100))

    @test get_val_at(m2, b"prefix:hello_world") == UInt32(100)
    @test get_val_at(m1, b"hello_world") == UInt32(7)   # m1 still unchanged

    # ── Scenario 3: join_map_into must not corrupt source ──
    m3 = PathMap.PathMap{UInt32}()
    set_val_at!(m3, b"foo", UInt32(1))

    m4 = PathMap.PathMap{UInt32}()
    wz6 = write_zipper(m4)
    wz_join_map_into!(wz6, m3)

    # Write to m4
    wz7 = write_zipper(m4)
    wz_descend_to!(wz7, b"foo")
    wz_set_val!(wz7, UInt32(999))

    @test get_val_at(m4, b"foo") == UInt32(999)
    @test get_val_at(m3, b"foo") == UInt32(1)   # m3 unchanged

    println("All lazy COW tests passed.")
end
