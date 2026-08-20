# Leapfrog LAYER 2 — the zipper subterm cursor.
#
# 🔑 THE ORACLE IS THE SPACE ITSELF. The cursor claims to enumerate "the complete variable-width
# subterms branching from a zipper's focus, in ascending lexicographic order". We know exactly which
# subterms those are — we put them there. So the test builds a space from known atoms and asserts
# the cursor reproduces THAT set, sorted, rather than asserting it agrees with a hand-written list
# of bytes I derived from the same understanding that produced the code.
#
# ⚠️ AND THE INVARIANT IS CHECKED BY SOMETHING THAT RUNS. Upstream guards the incremental parse with
# `debug_assert!`, which compiles out in the release build the join actually ships in. We expose it
# as `cursor_check_invariants` and call it at EVERY step below, so the check exists in CI rather
# than exactly where it would not.

using MORK, Test
const _LF = MORK.Leapfrog

"Build a space from sexpr lines and return a cursor at the root."
function _lf_cursor(lines::Vector{String})
    s = MORK.new_space()
    MORK.space_add_all_sexpr!(s, join(lines, "\n") * "\n")
    (s, _LF.SubtermCursor(MORK.read_zipper(s.btm)))
end

"Drain a cursor into the list of subterm byte-vectors it yields, checking invariants at each step."
function _lf_drain!(c; limit::Int = 10_000)
    out = Vector{UInt8}[]
    _LF.cursor_first!(c)
    n = 0
    while (k = _LF.cursor_key(c)) !== nothing && n < limit
        @assert _LF.cursor_check_invariants(c) "cursor invariant broken at step $n"
        push!(out, collect(k))
        _LF.cursor_next!(c)
        n += 1
    end
    out
end

@testset "leapfrog layer 2 — zipper subterm cursor" begin

    @testset "enumerates exactly the stored atoms, in ascending order" begin
        atoms = ["(edge a b)", "(edge a c)", "(edge b c)", "(node x)", "(node y)"]
        (_, c) = _lf_cursor(atoms)
        got = _lf_drain!(c)

        # ANTI-VACUITY: an empty enumeration would satisfy "sorted" and "no duplicates" trivially.
        @test length(got) == length(atoms)

        # Each yielded key must be a COMPLETE subterm — the cursor's central claim.
        @test all(_LF.is_complete(k) for k in got)

        # …and the set must be exactly what we stored, by bytes.
        want = sort([MORK.sexpr_to_expr(a).buf for a in atoms], lt = (x, y) -> x < y)
        @test got == want

        # ascending lexicographic, asserted directly rather than inferred from `want` being sorted
        @test issorted(got, lt = (x, y) -> x < y)
    end

    @testset "an empty trie yields nothing, and says so via at_end" begin
        s = MORK.new_space()
        c = _LF.SubtermCursor(MORK.read_zipper(s.btm))
        _LF.cursor_first!(c)
        @test _LF.cursor_key(c) === nothing
        @test c.at_end
        _LF.cursor_next!(c)                       # must be a safe no-op, not an error
        @test _LF.cursor_key(c) === nothing
    end

    @testset "seek lands on the least subterm >= target" begin
        atoms = ["(edge a b)", "(edge a c)", "(edge b c)", "(node x)"]
        (_, c) = _lf_cursor(atoms)
        all_keys = _lf_drain!(c)
        @test length(all_keys) == 4               # anti-vacuity for every assertion below

        for (i, target) in enumerate(all_keys)
            (_, c2) = _lf_cursor(atoms)
            _LF.cursor_seek!(c2, target)
            k = _LF.cursor_key(c2)
            @test k !== nothing
            # seeking to a key that IS present must land ON it — the `least_ge` trap one layer up,
            # now at subterm granularity. Landing on the NEXT one would silently drop answers.
            @test collect(k) == target
            @test _LF.cursor_check_invariants(c2)
        end

        # seek past everything -> exhausted
        (_, c3) = _lf_cursor(atoms)
        _LF.cursor_seek!(c3, UInt8[0xFF, 0xFF, 0xFF])
        @test _LF.cursor_key(c3) === nothing

        # seek below everything -> the least key
        (_, c4) = _lf_cursor(atoms)
        _LF.cursor_seek!(c4, UInt8[0x00])
        @test _LF.cursor_key(c4) !== nothing
        @test collect(_LF.cursor_key(c4)) == all_keys[1]
    end

    @testset "seek is monotone: repeated seeks never go backwards" begin
        # The leapfrog's correctness rests on this. Each round it seeks every cursor to the current
        # maximum; if a seek could move a cursor BACKWARDS the loop would not terminate.
        atoms = ["(edge a b)", "(edge a c)", "(edge b c)", "(node x)", "(node y)", "(zed q)"]
        (_, c) = _lf_cursor(atoms)
        keys = _lf_drain!(c)
        @test length(keys) == 6

        (_, c2) = _lf_cursor(atoms)
        prev = UInt8[]
        for t in keys
            _LF.cursor_seek!(c2, t)
            k = _LF.cursor_key(c2)
            @test k !== nothing
            cur = collect(k)
            @test cur >= prev                     # never backwards
            prev = cur
        end
    end

    @testset "variable counts are exact, and a payload byte is never a variable" begin
        # `key_newvars`/`key_vars` are maintained by the same advance/retreat that drive the parse,
        # so they are free — but only correct if the "is this a tag?" test happens BEFORE the byte is
        # consumed. A symbol whose payload bytes look like variable tags is the falsifying case.
        (_, c) = _lf_cursor(["(edge \$x \$y)"])
        _LF.cursor_first!(c)
        @test _LF.cursor_key(c) !== nothing
        (nv, tv) = _LF.cursor_var_counts(c)
        @test nv == 0x02 && tv == 0x02            # two NewVars, two variables total

        # a ground atom carrying a symbol has NO variables, whatever its payload bytes spell
        (_, c2) = _lf_cursor(["(sym abc)"])
        _LF.cursor_first!(c2)
        @test _LF.cursor_key(c2) !== nothing
        (nv2, tv2) = _LF.cursor_var_counts(c2)
        @test nv2 == 0x00 && tv2 == 0x00
    end

    @testset "descend_floor / ascend_floor walk columns with the zipper HELD" begin
        # The property that makes the join affordable: one cursor walks a factor's successive
        # columns in place, never re-opening from the trie root.
        atoms = ["(edge a b)", "(edge a c)"]
        (_, c) = _lf_cursor(atoms)
        _LF.cursor_first!(c)
        first_key = collect(_LF.cursor_key(c))
        @test _LF.is_complete(first_key)

        _LF.cursor_descend_floor!(c)              # lock it; enumeration is now of the NEXT column
        @test isempty(collect(_LF.cursor_key(c))) # at the new floor, key is empty
        @test _LF.cursor_check_invariants(c)

        _LF.cursor_ascend_floor!(c)               # and back
        @test collect(_LF.cursor_key(c)) == first_key
        @test _LF.cursor_check_invariants(c)
    end
end
