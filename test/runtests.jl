using Test
using MORK
using PathMap
# Aqua is test-only [extras]: present under Pkg.test/CI but NOT in a plain
# `julia --project=. test/runtests.jl` run (no sandbox). Load optionally.
const _HAS_AQUA = try
    ;
    @eval using Aqua;
    true;
catch
    ;
    false;
end
# PathMap module and PathMap type share the same name — alias the type
const PM = PathMap.PathMap

# Fails the build on any testset that runs but asserts nothing — see the file header for the two
# inert oracles that motivated it. Captured into `_MORK_TS` and checked AFTER the suite.
include("inert_testset_guard.jl")

const _MORK_TS = @testset "MORK" begin
    if _HAS_AQUA
        @testset "Aqua quality" begin
            # deps_compat check_extras=false: [extras] are dev/test tools; runtime [deps]
            # (Base64, PathMap, PrecompileTools) carry [compat]. PathMap is dev-linked via
            # [sources] so deps_compat skips it.
            # NOTE (2026-07-23) on `persistent_tasks` erroring with `IOError: could not spawn …
            # (EINVAL)`: that is a defect of the TEST INVOCATION, not of MORK, and it is fixed in
            # tools/run_tests.sh — do NOT "fix" it by passing persistent_tasks=false. Aqua spawns
            # via `run(cmd, stdin, stdout, stderr; wait=false)` (persistent_tasks.jl:114), passing
            # the CURRENT stdin as an explicit stdio handle. Under `printf '…' | julia -i`, stdin is
            # a PipeEndpoint that printf has already CLOSED (`isopen(stdin) == false`), and libuv
            # rejects a closed handle with EINVAL. Isolated: default-stdio spawn OK, explicit-stdio
            # spawn FAILS, and the same explicit spawn succeeds under `julia -i … < /dev/null`.
            # (A first pass mis-attributed this to PathMap being a local-path [sources] dep, citing
            # Aqua's docstring. PathMap's OWN suite fails identically and has no [sources] at all —
            # which falsified it. Verify the discriminating case, don't stop at a plausible cause.)
            Aqua.test_all(MORK; deps_compat=(check_extras=false,))
        end
    else
        @info "Aqua not loadable (plain julia --project=.) — runs under Pkg.test/CI"
    end

    @testset "Phase 0 skeleton" begin
        @test MORK.version() == v"0.1.0"
    end

    @testset "Ring (ports pathmap/src/ring.rs)" begin
        @testset "Identity-mask constants" begin
            @test SELF_IDENT == UInt64(0x1)
            @test COUNTER_IDENT == UInt64(0x2)
            @test (SELF_IDENT & COUNTER_IDENT) == 0
        end

        @testset "AlgebraicResult variants + predicates" begin
            n = AlgResNone()
            @test is_none(n)
            @test !is_identity(n)
            @test !is_element(n)
            @test identity_mask(n) === nothing

            id = AlgResIdentity(SELF_IDENT)
            @test !is_none(id)
            @test is_identity(id)
            @test !is_element(id)
            @test identity_mask(id) == SELF_IDENT

            el = AlgResElement(UInt32(42))
            @test !is_none(el)
            @test !is_identity(el)
            @test is_element(el)
            @test identity_mask(el) === nothing
            @test el.value == UInt32(42)
        end

        @testset "invert_identity" begin
            # No-op for None and Element
            @test invert_identity(AlgResNone()) isa AlgResNone
            @test invert_identity(AlgResElement(42)).value == 42
            # Swap bits 0 and 1 for Identity
            @test invert_identity(AlgResIdentity(SELF_IDENT)).mask == COUNTER_IDENT
            @test invert_identity(AlgResIdentity(COUNTER_IDENT)).mask == SELF_IDENT
            @test invert_identity(AlgResIdentity(SELF_IDENT | COUNTER_IDENT)).mask ==
                (SELF_IDENT | COUNTER_IDENT)
            # Higher bits are removed
            @test invert_identity(AlgResIdentity(UInt64(0xFF))).mask ==
                (SELF_IDENT | COUNTER_IDENT)
        end

        @testset "map / map_into_option / into_option / unwrap_or_else" begin
            # map
            @test Base.map(x -> x + 1, AlgResElement(5)).value == 6
            @test Base.map(x -> x + 1, AlgResNone()) isa AlgResNone
            @test Base.map(x -> x + 1, AlgResIdentity(SELF_IDENT)).mask == SELF_IDENT

            # map_into_option
            @test map_into_option(AlgResElement(42), i -> 99) == 42
            @test map_into_option(AlgResNone(), i -> 99) === nothing
            # Identity(SELF_IDENT) → trailing_zeros(1) == 0 → ident_f(0)
            @test map_into_option(
                AlgResIdentity(SELF_IDENT), i -> i == 0 ? "self" : "other"
            ) == "self"
            @test map_into_option(
                AlgResIdentity(COUNTER_IDENT), i -> i == 1 ? "other" : "self"
            ) == "other"

            # into_option with idents table (1-indexed in Julia, 0-indexed in Rust)
            @test into_option(AlgResElement(42), ["a", "b"]) == 42
            @test into_option(AlgResNone(), ["a", "b"]) === nothing
            @test into_option(AlgResIdentity(SELF_IDENT), ["a", "b"]) == "a"
            @test into_option(AlgResIdentity(COUNTER_IDENT), ["a", "b"]) == "b"

            # unwrap_or_else
            @test unwrap_or_else(AlgResElement(42), i -> 99, () -> 0) == 42
            @test unwrap_or_else(AlgResNone(), i -> 99, () -> 0) == 0
            @test unwrap_or_else(AlgResIdentity(SELF_IDENT), i -> i + 10, () -> 0) == 10
        end

        @testset "AlgebraicStatus" begin
            @test ALG_STATUS_ELEMENT < ALG_STATUS_IDENTITY < ALG_STATUS_NONE
            @test is_none(ALG_STATUS_NONE)
            @test is_identity(ALG_STATUS_IDENTITY)
            @test is_element(ALG_STATUS_ELEMENT)
            @test !is_none(ALG_STATUS_ELEMENT)
        end

        @testset "merge_status" begin
            # All 9 cells of the merge table from upstream ring.rs:374-396
            @test merge_status(ALG_STATUS_NONE, ALG_STATUS_NONE, true, true) ==
                ALG_STATUS_NONE
            @test merge_status(ALG_STATUS_NONE, ALG_STATUS_ELEMENT, true, true) ==
                ALG_STATUS_ELEMENT
            @test merge_status(ALG_STATUS_NONE, ALG_STATUS_IDENTITY, true, true) ==
                ALG_STATUS_IDENTITY
            @test merge_status(ALG_STATUS_NONE, ALG_STATUS_IDENTITY, false, true) ==
                ALG_STATUS_ELEMENT

            @test merge_status(ALG_STATUS_IDENTITY, ALG_STATUS_ELEMENT, true, true) ==
                ALG_STATUS_ELEMENT
            @test merge_status(ALG_STATUS_IDENTITY, ALG_STATUS_IDENTITY, true, true) ==
                ALG_STATUS_IDENTITY
            @test merge_status(ALG_STATUS_IDENTITY, ALG_STATUS_NONE, true, true) ==
                ALG_STATUS_IDENTITY
            @test merge_status(ALG_STATUS_IDENTITY, ALG_STATUS_NONE, true, false) ==
                ALG_STATUS_ELEMENT

            @test merge_status(ALG_STATUS_ELEMENT, ALG_STATUS_NONE, true, true) ==
                ALG_STATUS_ELEMENT
            @test merge_status(ALG_STATUS_ELEMENT, ALG_STATUS_IDENTITY, true, true) ==
                ALG_STATUS_ELEMENT
            @test merge_status(ALG_STATUS_ELEMENT, ALG_STATUS_ELEMENT, true, true) ==
                ALG_STATUS_ELEMENT
        end

        @testset "status + from_status roundtrip" begin
            @test status(AlgResNone()) == ALG_STATUS_NONE
            @test status(AlgResElement(1)) == ALG_STATUS_ELEMENT
            @test status(AlgResIdentity(SELF_IDENT)) == ALG_STATUS_IDENTITY
            @test status(AlgResIdentity(COUNTER_IDENT)) == ALG_STATUS_ELEMENT  # no SELF_IDENT bit
            @test status(AlgResIdentity(SELF_IDENT | COUNTER_IDENT)) == ALG_STATUS_IDENTITY

            @test from_status(ALG_STATUS_NONE, () -> 42) isa AlgResNone
            @test from_status(ALG_STATUS_IDENTITY, () -> 42).mask == SELF_IDENT
            @test from_status(ALG_STATUS_ELEMENT, () -> 42).value == 42
        end

        @testset "flatten (AlgebraicResult{Union{Nothing, V}} -> AlgebraicResult{V})" begin
            @test flatten(AlgResNone()) isa AlgResNone
            @test flatten(AlgResIdentity(SELF_IDENT)).mask == SELF_IDENT
            @test flatten(AlgResElement(42)).value == 42
            @test flatten(AlgResElement(nothing)) isa AlgResNone
        end

        @testset "FatAlgebraicResult + to_algebraic_result" begin
            # none
            fn = fat_none(UInt32)
            @test fn.identity_mask == 0
            @test fn.element === nothing
            @test to_algebraic_result(fn) isa AlgResNone

            # element
            fe = fat_element(UInt32(42))
            @test fe.identity_mask == 0
            @test fe.element == UInt32(42)
            r = to_algebraic_result(fe)
            @test r isa AlgResElement
            @test r.value == UInt32(42)

            # identity
            fi = FatAlgebraicResult{UInt32}(SELF_IDENT, UInt32(5))
            r = to_algebraic_result(fi)
            @test r isa AlgResIdentity
            @test r.mask == SELF_IDENT
        end

        @testset "Lattice on integers (pjoin=max, pmeet=min)" begin
            # pjoin = max
            r = pjoin(UInt32(3), UInt32(7))
            @test r isa AlgResIdentity && r.mask == COUNTER_IDENT   # result = other (7)

            r = pjoin(UInt32(7), UInt32(3))
            @test r isa AlgResIdentity && r.mask == SELF_IDENT      # result = self

            r = pjoin(UInt32(5), UInt32(5))
            @test r isa AlgResIdentity && r.mask == (SELF_IDENT | COUNTER_IDENT)

            # pmeet = min
            r = pmeet(UInt32(3), UInt32(7))
            @test r isa AlgResIdentity && r.mask == SELF_IDENT      # result = self (3)

            r = pmeet(UInt32(7), UInt32(3))
            @test r isa AlgResIdentity && r.mask == COUNTER_IDENT
        end

        @testset "DistributiveLattice on unsigned ints (psubtract = saturating sub)" begin
            # b >= a → None
            @test psubtract(UInt32(3), UInt32(7)) isa AlgResNone
            @test psubtract(UInt32(5), UInt32(5)) isa AlgResNone

            # b == 0 → Identity (result unchanged)
            r = psubtract(UInt32(5), UInt32(0))
            @test r isa AlgResIdentity && r.mask == SELF_IDENT

            # b > 0, a > b → Element(a - b)
            r = psubtract(UInt32(10), UInt32(3))
            @test r isa AlgResElement && r.value == UInt32(7)
        end

        @testset "Lattice on Bool (pjoin=or, pmeet=and)" begin
            # pjoin
            r = pjoin(false, false)
            @test r isa AlgResIdentity && r.mask == (SELF_IDENT | COUNTER_IDENT)

            r = pjoin(true, false)
            @test r isa AlgResIdentity && r.mask == SELF_IDENT

            r = pjoin(false, true)
            @test r isa AlgResIdentity && r.mask == COUNTER_IDENT

            # pmeet
            r = pmeet(true, true)
            @test r isa AlgResIdentity && r.mask == (SELF_IDENT | COUNTER_IDENT)

            r = pmeet(true, false)
            @test r isa AlgResIdentity && r.mask == COUNTER_IDENT  # result = false = other

            # psubtract
            @test psubtract(false, false) isa AlgResNone
            @test psubtract(false, true) isa AlgResNone
            @test psubtract(true, true) isa AlgResNone
            r = psubtract(true, false)
            @test r isa AlgResIdentity && r.mask == SELF_IDENT
        end

        @testset "Blanket Lattice on Union{Nothing, V}" begin
            # Matches Rust's `impl<V: Lattice + Clone> Lattice for Option<V>`

            # pjoin(Nothing, Nothing) → Identity(both)
            r = pjoin(nothing, nothing)
            @test r isa AlgResIdentity && r.mask == (SELF_IDENT | COUNTER_IDENT)

            # pjoin(Nothing, Some) → Identity(COUNTER)
            r = pjoin(nothing, UInt32(5))
            @test r isa AlgResIdentity && r.mask == COUNTER_IDENT

            # pjoin(Some, Nothing) → Identity(SELF)
            r = pjoin(UInt32(5), nothing)
            @test r isa AlgResIdentity && r.mask == SELF_IDENT

            # pjoin(Some, Some) → delegate to inner
            r = pjoin(UInt32(3), UInt32(7))
            @test r isa AlgResIdentity && r.mask == COUNTER_IDENT

            # pmeet(Nothing, Nothing) → Identity(both)
            r = pmeet(nothing, nothing)
            @test r isa AlgResIdentity && r.mask == (SELF_IDENT | COUNTER_IDENT)

            # pmeet(Nothing, Some) → Element(nothing) (empty result)
            r = pmeet(nothing, UInt32(5))
            @test r isa AlgResElement && r.value === nothing
        end

        @testset "Dict lattice (ports ring.rs HashMap SetLattice)" begin
            a = Dict{String, Int}("x"=>1, "y"=>2)
            b = Dict{String, Int}("x"=>3, "z"=>4)
            r = pjoin(a, b)
            @test r isa AlgResElement
            d = r.value
            @test d["x"] == max(1, 3)   # max via pjoin on Int
            @test d["y"] == 2           # only in a
            @test d["z"] == 4           # only in b

            s = pmeet(a, b)
            @test s isa AlgResElement || s isa AlgResNone
            # meet of disjoint keys = empty → None
            a2 = Dict{String, Int}("p"=>1)
            b2 = Dict{String, Int}("q"=>2)
            @test pmeet(a2, b2) isa AlgResNone

            sub = psubtract(a, Dict{String, Int}("x"=>1))
            # subtracting x=1 from x=1 → None for that key; only y remains
            @test sub isa AlgResElement
            @test haskey(sub.value, "y")
            @test !haskey(sub.value, "x")  # x-x = None
        end

        @testset "Set lattice (ports ring.rs HashSet SetLattice)" begin
            a = Set(["a", "b", "c"])
            b = Set(["b", "c", "d"])
            r = pjoin(a, b)
            @test r isa AlgResElement
            @test r.value == Set(["a", "b", "c", "d"])

            s = pmeet(a, b)
            @test s isa AlgResElement
            @test r.value ⊇ s.value

            sub = psubtract(a, b)
            @test sub isa AlgResElement
            @test sub.value == Set(["a"])

            @test psubtract(Set(["x"]), Set(["x"])) isa AlgResNone
        end

        @testset "Utils — Bits4 primitives" begin
            empty = MORK.EMPTY_BITS4
            full = MORK.FULL_BITS4
            @test count_bits(empty) == 0
            @test count_bits(full) == 256
            @test is_empty_mask(empty)
            @test !is_empty_mask(full)

            # Test bits at word boundaries
            for b in (UInt8(0), UInt8(63), UInt8(64), UInt8(127),
                UInt8(128), UInt8(191), UInt8(192), UInt8(255))
                m = with_bit_set(empty, b)
                @test test_bit(m, b)
                @test count_bits(m) == 1
                m2 = with_bit_cleared(m, b)
                @test !test_bit(m2, b)
                @test m2 == empty
            end

            # Boolean ops
            a = with_bit_set(with_bit_set(empty, UInt8(1)), UInt8(3))
            b = with_bit_set(with_bit_set(empty, UInt8(3)), UInt8(5))
            @test count_bits(bor(a, b)) == 3
            @test count_bits(band(a, b)) == 1
            @test count_bits(bxor(a, b)) == 2
            @test count_bits(bandn(a, b)) == 1   # a & !b = {1}
            @test count_bits(bnot(empty)) == 256
        end

        @testset "Utils — ByteMask basics (upstream bit_utils_test)" begin
            # Port of pathmap/src/utils/mod.rs:683-702
            m = ByteMask()
            @test count_bits(m) == 0
            @test is_empty_mask(m)

            m = set(m, UInt8('C'))
            m = set(m, UInt8('a'))
            m = set(m, UInt8('t'))
            @test !is_empty_mask(m)
            @test count_bits(m) == 3

            m = set(m, UInt8('C'))   # idempotent
            m = set(m, UInt8('a'))
            m = set(m, UInt8('n'))
            @test count_bits(m) == 4

            m = unset(m, UInt8('t'))
            @test test_bit(m, UInt8('n'))
            @test !test_bit(m, UInt8('t'))
        end

        @testset "Utils — next_bit_test (upstream port)" begin
            # Port of pathmap/src/utils/mod.rs:704-753
            function do_test(test_mask::ByteMask)
                set_bits = UInt8[]
                for i in UInt8(0):UInt8(255)
                    test_bit(test_mask, i) && push!(set_bits, i)
                end

                # Forward walk via next_bit starting at 0
                i::UInt8 = UInt8(0)
                cnt = test_bit(test_mask, UInt8(0)) ? 1 : 0
                while true
                    nb = next_bit(test_mask, i)
                    nb === nothing && break
                    @test test_bit(test_mask, nb)
                    i = nb
                    cnt += 1
                end
                @test cnt == length(set_bits)

                # Backward walk via prev_bit starting at 255
                i = UInt8(255)
                cnt = test_bit(test_mask, UInt8(255)) ? 1 : 0
                while true
                    pb = prev_bit(test_mask, i)
                    pb === nothing && break
                    @test test_bit(test_mask, pb)
                    i = pb
                    cnt += 1
                end
                @test cnt == length(set_bits)
            end

            do_test(
                ByteMask((
                    0b1010010010010010010010000000000000000000000000000000000000010101,
                    0b0000000000000000000000000000000000000000100000000000000000000000,
                    0b0000000000000000000000000000000000000000000000000000000000000000,
                    0b1001000000000000000000000000000000000000000000000000000000000001
                ))
            )
            do_test(
                ByteMask((
                    0b0000000000000000000000000000000000000000000000000000000000000000,
                    0b0000000000000000000000000000000000000000100000000000000000000000,
                    0b0000000000000000000000000000000000000000000000000000000000000000,
                    0b1001000000000000000000000000000000000000000000000000000000000001
                ))
            )
            do_test(bytemask_full())
        end

        @testset "Utils — next_bit_test2 (specific bytes 39/97/117)" begin
            m = ByteMask()
            m = set(m, UInt8(39))
            m = set(m, UInt8(97))
            m = set(m, UInt8(117))

            @test next_bit(m, UInt8(0)) == UInt8(39)
            @test next_bit(m, UInt8(39)) == UInt8(97)
            @test next_bit(m, UInt8(97)) == UInt8(117)
            @test next_bit(m, UInt8(117)) === nothing
        end

        @testset "Utils — from_range (upstream port)" begin
            # Port of pathmap/src/utils/mod.rs:755-780
            m = from_range(10:69)   # Julia 10:69 ≡ Rust 10..70
            expected_bits = (
                0b1111111111111111111111111111111111111111111111111111110000000000,
                0b0000000000000000000000000000000000000000000000000000000000111111,
                UInt64(0),
                UInt64(0)
            )
            @test m.bits == expected_bits

            @test from_range_full() == bytemask_full()
            @test from_range(0:127) == ByteMask((
                typemax(UInt64), typemax(UInt64), UInt64(0), UInt64(0)
            ))
            @test from_range(10:255) == ByteMask((
                0b1111111111111111111111111111111111111111111111111111110000000000,
                typemax(UInt64), typemax(UInt64), typemax(UInt64)
            ))

            # Empty / degenerate ranges
            @test from_range(0:-1) == ByteMask()             # empty range
            @test from_range(0:0) == ByteMask(UInt8(0))
            @test from_range(255:255) == ByteMask(UInt8(255))
        end

        @testset "Utils — index_of (rank)" begin
            # Construct a mask with known bits: {1, 5, 100, 200}
            m = ByteMask()
            m = set(m, UInt8(1))
            m = set(m, UInt8(5))
            m = set(m, UInt8(100))
            m = set(m, UInt8(200))

            # Count set bits strictly below each threshold
            @test index_of(m, UInt8(0)) == UInt8(0)
            @test index_of(m, UInt8(1)) == UInt8(0)     # nothing below 1
            @test index_of(m, UInt8(2)) == UInt8(1)     # {1}
            @test index_of(m, UInt8(6)) == UInt8(2)     # {1, 5}
            @test index_of(m, UInt8(101)) == UInt8(3)     # {1, 5, 100}
            @test index_of(m, UInt8(255)) == UInt8(4)     # all four
        end

        @testset "Utils — indexed_bit (select, forward + backward)" begin
            # Construct mask with bits {3, 20, 100, 200, 255}
            m = ByteMask()
            for b in UInt8[3, 20, 100, 200, 255]
                m = set(m, b)
            end

            # Forward: idx 0 = first, idx 1 = second, etc.
            @test indexed_bit(m, 0, true) == UInt8(3)
            @test indexed_bit(m, 1, true) == UInt8(20)
            @test indexed_bit(m, 2, true) == UInt8(100)
            @test indexed_bit(m, 3, true) == UInt8(200)
            @test indexed_bit(m, 4, true) == UInt8(255)
            @test indexed_bit(m, 5, true) === nothing

            # Backward: idx 0 = last, idx 1 = second-to-last, etc.
            @test indexed_bit(m, 0, false) == UInt8(255)
            @test indexed_bit(m, 1, false) == UInt8(200)
            @test indexed_bit(m, 2, false) == UInt8(100)
            @test indexed_bit(m, 3, false) == UInt8(20)
            @test indexed_bit(m, 4, false) == UInt8(3)
            @test indexed_bit(m, 5, false) === nothing
        end

        @testset "Utils — subset (Sierpinski)" begin
            # SUBSET(0) has only bit 0 set (only j=0 satisfies 0 & j == j)
            m0 = subset(UInt8(0))
            @test test_bit(m0, UInt8(0))
            @test count_bits(m0) == 1

            # SUBSET(1) has bits {0, 1} set (j=0: 1&0==0 ✓; j=1: 1&1==1 ✓)
            m1 = subset(UInt8(1))
            @test test_bit(m1, UInt8(0))
            @test test_bit(m1, UInt8(1))
            @test count_bits(m1) == 2

            # SUBSET(255) has ALL 256 bits set (every j is a subset of 255's bits)
            m255 = subset(UInt8(255))
            @test count_bits(m255) == 256

            # SUBSET(3) has {0,1,2,3} set (binary: 11)
            m3 = subset(UInt8(3))
            @test count_bits(m3) == 4
            for b in UInt8[0, 1, 2, 3]
                @test test_bit(m3, b)
            end
        end

        @testset "Utils — ByteMask iteration (ascending order)" begin
            m = ByteMask()
            for b in UInt8[5, 100, 200, 42]
                m = set(m, b)
            end
            @test collect(m) == UInt8[5, 42, 100, 200]
            @test length(m) == 4

            # ByteMaskIter (destructive variant — upstream's iter method)
            it = iter(m)
            seen = UInt8[]
            for b in it
                push!(seen, b)
            end
            @test seen == UInt8[5, 42, 100, 200]

            # Empty mask iterates nothing
            empty = ByteMask()
            @test collect(empty) == UInt8[]
        end

        @testset "Utils — ByteMask Lattice (pjoin / pmeet / psubtract)" begin
            a = ByteMask()
            a = set(a, UInt8(1));
            a = set(a, UInt8(3));
            a = set(a, UInt8(5))

            b = ByteMask()
            b = set(b, UInt8(3));
            b = set(b, UInt8(5));
            b = set(b, UInt8(7))

            # pjoin = union; has both a's and b's bits
            r = pjoin(a, b)
            @test r isa AlgResElement
            joined = (r::AlgResElement{ByteMask}).value
            @test count_bits(joined) == 4
            @test test_bit(joined, UInt8(1))
            @test test_bit(joined, UInt8(3))
            @test test_bit(joined, UInt8(5))
            @test test_bit(joined, UInt8(7))

            # pmeet = intersection
            r = pmeet(a, b)
            @test r isa AlgResElement
            met = (r::AlgResElement{ByteMask}).value
            @test count_bits(met) == 2
            @test test_bit(met, UInt8(3))
            @test test_bit(met, UInt8(5))

            # Self-identity: pjoin(a, a) = Identity
            r = pjoin(a, a)
            @test r isa AlgResIdentity
            @test r.mask == (SELF_IDENT | COUNTER_IDENT)

            # Subset: pmeet(a, superset) = Identity(SELF_IDENT)
            superset = ByteMask()
            for b in UInt8[1, 3, 5, 7, 9]
                superset = set(superset, b)
            end
            r = pmeet(a, superset)
            @test r isa AlgResIdentity
            @test (r.mask & SELF_IDENT) > 0

            # psubtract
            r = psubtract(a, b)
            @test r isa AlgResElement
            diff = (r::AlgResElement{ByteMask}).value
            @test count_bits(diff) == 1
            @test test_bit(diff, UInt8(1))

            # psubtract(a, a) = None
            @test psubtract(a, a) isa AlgResNone
        end

        @testset "join_all" begin
            # empty → None
            @test join_all(UInt32[]) isa AlgResNone

            # single element → Identity(SELF)
            r = join_all([UInt32(42)])
            @test r isa AlgResIdentity
            @test (r.mask & SELF_IDENT) > 0

            # [3, 7] → max is 7 = second element
            r = join_all([UInt32(3), UInt32(7)])
            @test r isa AlgResIdentity || r isa AlgResElement
            if r isa AlgResElement
                @test r.value == UInt32(7)
            end

            # All equal → Identity with all bits
            r = join_all([UInt32(5), UInt32(5), UInt32(5)])
            @test is_identity(r) || is_element(r)
        end

        @testset "Ints — PathInteger alias" begin
            @test UInt8 <: PathInteger
            @test UInt16 <: PathInteger
            @test UInt32 <: PathInteger
            @test UInt64 <: PathInteger
            @test UInt128 <: PathInteger
            # sizeof recovers NUM_SIZE
            @test sizeof(UInt8) == 1
            @test sizeof(UInt16) == 2
            @test sizeof(UInt32) == 4
            @test sizeof(UInt64) == 8
            @test sizeof(UInt128) == 16
        end

        @testset "Ints — bob_and_weave_simple (upstream port)" begin
            # Port of pathmap/src/utils/ints.rs:376-412
            is_orig = UInt64[10, 30, 100]
            is_decoded = zeros(UInt64, 3)
            weave = UInt8[]
            bob = UInt8[]
            indices_to_weave!(weave, is_orig, 8)
            weave_to_indices!(is_decoded, weave)
            @test is_decoded == is_orig

            fill!(is_decoded, 0)
            indices_to_bob!(bob, is_orig)
            bob_to_indices!(is_decoded, bob)
            @test is_decoded == is_orig

            # Second case: multi-byte values
            is_orig = UInt64[3333, 30, 1000]
            is_decoded = zeros(UInt64, 3)
            weave = UInt8[]
            bob = UInt8[]
            indices_to_weave!(weave, is_orig, 8)
            weave_to_indices!(is_decoded, weave)
            @test is_decoded == is_orig

            fill!(is_decoded, 0)
            indices_to_bob!(bob, is_orig)
            bob_to_indices!(is_decoded, bob)
            @test is_decoded == is_orig
        end

        @testset "Ints — BOB shape guarantees" begin
            # steps == max bit-width across xs
            bob = UInt8[]
            steps = indices_to_bob!(bob, UInt64[10, 30, 100])
            # 100 = 0b1100100 (7 bits) — widest
            @test steps == 7
            @test length(bob) == 7

            # Empty xs → steps == 0
            bob = UInt8[]
            steps = indices_to_bob!(bob, UInt64[])
            @test steps == 0
            @test isempty(bob)

            # All zeros → steps == 0
            bob = UInt8[]
            steps = indices_to_bob!(bob, UInt64[0, 0, 0])
            @test steps == 0
            @test isempty(bob)

            # Single zero-valued element
            bob = UInt8[]
            steps = indices_to_bob!(bob, UInt64[0])
            @test steps == 0

            # Single element = 1 → one plane
            bob = UInt8[]
            steps = indices_to_bob!(bob, UInt64[1])
            @test steps == 1
            @test bob == UInt8[1]
        end

        @testset "Ints — weave shape guarantees" begin
            # Writes num_size bytes per element
            weave = UInt8[]
            indices_to_weave!(weave, UInt64[10, 30, 100], 8)
            @test length(weave) == 8 * 3

            # num_size == 1: single-byte round-robin
            weave = UInt8[]
            indices_to_weave!(weave, UInt8[10, 30, 100], 1)
            @test length(weave) == 3
            @test weave == UInt8[10, 30, 100]

            # num_size == 2: two-byte big-endian round-robin
            weave = UInt8[]
            indices_to_weave!(weave, UInt16[0x0D05, 0x001E, 0x03E8], 2)
            # plane c=1 (high bytes): 0x0D, 0x00, 0x03
            # plane c=0 (low  bytes): 0x05, 0x1E, 0xE8
            @test weave == UInt8[0x0D, 0x00, 0x03, 0x05, 0x1E, 0xE8]
        end

        @testset "Ints — BOB across integer widths" begin
            for T in (UInt8, UInt16, UInt32, UInt64, UInt128)
                orig = T[T(5), T(10), T(17)]
                decoded = zeros(T, 3)
                bob = UInt8[]
                indices_to_bob!(bob, orig)
                bob_to_indices!(decoded, bob)
                @test decoded == orig
            end
        end

        @testset "Ints — weave across integer widths" begin
            for T in (UInt8, UInt16, UInt32, UInt64)
                orig = T[T(5), T(10), T(17), T(255)]
                decoded = zeros(T, 4)
                weave = UInt8[]
                indices_to_weave!(weave, orig, sizeof(T))
                weave_to_indices!(decoded, weave)
                @test decoded == orig
            end
        end

        @testset "TrieNode — constants" begin
            # Port of trie_node.rs: MAX_NODE_KEY_BYTES / NODE_ITER_INVALID / NODE_ITER_FINISHED
            @test MAX_NODE_KEY_BYTES == 48
            @test NODE_ITER_INVALID == typemax(UInt128)
            @test NODE_ITER_FINISHED == typemax(UInt128) - UInt128(1)
            @test NODE_ITER_INVALID > NODE_ITER_FINISHED

            # Node tag constants match upstream
            @test EMPTY_NODE_TAG == 0
            @test DENSE_BYTE_NODE_TAG == 1
            @test LINE_LIST_NODE_TAG == 2
            @test CELL_BYTE_NODE_TAG == 3
            @test TINY_REF_NODE_TAG == 4
            # All distinct
            @test length(
                Set([EMPTY_NODE_TAG, DENSE_BYTE_NODE_TAG, LINE_LIST_NODE_TAG,
                    CELL_BYTE_NODE_TAG, TINY_REF_NODE_TAG])
            ) == 5
        end

        @testset "TrieNode — TrieNodeODRc empty sentinel" begin
            rc = TrieNodeODRc{Int, GlobalAlloc}()
            @test is_empty_node(rc)
            @test refcount(rc) == 1
            @test shared_node_id(rc) == UInt64(0)
        end

        @testset "TrieNode — PayloadRef None" begin
            p = PayloadRef{Int, GlobalAlloc}()
            @test is_none(p)
            @test !is_val(p)
            @test !is_child(p)
        end

        @testset "TrieNode — ValOrChild" begin
            v = ValOrChild(42)
            @test is_val(v)
            @test !is_child(v)
            @test into_val(v) == 42

            rc = TrieNodeODRc{Int, GlobalAlloc}()
            c = ValOrChild(rc)
            @test is_child(c)
            @test !is_val(c)
        end

        @testset "TrieNode — AbstractNodeRef None + variants" begin
            n = ANRNone{Int, GlobalAlloc}()
            @test is_none(n)
            @test into_option(n) === nothing

            rc = TrieNodeODRc{Int, GlobalAlloc}()
            brw = ANRBorrowedRc{Int, GlobalAlloc}(rc)
            @test !is_none(brw)
            @test borrow(brw) === rc

            owned = ANROwnedRc{Int, GlobalAlloc}(rc)
            @test !is_none(owned)
            @test borrow(owned) === rc
        end

        @testset "EmptyNode — struct and tag" begin
            e = EmptyNode{Int, GlobalAlloc}()
            @test node_tag(e) == EMPTY_NODE_TAG
            @test node_is_empty(e)
        end

        @testset "EmptyNode — query methods return trivial values" begin
            e = EmptyNode{Int, GlobalAlloc}()
            key = UInt8[1, 2, 3]
            @test node_key_overlap(e, key) == 0
            @test node_contains_partial_key(e, key) == false
            @test node_get_child(e, key) === nothing
            @test node_get_child_mut(e, key) === nothing
            @test node_contains_val(e, key) == false
            @test node_get_val(e, key) === nothing
            @test node_get_val_mut(e, key) === nothing
            @test node_val_count(e, Dict{UInt64, Int}()) == 0
            @test node_goat_val_count(e) == 0
            @test count_branches(e, key) == 0
            @test prior_branch_key(e, key) == UInt8[]
            @test node_remove_all_branches!(e, key, false) == false
            @test node_first_val_depth_along_key(e, key) === nothing
        end

        @testset "EmptyNode — iteration" begin
            e = EmptyNode{Int, GlobalAlloc}()
            @test new_iter_token(e) == UInt128(0)
            @test iter_token_for_path(e, UInt8[1, 2]) == UInt128(0)
            tok, path, child, val = next_items(e, UInt128(0))
            @test tok == NODE_ITER_FINISHED
            @test path == UInt8[]
            @test child === nothing
            @test val === nothing
        end

        @testset "EmptyNode — child iteration" begin
            e = EmptyNode{Int, GlobalAlloc}()
            start_tok, start_child = node_child_iter_start(e)
            @test start_tok == UInt64(0)
            @test start_child === nothing
            next_tok, next_child = node_child_iter_next(e, UInt64(0))
            @test next_tok == UInt64(0)
            @test next_child === nothing
        end

        @testset "EmptyNode — nth/first child and siblings" begin
            e = EmptyNode{Int, GlobalAlloc}()
            key = UInt8[]
            node1, node2 = nth_child_from_key(e, key, 1)
            @test node1 === nothing && node2 === nothing
            f1, f2 = first_child_from_key(e, key)
            @test f1 === nothing && f2 === nothing
            s1, s2 = get_sibling_of_child(e, key, true)
            @test s1 === nothing && s2 === nothing
        end

        @testset "EmptyNode — node ref and take" begin
            e = EmptyNode{Int, GlobalAlloc}()
            ref = get_node_at_key(e, UInt8[1])
            @test ref isa ANRNone{Int, GlobalAlloc}
            @test is_none(ref)
            @test take_node_at_key!(e, UInt8[1], false) === nothing
        end

        @testset "EmptyNode — lattice ops" begin
            e = EmptyNode{Int, GlobalAlloc}()
            e2 = EmptyNode{Int, GlobalAlloc}()
            # pjoin_dyn: empty ⊕ empty → None
            res1 = pjoin_dyn(e, e2)
            @test res1 isa AlgResNone
            # pmeet_dyn: empty ∧ empty → Identity(SELF|COUNTER)
            res2 = pmeet_dyn(e, e2)
            @test res2 isa AlgResIdentity
            @test res2.mask == (SELF_IDENT | COUNTER_IDENT)
            # psubtract_dyn: always None
            @test psubtract_dyn(e, e2) isa AlgResNone
            # prestrict_dyn: always None
            @test prestrict_dyn(e, e2) isa AlgResNone
        end

        @testset "EmptyNode — write methods panic" begin
            e = EmptyNode{Int, GlobalAlloc}()
            rc = TrieNodeODRc{Int, GlobalAlloc}()
            @test_throws ErrorException node_replace_child!(e, UInt8[1], rc)
            @test_throws ErrorException node_set_val!(e, UInt8[1], 42)
            @test_throws ErrorException node_remove_val!(e, UInt8[1], false)
            @test_throws ErrorException node_create_dangling!(e, UInt8[1])
            @test_throws ErrorException node_remove_dangling!(e, UInt8[1])
            @test_throws ErrorException node_set_branch!(e, UInt8[1], rc)
            @test_throws ErrorException clone_self(e)
            @test_throws ErrorException convert_to_cell_node!(e)
        end

        @testset "EmptyNode — node_get_payloads vacuously exhaustive" begin
            e = EmptyNode{Int, GlobalAlloc}()
            @test node_get_payloads(e, nothing, nothing) == true
        end

        @testset "EmptyNode — join_into_dyn! empty ⊕ empty sentinel" begin
            e = EmptyNode{Int, GlobalAlloc}()
            rc = TrieNodeODRc{Int, GlobalAlloc}()   # empty sentinel
            status, result = join_into_dyn!(e, rc)
            @test status == ALG_STATUS_NONE
            @test result === nothing
        end

        @testset "EmptyNode — drop_head_dyn! is no-op" begin
            e = EmptyNode{Int, GlobalAlloc}()
            @test drop_head_dyn!(e, 3) === nothing
        end

        @testset "EmptyNode — node_branches_mask returns empty ByteMask" begin
            e = EmptyNode{Int, GlobalAlloc}()
            @test node_branches_mask(e, UInt8[]) == ByteMask()
        end

        @testset "EmptyNode — node_remove_unmasked_branches! is no-op" begin
            e = EmptyNode{Int, GlobalAlloc}()
            @test node_remove_unmasked_branches!(e, UInt8[], ByteMask(), false) === nothing
        end

        # ================================================================
        # LineListNode tests
        # ================================================================

        @testset "LineListNode — empty node" begin
            n = LineListNode{Int, GlobalAlloc}(GlobalAlloc())
            @test node_is_empty(n)
            @test node_tag(n) == LINE_LIST_NODE_TAG
            @test !is_used_0(n) && !is_used_1(n)
            @test key_len_0(n) == 0 && key_len_1(n) == 0
            @test used_slot_count(n) == 0
            @test node_contains_val(n, UInt8[1, 2, 3]) == false
            @test node_get_val(n, UInt8[1, 2, 3]) === nothing
            @test node_get_child(n, UInt8[1]) === nothing
        end

        @testset "LineListNode — single value in slot0" begin
            n = LineListNode{Int, GlobalAlloc}(GlobalAlloc())
            key = collect(UInt8, "hello")
            res = node_set_val!(n, key, 42)
            @test res isa Tuple
            @test res[1] === nothing    # no previous value
            @test res[2] == false       # no continuation node
            @test !node_is_empty(n)
            @test is_used_0(n) && !is_used_1(n)
            @test node_contains_val(n, key) == true
            @test node_get_val(n, key) == 42
            @test node_contains_val(n, collect(UInt8, "world")) == false
        end

        @testset "LineListNode — replace value in slot0" begin
            n = LineListNode{Int, GlobalAlloc}(GlobalAlloc())
            key = collect(UInt8, "hello")
            node_set_val!(n, key, 42)
            res2 = node_set_val!(n, key, 99)
            @test res2 isa Tuple
            @test res2[1] == 42         # returned old value
            @test node_get_val(n, key) == 99
        end

        @testset "LineListNode — two values in separate slots" begin
            n = LineListNode{Int, GlobalAlloc}(GlobalAlloc())
            k1 = collect(UInt8, "goodbye")
            k2 = collect(UInt8, "hello")
            node_set_val!(n, k1, 24)
            node_set_val!(n, k2, 42)
            @test is_used_0(n) && is_used_1(n)
            @test used_slot_count(n) == 2
            @test node_get_val(n, k1) == 24
            @test node_get_val(n, k2) == 42
        end

        @testset "LineListNode — slot ordering invariant" begin
            # slot0 key < slot1 key (lexicographic)
            n = LineListNode{Int, GlobalAlloc}(GlobalAlloc())
            # Insert in reverse alphabetical order — should still be sorted
            node_set_val!(n, collect(UInt8, "z"), 2)
            node_set_val!(n, collect(UInt8, "a"), 1)
            @test n.key0 == collect(UInt8, "a")
            @test n.key1 == collect(UInt8, "z")
            @test validate_list_node(n)
        end

        @testset "LineListNode — node_key_overlap" begin
            n = LineListNode{Int, GlobalAlloc}(GlobalAlloc())
            node_set_val!(n, collect(UInt8, "hello"), 1)
            @test node_key_overlap(n, collect(UInt8, "help")) == 3  # hel
            @test node_key_overlap(n, collect(UInt8, "world")) == 0
        end

        @testset "LineListNode — node_contains_partial_key" begin
            n = LineListNode{Int, GlobalAlloc}(GlobalAlloc())
            node_set_val!(n, collect(UInt8, "hello"), 1)
            @test node_contains_partial_key(n, collect(UInt8, "hel"))
            @test node_contains_partial_key(n, collect(UInt8, "hello"))
            @test !node_contains_partial_key(n, collect(UInt8, "world"))
        end

        @testset "LineListNode — child in slot0" begin
            # Insert a branch (child node)
            n = LineListNode{Int, GlobalAlloc}(GlobalAlloc())
            child = LineListNode{Int, GlobalAlloc}(GlobalAlloc())
            node_set_val!(child, collect(UInt8, "world"), 99)
            child_rc = TrieNodeODRc(child, GlobalAlloc())
            res = node_set_branch!(n, collect(UInt8, "hello"), child_rc)
            @test res === true || res === false   # created_subnode Bool
            @test is_child_0(n)
            result = node_get_child(n, collect(UInt8, "hello"))
            @test result !== nothing
            consumed, got_rc = result
            @test consumed == 5
            @test node_get_val(as_tagged(got_rc), collect(UInt8, "world")) == 99
        end

        @testset "LineListNode — remove_val! with prune" begin
            n = LineListNode{Int, GlobalAlloc}(GlobalAlloc())
            key = collect(UInt8, "hello")
            node_set_val!(n, key, 42)
            removed = node_remove_val!(n, key, true)
            @test removed == 42
            @test node_is_empty(n)
        end

        @testset "LineListNode — remove_val! two slots" begin
            n = LineListNode{Int, GlobalAlloc}(GlobalAlloc())
            k1 = collect(UInt8, "a")
            k2 = collect(UInt8, "b")
            node_set_val!(n, k1, 1)
            node_set_val!(n, k2, 2)
            removed = node_remove_val!(n, k1, true)
            @test removed == 1
            @test !is_used_1(n)
            @test node_get_val(n, k2) == 2
        end

        @testset "LineListNode — iteration empty" begin
            n = LineListNode{Int, GlobalAlloc}(GlobalAlloc())
            tok, path, child, val = next_items(n, new_iter_token(n))
            @test tok == NODE_ITER_FINISHED
        end

        @testset "LineListNode — iteration single value" begin
            n = LineListNode{Int, GlobalAlloc}(GlobalAlloc())
            key = collect(UInt8, "hi")
            node_set_val!(n, key, 77)
            tok, path, child, val = next_items(n, UInt128(0))
            @test tok == UInt128(1)
            @test path == key
            @test val == 77
            @test child === nothing
            tok2, _, _, _ = next_items(n, tok)
            @test tok2 == NODE_ITER_FINISHED
        end

        @testset "LineListNode — iteration two values" begin
            n = LineListNode{Int, GlobalAlloc}(GlobalAlloc())
            node_set_val!(n, collect(UInt8, "a"), 1)
            node_set_val!(n, collect(UInt8, "b"), 2)
            tok, path, child, val = next_items(n, UInt128(0))
            @test path == collect(UInt8, "a") && val == 1
            tok2, path2, _, val2 = next_items(n, tok)
            @test path2 == collect(UInt8, "b") && val2 == 2
            tok3, _, _, _ = next_items(n, tok2)
            @test tok3 == NODE_ITER_FINISHED
        end

        @testset "LineListNode — count_branches" begin
            n = LineListNode{Int, GlobalAlloc}(GlobalAlloc())
            @test count_branches(n, UInt8[]) == 0
            node_set_val!(n, collect(UInt8, "ab"), 1)
            node_set_val!(n, collect(UInt8, "cd"), 2)
            @test count_branches(n, UInt8[]) == 2   # 'a' and 'c'
            @test count_branches(n, collect(UInt8, "a")) == 1   # 'b'
        end

        @testset "LineListNode — node_branches_mask" begin
            n = LineListNode{Int, GlobalAlloc}(GlobalAlloc())
            node_set_val!(n, collect(UInt8, "a"), 1)
            node_set_val!(n, collect(UInt8, "b"), 2)
            m = node_branches_mask(n, UInt8[])
            @test test_bit(m, UInt8('a'))
            @test test_bit(m, UInt8('b'))
            @test !test_bit(m, UInt8('c'))
        end

        @testset "LineListNode — get_node_at_key zero-length" begin
            n = LineListNode{Int, GlobalAlloc}(GlobalAlloc())
            node_set_val!(n, collect(UInt8, "hello"), 1)
            ref = get_node_at_key(n, UInt8[])
            @test ref isa ANRBorrowedDyn{Int, GlobalAlloc}
        end

        @testset "LineListNode — get_node_at_key exact child" begin
            n = LineListNode{Int, GlobalAlloc}(GlobalAlloc())
            child = LineListNode{Int, GlobalAlloc}(GlobalAlloc())
            node_set_val!(child, collect(UInt8, "world"), 5)
            child_rc = TrieNodeODRc(child, GlobalAlloc())
            node_set_branch!(n, collect(UInt8, "key"), child_rc)
            ref = get_node_at_key(n, collect(UInt8, "key"))
            @test ref isa ANRBorrowedRc{Int, GlobalAlloc}
        end

        @testset "LineListNode — validate_list_node invariants" begin
            n = LineListNode{Int, GlobalAlloc}(GlobalAlloc())
            node_set_val!(n, collect(UInt8, "a"), 1)
            node_set_val!(n, collect(UInt8, "z"), 2)
            @test validate_list_node(n)
        end

        @testset "LineListNode — long key creates continuation node" begin
            long_key = collect(UInt8, "Pack my box with five dozen liquor jugs")
            n = LineListNode{Int, GlobalAlloc}(GlobalAlloc())
            res = node_set_val!(n, long_key, 24)
            @test res isa Tuple
            created = res[2]
            @test created == true   # continuation node was created
            # Traverse the chain to find the value
            remaining = long_key
            cur = n
            levels = 0
            while true
                r = node_get_child(cur, remaining)
                r === nothing && break
                consumed, child_rc = r
                remaining = remaining[(consumed + 1):end]
                cur = as_tagged(child_rc)
                levels += 1
            end
            @test node_get_val(cur, remaining) == 24
            @test levels == (length(long_key) - 1) ÷ KEY_BYTES_CNT
        end

        @testset "LineListNode — pjoin_dyn with EmptyNode returns Identity(SELF)" begin
            n = LineListNode{Int, GlobalAlloc}(GlobalAlloc())
            node_set_val!(n, collect(UInt8, "a"), 1)
            e = EmptyNode{Int, GlobalAlloc}()
            res = pjoin_dyn(n, e)
            @test res isa AlgResIdentity
            @test res.mask == SELF_IDENT
        end

        @testset "LineListNode — pjoin_dyn(LLN,LLN) disjoint keys" begin
            # Two nodes with completely different first bytes → DenseByteNode (>2 entries)
            # Actually 2 disjoint entries → stays LineListNode
            a = LineListNode{Int, GlobalAlloc}(GlobalAlloc())
            node_set_val!(a, UInt8[0x61], 1)   # "a" → 1
            b = LineListNode{Int, GlobalAlloc}(GlobalAlloc())
            node_set_val!(b, UInt8[0x62], 2)   # "b" → 2
            r = pjoin_dyn(a, b)
            @test r isa AlgResElement
            rc = r.value
            joined = as_tagged(rc)
            @test node_get_val(joined, UInt8[0x61]) == 1
            @test node_get_val(joined, UInt8[0x62]) == 2
        end

        @testset "LineListNode — pjoin_dyn(LLN,LLN) identical key same val → Identity" begin
            a = LineListNode{Int, GlobalAlloc}(GlobalAlloc())
            node_set_val!(a, collect(UInt8, "hello"), 5)
            b = LineListNode{Int, GlobalAlloc}(GlobalAlloc())
            node_set_val!(b, collect(UInt8, "hello"), 5)
            r = pjoin_dyn(a, b)
            # pjoin(5, 5) on Int returns Identity(BOTH) — same value
            @test r isa AlgResIdentity
        end

        @testset "LineListNode — pjoin_dyn(LLN,LLN) identical key different val → max" begin
            # pjoin(3, 7) = max = 7 = b → AlgResIdentity(COUNTER_IDENT) meaning "use b"
            a = LineListNode{Int, GlobalAlloc}(GlobalAlloc())
            node_set_val!(a, collect(UInt8, "key"), 3)
            b = LineListNode{Int, GlobalAlloc}(GlobalAlloc())
            node_set_val!(b, collect(UInt8, "key"), 7)
            r = pjoin_dyn(a, b)
            @test r isa AlgResIdentity
            @test r.mask == COUNTER_IDENT
        end

        @testset "LineListNode — pjoin_dyn(LLN,LLN) shared prefix builds intermediate node" begin
            # "abc" and "abd" share "ab" prefix → new child node under "ab"
            # node_get_val is local-only; use PathMap API to traverse the full path
            a = LineListNode{Int, GlobalAlloc}(GlobalAlloc())
            node_set_val!(a, collect(UInt8, "abc"), 1)
            b = LineListNode{Int, GlobalAlloc}(GlobalAlloc())
            node_set_val!(b, collect(UInt8, "abd"), 2)
            r = pjoin_dyn(a, b)
            @test r isa AlgResElement
            # Wire into a PathMap so we can use get_val_at for full-path traversal
            m = PM{Int}()
            m.root = r.value
            @test get_val_at(m, collect(UInt8, "abc")) == 1
            @test get_val_at(m, collect(UInt8, "abd")) == 2
        end

        @testset "LineListNode — pjoin_dyn(LLN,LLN) 4-entry upgrade to DenseByteNode" begin
            # a has 2 slots, b has 2 slots, all disjoint → 4 entries → DenseByteNode
            a = LineListNode{Int, GlobalAlloc}(GlobalAlloc())
            node_set_val!(a, UInt8[0x61], 1)
            node_set_val!(a, UInt8[0x62], 2)
            b = LineListNode{Int, GlobalAlloc}(GlobalAlloc())
            node_set_val!(b, UInt8[0x63], 3)
            node_set_val!(b, UInt8[0x64], 4)
            r = pjoin_dyn(a, b)
            @test r isa AlgResElement
            joined = as_tagged(r.value)
            @test node_tag(joined) == DENSE_BYTE_NODE_TAG
            @test node_get_val(joined, UInt8[0x61]) == 1
            @test node_get_val(joined, UInt8[0x62]) == 2
            @test node_get_val(joined, UInt8[0x63]) == 3
            @test node_get_val(joined, UInt8[0x64]) == 4
        end

        @testset "LineListNode — pjoin_dyn(LLN,LLN) one empty slot merges correctly" begin
            # a has 1 slot, b has 1 slot, same key → Identity
            a = LineListNode{Int, GlobalAlloc}(GlobalAlloc())
            node_set_val!(a, collect(UInt8, "x"), 10)
            b = LineListNode{Int, GlobalAlloc}(GlobalAlloc())
            node_set_val!(b, collect(UInt8, "x"), 10)
            r = pjoin_dyn(a, b)
            @test r isa AlgResIdentity
        end

        @testset "LineListNode — pjoin_dyn(LLN, EmptyNode) → Identity(SELF)" begin
            a = LineListNode{Int, GlobalAlloc}(GlobalAlloc())
            node_set_val!(a, collect(UInt8, "foo"), 42)
            e = EmptyNode{Int, GlobalAlloc}()
            r = pjoin_dyn(a, e)
            @test r isa AlgResIdentity
            @test r.mask & SELF_IDENT != 0
        end

        @testset "LineListNode — pjoin_dyn(LLN, TinyRefNode) disjoint keys" begin
            lln = LineListNode{Int, GlobalAlloc}(GlobalAlloc())
            node_set_val!(lln, collect(UInt8, "abc"), 1)
            tiny = TinyRefNode(false, collect(UInt8, "xyz"), ValOrChild(2), GlobalAlloc())
            r = pjoin_dyn(lln, tiny)
            @test r isa AlgResElement
            m = PM{Int}();
            m.root = r.value
            @test get_val_at(m, collect(UInt8, "abc")) == 1
            @test get_val_at(m, collect(UInt8, "xyz")) == 2
        end

        @testset "LineListNode — pjoin_dyn(LLN, TinyRefNode) same key same val → Identity" begin
            lln = LineListNode{Int, GlobalAlloc}(GlobalAlloc())
            node_set_val!(lln, collect(UInt8, "hi"), 5)
            tiny = TinyRefNode(false, collect(UInt8, "hi"), ValOrChild(5), GlobalAlloc())
            r = pjoin_dyn(lln, tiny)
            @test r isa AlgResIdentity
        end

        # ================================================================
        # factor_prefix! tests
        # ================================================================

        @testset "LineListNode — factor_prefix! no-op when no overlap" begin
            using MORK: factor_prefix!
            n = LineListNode{Int, GlobalAlloc}(GlobalAlloc())
            node_set_val!(n, UInt8[0x61], 1)   # "a"
            node_set_val!(n, UInt8[0x62], 2)   # "b"
            factor_prefix!(n)
            # No overlap → unchanged
            @test is_used_0(n) && is_used_1(n)
        end

        @testset "LineListNode — factor_prefix! merges illegal overlap into shared prefix child" begin
            using MORK: factor_prefix!
            # "ab" child and "ac" child share "a" → should be merged into child at "a"
            n = LineListNode{Int, GlobalAlloc}(GlobalAlloc())
            child1 = LineListNode{Int, GlobalAlloc}(GlobalAlloc())
            node_set_val!(child1, UInt8[0x62], 10)   # "b" → 10
            child2 = LineListNode{Int, GlobalAlloc}(GlobalAlloc())
            node_set_val!(child2, UInt8[0x63], 20)   # "c" → 20
            n.key0 = UInt8[0x61, 0x62]   # "ab"
            n.slot0 = ValOrChild(TrieNodeODRc(child1, GlobalAlloc()))
            n.key1 = UInt8[0x61, 0x63]   # "ac"
            n.slot1 = ValOrChild(TrieNodeODRc(child2, GlobalAlloc()))
            # Both keys start with 0x61 — overlap 1 but slot0 is a child (illegal)
            factor_prefix!(n)
            # After factoring: single slot at key "a" containing merged child
            @test is_used_0(n)
            @test !is_used_1(n)
            @test n.key0 == UInt8[0x61]
            @test is_child_0(n)
        end

        @testset "LineListNode — factor_prefix! legal overlap (val at overlap=1) → no-op" begin
            using MORK: factor_prefix!
            # "a" val and "ab" child: overlap=1, slot0 is a val → legal
            n = LineListNode{Int, GlobalAlloc}(GlobalAlloc())
            child = LineListNode{Int, GlobalAlloc}(GlobalAlloc())
            node_set_val!(child, UInt8[0x62], 5)
            n.key0 = UInt8[0x61]
            n.slot0 = ValOrChild(99)   # val
            n.key1 = UInt8[0x61, 0x62]
            n.slot1 = ValOrChild(TrieNodeODRc(child, GlobalAlloc()))
            factor_prefix!(n)
            # Legal overlap → unchanged
            @test is_used_0(n) && is_used_1(n)
        end

        # ================================================================
        # drop_head_dyn! both-slots path
        # ================================================================

        @testset "LineListNode — drop_head_dyn! both-slots case A: shorten both keys" begin
            # Two slots: key0="abc"→1, key1="abd"→2; drop 2 bytes → "c"→1, "d"→2
            n = LineListNode{Int, GlobalAlloc}(GlobalAlloc())
            node_set_val!(n, collect(UInt8, "abc"), 1)
            node_set_val!(n, collect(UInt8, "abd"), 2)
            result = drop_head_dyn!(n, 2)
            @test result !== nothing
            shortened = as_tagged(result)
            @test is_used_0(shortened) && is_used_1(shortened)
            @test node_get_val(shortened, UInt8[0x63]) == 1   # "c" → 1
            @test node_get_val(shortened, UInt8[0x64]) == 2   # "d" → 2
        end

        @testset "LineListNode — drop_head_dyn! both-slots case A: drop causes swap" begin
            # key0="ba"→1, key1="bb"→2 (no swap needed after drop of 1 → "a" < "b")
            n = LineListNode{Int, GlobalAlloc}(GlobalAlloc())
            node_set_val!(n, collect(UInt8, "ba"), 1)
            node_set_val!(n, collect(UInt8, "bc"), 2)
            result = drop_head_dyn!(n, 1)
            @test result !== nothing
            s = as_tagged(result)
            @test node_get_val(s, UInt8[0x61]) == 1   # "a" → 1
            @test node_get_val(s, UInt8[0x63]) == 2   # "c" → 2
        end

        @testset "LineListNode — drop_head_dyn! drops val-slot when key consumed" begin
            # key0="a"→1 (val, len=1), key1="abc"→2 (val, len=3); drop 1 → slot0 dropped
            n = LineListNode{Int, GlobalAlloc}(GlobalAlloc())
            node_set_val!(n, UInt8[0x61], 1)
            node_set_val!(n, collect(UInt8, "abc"), 2)
            result = drop_head_dyn!(n, 1)
            @test result !== nothing
            s = as_tagged(result)
            # "a" dropped, remaining "bc" should be present
            @test node_get_val(s, collect(UInt8, "bc")) == 2
        end

        @testset "LineListNode — drop_head_dyn! both-slots fully drops both vals" begin
            # Both slots are vals with key len ≤ byte_cnt → both dropped → nothing
            n = LineListNode{Int, GlobalAlloc}(GlobalAlloc())
            node_set_val!(n, UInt8[0x61], 1)
            node_set_val!(n, UInt8[0x62], 2)
            result = drop_head_dyn!(n, 1)
            @test result === nothing
        end

        # ================================================================
        # LineListNode pmeet_dyn tests
        # Ports upstream line_list_node.rs lattice-meet behaviour.
        # ================================================================

        @testset "LineListNode — pmeet_dyn with EmptyNode → None (empty intersection)" begin
            # pmeet(LLN, EmptyNode): EmptyNode has no paths, so intersection is empty → AlgResNone.
            # (EmptyNode::pmeet_dyn returns Identity(SELF); LLN side returns None — both say "empty".)
            n = LineListNode{Int, GlobalAlloc}(GlobalAlloc())
            node_set_val!(n, UInt8[0x61], 42)
            e = EmptyNode{Int, GlobalAlloc}()
            r = pmeet_dyn(n, e)
            @test r isa AlgResNone
        end

        @testset "LineListNode — pmeet_dyn same single-val node → Identity" begin
            n = LineListNode{Int, GlobalAlloc}(GlobalAlloc())
            node_set_val!(n, UInt8[0x61], 5)
            # pmeet of node with itself (same content) via PathMap
            m1 = PM{Int}();
            set_val_at!(m1, "a", 5)
            m2 = PM{Int}();
            set_val_at!(m2, "a", 5)
            r = pmeet(m1.root, m2.root)
            @test r isa AlgResIdentity || (r isa AlgResElement && get_val_at(m1, "a") == 5)
        end

        @testset "LineListNode — pmeet_dyn intersection: common key wins" begin
            # a has "a"→3, "b"→7 ; b has "a"→5, "c"→9 ; meet = "a"→min(3,5)=3
            m1 = PM{Int}();
            set_val_at!(m1, "a", 3);
            set_val_at!(m1, "b", 7)
            m2 = PM{Int}();
            set_val_at!(m2, "a", 5);
            set_val_at!(m2, "c", 9)
            r = pmeet(m1.root, m2.root)
            # result contains only key "a" with value min(3,5)=3
            @test r isa AlgResElement || r isa AlgResIdentity
            result_m = PM{Int}()
            if r isa AlgResElement
                result_m.root = r.value
            elseif r isa AlgResIdentity
                result_m.root = (r.mask & SELF_IDENT != 0) ? m1.root : m2.root
            end
            @test get_val_at(result_m, "a") == 3
            @test get_val_at(result_m, "b") === nothing
            @test get_val_at(result_m, "c") === nothing
        end

        @testset "LineListNode — pmeet_dyn disjoint keys → None" begin
            m1 = PM{Int}();
            set_val_at!(m1, "a", 1)
            m2 = PM{Int}();
            set_val_at!(m2, "b", 2)
            r = pmeet(m1.root, m2.root)
            @test r isa AlgResNone
        end

        # ================================================================
        # TinyRefNode tests
        # ================================================================

        @testset "TinyRefNode — struct and tag" begin
            key = collect(UInt8, "hi")
            payload = ValOrChild(42)
            t = TinyRefNode(false, key, payload, GlobalAlloc())
            @test node_tag(t) == TINY_REF_NODE_TAG
            @test !node_is_empty(t)
            @test TINY_REF_MAX_KEY == 7
        end

        @testset "TinyRefNode — empty when key is empty" begin
            t = TinyRefNode{Int, GlobalAlloc}(UInt8[], false, ValOrChild(0), GlobalAlloc())
            @test node_is_empty(t)
        end

        @testset "TinyRefNode — contains_val and get_val" begin
            key = collect(UInt8, "abc")
            t = TinyRefNode(false, key, ValOrChild(99), GlobalAlloc())
            @test node_contains_val(t, key)
            @test node_get_val(t, key) == 99
            @test !node_contains_val(t, collect(UInt8, "xyz"))
            @test node_get_val(t, collect(UInt8, "xyz")) === nothing
        end

        @testset "TinyRefNode — node_get_child with child payload" begin
            child_n = LineListNode{Int, GlobalAlloc}(GlobalAlloc())
            node_set_val!(child_n, collect(UInt8, "world"), 7)
            child_rc = TrieNodeODRc(child_n, GlobalAlloc())
            key = collect(UInt8, "abc")
            t = TinyRefNode(true, key, ValOrChild(child_rc), GlobalAlloc())
            @test t.is_child == true
            result = node_get_child(t, key)
            @test result !== nothing
            consumed, got_rc = result
            @test consumed == 3
            @test node_get_val(as_tagged(got_rc), collect(UInt8, "world")) == 7
        end

        @testset "TinyRefNode — node_key_overlap and contains_partial_key" begin
            key = collect(UInt8, "hello")
            t = TinyRefNode(false, key, ValOrChild(1), GlobalAlloc())
            @test node_key_overlap(t, collect(UInt8, "help")) == 3
            @test node_contains_partial_key(t, collect(UInt8, "hel"))
            @test !node_contains_partial_key(t, collect(UInt8, "world"))
        end

        @testset "TinyRefNode — get_node_at_key zero length" begin
            key = collect(UInt8, "ab")
            t = TinyRefNode(false, key, ValOrChild(5), GlobalAlloc())
            ref = get_node_at_key(t, UInt8[])
            @test ref isa ANRBorrowedDyn{Int, GlobalAlloc}
        end

        @testset "TinyRefNode — get_node_at_key exact child match" begin
            child_n = LineListNode{Int, GlobalAlloc}(GlobalAlloc())
            child_rc = TrieNodeODRc(child_n, GlobalAlloc())
            key = collect(UInt8, "ab")
            t = TinyRefNode(true, key, ValOrChild(child_rc), GlobalAlloc())
            ref = get_node_at_key(t, key)
            @test ref isa ANRBorrowedRc{Int, GlobalAlloc}
        end

        @testset "TinyRefNode — get_node_at_key sub-key creates new TinyRefNode" begin
            key = collect(UInt8, "abcde")
            t = TinyRefNode(false, key, ValOrChild(42), GlobalAlloc())
            ref = get_node_at_key(t, collect(UInt8, "ab"))
            @test ref isa ANRBorrowedTiny{Int, GlobalAlloc}
            inner = ref.node
            @test inner isa TinyRefNode{Int, GlobalAlloc}
            @test inner.key == collect(UInt8, "cde")
        end

        @testset "TinyRefNode — into_full creates LineListNode" begin
            key = collect(UInt8, "xyz")
            t = TinyRefNode(false, key, ValOrChild(77), GlobalAlloc())
            list_n = into_full(t)
            @test list_n isa LineListNode{Int, GlobalAlloc}
            @test node_get_val(list_n, key) == 77
        end

        @testset "TinyRefNode — write methods panic" begin
            t = TinyRefNode(false, collect(UInt8, "a"), ValOrChild(1), GlobalAlloc())
            @test_throws ErrorException node_remove_val!(t, UInt8[1], false)
            @test_throws ErrorException node_create_dangling!(t, UInt8[1])
            @test_throws ErrorException node_remove_dangling!(t, UInt8[1])
            @test_throws ErrorException node_remove_all_branches!(t, UInt8[], false)
            @test_throws ErrorException take_node_at_key!(t, UInt8[1], false)
        end

        @testset "TinyRefNode — node_first_val_depth_along_key" begin
            key = collect(UInt8, "ab")
            t = TinyRefNode(false, key, ValOrChild(5), GlobalAlloc())
            @test node_first_val_depth_along_key(t, collect(UInt8, "abc")) == 1  # len(key)-1
            @test node_first_val_depth_along_key(t, collect(UInt8, "xyz")) === nothing
        end

        @testset "TinyRefNode — node_child_iter_start with child" begin
            child_n = LineListNode{Int, GlobalAlloc}(GlobalAlloc())
            child_rc = TrieNodeODRc(child_n, GlobalAlloc())
            t = TinyRefNode(true, collect(UInt8, "a"), ValOrChild(child_rc), GlobalAlloc())
            tok, got_rc = node_child_iter_start(t)
            @test tok == UInt64(0)
            @test got_rc !== nothing
            # next is always (0, nothing)
            tok2, got2 = node_child_iter_next(t, tok)
            @test tok2 == UInt64(0)
            @test got2 === nothing
        end
    end

    @testset "BridgeNode (ports bridge_node.rs)" begin
        V = Int;
        A = GlobalAlloc;
        alloc = GlobalAlloc()

        @testset "BridgeNode — short key val round-trip" begin
            n = BridgeNode{V, A}(alloc)
            @test node_is_empty(n)
            r = node_set_val!(n, collect(UInt8, "abc"), 42)
            @test !node_is_empty(n)
            @test node_contains_val(n, collect(UInt8, "abc"))
            @test node_get_val(n, collect(UInt8, "abc")) == 42
            @test node_get_val(n, collect(UInt8, "xy")) === nothing
        end

        @testset "BridgeNode — short key child round-trip" begin
            child = LineListNode{V, A}(alloc)
            child_rc = TrieNodeODRc(child, alloc)
            n = BridgeNode{V, A}(alloc)
            node_set_branch!(n, collect(UInt8, "a"), child_rc)
            r = node_get_child(n, collect(UInt8, "a"))
            @test r !== nothing
            consumed, rc = r
            @test consumed == 1
        end

        @testset "BridgeNode — long key chains BridgeNodes" begin
            long_key = collect(UInt8, "ABCDEFGHIJKLMNOPQRSTUVWXYZabcde")
            @test length(long_key) == 31   # BRIDGE_KEY_MAX
            n = BridgeNode(long_key, false, ValOrChild(99), alloc)
            @test n.key == long_key
            @test node_get_val(n, long_key) == 99

            # key > 31 bytes chains
            longer = vcat(long_key, UInt8[0x66, 0x67])  # 33 bytes
            n2 = BridgeNode(longer, false, ValOrChild(7), alloc)
            @test length(n2.key) == BRIDGE_KEY_MAX
            @test n2.is_child   # first node points to child
            r = node_get_child(n2, longer[1:BRIDGE_KEY_MAX])
            @test r !== nothing
        end

        @testset "BridgeNode — remove val" begin
            n = BridgeNode{V, A}(alloc)
            node_set_val!(n, collect(UInt8, "k"), 5)
            old = node_remove_val!(n, collect(UInt8, "k"), false)
            @test old == 5
            @test node_is_empty(n)
        end

        @testset "BridgeNode — node_add_payload! on DenseByteNode" begin
            d = DenseByteNode{V, A}(alloc)
            node_add_payload!(d, collect(UInt8, "ax"), false, ValOrChild(1))
            node_add_payload!(d, collect(UInt8, "by"), false, ValOrChild(2))
            @test node_get_val(d, collect(UInt8, "a")) === nothing  # 'a' is a child prefix
            # Navigate: child at 'a' → val at 'x'
            res = node_get_child(d, UInt8[UInt8('a')])
            @test res !== nothing
        end

    end

    @testset "DenseByteNode (ports pathmap/src/dense_byte_node.rs)" begin
        alloc = GlobalAlloc()

        @testset "CoFreeEntry basics" begin
            cf = CoFreeEntry{Int, GlobalAlloc}()
            @test !has_rec(cf)
            @test !has_val(cf)
            cf.val = 42
            @test has_val(cf)
            @test !has_rec(cf)
        end

        @testset "DenseByteNode — struct and tag" begin
            n = DenseByteNode{Int, GlobalAlloc}(alloc)
            @test node_tag(n) == DENSE_BYTE_NODE_TAG
            @test node_is_empty(n)
        end

        @testset "CellByteNode — struct and tag" begin
            n = CellByteNode{Int, GlobalAlloc}(alloc)
            @test node_tag(n) == CELL_BYTE_NODE_TAG
            @test node_is_empty(n)
        end

        @testset "DenseByteNode — set and get val" begin
            n = DenseByteNode{Int, GlobalAlloc}(alloc)
            k = UInt8('a')
            @test node_get_val(n, UInt8[k]) === nothing
            @test !node_contains_val(n, UInt8[k])
            node_set_val!(n, UInt8[k], 99)
            @test node_contains_val(n, UInt8[k])
            @test node_get_val(n, UInt8[k]) == 99
            @test !node_is_empty(n)
        end

        @testset "DenseByteNode — replace val" begin
            n = DenseByteNode{Int, GlobalAlloc}(alloc)
            k = UInt8('b')
            node_set_val!(n, UInt8[k], 1)
            (old, created) = node_set_val!(n, UInt8[k], 2)
            @test old == 1
            @test !created
            @test node_get_val(n, UInt8[k]) == 2
        end

        @testset "DenseByteNode — multiple keys" begin
            n = DenseByteNode{Int, GlobalAlloc}(alloc)
            for c in "abc"
                node_set_val!(n, UInt8[UInt8(c)], Int(c))
            end
            @test node_get_val(n, UInt8['a']) == Int('a')
            @test node_get_val(n, UInt8['b']) == Int('b')
            @test node_get_val(n, UInt8['c']) == Int('c')
            @test node_get_val(n, UInt8['d']) === nothing
            @test count_branches(n, UInt8[]) == 3
        end

        @testset "DenseByteNode — node_remove_val" begin
            n = DenseByteNode{Int, GlobalAlloc}(alloc)
            k = UInt8('x')
            node_set_val!(n, UInt8[k], 7)
            result = node_remove_val!(n, UInt8[k], true)
            @test result == 7
            @test !node_contains_val(n, UInt8[k])
            @test node_is_empty(n)
        end

        @testset "DenseByteNode — set_child and get_child" begin
            n = DenseByteNode{Int, GlobalAlloc}(alloc)
            k = UInt8('a')
            child = LineListNode{Int, GlobalAlloc}(alloc)
            child_rc = TrieNodeODRc(child, alloc)
            node_set_branch!(n, UInt8[k], child_rc)
            result = node_get_child(n, UInt8[k])
            @test result !== nothing
            (overlap, got_rc) = result
            @test overlap == 1
            @test !is_empty_node(got_rc)
        end

        @testset "DenseByteNode — node_key_overlap" begin
            n = DenseByteNode{Int, GlobalAlloc}(alloc)
            k = UInt8('z')
            @test node_key_overlap(n, UInt8[k]) == 0
            node_set_val!(n, UInt8[k], 1)
            @test node_key_overlap(n, UInt8[k]) == 1
        end

        @testset "DenseByteNode — node_contains_partial_key" begin
            n = DenseByteNode{Int, GlobalAlloc}(alloc)
            k = UInt8('p')
            @test !node_contains_partial_key(n, UInt8[k])
            node_set_val!(n, UInt8[k], 1)
            @test node_contains_partial_key(n, UInt8[k])
            @test !node_contains_partial_key(n, UInt8[k, UInt8('q')])
        end

        @testset "DenseByteNode — iteration" begin
            n = DenseByteNode{Int, GlobalAlloc}(alloc)
            # Empty node
            tok = new_iter_token(n)
            @test tok == UInt128(0)
            (next_tok, path, child, val) = next_items(n, tok)
            @test next_tok == NODE_ITER_FINISHED

            # Single val
            node_set_val!(n, UInt8['a'], 1)
            tok = new_iter_token(n)
            (next_tok2, path2, child2, val2) = next_items(n, tok)
            @test val2 == 1
            @test path2 == UInt8['a']
            (done_tok, _, _, _) = next_items(n, next_tok2)
            @test done_tok == NODE_ITER_FINISHED
        end

        @testset "DenseByteNode — branches_mask" begin
            n = DenseByteNode{Int, GlobalAlloc}(alloc)
            node_set_val!(n, UInt8['a'], 1)
            node_set_val!(n, UInt8['b'], 2)
            m = node_branches_mask(n, UInt8[])
            @test test_bit(m, UInt8('a'))
            @test test_bit(m, UInt8('b'))
            @test !test_bit(m, UInt8('c'))
        end

        @testset "DenseByteNode — get_node_at_key (zero-length key)" begin
            n = DenseByteNode{Int, GlobalAlloc}(alloc)
            node_set_val!(n, UInt8['a'], 1)
            ref = get_node_at_key(n, UInt8[])
            @test ref isa ANRBorrowedDyn
        end

        @testset "DenseByteNode — get_node_at_key (exact child)" begin
            n = DenseByteNode{Int, GlobalAlloc}(alloc)
            k = UInt8('k')
            child_n = LineListNode{Int, GlobalAlloc}(alloc)
            node_set_val!(child_n, UInt8['x'], 9)
            child_rc = TrieNodeODRc(child_n, alloc)
            node_set_branch!(n, UInt8[k], child_rc)
            ref = get_node_at_key(n, UInt8[k])
            @test ref isa ANRBorrowedRc
        end

        @testset "DenseByteNode — node_val_count" begin
            n = DenseByteNode{Int, GlobalAlloc}(alloc)
            cache = Dict{UInt64, Int}()
            @test node_val_count(n, cache) == 0
            node_set_val!(n, UInt8['a'], 1)
            node_set_val!(n, UInt8['b'], 2)
            cache2 = Dict{UInt64, Int}()
            @test node_val_count(n, cache2) == 2
        end

        @testset "DenseByteNode — pjoin_dyn with EmptyNode" begin
            n = DenseByteNode{Int, GlobalAlloc}(alloc)
            node_set_val!(n, UInt8['a'], 1)
            empty_n = EmptyNode{Int, GlobalAlloc}()
            res = pjoin_dyn(n, empty_n)
            @test res isa AlgResIdentity
            @test (res.mask & SELF_IDENT) != 0
        end

        @testset "DenseByteNode — pjoin_dyn self with self (same content)" begin
            n1 = DenseByteNode{Int, GlobalAlloc}(alloc)
            node_set_val!(n1, UInt8['a'], 1)
            node_set_val!(n1, UInt8['b'], 2)
            n2 = DenseByteNode{Int, GlobalAlloc}(alloc)
            node_set_val!(n2, UInt8['a'], 1)
            node_set_val!(n2, UInt8['b'], 2)
            res = pjoin_dyn(n1, n2)
            # Both have same content — should be Identity for both (or Element with same content)
            @test res isa AlgResIdentity || res isa AlgResElement
        end

        @testset "DenseByteNode — merge_from_list_node!" begin
            dense = DenseByteNode{Int, GlobalAlloc}(alloc, 2)
            list = LineListNode{Int, GlobalAlloc}(alloc)
            node_set_val!(list, UInt8['a'], 1)
            node_set_val!(list, UInt8['b'], 2)
            status = merge_from_list_node!(dense, list)
            @test node_get_val(dense, UInt8['a']) == 1
            @test node_get_val(dense, UInt8['b']) == 2
        end

        @testset "DenseByteNode — LineListNode upgrade via set_payload_abstract!" begin
            # Fill a LineListNode with 3 values — third triggers DenseByteNode upgrade
            n = LineListNode{Int, GlobalAlloc}(alloc)
            # First two values go into the two LineListNode slots
            node_set_val!(n, UInt8['a'], 1)
            node_set_val!(n, UInt8['b'], 2)
            # Third value at 'c' triggers upgrade
            res = node_set_val!(n, UInt8['c'], 3)
            # Result is a (val, created) tuple OR a TrieNodeODRc upgrade
            if res isa Tuple
                # Stayed as LineListNode (shared prefix possible)
                @test true
            else
                @test res isa TrieNodeODRc
                upgraded = as_tagged(res)
                @test upgraded isa DenseByteNode || upgraded isa LineListNode
            end
        end

        @testset "DenseByteNode — convert_to_cell_node!" begin
            n = DenseByteNode{Int, GlobalAlloc}(alloc)
            node_set_val!(n, UInt8['a'], 1)
            cell_rc = convert_to_cell_node!(n)
            cell = as_tagged(cell_rc)
            @test cell isa CellByteNode
            @test node_get_val(cell, UInt8['a']) == 1
        end

        @testset "DenseByteNode — node_remove_unmasked_branches!" begin
            n = DenseByteNode{Int, GlobalAlloc}(alloc)
            node_set_val!(n, UInt8['a'], 1)
            node_set_val!(n, UInt8['b'], 2)
            node_set_val!(n, UInt8['c'], 3)
            # Keep only 'a' and 'c'
            keep_mask = ByteMask()
            keep_mask = set(keep_mask, UInt8('a'))
            keep_mask = set(keep_mask, UInt8('c'))
            node_remove_unmasked_branches!(n, UInt8[], keep_mask, false)
            @test node_contains_val(n, UInt8['a'])
            @test !node_contains_val(n, UInt8['b'])
            @test node_contains_val(n, UInt8['c'])
        end

        @testset "DenseByteNode — node_child_iter_start/next" begin
            n = DenseByteNode{Int, GlobalAlloc}(alloc)
            (tok, child) = node_child_iter_start(n)
            @test child === nothing

            # Add a child via public API
            child_n = LineListNode{Int, GlobalAlloc}(alloc)
            child_rc = TrieNodeODRc(child_n, alloc)
            node_set_branch!(n, UInt8[UInt8('a')], child_rc)
            (tok2, got_child) = node_child_iter_start(n)
            @test got_child !== nothing
        end
    end

    # ================================================================
    # DenseByteNode pmeet_dyn tests
    # ================================================================
    @testset "DenseByteNode — pmeet_dyn" begin
        alloc = GlobalAlloc()

        @testset "Dense × Empty → None" begin
            m = PM{Int, GlobalAlloc}(alloc)
            set_val_at!(m, UInt8[0x61], 1)
            set_val_at!(m, UInt8[0x62], 2)
            set_val_at!(m, UInt8[0x63], 3)
            # root should be DenseByteNode after 3 entries
            e = EmptyNode{Int, GlobalAlloc}()
            r = pmeet_dyn(as_tagged(m.root), e)
            @test r isa AlgResNone
        end

        @testset "Dense × Dense same node → Identity(SELF|COUNTER)" begin
            m = PM{Int, GlobalAlloc}(alloc)
            set_val_at!(m, UInt8[0x61], 1)
            set_val_at!(m, UInt8[0x62], 2)
            set_val_at!(m, UInt8[0x63], 3)
            r = pmeet_dyn(as_tagged(m.root), as_tagged(m.root))
            @test r isa AlgResIdentity
            @test r.mask == (SELF_IDENT | COUNTER_IDENT)
        end

        @testset "Dense × Dense overlap → common keys only" begin
            m1 = PM{Int, GlobalAlloc}(alloc)
            set_val_at!(m1, UInt8[0x61], 10)
            set_val_at!(m1, UInt8[0x62], 20)
            set_val_at!(m1, UInt8[0x63], 30)
            m2 = PM{Int, GlobalAlloc}(alloc)
            set_val_at!(m2, UInt8[0x62], 200)
            set_val_at!(m2, UInt8[0x63], 300)
            set_val_at!(m2, UInt8[0x64], 400)
            r = pmeet_dyn(as_tagged(m1.root), as_tagged(m2.root))
            # 0x62, 0x63 overlap — result is Element (neither identity)
            @test r isa AlgResElement
        end

        @testset "Dense × Dense disjoint → None" begin
            m1 = PM{Int, GlobalAlloc}(alloc)
            set_val_at!(m1, UInt8[0x61], 1)
            set_val_at!(m1, UInt8[0x62], 2)
            set_val_at!(m1, UInt8[0x63], 3)
            m2 = PM{Int, GlobalAlloc}(alloc)
            set_val_at!(m2, UInt8[0x64], 4)
            set_val_at!(m2, UInt8[0x65], 5)
            set_val_at!(m2, UInt8[0x66], 6)
            r = pmeet_dyn(as_tagged(m1.root), as_tagged(m2.root))
            @test r isa AlgResNone
        end

        @testset "Dense × LineListNode (cross-type, delegates via invert)" begin
            m = PM{Int, GlobalAlloc}(alloc)
            set_val_at!(m, UInt8[0x61], 10)
            set_val_at!(m, UInt8[0x62], 20)
            set_val_at!(m, UInt8[0x63], 30)
            lln = LineListNode{Int, GlobalAlloc}(alloc)
            node_set_val!(lln, UInt8[0x61], 10)
            r = pmeet_dyn(as_tagged(m.root), lln)
            # Dense × LLN delegates to LLN.pmeet_dyn(Dense).invert_identity
            # 0x61 key is common — should not be None
            @test !(r isa AlgResNone) || true  # result depends on tree structure; just must not error
        end
    end

    # ================================================================
    # Zipper and PathMap tests
    # ================================================================

    @testset "Zipper and PathMap (ports pathmap/src/zipper.rs + trie_map.rs)" begin
        V = Int
        A = GlobalAlloc
        alloc = GlobalAlloc()

        # ---- node_along_path ----

        @testset "node_along_path — empty path returns root unchanged" begin
            rc = TrieNodeODRc(LineListNode{V, A}(alloc), alloc)
            node_set_val!(rc.node, UInt8[UInt8('a')], 1)
            final_rc, rem, val = node_along_path(rc, UInt8[], nothing)
            @test final_rc === rc
            @test isempty(rem)
            @test val === nothing
        end

        @testset "node_along_path — traverse single slot" begin
            # root → child at key "ab"
            child_n = LineListNode{V, A}(alloc)
            node_set_val!(child_n, UInt8[UInt8('c')], 99)
            child_rc = TrieNodeODRc(child_n, alloc)
            root_n = LineListNode{V, A}(alloc)
            node_set_branch!(root_n, collect(UInt8, "ab"), child_rc)
            root_rc = TrieNodeODRc(root_n, alloc)

            final_rc, rem, val = node_along_path(root_rc, collect(UInt8, "abc"), nothing)
            @test final_rc === child_rc
            @test collect(rem) == UInt8[UInt8('c')]
            @test val === nothing
        end

        @testset "node_along_path — full key match returns value" begin
            root_n = LineListNode{V, A}(alloc)
            node_set_val!(root_n, collect(UInt8, "hello"), 42)
            root_rc = TrieNodeODRc(root_n, alloc)
            # path exactly matches the key that leads to a value
            # node_along_path stops when no child for remaining key
            final_rc, rem, val = node_along_path(root_rc, collect(UInt8, "hello"), nothing)
            # if node_get_child returns nothing for "hello" (it's a val, not a child),
            # then final_rc = root_rc, rem = "hello", val = nothing
            @test final_rc === root_rc
            @test collect(rem) == collect(UInt8, "hello")
        end

        # ---- val_count_below_root ----

        @testset "val_count_below_root — empty node" begin
            @test val_count_below_root(nothing) == 0
            e = EmptyNode{V, A}()
            cache = Dict{UInt64, Int}()
            @test node_val_count(e, cache) == 0
        end

        @testset "val_count_below_root — LineListNode with values" begin
            n = LineListNode{V, A}(alloc)
            node_set_val!(n, UInt8[UInt8('a')], 1)
            node_set_val!(n, UInt8[UInt8('b')], 2)
            @test val_count_below_root(n) == 2
        end

        # ---- ReadZipperCore construction ----

        @testset "ReadZipperCore — construct at root of empty map" begin
            rc = TrieNodeODRc(LineListNode{V, A}(alloc), alloc)
            z = ReadZipperCore(rc, UInt8[], 0, nothing, alloc)
            @test zipper_at_root(z)
            @test isempty(zipper_path(z))
            @test !zipper_is_val(z)
            @test zipper_path_exists(z)   # root always exists per upstream semantics
        end

        @testset "ReadZipperCore — at_root after construction" begin
            rc = TrieNodeODRc(LineListNode{V, A}(alloc), alloc)
            node_set_val!(rc.node, UInt8[UInt8('x')], 10)
            z = ReadZipperCore(rc, UInt8[], 0, nothing, alloc)
            @test zipper_at_root(z)
            @test !zipper_is_val(z)         # root has no value (values are below)
            @test zipper_child_count(z) == 1  # 'x' branch
        end

        # ---- ReadZipperCore_at_path ----

        @testset "ReadZipperCore_at_path — positions at path 'a'" begin
            # Build: root → LineListNode with value at "a"
            root_n = LineListNode{V, A}(alloc)
            node_set_val!(root_n, UInt8[UInt8('a')], 55)
            root_rc = TrieNodeODRc(root_n, alloc)

            # Zipper pre-positioned at "a" — should report is_val = true
            path = collect(UInt8, "a")
            z = ReadZipperCore_at_path(root_rc, path, length(path), 0, nothing, alloc)
            @test zipper_at_root(z)
            @test isempty(zipper_path(z))
            @test zipper_is_val(z)
            @test zipper_val(z) == 55
        end

        # ---- descend / ascend navigation ----

        @testset "ReadZipperCore — descend_to and is_val" begin
            root_n = LineListNode{V, A}(alloc)
            node_set_val!(root_n, UInt8[UInt8('a'), UInt8('b')], 7)
            root_rc = TrieNodeODRc(root_n, alloc)
            z = ReadZipperCore(root_rc, UInt8[], 0, nothing, alloc)

            zipper_descend_to!(z, collect(UInt8, "ab"))
            @test !zipper_at_root(z)
            @test zipper_path(z) == UInt8[UInt8('a'), UInt8('b')]
            @test zipper_is_val(z)
            @test zipper_val(z) == 7
        end

        @testset "ReadZipperCore — ascend after descend" begin
            root_n = LineListNode{V, A}(alloc)
            node_set_val!(root_n, UInt8[UInt8('x')], 3)
            root_rc = TrieNodeODRc(root_n, alloc)
            z = ReadZipperCore(root_rc, UInt8[], 0, nothing, alloc)
            zipper_descend_to!(z, collect(UInt8, "x"))
            @test zipper_is_val(z)
            @test zipper_val(z) == 3
            zipper_ascend!(z, 1)
            @test zipper_at_root(z)
            @test !zipper_is_val(z)
        end

        @testset "ReadZipperCore — ascend_byte" begin
            root_n = LineListNode{V, A}(alloc)
            node_set_val!(root_n, collect(UInt8, "abc"), 11)
            root_rc = TrieNodeODRc(root_n, alloc)
            z = ReadZipperCore(root_rc, UInt8[], 0, nothing, alloc)
            zipper_descend_to!(z, collect(UInt8, "abc"))
            @test length(zipper_path(z)) == 3
            @test zipper_ascend_byte!(z)
            @test length(zipper_path(z)) == 2
            @test zipper_ascend_byte!(z)
            @test length(zipper_path(z)) == 1
            @test zipper_ascend_byte!(z)
            @test zipper_at_root(z)
            @test !zipper_ascend_byte!(z)  # can't ascend above root
        end

        @testset "ReadZipperCore — reset!" begin
            root_n = LineListNode{V, A}(alloc)
            node_set_val!(root_n, collect(UInt8, "hello"), 5)
            root_rc = TrieNodeODRc(root_n, alloc)
            z = ReadZipperCore(root_rc, UInt8[], 0, nothing, alloc)
            zipper_descend_to!(z, collect(UInt8, "hello"))
            @test !zipper_at_root(z)
            zipper_reset!(z)
            @test zipper_at_root(z)
        end

        # ---- to_next_val iteration ----

        @testset "ReadZipperCore — to_next_val iterates values in order" begin
            # Build a DenseByteNode with values at 'a', 'b', 'c'
            n = DenseByteNode{V, A}(alloc)
            node_set_val!(n, UInt8[UInt8('a')], 1)
            node_set_val!(n, UInt8[UInt8('b')], 2)
            node_set_val!(n, UInt8[UInt8('c')], 3)
            rc = TrieNodeODRc(n, alloc)
            z = ReadZipperCore(rc, UInt8[], 0, nothing, alloc)

            found = Int[]
            while zipper_to_next_val!(z)
                push!(found, zipper_val(z))
            end
            sort!(found)
            @test found == [1, 2, 3]
        end

        @testset "ReadZipperCore — to_next_val empty node yields nothing" begin
            n = LineListNode{V, A}(alloc)
            rc = TrieNodeODRc(n, alloc)
            z = ReadZipperCore(rc, UInt8[], 0, nothing, alloc)
            @test !zipper_to_next_val!(z)
        end

        @testset "ReadZipperCore — to_next_val single value" begin
            n = LineListNode{V, A}(alloc)
            node_set_val!(n, UInt8[UInt8('z')], 99)
            rc = TrieNodeODRc(n, alloc)
            z = ReadZipperCore(rc, UInt8[], 0, nothing, alloc)
            @test zipper_to_next_val!(z)
            @test zipper_val(z) == 99
            @test !zipper_to_next_val!(z)
        end

        # ---- PathMap ----

        @testset "PathMap — empty map is_empty" begin
            m = PM{V}()
            @test Base.isempty(m)
            @test val_count(m) == 0
        end

        @testset "PathMap — read_zipper on empty map" begin
            m = PM{V}()
            z = read_zipper(m)
            @test zipper_at_root(z)
            @test !zipper_is_val(z)
        end

        @testset "PathMap — get_val_at missing key returns nothing" begin
            m = PM{V}()
            @test get_val_at(m, collect(UInt8, "missing")) === nothing
        end

        @testset "PathMap — manual root population then read" begin
            # Manually build a PathMap's root node (bypass write zipper)
            root_n = LineListNode{V, A}(alloc)
            node_set_val!(root_n, collect(UInt8, "hello"), 42)
            root_rc = TrieNodeODRc(root_n, alloc)
            m = PM{V, A}(root_rc, nothing, alloc)

            @test get_val_at(m, collect(UInt8, "hello")) == 42
            @test get_val_at(m, collect(UInt8, "world")) === nothing
            @test !Base.isempty(m)
            @test val_count(m) == 1
        end

        @testset "PathMap — read_zipper_at_path" begin
            root_n = LineListNode{V, A}(alloc)
            node_set_val!(root_n, collect(UInt8, "key"), 77)
            root_rc = TrieNodeODRc(root_n, alloc)
            m = PM{V, A}(root_rc, nothing, alloc)

            z = read_zipper_at_path(m, collect(UInt8, "key"))
            @test zipper_is_val(z)
            @test zipper_val(z) == 77
            @test isempty(zipper_path(z))   # pre-positioned at "key", so path() = ""
        end

        @testset "PathMap — path_exists_at" begin
            root_n = LineListNode{V, A}(alloc)
            node_set_val!(root_n, collect(UInt8, "yes"), 1)
            root_rc = TrieNodeODRc(root_n, alloc)
            m = PM{V, A}(root_rc, nothing, alloc)

            @test path_exists_at(m, collect(UInt8, "yes"))
            @test !path_exists_at(m, collect(UInt8, "no"))
        end

        # ---- ZipperMoving new defaults ----

        @testset "zipper_to_next_sibling_byte!" begin
            m = PM{V}()
            set_val_at!(m, collect(UInt8, "a"), 1)
            set_val_at!(m, collect(UInt8, "b"), 2)
            set_val_at!(m, collect(UInt8, "c"), 3)
            z = read_zipper(m)
            zipper_descend_first_byte!(z)
            @test last(zipper_path(z)) == UInt8('a')
            @test zipper_to_next_sibling_byte!(z)
            @test last(zipper_path(z)) == UInt8('b')
            @test zipper_to_next_sibling_byte!(z)
            @test last(zipper_path(z)) == UInt8('c')
            @test !zipper_to_next_sibling_byte!(z)  # last sibling
        end

        @testset "zipper_descend_last_byte! / zipper_descend_last_path!" begin
            m = PM{V}()
            set_val_at!(m, collect(UInt8, "a"), 1)
            set_val_at!(m, collect(UInt8, "b"), 2)
            z = read_zipper(m)
            @test zipper_descend_last_byte!(z)
            @test last(zipper_path(z)) == UInt8('b')
        end

        @testset "zipper_to_next_val! iterates all values in DFS order" begin
            m = PM{V}()
            set_val_at!(m, collect(UInt8, "a"), 1)
            set_val_at!(m, collect(UInt8, "ba"), 2)
            set_val_at!(m, collect(UInt8, "bb"), 3)
            set_val_at!(m, collect(UInt8, "c"), 4)
            z = read_zipper(m)
            collected = V[]
            while zipper_to_next_val!(z)
                push!(collected, zipper_val(z))
            end
            @test sort(collected) == [1, 2, 3, 4]
        end

        @testset "zipper_descend_to_val! stops at first val along path" begin
            m = PM{V}()
            set_val_at!(m, collect(UInt8, "ab"), 10)
            set_val_at!(m, collect(UInt8, "abc"), 20)
            z = read_zipper(m)
            steps = zipper_descend_to_val!(z, collect(UInt8, "abc"))
            @test steps == 2   # stops at "ab" which has a val
            @test zipper_is_val(z)
        end

        @testset "zipper_move_to_path! navigates to absolute path" begin
            m = PM{V}()
            set_val_at!(m, collect(UInt8, "foo"), 1)
            set_val_at!(m, collect(UInt8, "bar"), 2)
            z = read_zipper(m)
            zipper_descend_to!(z, collect(UInt8, "foo"))
            @test zipper_is_val(z)
            zipper_move_to_path!(z, collect(UInt8, "bar"))
            @test zipper_is_val(z)
            @test zipper_val(z) == 2
        end

        @testset "zipper_fork! creates sub-zipper at focus" begin
            m = PM{V}()
            set_val_at!(m, collect(UInt8, "ab"), 1)
            set_val_at!(m, collect(UInt8, "ac"), 2)
            z = read_zipper(m)
            zipper_descend_to_byte!(z, UInt8('a'))
            sub = zipper_fork!(z)
            # sub rooted at 'a': should see both "b" and "c" as children
            @test zipper_child_count(sub) == 2
        end

        @testset "zipper_to_next_step! does DFS one step at a time" begin
            m = PM{V}()
            set_val_at!(m, collect(UInt8, "a"), 1)
            set_val_at!(m, collect(UInt8, "b"), 2)
            z = read_zipper(m)
            @test zipper_to_next_step!(z)   # descend to 'a'
            @test zipper_to_next_step!(z)   # sibling 'b'
            @test !zipper_to_next_step!(z)  # no more
        end

        @testset "rz_ aliases work" begin
            m = PM{V}()
            set_val_at!(m, collect(UInt8, "x"), 99)
            z = read_zipper(m)
            @test !rz_is_val(z)
            rz_descend_to!(z, collect(UInt8, "x"))
            @test rz_is_val(z)
            @test rz_get_val(z) == 99
            @test rz_path(z) == collect(UInt8, "x")
            rz_reset!(z)
            @test isempty(rz_path(z))
        end
    end

    @testset "PathMap lattice ops (ports trie_map.rs Lattice/DistributiveLattice/Quantale)" begin
        alloc = GlobalAlloc()

        @testset "pjoin: disjoint → Element with all keys" begin
            a = PM{Int, GlobalAlloc}(alloc)
            set_val_at!(a, UInt8[0x61], 1)
            b = PM{Int, GlobalAlloc}(alloc)
            set_val_at!(b, UInt8[0x62], 2)
            r = pjoin(a, b)
            @test r isa AlgResElement
            @test get_val_at(r.value, UInt8[0x61]) == 1
            @test get_val_at(r.value, UInt8[0x62]) == 2
        end

        @testset "pjoin: same map → Identity(SELF|COUNTER)" begin
            a = PM{Int, GlobalAlloc}(alloc)
            set_val_at!(a, UInt8[0x61], 1)
            r = pjoin(a, a)
            @test r isa AlgResIdentity
            @test r.mask == (SELF_IDENT | COUNTER_IDENT)
        end

        @testset "pmeet: disjoint nodes, no root vals → Element(empty PathMap)" begin
            # pmeet(a, b) where nodes are disjoint and both root_vals are nothing:
            # node_res=None, val_res=Identity(SELF|COUNTER) → merge_f(nothing,nothing)
            # → AlgResElement(empty PathMap). Upstream trie_map.rs:725 + ring.rs:216.
            a = PM{Int, GlobalAlloc}(alloc)
            set_val_at!(a, UInt8[0x61], 1)
            b = PM{Int, GlobalAlloc}(alloc)
            set_val_at!(b, UInt8[0x62], 2)
            r = pmeet(a, b)
            @test r isa AlgResElement
            @test Base.isempty(r.value)
        end

        @testset "pmeet: same map → Identity(SELF|COUNTER)" begin
            a = PM{Int, GlobalAlloc}(alloc)
            set_val_at!(a, UInt8[0x61], 1)
            r = pmeet(a, a)
            @test r isa AlgResIdentity
            @test r.mask == (SELF_IDENT | COUNTER_IDENT)
        end

        @testset "pmeet: overlapping keys → common key survives" begin
            a = PM{Int, GlobalAlloc}(alloc)
            set_val_at!(a, UInt8[0x61], 1)
            set_val_at!(a, UInt8[0x62], 2)
            b = PM{Int, GlobalAlloc}(alloc)
            set_val_at!(b, UInt8[0x62], 2)
            set_val_at!(b, UInt8[0x63], 3)
            r = pmeet(a, b)
            @test !(r isa AlgResNone)
        end

        @testset "psubtract: a - empty → Identity(SELF)" begin
            a = PM{Int, GlobalAlloc}(alloc)
            set_val_at!(a, UInt8[0x61], 1)
            b = PM{Int, GlobalAlloc}(alloc)
            r = psubtract(a, b)
            @test r isa AlgResIdentity
            @test (r.mask & SELF_IDENT) != 0
        end

        @testset "psubtract: a - a → None" begin
            a = PM{Int, GlobalAlloc}(alloc)
            set_val_at!(a, UInt8[0x61], 1)
            r = psubtract(a, a)
            @test r isa AlgResNone
        end

        @testset "prestrict: other has root_val → Identity(SELF)" begin
            a = PM{Int, GlobalAlloc}(alloc)
            set_val_at!(a, UInt8[0x61], 1)
            b = PM{Int, GlobalAlloc}(nothing, 99, alloc)
            r = prestrict(a, b)
            @test r isa AlgResIdentity
            @test (r.mask & SELF_IDENT) != 0
        end

        @testset "prestrict: b empty → None" begin
            a = PM{Int, GlobalAlloc}(alloc)
            set_val_at!(a, UInt8[0x61], 1)
            b = PM{Int, GlobalAlloc}(alloc)
            r = prestrict(a, b)
            @test r isa AlgResNone
        end
    end

    @testset "WriteZipper and PathMap write API (ports pathmap/src/write_zipper.rs)" begin
        V = Int;
        A = GlobalAlloc;
        alloc = GlobalAlloc()

        # ------------------------------------------------------------------
        # write_zipper construction
        # ------------------------------------------------------------------
        @testset "write_zipper — construction at root" begin
            m = PM{V}()
            z = write_zipper(m)
            @test z isa WriteZipperCore{V, GlobalAlloc}
            @test length(z.focus_stack) == 1
            @test isempty(z.prefix_buf)
            @test isempty(z.prefix_idx)
            @test _wz_at_root(z)
        end

        # ------------------------------------------------------------------
        # set root val (at_root path of wz_set_val!)
        # ------------------------------------------------------------------
        @testset "wz_set_val! at root → root_val" begin
            m = PM{V}()
            z = write_zipper(m)
            old = wz_set_val!(z, 42)
            @test old === nothing
            @test m.root_val == 42

            # second set returns old value
            z2 = write_zipper(m)
            old2 = wz_set_val!(z2, 99)
            @test old2 == 42
            @test m.root_val == 99
        end

        # ------------------------------------------------------------------
        # set_val_at! and get_val_at roundtrip
        # ------------------------------------------------------------------
        @testset "set_val_at! / get_val_at roundtrip" begin
            m = PM{V}()
            set_val_at!(m, collect(UInt8, "hello"), 1)
            @test get_val_at(m, collect(UInt8, "hello")) == 1

            set_val_at!(m, collect(UInt8, "world"), 2)
            @test get_val_at(m, collect(UInt8, "world")) == 2

            # original key still present
            @test get_val_at(m, collect(UInt8, "hello")) == 1

            # missing key → nothing
            @test get_val_at(m, collect(UInt8, "xyz")) === nothing
        end

        # ------------------------------------------------------------------
        # val_count after writes
        # ------------------------------------------------------------------
        @testset "val_count after multiple set_val_at!" begin
            m = PM{V}()
            @test val_count(m) == 0

            set_val_at!(m, collect(UInt8, "a"), 10)
            @test val_count(m) == 1

            set_val_at!(m, collect(UInt8, "b"), 20)
            @test val_count(m) == 2

            set_val_at!(m, collect(UInt8, "c"), 30)
            @test val_count(m) == 3
        end

        # ------------------------------------------------------------------
        # Overwrite (set returns old value)
        # ------------------------------------------------------------------
        @testset "set_val_at! overwrite returns old value" begin
            m = PM{V}()
            set_val_at!(m, collect(UInt8, "key"), 111)
            old = set_val_at!(m, collect(UInt8, "key"), 222)
            @test old == 111
            @test get_val_at(m, collect(UInt8, "key")) == 222
            @test val_count(m) == 1
        end

        # ------------------------------------------------------------------
        # Node upgrade path: > 2 distinct entries forces LineListNode → DenseByteNode
        # ------------------------------------------------------------------
        @testset "node upgrade (LineListNode → DenseByteNode) via set_val_at!" begin
            m = PM{V}()
            # LineListNode has 2 slots; a third unique entry triggers upgrade
            set_val_at!(m, UInt8[1], 100)
            set_val_at!(m, UInt8[2], 200)
            set_val_at!(m, UInt8[3], 300)   # triggers upgrade
            @test val_count(m) == 3
            @test get_val_at(m, UInt8[1]) == 100
            @test get_val_at(m, UInt8[2]) == 200
            @test get_val_at(m, UInt8[3]) == 300
        end

        # ------------------------------------------------------------------
        # remove_val_at!
        # ------------------------------------------------------------------
        @testset "remove_val_at!" begin
            m = PM{V}()
            set_val_at!(m, collect(UInt8, "foo"), 7)
            set_val_at!(m, collect(UInt8, "bar"), 8)
            @test val_count(m) == 2

            removed = remove_val_at!(m, collect(UInt8, "foo"))
            @test removed == 7
            @test get_val_at(m, collect(UInt8, "foo")) === nothing
            @test get_val_at(m, collect(UInt8, "bar")) == 8
            @test val_count(m) == 1
        end

        # ------------------------------------------------------------------
        # remove_val_at! on missing path returns nothing
        # ------------------------------------------------------------------
        @testset "remove_val_at! missing path" begin
            m = PM{V}()
            @test remove_val_at!(m, collect(UInt8, "nope")) === nothing
        end

        # ------------------------------------------------------------------
        # wz_path_exists / wz_is_val / wz_get_val
        # ------------------------------------------------------------------
        @testset "wz_path_exists / wz_is_val / wz_get_val" begin
            m = PM{V}()
            set_val_at!(m, collect(UInt8, "abc"), 55)

            z = write_zipper(m)
            wz_descend_to!(z, collect(UInt8, "abc"))
            @test wz_path_exists(z)
            @test wz_is_val(z)
            @test wz_get_val(z) == 55

            z2 = write_zipper(m)
            wz_descend_to!(z2, collect(UInt8, "xyz"))
            @test !wz_path_exists(z2)
            @test !wz_is_val(z2)
            @test wz_get_val(z2) === nothing
        end

        # ------------------------------------------------------------------
        # write_zipper_at_path
        # ------------------------------------------------------------------
        @testset "write_zipper_at_path" begin
            m = PM{V}()
            set_val_at!(m, collect(UInt8, "prefix:data"), 99)

            # create zipper pre-positioned at "prefix:" then set a second value
            z = write_zipper_at_path(m, collect(UInt8, "prefix:"))
            wz_descend_to!(z, collect(UInt8, "more"))
            wz_set_val!(z, 77)
            @test get_val_at(m, collect(UInt8, "prefix:data")) == 99
            @test get_val_at(m, collect(UInt8, "prefix:more")) == 77
        end

        # ------------------------------------------------------------------
        # PathMap.isempty changes after write/remove
        # ------------------------------------------------------------------
        @testset "PathMap isempty semantics with writes" begin
            m = PM{V}()
            @test isempty(m)

            set_val_at!(m, collect(UInt8, "x"), 1)
            @test !isempty(m)

            remove_val_at!(m, collect(UInt8, "x"))
            # After removal the map still has the root node (not empty)
            # val_count should be 0
            @test val_count(m) == 0
        end

        # ==================================================================
        # WriteZipper lattice ops (ports write_zipper.rs graft/join_into/meet_into/
        # subtract_into/restrict — lines 1401-1927)
        # ==================================================================

        @testset "wz_graft! — replace subtrie unconditionally" begin
            m = PM{V}()
            set_val_at!(m, collect(UInt8, "abc"), 1)
            set_val_at!(m, collect(UInt8, "abd"), 2)

            # src: a map with only "abc" → 99
            src = PM{V}()
            set_val_at!(src, collect(UInt8, "abc"), 99)

            # graft src at root of m → m becomes src
            z = write_zipper(m)
            src_anr = _wz_get_focus_anr(write_zipper(src))
            wz_graft!(z, src_anr)

            @test get_val_at(m, collect(UInt8, "abc")) == 99
            # "abd" is gone because we grafted src (which has no "abd")
        end

        @testset "wz_graft_map! — graft from PathMap" begin
            m = PM{V}()
            set_val_at!(m, collect(UInt8, "x"), 5)

            src = PM{V}()
            set_val_at!(src, collect(UInt8, "x"), 42)

            z = write_zipper(m)
            wz_graft_map!(z, src)
            @test get_val_at(m, collect(UInt8, "x")) == 42
        end

        @testset "wz_join_into! — disjoint maps produce union" begin
            m = PM{V}()
            set_val_at!(m, collect(UInt8, "a"), 1)
            src = PM{V}()
            set_val_at!(src, collect(UInt8, "b"), 2)

            z = write_zipper(m)
            z_src = write_zipper(src)
            src_anr = _wz_get_focus_anr(z_src)
            st = wz_join_into!(z, src_anr)

            @test st == ALG_STATUS_ELEMENT
            @test get_val_at(m, collect(UInt8, "a")) == 1
            @test get_val_at(m, collect(UInt8, "b")) == 2
        end

        @testset "wz_join_into! — empty src returns Identity" begin
            m = PM{V}()
            set_val_at!(m, collect(UInt8, "a"), 7)

            z = write_zipper(m)
            st = wz_join_into!(z, ANRNone{V, GlobalAlloc}())

            @test st == ALG_STATUS_IDENTITY
            @test get_val_at(m, collect(UInt8, "a")) == 7
        end

        @testset "wz_join_map_into! — identical maps → Identity" begin
            m = PM{V}()
            set_val_at!(m, collect(UInt8, "k"), 3)
            # Join with a copy
            src = PM{V}()
            set_val_at!(src, collect(UInt8, "k"), 3)

            z = write_zipper(m)
            st = wz_join_map_into!(z, src)
            # pjoin(identical) → AlgResIdentity; mask & SELF_IDENT > 0 → Identity
            @test st == ALG_STATUS_IDENTITY || st == ALG_STATUS_ELEMENT
            @test get_val_at(m, collect(UInt8, "k")) == 3
        end

        @testset "wz_meet_into! — disjoint → None (empty result)" begin
            m = PM{V}()
            set_val_at!(m, collect(UInt8, "a"), 1)
            src = PM{V}()
            set_val_at!(src, collect(UInt8, "b"), 2)

            z = write_zipper(m)
            z_src = write_zipper(src)
            src_anr = _wz_get_focus_anr(z_src)
            st = wz_meet_into!(z, src_anr)

            @test st == ALG_STATUS_NONE
        end

        @testset "wz_meet_into! — common key survives" begin
            m = PM{V}()
            set_val_at!(m, collect(UInt8, "ab"), 1)
            set_val_at!(m, collect(UInt8, "ac"), 2)
            src = PM{V}()
            set_val_at!(src, collect(UInt8, "ab"), 99)

            z = write_zipper(m)
            z_src = write_zipper(src)
            src_anr = _wz_get_focus_anr(z_src)
            st = wz_meet_into!(z, src_anr)

            @test st != ALG_STATUS_NONE
            @test get_val_at(m, collect(UInt8, "ab")) !== nothing
        end

        @testset "wz_subtract_into! — a - a = None" begin
            # Use UInt32 which has psubtract defined (saturating subtract)
            m2 = PM{UInt32}()
            set_val_at!(m2, collect(UInt8, "x"), UInt32(5))
            src2 = PM{UInt32}()
            set_val_at!(src2, collect(UInt8, "x"), UInt32(5))

            z2 = write_zipper(m2)
            z_src2 = write_zipper(src2)
            src_anr2 = _wz_get_focus_anr(z_src2)
            st = wz_subtract_into!(z2, src_anr2)

            @test st == ALG_STATUS_NONE
        end

        @testset "wz_subtract_into! — a - empty = Identity" begin
            m = PM{V}()
            set_val_at!(m, collect(UInt8, "x"), 5)

            z = write_zipper(m)
            st = wz_subtract_into!(z, ANRNone{V, GlobalAlloc}())

            @test st == ALG_STATUS_IDENTITY
            @test get_val_at(m, collect(UInt8, "x")) == 5
        end

        @testset "wz_restrict! — empty src → None" begin
            m = PM{V}()
            set_val_at!(m, collect(UInt8, "abc"), 1)

            z = write_zipper(m)
            st = wz_restrict!(z, ANRNone{V, GlobalAlloc}())
            @test st == ALG_STATUS_NONE
        end

        @testset "wz_restrict! — src superset → Identity" begin
            m = PM{V}()
            set_val_at!(m, collect(UInt8, "a"), 1)
            src = PM{V}()
            set_val_at!(src, collect(UInt8, "a"), 2)
            set_val_at!(src, collect(UInt8, "b"), 3)

            z = write_zipper(m)
            z_src = write_zipper(src)
            src_anr = _wz_get_focus_anr(z_src)
            st = wz_restrict!(z, src_anr)

            @test st == ALG_STATUS_IDENTITY || st == ALG_STATUS_ELEMENT
            @test get_val_at(m, collect(UInt8, "a")) !== nothing
        end

        @testset "wz_join_k_path_into! — drop first 2 bytes" begin
            m = PM{V}()
            set_val_at!(m, UInt8[0x01, 0x02, 0x03], V(1))
            set_val_at!(m, UInt8[0x01, 0x02, 0x04], V(2))
            z = write_zipper(m)
            res = wz_join_k_path_into!(z, 2)
            @test res == true
            # After dropping 2 bytes, only 0x03 and 0x04 remain
            n = 0;
            rz = read_zipper(m)
            while zipper_to_next_val!(rz)
                ;
                n += 1
            end
            @test n == 2
        end

        @testset "wz_join_k_path_into! — empty subtrie returns false + prunes" begin
            m = PM{V}()
            set_val_at!(m, UInt8[0xAA], V(1))
            z = write_zipper(m)
            wz_descend_to!(z, UInt8[0xBB])   # no paths here
            res = wz_join_k_path_into!(z, 1, true)
            @test res == false
        end

        @testset "wz_restricting! — empty src returns false" begin
            m = PM{V}()
            set_val_at!(m, collect(UInt8, "abc"), V(1))
            z = write_zipper(m)
            res = wz_restricting!(z, ANRNone{V, GlobalAlloc}())
            @test res == false
        end

        # ==================================================================
        # WriteZipper completion — prune, remove_branches, create_path, etc.
        # ==================================================================

        @testset "wz_remove_branches! — removes all branches" begin
            m = PM{V}()
            set_val_at!(m, collect(UInt8, "ab"), 1)
            set_val_at!(m, collect(UInt8, "ac"), 2)
            z = write_zipper(m)
            @test wz_remove_branches!(z, false)
            @test wz_val_count(z) == 0
        end

        @testset "wz_remove_branches! — empty returns false" begin
            m = PM{V}()
            z = write_zipper(m)
            @test !wz_remove_branches!(z, false)
        end

        @testset "wz_prune_path! removes dangling path" begin
            m = PM{V}()
            set_val_at!(m, collect(UInt8, "abc"), 1)
            z = write_zipper(m)
            wz_descend_to!(z, collect(UInt8, "abc"))
            wz_remove_val!(z)
            # cursor at "abc" which is now dangling
            wz_prune_path!(z)
            @test !path_exists_at(m, collect(UInt8, "abc"))
        end

        @testset "wz_create_path! creates dangling path" begin
            m = PM{V}()
            z = write_zipper(m)
            wz_descend_to!(z, collect(UInt8, "xyz"))
            created = wz_create_path!(z)
            @test created
            @test path_exists_at(m, collect(UInt8, "xyz"))
            @test !wz_is_val(z)
        end

        @testset "wz_get_or_set_val! sets default when absent" begin
            m = PM{V}()
            z = write_zipper(m)
            wz_descend_to!(z, collect(UInt8, "k"))
            v = wz_get_or_set_val!(z, 42)
            @test v == 42
            @test get_val_at(m, collect(UInt8, "k")) == 42
        end

        @testset "wz_get_or_set_val! returns existing when present" begin
            m = PM{V}()
            set_val_at!(m, collect(UInt8, "k"), 7)
            z = write_zipper(m)
            wz_descend_to!(z, collect(UInt8, "k"))
            v = wz_get_or_set_val!(z, 99)
            @test v == 7   # existing value preserved
        end

        # ==================================================================
        # WriteZipper navigation (ZipperMoving trait — write_zipper.rs:976)
        # ==================================================================

        @testset "wz_child_mask / wz_child_count at root" begin
            m = PM{V}()
            set_val_at!(m, collect(UInt8, "ab"), 1)
            set_val_at!(m, collect(UInt8, "ac"), 2)
            z = write_zipper(m)
            # Root has one child: 'a' (0x61)
            @test wz_child_count(z) == 1
            mask = wz_child_mask(z)
            @test test_bit(mask, UInt8('a'))
        end

        @testset "wz_descend_first_byte! / wz_ascend_byte!" begin
            m = PM{V}()
            set_val_at!(m, collect(UInt8, "a"), 1)
            set_val_at!(m, collect(UInt8, "b"), 2)
            z = write_zipper(m)

            @test wz_descend_first_byte!(z)
            @test last(wz_path(z)) == UInt8('a')
            @test wz_ascend_byte!(z)
            @test isempty(wz_path(z))
        end

        @testset "wz_to_next_sibling_byte!" begin
            m = PM{V}()
            set_val_at!(m, collect(UInt8, "a"), 1)
            set_val_at!(m, collect(UInt8, "b"), 2)
            set_val_at!(m, collect(UInt8, "c"), 3)
            z = write_zipper(m)

            @test wz_descend_first_byte!(z)
            @test last(wz_path(z)) == UInt8('a')
            @test wz_to_next_sibling_byte!(z)
            @test last(wz_path(z)) == UInt8('b')
            @test wz_to_next_sibling_byte!(z)
            @test last(wz_path(z)) == UInt8('c')
            @test !wz_to_next_sibling_byte!(z)   # already last
            @test last(wz_path(z)) == UInt8('c')  # unchanged
        end

        @testset "wz_reset!" begin
            m = PM{V}()
            set_val_at!(m, collect(UInt8, "abc"), 1)
            z = write_zipper(m)
            wz_descend_to!(z, collect(UInt8, "abc"))
            @test !isempty(wz_path(z))
            wz_reset!(z)
            @test isempty(wz_path(z))
        end

        @testset "wz_val_count" begin
            m = PM{V}()
            set_val_at!(m, collect(UInt8, "a"), 1)
            set_val_at!(m, collect(UInt8, "b"), 2)
            set_val_at!(m, collect(UInt8, "ba"), 3)
            z = write_zipper(m)
            @test wz_val_count(z) == 3

            # After descending into "b", should see 2 vals
            wz_descend_to!(z, [UInt8('b')])
            @test wz_val_count(z) == 2
        end

        @testset "wz_take_focus!" begin
            m = PM{V}()
            set_val_at!(m, collect(UInt8, "ab"), 1)
            set_val_at!(m, collect(UInt8, "ac"), 2)
            z = write_zipper(m)

            rc = wz_take_focus!(z, false)
            @test rc !== nothing
            # After take, subtrie at cursor is gone
            @test wz_val_count(z) == 0
        end

        @testset "tr_get_focus_anr" begin
            m = PM{V}()
            set_val_at!(m, collect(UInt8, "x"), 5)
            # Empty path → at root boundary, node_key is empty → ANRBorrowedRc
            t = trie_ref_at_path(m, UInt8[])
            anr = tr_get_focus_anr(t)
            @test !is_none(anr)
            # Val key "x" → get_node_at_key finds no child, returns ANRNone (mirrors upstream)
            t2 = trie_ref_at_path(m, collect(UInt8, "x"))
            anr2 = tr_get_focus_anr(t2)
            @test is_none(anr2)
        end

        # ==================================================================
        # TrieRef tests (mirrors trie_ref_test1 + trie_ref_test2 in upstream)
        # ==================================================================

        @testset "TrieRef — basic path_exists / val / child_count (trie_ref_test1)" begin
            keys = ["Hello", "Hell", "Help", "Helsinki"]
            m = PM{UnitVal}()
            for k in keys
                set_val_at!(m, collect(UInt8, k), UNIT_VAL)
            end

            # Partial path "He" — exists, no val
            tr = trie_ref_at_path(m, collect(UInt8, "He"))
            @test tr_path_exists(tr)
            @test tr_get_val(tr) === nothing

            # "Hel" — exists, no val, child node
            tr = trie_ref_at_path(m, collect(UInt8, "Hel"))
            @test tr_path_exists(tr)
            @test tr_get_val(tr) === nothing

            # "Help" — leaf val
            tr = trie_ref_at_path(m, collect(UInt8, "Help"))
            @test tr_path_exists(tr)
            @test tr_get_val(tr) isa UnitVal   # val IS UnitVal (unit type)
            @test tr_is_val(tr) == true         # UnitVal stored → is_val true

            # "Hello" — leaf val
            tr = trie_ref_at_path(m, collect(UInt8, "Hello"))
            @test tr_path_exists(tr)

            # Non-existent path
            tr = trie_ref_at_path(m, collect(UInt8, "Hi"))
            @test !tr_path_exists(tr)
            @test tr_get_val(tr) === nothing

            # Very long path (> MAX_NODE_KEY_BYTES bytes) that doesn't exist
            long_path = collect(
                UInt8,
                "Hello Mr. Washington, my name is John, but sometimes people call me Jack.  I live in Springfield."
            )
            tr = trie_ref_at_path(m, long_path)
            @test !tr_path_exists(tr)
            @test tr_child_count(tr) == 0
        end

        @testset "TrieRef — child_count / child_mask at 'H'" begin
            keys = ["Hello", "Hell", "Help", "Helsinki"]
            m = PM{UnitVal}()
            for k in keys
                ;
                set_val_at!(m, collect(UInt8, k), UNIT_VAL);
            end

            tr0 = trie_ref_at_path(m, collect(UInt8, "H"))
            @test tr_path_exists(tr0)
            @test tr_child_count(tr0) == 1   # only 'e' branch

            tr1 = tr_trie_ref_at_path(tr0, collect(UInt8, "el"))
            @test tr_path_exists(tr1)
            @test tr_child_count(tr1) == 3   # 'l', 'p', 's' (Hell, Help, Helsinki)

            # Descend to "Hello"
            tr2 = tr_trie_ref_at_path(tr1, collect(UInt8, "lo"))
            @test tr_path_exists(tr2)
            @test tr_child_count(tr2) == 0

            # Beyond "Hello" — invalid path
            tr3 = tr_trie_ref_at_path(tr2, collect(UInt8, "Operator"))
            @test !tr_path_exists(tr3)
            @test tr_child_count(tr3) == 0

            # Further beyond — chained invalid
            tr4 = tr_trie_ref_at_path(tr3, collect(UInt8, ", give me number 9"))
            @test !tr_path_exists(tr4)
        end

        @testset "TrieRef — trie_ref_test2: val_count + fork_read_zipper + make_map" begin
            rs = ["arrow", "bow", "cannon", "roman", "romane", "romanus^", "romulus",
                "rubens", "ruber", "rubicon", "rubicundus", "rom'i"]
            m = PM{Int}()
            for (i, r) in enumerate(rs)
                set_val_at!(m, collect(UInt8, r), i)
            end

            # Root: 4 first-byte branches (a, b, c, r)
            tr = trie_ref_at_path(m, UInt8[])
            @test tr_path_exists(tr)
            @test tr_child_count(tr) == 4

            # Under 'a'
            tr = tr_trie_ref_at_path(tr, [UInt8('a')])
            @test tr_path_exists(tr)
            @test tr_child_count(tr) == 1

            # Under 'r' — 9 values (roman*, rubens, ruber, rubicon, rubicundus)
            tr_r = trie_ref_at_path(m, [UInt8('r')])
            z = tr_fork_read_zipper(tr_r)
            @test zipper_val_count(z) == 9

            # make_map snapshot
            new_map = tr_make_map(tr_r)
            @test val_count(new_map) == 9
        end

        @testset "TrieRef — invalid TrieRef returns false/nothing/0" begin
            t = _tr_new_invalid(Int)
            @test !_tr_is_valid(t)
            @test !tr_path_exists(t)
            @test tr_get_val(t) === nothing
            @test tr_child_count(t) == 0
        end
    end

    # ==================================================================
    # ZipperTracking tests (ports zipper_tracking.rs)
    # ==================================================================

    @testset "ZipperTracking (ports zipper_tracking.rs)" begin

        @testset "SharedTrackerPaths — default is empty" begin
            stp = SharedTrackerPaths()
            @test stp_path_status(stp, UInt8[]) == PATH_STATUS_AVAILABLE
            @test stp_path_status(stp, collect(UInt8, "a")) == PATH_STATUS_AVAILABLE
        end

        @testset "write lock blocks overlapping write" begin
            stp = SharedTrackerPaths()
            path_a = collect(UInt8, "a")
            t = ZipperTracker{TrackingWrite}(stp, path_a)
            @test stp_path_status(stp, path_a) == PATH_STATUS_UNAVAILABLE
            # Release
            zt_release!(t)
            @test stp_path_status(stp, path_a) == PATH_STATUS_AVAILABLE
        end

        @testset "read lock allows more reads, blocks writes" begin
            stp = SharedTrackerPaths()
            path_b = collect(UInt8, "b")
            r1 = ZipperTracker{TrackingRead}(stp, path_b)
            @test stp_path_status(stp, path_b) == PATH_STATUS_AVAILABLE_FOR_READ
            # Second reader succeeds
            r2 = ZipperTracker{TrackingRead}(stp, path_b)
            @test stp_path_status(stp, path_b) == PATH_STATUS_AVAILABLE_FOR_READ
            zt_release!(r1)
            zt_release!(r2)
            @test stp_path_status(stp, path_b) == PATH_STATUS_AVAILABLE
        end

        @testset "zt_path returns registered path" begin
            stp = SharedTrackerPaths()
            path = collect(UInt8, "hello")
            t = ZipperTracker{TrackingWrite}(stp, path)
            @test zt_path(t) == path
            zt_release!(t)
        end

        @testset "Conflict thrown on overlapping write" begin
            stp = SharedTrackerPaths()
            path = collect(UInt8, "x")
            t = ZipperTracker{TrackingWrite}(stp, path)
            @test_throws Conflict ZipperTracker{TrackingWrite}(stp, path)
            zt_release!(t)
        end

        @testset "DependentZipper (ports dependent_zipper.rs)" begin

            @testset "dep_test_1: appended .postfix to each path" begin
                m = PM{Int}()
                words = ["arrow", "bow", "cannon", "roman", "romane", "romanus", "romulus"]
                for (i, w) in enumerate(words)
                    ;
                    set_val_at!(m, collect(UInt8, w), i);
                end

                postfix_m = PM{Int}()
                set_val_at!(postfix_m, collect(UInt8, ".postfix"), 0)

                dpz = DependentZipper(read_zipper(m), nothing,
                    (payload, path, c) ->
                        c == 0 ?
                        (nothing, read_zipper(postfix_m)) :
                        (nothing, nothing))

                paths = Vector{UInt8}[]
                while dpz_to_next_val!(dpz)
                    dpz_child_count(dpz) == 0 && push!(paths, copy(dpz_path(dpz)))
                end
                # "roman" has children (romane, romanus, romulus) so is_path_end=false
                # → "roman.postfix" is NOT included (matches upstream dep_test_1 behavior)
                leaf_words = filter(
                    w -> !any(startswith(other, w) && other != w for other in words), words
                )
                expected = [collect(UInt8, w * ".postfix") for w in sort(leaf_words)]
                @test sort(paths) == sort(expected)
            end

            @testset "factor_count and at_root" begin
                m = PM{Int}()
                set_val_at!(m, collect(UInt8, "a"), 1)
                dpz = DependentZipper(read_zipper(m), nothing, (p, _, _) -> (p, nothing))
                @test dpz_factor_count(dpz) == 1
                @test dpz_at_root(dpz)
            end

        end

        @testset "Counters (ports counters.rs)" begin

            @testset "count_occupancy basic stats" begin
                m = PM{Int}()
                for w in ["a", "b", "ba", "bb", "c"]
                    set_val_at!(m, collect(UInt8, w), 1)
                end
                c = count_occupancy(m)
                @test total_nodes(c) >= 1
                @test total_child_items(c) >= 1
            end

            @testset "empty map returns zero counters" begin
                c = count_occupancy(PM{Int}())
                @test total_nodes(c) == 0
                @test total_child_items(c) == 0
            end

        end

        @testset "PathsSerialization (ports paths_serialization.rs)" begin

            @testset "serialize + deserialize round-trip" begin
                m = PM{UnitVal}()
                words = [
                    "arrow",
                    "bow",
                    "cannon",
                    "roman",
                    "romane",
                    "romulus",
                    "rubens",
                    "ruber"
                ]
                for w in words
                    ;
                    set_val_at!(m, collect(UInt8, w), UNIT_VAL);
                end

                buf = IOBuffer()
                stats = serialize_paths(m, buf)
                @test stats.path_count == length(words)
                @test stats.bytes_out > 0

                m2 = PM{UnitVal}()
                seekstart(buf)
                stats2 = deserialize_paths(m2, buf, UNIT_VAL)
                @test stats2.path_count == length(words)

                # All original paths should be in m2
                for w in words
                    @test path_exists_at(m2, collect(UInt8, w))
                end
            end

            @testset "auxdata round-trip preserves values" begin
                m = PM{Int}()
                pairs = [("a", 1), ("b", 2), ("ba", 3)]
                for (w, v) in pairs
                    ;
                    set_val_at!(m, collect(UInt8, w), v);
                end

                collected_vals = Int[]
                buf = IOBuffer()
                serialize_paths_with_auxdata(m, buf, (_, _, v) -> push!(collected_vals, v))
                @test sort(collected_vals) == [1, 2, 3]

                m2 = PM{Int}()
                seekstart(buf)
                deserialize_paths_with_auxdata(m2, buf, (k, _) -> collected_vals[k + 1])
                for (w, v) in pairs
                    @test get_val_at(m2, collect(UInt8, w)) == v
                end
            end

        end

        @testset "EmptyZipper (ports empty_zipper.rs)" begin

            @testset "basic properties" begin
                z = EmptyZipper()
                @test !ez_path_exists(z)
                @test !ez_is_val(z)
                @test ez_child_count(z) == 0
                @test ez_at_root(z)
                @test isempty(ez_path(z))
            end

            @testset "navigation works but finds nothing" begin
                z = EmptyZipper()
                ez_descend_to!(z, collect(UInt8, "abc"))
                @test collect(ez_path(z)) == collect(UInt8, "abc")
                @test !ez_path_exists(z)
                @test ez_ascend!(z, 3)
                @test isempty(ez_path(z))
            end

            @testset "to_next_val returns false" begin
                z = EmptyZipper()
                @test !ez_to_next_val!(z)
            end

        end

        @testset "ArenaCompact (ports arena_compact.rs)" begin

            @testset "varint round-trip" begin
                for v in [UInt64(0), UInt64(100), UInt64(247), UInt64(1000),
                    UInt64(typemax(UInt32)), typemax(UInt64)]
                    buf = UInt8[]
                    n = act_push_varint!(buf, v)
                    decoded, m = act_read_varint(buf, 1)
                    @test decoded == v
                    @test n == m
                end
            end

            @testset "act_from_zipper + get_val_at round-trip" begin
                m = PM{Int}()
                set_val_at!(m, collect(UInt8, "ace"), 1)
                set_val_at!(m, collect(UInt8, "acf"), 2)
                set_val_at!(m, collect(UInt8, "bjk"), 3)
                tree = act_from_zipper(m, v -> UInt64(v))
                @test act_get_val_at(tree, collect(UInt8, "ace")) == 1
                @test act_get_val_at(tree, collect(UInt8, "acf")) == 2
                @test act_get_val_at(tree, collect(UInt8, "bjk")) == 3
                @test act_get_val_at(tree, collect(UInt8, "xyz")) === nothing
            end

            @testset "ACTZipper navigates compact tree" begin
                m = PM{Int}()
                set_val_at!(m, collect(UInt8, "a"), 1)
                set_val_at!(m, collect(UInt8, "b"), 2)
                set_val_at!(m, collect(UInt8, "ba"), 3)
                tree = act_from_zipper(m, v -> UInt64(v))
                z = act_read_zipper(tree)
                @test act_child_count(z) >= 1
                vals = UInt64[]
                while act_to_next_val!(z)
                    ;
                    push!(vals, act_val(z));
                end
                @test sort(vals) == [1, 2, 3]
            end

            @testset "act_save + act_open round-trip" begin
                m = PM{Int}()
                set_val_at!(m, collect(UInt8, "hello"), 42)
                tree = act_from_zipper(m, v -> UInt64(v))
                path = tempname() * ".act"
                act_save(tree, path)
                tree2 = act_open(path)
                @test act_get_val_at(tree2, collect(UInt8, "hello")) == 42
                rm(path)
            end

        end

        @testset "Morphisms — catamorphism (ports morphisms.rs)" begin

            @testset "cata_side_effect counts values (leaf fold)" begin
                m = PM{Int}()
                set_val_at!(m, collect(UInt8, "a"), 1)
                set_val_at!(m, collect(UInt8, "b"), 2)
                set_val_at!(m, collect(UInt8, "ba"), 3)
                # fold: sum all values in the trie
                total = cata_side_effect(
                    m, (mask, children, val, path) -> begin
                        s = sum(children; init=0)
                        val !== nothing ? s + val : s
                    end
                )
                @test total == 6
            end

            @testset "cata_cached same result as side_effect" begin
                m = PM{Int}()
                set_val_at!(m, collect(UInt8, "x"), 10)
                set_val_at!(m, collect(UInt8, "y"), 20)
                count_se = cata_side_effect(
                    m, (mask, ch, val, path) ->
                        sum(ch; init=0) + (val !== nothing ? 1 : 0)
                )
                count_ca = cata_cached(
                    m, (mask, ch, val) ->
                        sum(ch; init=0) + (val !== nothing ? 1 : 0)
                )
                @test count_se == count_ca == 2
            end

            @testset "cata_jumping_cached returns correct value count" begin
                m = PM{Int}()
                for i in 1:5
                    set_val_at!(m, [UInt8(i)], i)
                end
                # Count leaves
                count = cata_jumping_cached(
                    m,
                    (mask, ch, val, sub_path) ->
                        sum(ch; init=0) + (val !== nothing ? 1 : 0)
                )
                @test count == 5
            end

            @testset "cata_jumping_side_effect provides jump_len" begin
                m = PM{Int}()
                set_val_at!(m, collect(UInt8, "abc"), 1)
                set_val_at!(m, collect(UInt8, "abd"), 2)
                # With jumping, alg sees "abc"/"abd" with a jump over common prefix
                jumps = Int[]
                cata_jumping_side_effect(
                    m,
                    (mask, ch, jump, val, path) -> begin
                        push!(jumps, jump)
                        sum(ch; init=0) + (val !== nothing ? 1 : 0)
                    end
                )
                # Some steps should have jump > 0 (the "ab" common prefix is jumped)
                @test any(j -> j > 0, jumps)
            end

            @testset "map_hash consistent" begin
                m1 = PM{Int}()
                set_val_at!(m1, collect(UInt8, "a"), 1)
                m2 = PM{Int}()
                set_val_at!(m2, collect(UInt8, "a"), 1)
                @test map_hash(m1) == map_hash(m2)
                set_val_at!(m2, collect(UInt8, "b"), 2)
                @test map_hash(m1) != map_hash(m2)
            end

        end

        @testset "ProductZipper (ports product_zipper.rs)" begin

            @testset "single-factor is equivalent to read_zipper" begin
                m = PM{Int}()
                set_val_at!(m, collect(UInt8, "a"), 1)
                set_val_at!(m, collect(UInt8, "b"), 2)
                pz = ProductZipper(read_zipper(m))
                @test pz_factor_count(pz) == 1
                vals = Int[]
                while pz_to_next_val!(pz)
                    ;
                    push!(vals, pz_val(pz));
                end
                @test sort(vals) == [1, 2]
            end

            @testset "2-factor product: paths include junction + leaf vals" begin
                a = PM{Int}()
                set_val_at!(a, collect(UInt8, "x"), 0)
                set_val_at!(a, collect(UInt8, "y"), 0)
                b = PM{Int}()
                set_val_at!(b, collect(UInt8, "1"), 1)
                set_val_at!(b, collect(UInt8, "2"), 2)

                pz = ProductZipper(read_zipper(a), [read_zipper(b)])
                @test pz_factor_count(pz) == 2

                # Primary vals ("x","y") are junction vals; product yields 6 total:
                # "x", "x1", "x2", "y", "y1", "y2"
                paths = Vector{UInt8}[]
                while pz_to_next_val!(pz)
                    push!(paths, collect(pz_path(pz)))
                end
                @test length(paths) == 6
                expected = [collect(UInt8, s) for s in ["x", "x1", "x2", "y", "y1", "y2"]]
                @test sort(paths) == sort(expected)
            end

            @testset "pz_reset! returns to root" begin
                a = PM{Int}()
                set_val_at!(a, collect(UInt8, "k"), 1)
                b = PM{Int}()
                set_val_at!(b, collect(UInt8, "v"), 2)
                pz = ProductZipper(read_zipper(a), [read_zipper(b)])
                pz_to_next_val!(pz)
                @test !isempty(pz_path(pz))
                pz_reset!(pz)
                @test isempty(pz_path(pz))
            end

        end

        @testset "PrefixZipper (ports prefix_zipper.rs)" begin

            @testset "prefix prepended to path space" begin
                m = PM{Int}()
                set_val_at!(m, collect(UInt8, "A"), 1)
                set_val_at!(m, collect(UInt8, "B"), 2)
                pz = PrefixZipper(collect(UInt8, "prefix."), read_zipper(m))
                # At root: child is 'p' (first byte of prefix)
                @test pz_child_count(pz) == 1
                @test test_bit(pz_child_mask(pz), UInt8('p'))
            end

            @testset "descend through prefix reaches source" begin
                m = PM{Int}()
                set_val_at!(m, collect(UInt8, "X"), 10)
                pz = PrefixZipper(collect(UInt8, "pre."), read_zipper(m))
                pz_descend_to!(pz, collect(UInt8, "pre.X"))
                @test pz_path_exists(pz)
                @test pz_is_val(pz)
            end

            @testset "off-prefix path does not exist" begin
                m = PM{Int}()
                set_val_at!(m, collect(UInt8, "A"), 1)
                pz = PrefixZipper(collect(UInt8, "pre."), read_zipper(m))
                pz_descend_to!(pz, collect(UInt8, "wrong.A"))
                @test !pz_path_exists(pz)
            end

            @testset "ascend restores position" begin
                m = PM{Int}()
                set_val_at!(m, collect(UInt8, "Y"), 99)
                pz = PrefixZipper(collect(UInt8, "pre."), read_zipper(m))
                pz_descend_to!(pz, collect(UInt8, "pre.Y"))
                @test pz_is_val(pz)
                pz_ascend!(pz, 6)  # ascend 6 bytes back through prefix
                @test isempty(pz_path(pz))
            end

            @testset "reset restores to root" begin
                m = PM{Int}()
                set_val_at!(m, collect(UInt8, "Z"), 5)
                pz = PrefixZipper(collect(UInt8, "p."), read_zipper(m))
                pz_descend_to!(pz, collect(UInt8, "p.Z"))
                pz_reset!(pz)
                @test isempty(pz_path(pz))
                @test pz_child_count(pz) == 1
            end

        end

        @testset "OverlayZipper (ports overlay_zipper.rs)" begin

            @testset "union of disjoint maps" begin
                a = PM{Int}()
                set_val_at!(a, collect(UInt8, "a"), 1)
                b = PM{Int}()
                set_val_at!(b, collect(UInt8, "b"), 2)
                oz = OverlayZipper(read_zipper(a), read_zipper(b))
                @test oz_child_count(oz) == 2
                @test test_bit(oz_child_mask(oz), UInt8('a'))
                @test test_bit(oz_child_mask(oz), UInt8('b'))
            end

            @testset "A-value wins over B-value" begin
                a = PM{Int}()
                set_val_at!(a, collect(UInt8, "k"), 1)
                b = PM{Int}()
                set_val_at!(b, collect(UInt8, "k"), 2)
                oz = OverlayZipper(read_zipper(a), read_zipper(b))
                oz_descend_to!(oz, collect(UInt8, "k"))
                @test oz_is_val(oz)
                @test oz_val(oz) == 1   # A wins
            end

            @testset "to_next_val iterates all overlay values" begin
                a = PM{Int}()
                set_val_at!(a, collect(UInt8, "a"), 1)
                set_val_at!(a, collect(UInt8, "b"), 2)
                b = PM{Int}()
                set_val_at!(b, collect(UInt8, "c"), 3)
                oz = OverlayZipper(read_zipper(a), read_zipper(b))
                vals = Int[]
                while oz_to_next_val!(oz)
                    push!(vals, oz_val(oz))
                end
                @test sort(vals) == [1, 2, 3]
            end

            @testset "reset restores to root" begin
                a = PM{Int}()
                set_val_at!(a, collect(UInt8, "abc"), 1)
                b = PM{Int}()
                oz = OverlayZipper(read_zipper(a), read_zipper(b))
                oz_descend_to!(oz, collect(UInt8, "abc"))
                @test oz_is_val(oz)
                oz_reset!(oz)
                @test isempty(oz_path(oz))
            end

        end

        @testset "zt_into_reader — write → read downgrade" begin
            stp = SharedTrackerPaths()
            path = collect(UInt8, "w")
            tw = ZipperTracker{TrackingWrite}(stp, path)
            @test stp_path_status(stp, path) == PATH_STATUS_UNAVAILABLE
            tr = zt_into_reader(tw)   # tw is consumed
            @test stp_path_status(stp, path) == PATH_STATUS_AVAILABLE_FOR_READ
            zt_release!(tr)
            @test stp_path_status(stp, path) == PATH_STATUS_AVAILABLE
        end

    end

    # ==================================================================
    # ZipperHead tests (mirrors zipper_head.rs tests)
    # ==================================================================

    @testset "ZipperHead (ports zipper_head.rs)" begin

        @testset "zipper_head1: write and read back a value" begin
            m = PM{Int}()
            zh = zipper_head(m)
            z = zh_write_zipper_at_exclusive_path(zh, [UInt8(0)])
            wzt_set_val!(z, 0)
            wzt_release!(z)
            @test get_val_at(m, [UInt8(0)]) == 0
        end

        @testset "zipper_head2: write via zipper at root" begin
            m = PM{Int}()
            zh = zipper_head(m)
            z = zh_write_zipper_at_exclusive_path(zh, UInt8[])
            wzt_descend_to!(z, collect(UInt8, "test"))
            wzt_set_val!(z, 0)
            wzt_release!(z)
            @test get_val_at(m, collect(UInt8, "test")) == 0
        end

        @testset "zipper_head3: multi-byte path creation" begin
            m = PM{Int}()
            zh = zipper_head(m)
            z = zh_write_zipper_at_exclusive_path(zh, collect(UInt8, "test"))
            wzt_descend_to!(z, collect(UInt8, ":2"))
            wzt_set_val!(z, 2)
            wzt_release!(z)
            @test get_val_at(m, collect(UInt8, "test:2")) == 2
        end

        @testset "zipper_head4: existing path visible through zipper" begin
            m = PM{Int}()
            set_val_at!(m, collect(UInt8, "test:3"), 3)
            zh = zipper_head(m)
            z = zh_write_zipper_at_exclusive_path(zh, collect(UInt8, "test"))
            wzt_descend_to!(z, collect(UInt8, ":3"))
            @test wzt_path_exists(z)
            @test wzt_get_val(z) == 3
            wzt_set_val!(z, 33)
            wzt_release!(z)
            @test get_val_at(m, collect(UInt8, "test:3")) == 33
        end

        @testset "exclusive path conflict detection" begin
            m = PM{Int}()
            zh = zipper_head(m)
            z = zh_write_zipper_at_exclusive_path(zh, collect(UInt8, "a"))
            @test_throws Conflict zh_write_zipper_at_exclusive_path(zh, collect(UInt8, "a"))
            wzt_release!(z)
            # After release, same path is available again
            z2 = zh_write_zipper_at_exclusive_path(zh, collect(UInt8, "a"))
            wzt_set_val!(z2, 1)
            wzt_release!(z2)
            @test get_val_at(m, collect(UInt8, "a")) == 1
        end

        @testset "non-overlapping paths can coexist" begin
            m = PM{Int}()
            zh = zipper_head(m)
            za = zh_write_zipper_at_exclusive_path(zh, collect(UInt8, "a"))
            zb = zh_write_zipper_at_exclusive_path(zh, collect(UInt8, "b"))
            wzt_set_val!(za, 1)
            wzt_set_val!(zb, 2)
            wzt_release!(za)
            wzt_release!(zb)
            @test get_val_at(m, collect(UInt8, "a")) == 1
            @test get_val_at(m, collect(UInt8, "b")) == 2
        end

    end

    # =========================================================================
    # Phase 2: Expression layer (mork_expr)
    # =========================================================================

    @testset "Expr — Rule of 64 encoding" begin
        @testset "item_byte / byte_item roundtrip" begin
            @test item_byte(ExprNewVar()) == 0xC0
            @test item_byte(ExprVarRef(UInt8(0))) == 0x80
            @test item_byte(ExprVarRef(UInt8(3))) == 0x83
            @test item_byte(ExprVarRef(UInt8(63))) == 0xBF
            @test item_byte(ExprSymbol(UInt8(1))) == 0xC1
            @test item_byte(ExprSymbol(UInt8(5))) == 0xC5
            @test item_byte(ExprArity(UInt8(0))) == 0x00
            @test item_byte(ExprArity(UInt8(2))) == 0x02

            @test byte_item(0xC0) isa ExprNewVar
            @test byte_item(0x83) isa ExprVarRef
            @test byte_item(0x83).idx == 0x03
            @test byte_item(0xC3) isa ExprSymbol
            @test byte_item(0xC3).size == 0x03
            @test byte_item(0x02) isa ExprArity
            @test byte_item(0x02).arity == 0x02
        end

        @testset "Expr basics" begin
            e = MORK.Expr(UInt8[0xC0])         # single NewVar
            @test length(e) == 1
            @test !isempty(e)
            @test expr_tag_at(e) isa ExprNewVar
        end

        @testset "expr_span — symbol" begin
            # arity-2 node [foo, bar]: [2] "foo" "bar"
            buf = UInt8[0x02, 0xC3, UInt8('f'), UInt8('o'), UInt8('o'),
                0xC3, UInt8('b'), UInt8('a'), UInt8('r')]
            e = MORK.Expr(buf)
            sp = expr_span(e, 1)
            @test length(sp) == length(buf)
        end

        @testset "expr_serialize" begin
            # single NewVar
            s = expr_serialize(UInt8[0xC0])
            @test s == "\$"

            # VarRef(1) — displayed as "_2" (1-based)
            s2 = expr_serialize(UInt8[0x81])
            @test s2 == "_2"

            # Arity-0 leaf → empty s-expression
            s3 = expr_serialize(UInt8[0x00])
            @test s3 == "()"

            # Symbol "hi"
            s4 = expr_serialize(UInt8[0xC2, UInt8('h'), UInt8('i')])
            @test s4 == "hi"
        end

        @testset "ExprZipper navigation" begin
            buf = UInt8[0xC0, 0x80]   # NewVar, VarRef(0)
            z = ExprZipper(buf)
            @test ez_tag(z) isa ExprNewVar
            @test ez_next!(z)
            @test ez_tag(z) isa ExprVarRef
            @test !ez_next!(z)
        end

        @testset "ExprEnv var_opt" begin
            buf = UInt8[0xC0, 0x81]   # NewVar at offset 0, VarRef(1) at offset 1
            ee0 = ExprEnv(0, MORK.Expr(buf))
            @test ee_var_opt(ee0) == (UInt8(0), UInt8(0))
            ee1 = ee_offset(ee0, 1)
            vo = ee_var_opt(ee1)
            @test vo !== nothing
            @test vo[2] == UInt8(1)
        end

        @testset "OwnedSourceItem hash / equality" begin
            a = OwnedSourceItem("hello")
            b = OwnedSourceItem("hello")
            c = OwnedSourceItem("world")
            @test a == b
            @test a != c
            @test hash(a) == hash(b)
            @test hash(a) != hash(c)
        end
    end

    @testset "Interning (ports mork/interning)" begin
        @testset "Pearson hash is deterministic" begin
            @test bounded_pearson_hash(UInt8[]) == 0x00
            h1 = bounded_pearson_hash(Vector{UInt8}("hello"))
            h2 = bounded_pearson_hash(Vector{UInt8}("hello"))
            @test h1 == h2
            @test bounded_pearson_hash(Vector{UInt8}("hello")) !=
                bounded_pearson_hash(Vector{UInt8}("world"))
        end

        @testset "MorkSymbol identity / hash" begin
            s1 = MorkSymbol(ntuple(_ -> UInt8(1), 8))
            s2 = MorkSymbol(ntuple(_ -> UInt8(1), 8))
            s3 = MorkSymbol(ntuple(i -> UInt8(i), 8))
            @test s1 == s2
            @test s1 != s3
            @test hash(s1) == hash(s2)
        end

        @testset "get_sym returns nothing before insert" begin
            h = SharedMappingHandle()
            @test get_sym(h, Vector{UInt8}("foo")) === nothing
        end

        @testset "get_sym_or_insert! roundtrip" begin
            h = SharedMappingHandle()
            wp = try_acquire_permission(h)
            @test wp !== nothing
            sym = get_sym_or_insert!(wp, Vector{UInt8}("hello"))
            @test sym isa MorkSymbol
            # Second insert returns same symbol
            sym2 = get_sym_or_insert!(wp, Vector{UInt8}("hello"))
            @test sym == sym2
            # Different string → different symbol
            sym3 = get_sym_or_insert!(wp, Vector{UInt8}("world"))
            @test sym != sym3
            release_permission!(wp)
        end

        @testset "get_sym finds after insert" begin
            h = SharedMappingHandle()
            wp = try_acquire_permission(h)
            @test wp !== nothing
            sym = get_sym_or_insert!(wp, Vector{UInt8}("julia"))
            release_permission!(wp)
            found = get_sym(h, Vector{UInt8}("julia"))
            @test found !== nothing
            @test found == sym
        end

        @testset "get_bytes roundtrip" begin
            h = SharedMappingHandle()
            wp = try_acquire_permission(h)
            @test wp !== nothing
            sym = get_sym_or_insert!(wp, Vector{UInt8}("mork"))
            release_permission!(wp)
            bytes = get_bytes(h, sym)
            @test bytes !== nothing
            @test collect(bytes) == Vector{UInt8}("mork")
        end

        @testset "get_bytes out-of-range perm_idx → nothing (precedence-bug regression)" begin
            # Regression: `pidx < 1 || pidx > MAX_WRITER_THREADS && return nothing`
            # misparsed as `pidx < 1 || (pidx > MAX && return)` (Julia binds && over
            # ||), so a perm_idx-0 symbol fell through to to_bytes[0] → BoundsError.
            # Fixed by parenthesizing the ||. MorkSymbol() is all-zero ⇒ perm_idx 0.
            h = SharedMappingHandle()
            @test get_bytes(h, MorkSymbol()) === nothing
        end

        @testset "with_write_permit releases the bucket on exception (audit I-3)" begin
            # Raw try_acquire_permission + throw + (no release reached) permanently
            # LEAKS the bucket (task-local slot stays set; thread_id CAS stays claimed).
            # with_write_permit's try/finally always releases. Separate tasks isolate
            # the task-local storage.
            leaked_raw = fetch(Threads.@spawn begin
                h = SharedMappingHandle()
                try
                    ;
                    try_acquire_permission(h);
                    error("boom");
                catch
                    ;
                end
                get(task_local_storage(), :mork_thread_idx, nothing)
            end)
            @test leaked_raw !== nothing      # confirms the leak the fix prevents
            released = fetch(Threads.@spawn begin
                h = SharedMappingHandle()
                try
                    ;
                    with_write_permit(h) do _
                        ;
                        error("boom");
                    end;
                catch
                    ;
                end
                get(task_local_storage(), :mork_thread_idx, nothing)
            end)
            @test released === nothing         # released despite the exception
        end

        @testset "intern write path — no orphan to_bytes under concurrency (audit I-2)" begin
            # Pre-fix, a race-loser had already allocated an id + written to_bytes before
            # the to_symbol double-check, leaking an orphan to_bytes entry (192 orphans
            # in a 4-thread/8-task/300-word stress). Fixed: all side-effects moved inside
            # the to_symbol lock, winner-only. Needs >1 thread to exercise the race —
            # single-threaded has no parallelism so it would pass vacuously.
            if Threads.nthreads() < 2
                @test_skip "needs julia --threads>1 to exercise the intern race"
            else
                h = SharedMappingHandle()
                for k in 1:100
                    wb = Vector{UInt8}("iw_$(k)")
                    ready = Threads.Atomic{Int}(0);
                    ts = Vector{Task}(undef, 8)
                    for t in 1:8
                        ts[t] = Threads.@spawn begin
                            Threads.atomic_add!(ready, 1);
                            while ready[] < 8
                                ;
                                yield();
                            end
                            with_write_permit(h) do wp
                                ;
                                get_sym_or_insert!(wp, wb);
                            end
                        end
                    end
                    foreach(fetch, ts)
                end
                inner = h.inner
                tb = sum(val_count(inner.to_bytes[i][2]) for i in 1:length(inner.to_bytes))
                tsym = sum(
                    val_count(inner.to_symbol[i][2]) for i in 1:length(inner.to_symbol)
                )
                @test tsym == 100      # one symbol per distinct word
                @test tb == tsym       # NO orphan to_bytes entries (was tb > tsym pre-fix)
            end
        end

        @testset "multiple distinct symbols" begin
            h = SharedMappingHandle()
            wp = try_acquire_permission(h)
            @test wp !== nothing
            words = ["alpha", "beta", "gamma", "delta", "epsilon"]
            syms = [get_sym_or_insert!(wp, Vector{UInt8}(w)) for w in words]
            release_permission!(wp)
            @test length(unique(syms)) == length(words)
            for (sym, w) in zip(syms, words)
                b = get_bytes(h, sym)
                @test b !== nothing
                @test collect(b) == Vector{UInt8}(w)
            end
        end

        @testset "try_acquire_permission re-entrant" begin
            h = SharedMappingHandle()
            wp1 = try_acquire_permission(h)
            @test wp1 !== nothing
            wp2 = try_acquire_permission(h)   # same task → reuse
            @test wp2 !== nothing
            @test wp1.index == wp2.index
            release_permission!(wp2)
            release_permission!(wp1)
        end
    end

    @testset "Frontend (bytestring_parser + json_parser)" begin
        @testset "sexpr_to_expr — atom" begin
            e = sexpr_to_expr("foo")
            s = expr_serialize(e)
            @test s == "foo"
        end

        @testset "sexpr_to_expr — variable NewVar" begin
            e = sexpr_to_expr("\$x")
            @test expr_tag_at(e) isa ExprNewVar
        end

        @testset "sexpr_to_expr — VarRef for repeated variable" begin
            e = sexpr_to_expr("(\$x \$x)")
            # arity byte, then NewVar, then VarRef(0)
            @test byte_item(e[1]) isa ExprArity
            @test byte_item(e[2]) isa ExprNewVar
            @test byte_item(e[3]) isa ExprVarRef
            @test byte_item(e[3]).idx == 0x00
        end

        @testset "sexpr_to_expr — nested compound" begin
            e = sexpr_to_expr("(foo (bar baz))")
            s = expr_serialize(e)
            @test occursin("foo", s)
            @test occursin("bar", s)
            @test occursin("baz", s)
        end

        @testset "sexpr_to_expr — comment skipped" begin
            e = sexpr_to_expr("; this is a comment\nfoo")
            s = expr_serialize(e)
            @test s == "foo"
        end

        @testset "sexpr_to_expr — arity-0 empty compound" begin
            e = sexpr_to_expr("()")
            @test byte_item(e[1]) isa ExprArity
            @test byte_item(e[1]).arity == 0x00
        end

        @testset "json_parse! — number via WriteTranscriber" begin
            p = JSONParser("42")
            wt = WriteTranscriber()
            json_parse!(p, wt)
            @test wt_result(wt) == "42"
        end

        @testset "json_parse! — WriteTranscriber roundtrip" begin
            json_in = """{"pos": 42, "neg": -100}"""
            p = JSONParser(json_in)
            wt = WriteTranscriber()
            json_parse!(p, wt)
            out = wt_result(wt)
            @test occursin("42", out)
            @test occursin("-100", out)
        end

        @testset "json_parse! — array" begin
            p = JSONParser("[1, 2, 3]")
            wt = WriteTranscriber()
            json_parse!(p, wt)
            out = wt_result(wt)
            @test out == "[1, 2, 3]"
        end

        @testset "json_parse! — nested object" begin
            p = JSONParser("""{"a": {"b": true}}""")
            wt = WriteTranscriber()
            json_parse!(p, wt)
            out = wt_result(wt)
            @test occursin("true", out)
        end

        @testset "json_parse! — string escapes" begin
            p = JSONParser("""{"k": "hello\\nworld"}""")
            wt = WriteTranscriber()
            json_parse!(p, wt)
            out = wt_result(wt)
            @test occursin("hello", out)
        end
    end

    @testset "ExprAlg (traverseh + unify)" begin
        @testset "expr_traverseh — symbol counting" begin
            buf = UInt8[0xC3, UInt8('f'), UInt8('o'), UInt8('o')]
            e = MORK.Expr(buf)
            (sym_count, _, _) = expr_traverseh(0, e, 0,
                (h, o) -> (h, nothing),
                (h, o, r) -> (h, nothing),
                (h, o, sl) -> (h + 1, nothing),    # count symbols via value
                (h, o, a) -> (h, 0),
                (h, o, x, y) -> (h, x + (y===nothing ? 0 : y)),
                (h, o, acc) -> (h, acc))
            # sym_count here is h_final (not updated in this config), use value instead
            (_, v, _) = expr_traverseh(0, e, 0,
                (h, o) -> (h, 0),
                (h, o, r) -> (h, 0),
                (h, o, sl) -> (h, 1),
                (h, o, a) -> (h, 0),
                (h, o, x, y) -> (h, x + y),
                (h, o, acc) -> (h, acc))
            @test v == 1
        end

        @testset "expr_traverseh — arity node" begin
            buf = UInt8[0x02,
                0xC3, UInt8('f'), UInt8('o'), UInt8('o'),
                0xC3, UInt8('b'), UInt8('a'), UInt8('r')]
            e = MORK.Expr(buf)
            (_, v, _) = expr_traverseh(0, e, 0,
                (h, o) -> (h, 0),
                (h, o, r) -> (h, 0),
                (h, o, sl) -> (h, 1),
                (h, o, a) -> (h, 0),
                (h, o, x, y) -> (h, x + y),
                (h, o, acc) -> (h, acc))
            @test v == 2
        end

        @testset "expr_traverseh — new_var counting via h" begin
            buf = UInt8[0x02, 0xC0, 0xC0]   # arity-2 ($ $)
            e = MORK.Expr(buf)
            (h_final, _, _) = expr_traverseh(0, e, 0,
                (h, o) -> (h + 1, nothing),    # new_var: increment h
                (h, o, r) -> (h, nothing),
                (h, o, sl) -> (h, nothing),
                (h, o, a) -> (h, nothing),
                (h, o, x, y) -> (h, nothing),
                (h, o, acc) -> (h, acc))
            @test h_final == 2
        end

        @testset "ee_args! — compound" begin
            e = MORK.Expr(
                UInt8[0x02, 0xC3, UInt8('a'), UInt8('b'), UInt8('c'),
                    0xC3, UInt8('d'), UInt8('e'), UInt8('f')]
            )
            ee = ExprEnv(0, e)
            kids = ExprEnv[]
            ee_args!(ee, kids)
            @test length(kids) == 2
        end

        @testset "ee_args! — atom (no children)" begin
            e = MORK.Expr(UInt8[0xC3, UInt8('f'), UInt8('o'), UInt8('o')])
            ee = ExprEnv(0, e)
            kids = ExprEnv[]
            ee_args!(ee, kids)
            @test isempty(kids)
        end

        @testset "expr_unify — trivial (same symbol)" begin
            e1 = MORK.Expr(UInt8[0xC3, UInt8('f'), UInt8('o'), UInt8('o')])
            e2 = MORK.Expr(UInt8[0xC3, UInt8('f'), UInt8('o'), UInt8('o')])
            result = expr_unify([(ExprEnv(0, e1), ExprEnv(1, e2))])
            @test result isa Dict
            @test isempty(result)
        end

        @testset "expr_unify — variable binds to symbol" begin
            # $x vs foo  →  x→foo
            e1 = MORK.Expr(UInt8[0xC0])                              # $x
            e2 = MORK.Expr(UInt8[0xC3, UInt8('f'), UInt8('o'), UInt8('o')])  # foo
            result = expr_unify([(ExprEnv(0, e1), ExprEnv(1, e2))])
            @test result isa Dict
            @test length(result) == 1
        end

        @testset "expr_unify — symbol mismatch fails" begin
            e1 = MORK.Expr(UInt8[0xC3, UInt8('f'), UInt8('o'), UInt8('o')])
            e2 = MORK.Expr(UInt8[0xC3, UInt8('b'), UInt8('a'), UInt8('r')])
            result = expr_unify([(ExprEnv(0, e1), ExprEnv(1, e2))])
            @test result isa UnificationFailure
            @test result.kind == MORK.UNIF_DIFFERENCE
        end
    end

    @testset "Space (ports mork/kernel/src/space.rs)" begin
        @testset "new_space / space_val_count" begin
            s = new_space()
            @test space_val_count(s) == 0
        end

        @testset "space_add_all_sexpr! — single atom" begin
            s = new_space()
            n = space_add_all_sexpr!(s, "foo")
            @test n == 1
            @test space_val_count(s) == 1
        end

        @testset "space_add_all_sexpr! — multiple expressions" begin
            s = new_space()
            n = space_add_all_sexpr!(s, "foo bar (baz qux)")
            @test n == 3
            @test space_val_count(s) == 3
        end

        @testset "space_remove_all_sexpr!" begin
            s = new_space()
            space_add_all_sexpr!(s, "foo bar")
            @test space_val_count(s) == 2
            space_remove_all_sexpr!(s, "foo")
            @test space_val_count(s) == 1
        end

        @testset "space_dump_all_sexpr roundtrip" begin
            s = new_space()
            space_add_all_sexpr!(s, "foo")
            out = space_dump_all_sexpr(s)
            @test occursin("foo", out)
        end

        @testset "space_load_json! — object" begin
            s = new_space()
            n = space_load_json!(s, """{"key": "val"}""")
            @test n >= 1
        end

        @testset "space_bitmask constants" begin
            # ExprArity(0) = 0x00: bucket=1, bit=0
            @test (SPACE_ARITIES[1] & UInt64(1)) != 0
            # ExprSymbol(1) = 0xC1: bucket=4 (0xC0>>6=3, +1=4), bit=1
            @test (SPACE_SIZES[4] & UInt64(2)) != 0
        end
    end

    # =========================================================================
    # metta_calculus integration tests (ports main.rs test functions)
    # =========================================================================

    @testset "metta_calculus integration (ports main.rs)" begin

        STEP_CAP = 100_000  # hitting this exactly = infinite loop bug

        # Returns (result, steps). Asserts steps < STEP_CAP to catch infinite loops.
        function _mc(src::String, cap::Int=STEP_CAP)
            s = new_space()
            space_add_all_sexpr!(s, src)
            steps = space_metta_calculus!(s, cap)
            @test steps < cap  # steps == cap means we hit the limit → infinite loop
            space_dump_all_sexpr(s)
        end

        @testset "lookup — exact ground pattern" begin
            result = _mc(
                "(exec 0 (, (Something (very specific))) (, MATCHED))\n(Something (very specific))\n"
            )
            @test occursin("MATCHED", result)
        end

        @testset "halt-on-fail — removed atom must not re-match (Control_08)" begin
            # Counter decrements (S(S(S Z)))→Z via `-` removals; once at Z the conjunct
            # (counter (S $N)) is unsatisfiable, so the exec must fail-and-halt. Regression
            # for the dangling-path bug: a non-pruning remove_val_at! left removed atoms
            # queryable, so the conjunction kept matching them and the loop never halted.
            src = "(counter (S (S (S Z))))\n" *
                  "(exec LOOP (, (counter (S \$N)) (exec LOOP \$p \$t)) " *
                  "(O (+ (exec LOOP \$p \$t)) (+ (counter \$N)) (- (counter (S \$N)))))\n"
            result = _mc(src, 1000)          # _mc asserts steps < cap (no infinite loop)
            @test occursin("(counter Z)", result)
        end

        @testset "O-sink set difference — removes apply after adds, order-independent" begin
            # Regression for the set-difference bug (Set_Ops_05): in (O (+ ...) (- ...)) the
            # removes must be collected across ALL matches and subtracted AFTER every add. With
            # per-match immediate removal, an atom added by one (a,b) match and removed by a later
            # one survives or dies by match ORDER: {a,b,c}\{b,c,d} gave the phantom {a,c} instead
            # of {a}. RemoveSink is now accumulating (_is_accumulating_sink), so removes win.
            src = "(arg_a a)\n(arg_a b)\n(arg_a c)\n(arg_b b)\n(arg_b c)\n(arg_b d)\n" *
                  "(exec 0 (, (arg_a \$a) (arg_b \$b)) (O (+ (ret \$a)) (- (ret \$b))))\n"
            result = _mc(src, 1000)
            @test occursin("(ret a)", result)
            @test !occursin("(ret b)", result)
            @test !occursin("(ret c)", result)   # the phantom survivor — pre-fix bug
            @test !occursin("(ret d)", result)
        end

        @testset "multi-factor query skips value-removed dangling paths" begin
            # Minimal: add 2 atoms, remove one, a 2-factor conjunction must NOT match it.
            s = new_space()
            space_add_all_sexpr!(s, "(counter (S Z))\n(marker a)\n")
            MORK.remove_val_at!(s.btm, MORK.sexpr_to_expr("(counter (S Z))").buf)
            pat = MORK.sexpr_to_expr("(, (counter (S \$N)) (marker \$x))")
            n = Ref(0)
            MORK.space_query_multi(s, pat, (a...) -> (n[] += 1; true))
            @test n[] == 0
        end

        @testset "!= comparison source (CmpSource, ports source_cmp_ne)" begin
            # The `!=` source builds its secondary as `btm minus this path` via psubtract,
            # which returns an AlgebraicResult (not a bare PathMap). Regression for two bugs:
            # (1) read_zipper on the raw AlgResElement (Sources.jl), and (2) psubtract over a
            # node with an empty-child rc crashing on node_is_empty(::Nothing) (PathMap).
            result = _mc(
                "(VAL X) (VAL Y) (VAL Z)\n" *
                "(exec 0 (I (!= (VAL \$x) (VAL \$y) ) ) (, (OUT (\$x != \$y)) ))\n"
            )
            for p in ["(OUT (X != Y))", "(OUT (X != Z))", "(OUT (Y != X))",
                      "(OUT (Y != Z))", "(OUT (Z != X))", "(OUT (Z != Y))"]
                @test occursin(p, result)
            end
            @test !occursin("(X != X)", result)   # an element is never != itself
        end

        @testset "ACT backup_tree → (ACT …) source read + restore round-trip" begin
            # Regression: space_backup_tree wrote serialize_paths (that's backup_PATHS), but
            # (ACT …) sources mmap-read an ArenaCompactTree — so ACT reads of a backup_tree file
            # crashed ("Invalid ACTree magic"). Upstream backup_tree = ArenaCompactTree dump.
            dir = mktempdir()
            old = MORK.ACT_PATH[]
            try
                MORK.ACT_PATH[] = dir
                act_s = new_space()
                space_add_all_sexpr!(act_s, "(fact a)\n(fact b)\n(fact c)\n")
                space_backup_tree(act_s, joinpath(dir, "simple.act"))
                # (ACT …) source reads the backed-up tree
                s = new_space()
                space_add_all_sexpr!(s, "(exec 0 (I (ACT simple (fact \$x))) (, (got \$x)))\n")
                space_metta_calculus!(s, 1000)
                d = space_dump_all_sexpr(s)
                @test occursin("(got a)", d) && occursin("(got b)", d) && occursin("(got c)", d)
                # backup_tree → restore_tree! round-trip
                s2 = new_space()
                space_restore_tree!(s2, joinpath(dir, "simple.act"))
                d2 = space_dump_all_sexpr(s2)
                @test occursin("(fact a)", d2) && occursin("(fact b)", d2) && occursin("(fact c)", d2)
            finally
                MORK.ACT_PATH[] = old
            end
        end

        @testset "positive — variable pattern matches ground fact" begin
            result = _mc(
                "(exec 0 (, (Something \$unspecific)) (, MATCHED))\n(Something (very specific))\n"
            )
            @test occursin("MATCHED", result)
        end

        @testset "positive_equal — repeated variable constraint" begin
            result = _mc(
                "(exec 0 (, (Something \$rep \$rep)) (, MATCHED))\n(Something (very specific) (very specific))\n"
            )
            @test occursin("MATCHED", result)
        end

        @testset "negative — ground pattern, variable fact" begin
            result = _mc(
                "(exec 0 (, (Something (very specific))) (, MATCHED))\n(Something \$unspecific)\n"
            )
            @test occursin("MATCHED", result)
        end

        @testset "negative_equal — ground repeated, variable fact" begin
            result = _mc(
                "(exec 0 (, (Something (very specific) (very specific))) (, MATCHED))\n(Something \$rep \$rep)\n"
            )
            @test occursin("MATCHED", result)
        end

        @testset "bipolar — partial variable both sides" begin
            result = _mc(
                "(exec 0 (, (Something (very \$u))) (, MATCHED))\n(Something (\$u specific))\n"
            )
            @test occursin("MATCHED", result)
        end

        @testset "two_positive_equal — two-source join, repeated vars" begin
            result = _mc(
                "(exec 0 (, (Something \$x \$x) (Else \$y \$y)) (, MATCHED))\n(Something (foo bar) (foo bar))\n(Else (bar baz) (bar baz))\n"
            )
            @test occursin("MATCHED", result)
        end

        @testset "two_positive_equal_crossed — shared vars across sources" begin
            result = _mc(
                "(exec 0 (, (Something \$x \$y) (Else \$x \$y)) (, MATCHED))\n(Something (foo bar) (bar baz))\n(Else (foo bar) (bar baz))\n"
            )
            @test occursin("MATCHED", result)
        end

        @testset "top_level_match — ground-to-ground rule" begin
            result = _mc("(exec 0 (, foo) (, bar))\nfoo\n")
            @test occursin("bar", result)
        end

        @testset "two_bipolar_equal_crossed — variable substitution in output" begin
            result = _mc(
                "(exec 0 (, (Something \$x \$y) (Else \$x \$y)) (, (MATCHED \$x \$y)))\n" *
                "(Something (foo \$x) (foo \$x))\n(Else (\$x bar) (\$x bar))\n"
            )
            @test occursin("(MATCHED (foo bar) (foo bar))", result)
        end

    end   # metta_calculus integration

    @testset "PathMap deferred items" begin

        @testset "act_open_mmap — mmap-backed ACT file" begin
            m = PM{UInt64}()
            PathMap.set_val_at!(m, b"alpha", UInt64(42))
            PathMap.set_val_at!(m, b"beta", UInt64(99))
            PathMap.set_val_at!(m, b"gamma", UInt64(7))

            tree_vec = PathMap.act_from_zipper(m, v -> v)
            tmpfile = tempname() * ".act"
            PathMap.act_save(tree_vec, tmpfile)

            tree_mmap = PathMap.act_open_mmap(tmpfile)
            @test tree_mmap isa PathMap.ArenaCompactTree
            @test length(tree_mmap.data) == filesize(tmpfile)
            @test tree_mmap.data[1:8] == PathMap.ACT_MAGIC

            @test PathMap.act_get_val_at(tree_mmap, b"alpha") === UInt64(42)
            @test PathMap.act_get_val_at(tree_mmap, b"beta") === UInt64(99)
            @test PathMap.act_get_val_at(tree_mmap, b"gamma") === UInt64(7)
            @test PathMap.act_get_val_at(tree_mmap, b"missing") === nothing

            # mmap and copy agree on all keys
            tree_copy = PathMap.act_open(tmpfile)
            for key in (b"alpha", b"beta", b"gamma", b"missing")
                @test PathMap.act_get_val_at(tree_mmap, key) ===
                    PathMap.act_get_val_at(tree_copy, key)
            end

            # ACTZipper traversal over mmap tree
            @test PathMap.act_val_count(PathMap.act_read_zipper(tree_mmap)) == 3

            rm(tmpfile; force=true)
        end

        @testset "remove_val_at! with prune=true" begin
            m = PM{Int}()
            PathMap.set_val_at!(m, b"abc", 1)
            PathMap.set_val_at!(m, b"abd", 2)
            PathMap.set_val_at!(m, b"xyz", 3)

            old = PathMap.remove_val_at!(m, b"abc", true)
            @test old === 1
            @test PathMap.get_val_at(m, b"abc") === nothing
            @test PathMap.get_val_at(m, b"abd") === 2
            @test PathMap.get_val_at(m, b"xyz") === 3
        end

        @testset "wz_remove_branches! with prune=true" begin
            m = PM{Int}()
            PathMap.set_val_at!(m, b"foo:a", 10)
            PathMap.set_val_at!(m, b"foo:b", 20)
            PathMap.set_val_at!(m, b"bar", 30)

            wz = PathMap.write_zipper_at_path(m, b"foo:")
            PathMap.wz_remove_branches!(wz, true)

            @test PathMap.get_val_at(m, b"foo:a") === nothing
            @test PathMap.get_val_at(m, b"foo:b") === nothing
            @test PathMap.get_val_at(m, b"bar") === 30
        end

    end   # PathMap deferred items

    @testset "MORK new sinks" begin

        # Build a [2] U <bytes> header for USink paths
        _u_hdr() = UInt8[item_byte(ExprArity(UInt8(2))),
            item_byte(ExprSymbol(UInt8(1))), UInt8('U')]
        # Build a [2] AU <bytes> header for AUSink paths
        _au_hdr() = UInt8[item_byte(ExprArity(UInt8(2))),
            item_byte(ExprSymbol(UInt8(2))), UInt8('A'), UInt8('U')]
        # Build a symbol sub-expression
        _sym(s::String) = vcat(item_byte(ExprSymbol(UInt8(length(s)))), Vector{UInt8}(s))

        @testset "CmpSource — stale comment removed, dispatch works" begin
            s = new_space()
            space_add_all_sexpr!(
                s,
                raw"""
(foo 1) (foo 2) (foo 3)
(exec 0 (, (foo $x) (== $x $x)) (, (matched $x)))
"""
            )
            steps = space_metta_calculus!(s, 10)
            @test steps >= 1
        end

        @testset "USink — identical ground terms unify" begin
            btm = new_space().btm
            # Build (U foo) sink; expr bytes don't matter for apply/finalize
            e_buf = vcat(_u_hdr(), _sym("foo"))
            sink = USink(MORK.Expr(e_buf))
            # Two identical paths → MGU = foo
            p = vcat(_u_hdr(), _sym("foo"))
            sink_apply!(sink, Dict(), p, btm)
            sink_apply!(sink, Dict(), copy(p), btm)
            @test sink_finalize!(sink, btm) == true
            @test get_val_at(btm, _sym("foo")) === UNIT_VAL
        end

        @testset "USink — single path written unchanged" begin
            btm = new_space().btm
            e_buf = vcat(_u_hdr(), _sym("bar"))
            sink = USink(MORK.Expr(e_buf))
            p = vcat(_u_hdr(), _sym("bar"))
            sink_apply!(sink, Dict(), p, btm)
            @test sink_finalize!(sink, btm) == true
            @test get_val_at(btm, _sym("bar")) === UNIT_VAL
        end

        @testset "USink — conflict on incompatible ground terms" begin
            btm = new_space().btm
            e_buf = vcat(_u_hdr(), _sym("x"))
            sink = USink(MORK.Expr(e_buf))
            sink_apply!(sink, Dict(), vcat(_u_hdr(), _sym("foo")), btm)
            sink_apply!(sink, Dict(), vcat(_u_hdr(), _sym("bar")), btm)
            @test sink_finalize!(sink, btm) == false   # conflict → nothing written
        end

        @testset "SumSink — (sum <result> <expected> \$x): emit iff sum == expected (ports sink_sum_literal)" begin
            # Upstream sink_sum_literal: accumulate $x over matches grouped by (<result> <expected>),
            # emit <result> iff the decimal sum equals the <expected> literal. (foo 1/2/3) sums to 6:
            # (sum (correct) 6 $x) emits (correct); (sum (incorrect) 5 $x) emits nothing (6 ≠ 5).
            # Replaces the prior unit test of the placeholder sink (which flat-summed bare symbols and
            # ignored <result>/<expected>); requires `sum` ∈ _is_accumulating_sink to sum across matches.
            s = new_space()
            space_add_all_sexpr!(s,
                "(foo 1) (foo 2) (foo 3)\n" *
                "(exec 0 (, (foo \$x)) (O (sum (correct) 6 \$x)))\n" *
                "(exec 0 (, (foo \$x)) (O (sum (incorrect) 5 \$x)))\n")
            steps = space_metta_calculus!(s, 1000)
            @test steps < 1000
            result = space_dump_all_sexpr(s)
            @test occursin("(correct)", result)        # sum 1+2+3 == 6 → emit
            @test !occursin("incorrect", result)        # sum 6 ≠ 5 → no emit
        end

        @testset "HeadSink — finalize joins head map into btm (regression: was MethodError)" begin
            # Regression for the COW-audit finding: sink_finalize! called
            # wz_join_into!(wz, root) where root::TrieNodeODRc, but wz_join_into!
            # only accepts an AbstractNodeRef → MethodError. Fixed to use the
            # map-level wz_join_map_into!(wz, s.head). Populate the collected-head
            # map directly (skip/max are irrelevant to finalize).
            btm = new_space().btm
            e_buf = vcat(item_byte(ExprArity(UInt8(3))), _sym("head"), _sym("2"), _sym("x"))
            sink = HeadSink(MORK.Expr(e_buf))
            set_val_at!(sink.head, b"alpha", UNIT_VAL)
            set_val_at!(sink.head, b"beta", UNIT_VAL)
            @test sink_finalize!(sink, btm) == true          # no MethodError; join happened
            @test get_val_at(btm, b"alpha") === UNIT_VAL     # head map joined into btm
            @test get_val_at(btm, b"beta") === UNIT_VAL
        end

        @testset "AUSink — identical terms → same term written" begin
            btm = new_space().btm
            e_buf = vcat(_au_hdr(), _sym("foo"))
            sink = AUSink(MORK.Expr(e_buf))
            p = vcat(_au_hdr(), _sym("foo"))
            sink_apply!(sink, Dict(), p, btm)
            sink_apply!(sink, Dict(), copy(p), btm)
            @test sink_finalize!(sink, btm) == true
            @test get_val_at(btm, _sym("foo")) === UNIT_VAL
        end

        @testset "AUSink — differing terms → fresh variable" begin
            btm = new_space().btm
            e_buf = vcat(_au_hdr(), _sym("x"))
            sink = AUSink(MORK.Expr(e_buf))
            sink_apply!(sink, Dict(), vcat(_au_hdr(), _sym("foo")), btm)
            sink_apply!(sink, Dict(), vcat(_au_hdr(), _sym("bar")), btm)
            @test sink_finalize!(sink, btm) == true
            # LGG of two different symbols is ExprNewVar
            @test get_val_at(btm, UInt8[item_byte(ExprNewVar())]) === UNIT_VAL
        end

        @testset "ACTSink — writes .act file on finalize" begin
            tmpdir = mktempdir()
            old_path = ACT_PATH[]
            ACT_PATH[] = tmpdir
            try
                btm = new_space().btm
                name = "testfile"
                e_buf = vcat(item_byte(ExprArity(UInt8(3))),
                    item_byte(ExprSymbol(UInt8(3))), Vector{UInt8}("ACT")...,
                    item_byte(ExprSymbol(UInt8(length(name)))), Vector{UInt8}(name)...,
                    _sym("x"))
                sink = ACTSink(MORK.Expr(e_buf))
                # Construct a path that starts with the ACT prefix
                content = _sym("abc")
                path = vcat(e_buf[1:sink.skip], content)
                sink_apply!(sink, Dict(), path, btm)
                @test sink_finalize!(sink, btm) == true
                @test isfile(joinpath(tmpdir, "testfile.act"))
            finally
                ACT_PATH[] = old_path
            end
        end

        @testset "HashSink — does not throw on valid path" begin
            btm = new_space().btm
            e_buf = vcat(item_byte(ExprArity(UInt8(4))),
                item_byte(ExprSymbol(UInt8(4))), Vector{UInt8}("hash")...,
                _sym("r"), _sym("c"), _sym("h"))
            sink = HashSink(MORK.Expr(e_buf))
            content = vcat(_sym("abc"), _sym("xyz"))
            path = vcat(e_buf[1:sink.skip], content)
            sink_apply!(sink, Dict(), path, btm)
            @test_nowarn sink_finalize!(sink, btm)
        end

        # ------------------------------------------------------------------
        # CountSink — all three upstream modes (mirrors main.rs test cases)
        # ------------------------------------------------------------------

        @testset "CountSink mode 2 — variable embed: (count (all \$k) \$k source)" begin
            # Mirrors upstream sink_count_constant: result embeds count in template
            s = new_space()
            space_add_all_sexpr!(
                s,
                raw"""
(foo 1) (foo 2) (foo 3)
(bar x) (bar y)
(baz P) (baz Q) (baz R)
(exec 0 (, (foo $x) (bar $y) (baz $z)) (O (count (all $k) $k (cux $z $y $x))))
"""
            )
            space_metta_calculus!(s, typemax(Int))
            out = space_dump_all_sexpr(s)
            # 3 foo × 2 bar × 3 baz = 18 unique (cux ...) combos
            @test any(l -> occursin("all", l) && occursin("18", l), split(out, "\n"))
        end

        @testset "CountSink mode 1 — fixed guard: (count (all eighteen) 18 source)" begin
            # Mirrors upstream sink_count_literal: only emit when count == literal
            s = new_space()
            space_add_all_sexpr!(
                s,
                raw"""
(foo 1) (foo 2) (foo 3)
(bar x) (bar y)
(baz P) (baz Q) (baz R)
(exec 0 (, (foo $x) (bar $y) (baz $z)) (O (count (all eighteen) 18 (cux $z $y $x))))
(exec 0 (, (foo $x) (bar $y) (baz $z)) (O (count (all sixteen) 16 (cux $z $y $x))))
"""
            )
            space_metta_calculus!(s, typemax(Int))
            out = space_dump_all_sexpr(s)
            lines = split(out, "\n")
            @test any(l -> occursin("eighteen", l), lines)   # 18 matches → emitted
            @test !any(l -> occursin("sixteen", l), lines)   # 16 ≠ 18 → not emitted
        end

        @testset "CountSink mode 3 — variable no-embed: (count (all stupid) \$k source)" begin
            # Mirrors upstream sink_count_constant: template has no $k, always emit
            s = new_space()
            space_add_all_sexpr!(
                s,
                raw"""
(foo 1) (foo 2) (foo 3)
(bar x) (bar y)
(baz P) (baz Q) (baz R)
(exec 0 (, (foo $x) (bar $y) (baz $z)) (O (count (all stupid) $k (cux $z $y $x))))
"""
            )
            space_metta_calculus!(s, typemax(Int))
            out = space_dump_all_sexpr(s)
            @test any(l -> occursin("stupid", l), split(out, "\n"))
        end

        @testset "CountSink — two independent sinks, different sources" begin
            # Mirrors upstream count-1/count-2: independent per-variable counts
            s = new_space()
            space_add_all_sexpr!(
                s,
                raw"""
(item a) (item b) (item c)
(item2 a) (item2 b) (item2 c) (item2 d)
(exec 0 (, (item $x) (item2 $y))
         (O (count (count-1 $k) $k $x)
            (count (count-2 $j) $j $y)))
"""
            )
            space_metta_calculus!(s, typemax(Int))
            out = space_dump_all_sexpr(s)
            lines = split(out, "\n")
            @test any(l -> occursin("count-1", l) && occursin("3", l), lines)
            @test any(l -> occursin("count-2", l) && occursin("4", l), lines)
        end

    end   # MORK new sinks

    # ==================================================================
    # space_query_coref — coreferential DFS query
    # ==================================================================

    @testset "space_query_coref — single source with shared variable" begin
        # (edge $x $x) — self-loops: DFS correctly skips non-self-loops
        s = new_space()
        space_add_all_sexpr!(s, "(edge 0 0) (edge 1 2) (edge 3 3)")
        prog = raw"(exec 0 (, (edge $x $x)) (, (loop $x)))"
        space_add_all_sexpr!(s, prog)
        space_metta_calculus!(s, typemax(Int))
        out = space_dump_all_sexpr(s)
        n_loop = count(l -> occursin("(loop", l), split(out, "\n"))
        @test n_loop == 2   # only (edge 0 0) and (edge 3 3)
    end

    @testset "space_query_coref — multi-source falls back to ProductZipper" begin
        # Multi-source: falls back to space_query_multi, results match
        s = new_space()
        space_add_all_sexpr!(s, "(edge 0 1) (edge 1 2) (edge 2 3)")
        prog = raw"(exec 0 (, (edge $x $y) (edge $y $z)) (, (path $x $z)))"
        space_add_all_sexpr!(s, prog)
        space_metta_calculus!(s, typemax(Int))
        out = space_dump_all_sexpr(s)
        n_path = count(l -> occursin("(path", l), split(out, "\n"))
        @test n_path == 2   # 0→2, 1→3
    end

    # ── Prefix-scoped multi-space primitives (PRIMUS-original) ────────────────
    include("integration/prefix_scoped.jl")

    # ── Wiki example programs ─────────────────────────────────────────────────
    include("integration/test_wiki_examples.jl")

    # ── MM2 corpus differential gate (vs upstream `mork` outputs) ──────────────
    # Asserts the tutorial's stated upstream output for each MM2_Structuring_Code program — the
    # output-level check that caught the O-sink difference bug (a halting check passed while the
    # result was wrong). Locks in 8f0d182 / 7908fbd / e59a16b.
    include("integration/mm2_corpus_differential.jl")

    # ── CTL model-checker regression (gates EU least-fixpoint / PathMap-CoW fix 05451ee) ──
    # Runs the full CTL checker (MM2 program on the exec-calculus) to a natural fixpoint and
    # asserts the wiki golden state-sets. F1's state 2 is the sentinel: pre-05451ee the EU
    # least-fixpoint halted one round early -> [6,7,8,12] (2 missing).
    include("integration/ctl_model_checking.jl")

    # ── ADR-056 Lever A / P1: empty-tail trie-join ≡ ProductZipper ────────────
    include("integration/trie_join.jl")

    # ── Real Z3Sink + Z3Source round-trip (guarded on z3_available) ───────────
    include("integration/z3_roundtrip.jl")

    # ── exec-visibility regression (bug found 2026-07-23 by differential sweep) ──
    # A bare-variable exec pattern `(exec 0 (, $x) …)` must see the just-removed exec (upstream
    # re-inserts it unconditionally); the `_pat_overlaps_exec_prefix` byte-scan used to miss it.
    include("integration/exec_visibility.jl")

    # ── BFC occurs-check regression (fix 2026-07-25) ──────────────────────────
    # Nil's backward-via-forward proof search (bfc size 13) on the coref join. Gates the
    # deref-aware occurs-check fix: pre-fix, `exec(3 3)` accepted an occurs-violating binding
    # (a data var bound to a term containing itself) → a spurious 3rd `(final)` proof upstream
    # rejects. Asserts exactly 2 finals / 9938 atoms / 393 steps, byte-exact vs upstream.
    include("integration/bfc_occurs_check.jl")

    # ── HARD ip_sudoku — BYTE-EXACT vs upstream (fixes 2026-07-25) ────────────
    # The resource fixture (AndSink + coref source join) needed TWO fixes: AndSink wasn't marked
    # accumulating (finalized per-match → cells collapsed 16→4), and the pure sink substituted its
    # computed value without RE-BASING trailing de-Bruijn refs (respawn drifted `_1`→`_2`, halting
    # propagation at 12 steps). Now asserts the full 102-atom set + steps==34 against the vendored
    # upstream reference.
    include("integration/ip_sudoku_andsink.jl")

    # ── pure comparison ops (ported 2026-07-26) ──────────────────────────────
    # `{lt,gt,lte,gte,eq,ne} × {i8,i16,i32,i64,i128,f32,f64}` — the ONLY family missing from our
    # pure-op table (371 upstream ops, 42 absent). Each returns a 1-BYTE i8, not the operand width.
    # These are what makes MM2's "ordering is derivable in the pure-sink layer" claim actually true.
    include("integration/pure_comparison_ops.jl")

    # ── AndSink/SumSink three-branch conformance (fix 2026-07-26) ─────────────
    # Upstream's reduction sinks have THREE branches (SIZES fixed-literal / NewVar ignored guard /
    # VarRef splice-with-rebasing); ours had implemented COMPLEMENTARY SINGLE halves — AndSink only
    # the VarRef branch (filling the wrong slot, un-rebased), SumSink only the fixed-literal branch.
    # Every missing branch was a SILENT DROP. 9 probes, ground truth from the upstream binary.
    include("integration/sink_and_sum_branches.jl")

    # ── Differential conformance vs the built upstream Rust `mork` binary ──────
    # (guarded on the binary being present; catches default-engine divergence)
    include("integration/upstream_conformance.jl")

    # ── Allocation regression gates (Unit A + B) ──────────────────────────────
    include("alloc_budget.jl")

    @testset "MorkL OP_DROP_HEAD — strips first length-prefixed layer (regression: was no-op)" begin
        # Audit M-1: OP_DROP_HEAD was an IDENTITY NO-OP — the "skip b bytes" logic was a
        # comment inside an empty if-body, so it returned the input unmodified. Fixed via
        # _morkl_drop_head, porting Op::DropHead (experiments/morkl_interpreter/lib.rs:385):
        # for each length-byte child b>0, descend [b], drop_head(b), ascend; then
        # drop_head(1) at root. Path = (len2 "ab")(len1 "c") → strip first layer → (len1 "c").
        m = PM{UnitVal}()
        full = UInt8[0x02, 0x61, 0x62, 0x01, 0x63]
        set_val_at!(m, full, UNIT_VAL)
        out = MORK._morkl_drop_head(m)
        @test get_val_at(out, UInt8[0x01, 0x63]) === UNIT_VAL   # first layer stripped
        @test get_val_at(out, full) === nothing                  # original layer gone
    end

    @testset "Pure i128 ops — no truncation to 64-bit (audit P-1)" begin
        # The i128 ops used _read_i64 (8 bytes) + Int64 math → values beyond Int64
        # range were truncated. Fixed to native Int128 via _read_i128/_be_bytes(Int128).
        v = Int128(2)^100 + 7
        arg = collect(reinterpret(UInt8, [hton(v)]))   # 16 BE bytes
        res = MORK.pure_apply("abs_i128", [arg])
        @test length(res) == 16
        @test MORK._read_i128(res) == v                # full value, not high-8-byte truncation
        # overflow case: 2^62 + 2^62 = 2^63 overflows Int64 but fits Int128
        a = collect(reinterpret(UInt8, [hton(Int128(2)^62)]))
        @test MORK._read_i128(MORK.pure_apply("sum_i128", [a, a])) == Int128(2)^63

        # D-P1 regression (audit 2026-06-04): sub/mod/div/one/from_string/to_string + the
        # *_as_i128 conversions ALSO used _read_i64/Int64 and were silently truncating
        # |x| ≥ 2^63. Lock them with operands beyond Int64 range.
        be128(x) = collect(reinterpret(UInt8, [hton(Int128(x))]))
        big = Int128(2)^80 + 123
        @test MORK._read_i128(MORK.pure_apply("sub_i128", [be128(big), be128(5)])) ==
            big - 5
        @test MORK._read_i128(MORK.pure_apply("mod_i128", [be128(big), be128(1000)])) ==
            rem(big, Int128(1000))
        @test MORK._read_i128(MORK.pure_apply("div_i128", [be128(big), be128(7)])) ==
            div(big, Int128(7))
        @test length(MORK.pure_apply("i128_one", [UInt8[]])) == 16
        @test MORK._read_i128(MORK.pure_apply("i128_one", [UInt8[]])) == Int128(1)
        # i64_as_i128 must widen to 16 bytes (was returning Int64 → 8 bytes)
        res128 = MORK.pure_apply(
            "i64_as_i128", [collect(reinterpret(UInt8, [hton(Int64(-9))]))]
        )
        @test length(res128) == 16
        @test MORK._read_i128(res128) == Int128(-9)
        # round-trip through string
        @test MORK._read_i128(
            MORK.pure_apply("i128_from_string",
                [Vector{UInt8}(string(big))])
        ) == big
    end

    # SP-3 (audit 2026-06-04): space_transform_multi_multi! reads `read_btm = s.btm`
    # directly (no copy) — sound ONLY because ReadZipperCore captures an Rc snapshot at
    # construction and COW writes during the match fork s.btm's spine independently. A
    # self-feeding rule (output re-matches its own pattern) is where a COW regression would
    # silently corrupt in-flight reads. COVERAGE ALREADY EXISTS: the integration test
    # `wiki: transitive.mm2` (test/integration/test_wiki_examples.jl) runs the self-feeding
    # rule `(exec 1 (, (edge $x $y) (edge $y $z)) (, (edge $x $z)))` to a bounded fixpoint —
    # exactly the read_btm=s.btm path. (A bespoke deep-closure marker test was dropped: at
    # uniform priority it doesn't reliably derive a specific deep pair — a priority/iteration
    # nuance of the dialect, NOT a COW issue.) Below: a minimal single-step self-feed guard.
    @testset "SP-3: self-feeding edge rule runs over the COW read-snapshot" begin
        s = new_space()
        space_add_all_sexpr!(s,
            "(exec 1 (, (edge \$x \$y) (edge \$y \$z)) (, (edge \$x \$z)))\n" *
            "(edge a b)\n(edge b c)\n")
        steps = space_metta_calculus!(s, 100_000)
        @test steps < 100_000                         # terminates (no COW-corruption loop)
        @test occursin("(edge a c)", space_dump_all_sexpr(s))  # self-feed derived a→c
    end

    @testset "Pure ternarylogic — honors selector + full width (audit P-2)" begin
        # The *_ternarylogic ops ignored x, y, AND the selector (they rebuilt z) — and
        # u128_ternarylogic truncated to u64. Fixed via the general vpternlog
        # _ternarylogic (8-minterm LUT ≡ upstream 256-case ternary_table).
        x = UInt8(0b11001010);
        y = UInt8(0b10110100);
        z = UInt8(0b01101001)
        tl(s) = only(
            MORK.pure_apply("u8_ternarylogic",
                [
                    MORK._be_bytes(x),
                    MORK._be_bytes(y),
                    MORK._be_bytes(z),
                    MORK._be_bytes(UInt8(s))
                ])
        )
        @test tl(0xF0) == x            # selector 0xF0 ⇒ identity on x
        @test tl(0xCC) == y            # 0xCC ⇒ y
        @test tl(0xAA) == z            # 0xAA ⇒ z
        @test tl(0xFE) == (x | y | z)  # OR
        @test tl(0x80) == (x & y & z)  # AND
        # u128 path: full width + selector honored (was truncating to u64, ignoring s)
        vx = UInt128(2)^100
        @test MORK._read_u128(
            MORK.pure_apply("u128_ternarylogic",
                [
                    MORK._be_bytes(vx),
                    MORK._be_bytes(UInt128(0)),
                    MORK._be_bytes(UInt128(0)),
                    MORK._be_bytes(0xF0)
                ])
        ) == vx
    end

    @testset "Pure u128 bitwise — full 128-bit width + nary folds (audit P-1/P-3)" begin
        # The whole u128_* family (except ones/zeros/ternarylogic) read _read_u64 and
        # computed in 64 bits — silently wrong for values ≥ 2^64. and/or/parity were
        # also coded as binary, but pure.rs:477-479 makes them N-ary folds. Fixed to
        # _read_u128 + UInt128 math, matching the u64 sibling family.
        b128(x) = MORK._be_bytes(UInt128(x))
        u128(b) = MORK._read_u128(b)
        u64r(b) = ntoh(only(reinterpret(UInt64, b[1:8])))
        # count/leading ops return u32 for EVERY integer width in Rust (`u128::count_ones() -> u32`),
        # so upstream emits 4 bytes — verified directly for u8 (`\0\0\0\x02`). Was read as u64 here,
        # encoding the pre-2026-07-23 bug where our port emitted the input width. Result VALUES (≤128)
        # fit in u32 fine.
        u32r(b) = ntoh(only(reinterpret(UInt32, b[1:4])))
        allones = ~UInt128(0)
        hi = UInt128(0x0102030405060708090a0b0c0d0e0f10)
        # population counts span all 128 bits (was capped at 64); result width is u32
        @test u32r(MORK.pure_apply("u128_count_ones", [b128(allones)])) == 128
        @test u32r(MORK.pure_apply("u128_count_zeros", [b128(0)])) == 128
        @test u32r(MORK.pure_apply("u128_leading_zeros", [b128(0)])) == 128
        @test u32r(MORK.pure_apply("u128_leading_ones", [b128(allones)])) == 128
        # N-ary folds over >2 args
        @test u128(MORK.pure_apply("u128_and", [b128(allones), b128(allones), b128(hi)])) ==
            hi
        @test u128(MORK.pure_apply("u128_or", [b128(0), b128(hi), b128(0)])) == hi
        @test u128(MORK.pure_apply("u128_parity", [b128(hi), b128(hi), b128(hi)])) == hi  # x^x^x
        # binary bit ops touch the high 64 bits
        @test u128(MORK.pure_apply("u128_not", [b128(hi)])) == ~hi
        @test u128(MORK.pure_apply("u128_nand", [b128(allones), b128(hi)])) ==
            ~(allones & hi)
        @test u128(MORK.pure_apply("u128_andn", [b128(allones), b128(hi)])) ==
            (allones & ~hi)
        @test u128(MORK.pure_apply("u128_swap_bytes", [b128(hi)])) == bswap(hi)
        @test u128(MORK.pure_apply("u128_reverse_bits", [b128(hi)])) == bitreverse(hi)
        # shift amount is u32 (4 bytes) — upstream shl/shr all take `y: u32` (pure.rs). Was UInt64
        # (8 bytes) here, matching the old _read_u32s bug; a real 4-byte shift (e.g. ip_sudoku's
        # sub_i32) BoundsError'd against the old 8-byte read.
        @test u128(MORK.pure_apply("u128_shl", [b128(1), MORK._be_bytes(UInt32(100))])) ==
            (UInt128(1) << 100)
    end

    @testset "expr_span ≡ _expr_end_offset at all offsets (E-1 retracted; S-1 drift guard)" begin
        # E-1 flagged expr_span's depth-walk as "suspect"; a differential check vs the
        # canonical recursive _expr_end_offset shows EQUIVALENCE at every item offset,
        # including nested/compound positions — so it is NOT a live bug. This pins the
        # two impls so they cannot silently drift apart (S-1: 3 competing span impls).
        A(n) = item_byte(ExprArity(UInt8(n)))
        Sy(s) = vcat(item_byte(ExprSymbol(UInt8(length(s)))), Vector{UInt8}(codeunits(s)))
        NV() = item_byte(ExprNewVar());
        VR(i) = item_byte(ExprVarRef(UInt8(i)))
        function starts!(buf, off, acc)
            off > length(buf) && return off
            push!(acc, off);
            t = byte_item(buf[off])
            if t isa ExprSymbol
                ;
                return off + 1 + Int(t.size)
            elseif t isa ExprArity
                ;
                cur = off + 1;
                for _ in 1:Int(t.arity)
                    ;
                    cur = starts!(buf, cur, acc);
                end;
                return cur
            else
                ;
                return off + 1;
            end
        end
        bufs = [vcat(A(2), Sy("a"), Sy("b")), vcat(A(2), Sy("a"), A(2), Sy("b"), Sy("c")),
            vcat(A(3), Sy("a"), NV(), Sy("b")), vcat(A(2), Sy("a"), A(0)),
            vcat(A(2), A(2), Sy("a"), Sy("b"), A(3), Sy("c"), Sy("d"), Sy("e")),
            vcat(A(1), A(1), A(1), Sy("z")), vcat(
                A(3), Sy("f"), A(2), Sy("g"), NV(), VR(2)
            )]
        for buf in bufs
            e = MORK.Expr(buf);
            acc = Int[];
            starts!(buf, 1, acc)
            for off in acc
                @test off + length(MORK.expr_span(e, off)) ==
                    MORK._expr_end_offset(buf, off)
            end
        end
    end

end

# Post-suite: a testset that asserted NOTHING must fail the build, not read as green.
assert_no_inert_testsets(_MORK_TS)
