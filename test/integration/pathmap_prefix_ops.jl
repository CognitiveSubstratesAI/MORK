# test/integration/pathmap_prefix_ops.jl
# Ports write_zipper_insert_prefix_test + write_zipper_remove_prefix_test
# from PathMap/src/write_zipper.rs
using MORK, PathMap, Test

@testset "pathmap prefix ops" begin

    # ── insert_prefix ──────────────────────────────────────────────────
    @testset "insert_prefix" begin
        m = PathMap.PathMap{UInt64}()
        set_val_at!(m, b"123:Bob:Fido", UInt64(0))
        set_val_at!(m, b"123:Jim:Felix", UInt64(1))
        set_val_at!(m, b"123:Pam:Bandit", UInt64(2))
        set_val_at!(m, b"123:Sue:Cornelius", UInt64(3))

        wz = write_zipper_at_path(m, b"123:")
        result = wz_insert_prefix!(wz, b"pet:")
        @test result == true

        @test get_val_at(m, b"123:pet:Bob:Fido") == UInt64(0)
        @test get_val_at(m, b"123:pet:Jim:Felix") == UInt64(1)
        @test get_val_at(m, b"123:pet:Pam:Bandit") == UInt64(2)
        @test get_val_at(m, b"123:pet:Sue:Cornelius") == UInt64(3)
        # original paths gone
        @test get_val_at(m, b"123:Bob:Fido") === nothing

        # insert_prefix on empty focus returns false
        m2 = PathMap.PathMap{UInt64}()
        wz2 = write_zipper_at_path(m2, b"no:data:")
        @test wz_insert_prefix!(wz2, b"prefix:") == false
    end

    # ── remove_prefix ──────────────────────────────────────────────────
    @testset "remove_prefix — partial ascent" begin
        m = PathMap.PathMap{UInt64}()
        set_val_at!(m, b"123:Bob.Fido", UInt64(0))
        set_val_at!(m, b"123:Jim.Felix", UInt64(1))
        set_val_at!(m, b"123:Pam.Bandit", UInt64(2))
        set_val_at!(m, b"123:Sue.Cornelius", UInt64(3))

        wz = write_zipper_at_path(m, b"123")
        wz_descend_to!(wz, b":Pam")
        result = wz_remove_prefix!(wz, 4)   # strip ":Pam" (4 bytes)
        @test result == true

        # Only Pam's subtrie remains, lifted up by 4 bytes
        @test get_val_at(m, b"123.Bandit") == UInt64(2)
        # Others untouched
        @test PathMap.val_count(m) == 1
    end

    @testset "remove_prefix — CLAMPED at the zipper's own origin" begin
        # This testset previously asserted a "full ascent to root": that a zipper created AT
        # `pre:` could strip its own 4-byte origin, returning true. That encoded a PathMap bug,
        # not upstream's behaviour, and it kept the bug alive.
        #
        # Upstream `WriteZipperCore::remove_prefix` (write_zipper.rs:1866) is
        #     let downstream = self.get_focus().into_option();
        #     let fully_ascended = self.ascend(n);
        #     self.graft_internal(downstream);
        #     fully_ascended
        # and `ascend` CLAMPS at the zipper root — `at_root()` is
        # `prefix_buf.len() <= origin_path.len()` (:1002). A zipper built by
        # `write_zipper_at_path(m, "pre:")` is ALREADY at its origin, so nothing moves, the
        # subtrie is grafted back where it was, and the call returns FALSE.
        #
        # Settled by execution against the upstream Rust binary, not by argument — see
        # PathMap/test/differential, scenarios `prefix/remove_prefix_full_ascent_at_origin`
        # (`[pre:alpha,pre:beta] vc=2`) and `..._ret` (`false`).
        m = PathMap.PathMap{UInt64}()
        set_val_at!(m, b"pre:alpha", UInt64(10))
        set_val_at!(m, b"pre:beta", UInt64(20))

        wz = write_zipper_at_path(m, b"pre:")
        result = wz_remove_prefix!(wz, 4)   # cannot ascend above the origin
        @test result == false

        # The map is untouched.
        @test get_val_at(m, b"pre:alpha") == UInt64(10)
        @test get_val_at(m, b"pre:beta") == UInt64(20)
        @test get_val_at(m, b"alpha") === nothing
        @test PathMap.val_count(m) == 2
    end

    println("All prefix ops tests passed.")
end

# ── Regression: insert_prefix on single-value map (Int32) ────────
# Bug: set_recursive in LineListNode used `res === nothing` instead of
# `res isa TrieNodeODRc`, passing Bool to SetPayloadUpgrade constructor.
# Triggered when new key is a strict prefix of an existing value key.
@testset "insert_prefix regression — key prefix of existing value key" begin
    m = PathMap.PathMap{UInt32}()
    set_val_at!(m, b"foo:bar", UInt32(99))
    wz = write_zipper_at_path(m, b"foo:")
    @test wz_insert_prefix!(wz, b"ns:") == true
    # `ns:foo:bar` is only producible from a ROOT zipper; this test inserts through
    # write_zipper_at_path(m, b"foo:"), so the prefix lands INSIDE that subtree -> `foo:ns:bar`.
    # Verified byte-identical to upstream PathMap (write_zipper.rs:1841-1851): ours and upstream
    # both give get(ns:foo:bar)=None, get(foo:ns:bar)=Some(99).
    @test get_val_at(m, b"foo:ns:bar") == UInt32(99)
    @test get_val_at(m, b"foo:bar") === nothing
end
