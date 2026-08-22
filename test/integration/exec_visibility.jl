# exec_visibility.jl — regression guard for the exec-visibility bug fixed 2026-07-23.
#
# The driver removes an exec from the space before interpreting it; upstream re-inserts it into the
# match space UNCONDITIONALLY (space.rs transform_multi_multi_io: read_copy.insert(add.span())), so
# an exec's own pattern can bind the exec itself. Our port gated that re-insertion behind
# `_pat_overlaps_exec_prefix`, which did a LITERAL byte-scan for the `exec` prefix — invisible to a
# variable conjunct. So `(exec 0 (, $x) (, …))` (a bare-variable pattern, which upstream matches
# against the exec at bootstrap) silently matched NOTHING, and whole exec-chaining programs produced
# no output (Control_02: upstream 4 ground atoms / ours 0; Control_03: 1 / 0). Found by a differential
# sweep vs the built upstream binary; fixed by making the gate sound (bare-var / var-head /
# literal-exec conjuncts route to the re-insert path, concrete-head data rules keep the fast path).
# See kernel/Space.jl `_pat_overlaps_exec_prefix`.
using MORK, Test

_atoms(src) = begin
    s = new_space()
    space_add_all_sexpr!(s, src)
    space_metta_calculus!(s)
    Set(strip(l) for l in split(space_dump_all_sexpr(s), '\n') if !isempty(strip(l)))
end

@testset "exec visibility — bare-variable pattern matches the exec instruction" begin
    # T2: the exec is the ONLY atom; a bare-var pattern must match it and fire the template.
    @test "done" in _atoms("(exec 0 (, \$x) (, done))")

    # Control_02: nested-exec chain bootstrapped by a bare-var outer pattern → exactly {0,1,2,3}.
    a2 = _atoms(
        "(exec 0 (, \$x) (, 0 (exec 0 (, 0) (, 1 (exec 0 (, 1) (, 2 (exec 0 (, 2) (, 3))))))))"
    )
    @test "0" in a2 && "1" in a2 && "2" in a2 && "3" in a2

    # Control_03: inner patterns match the never-present symbol `!`; each exec is consumed but writes
    # nothing, so ONLY the bootstrap `0` survives — 1/2/3 must be absent.
    a3 = _atoms(
        "(exec 0 (, \$x) (, 0 (exec 0 (, !) (, 1 (exec 0 (, !) (, 2 (exec 0 (, !) (, 3))))))))"
    )
    @test "0" in a3
    @test !("1" in a3) && !("2" in a3) && !("3" in a3)

    # Variable-HEAD conjunct: ($h bar) can bind (exec …)'s head → must route to the re-insert path.
    @test "(mh foo)" in _atoms("(foo bar)\n(exec 0 (, (\$h bar)) (, (mh \$h)))")
end

@testset "exec visibility — concrete-head data rules keep the fast path (unchanged)" begin
    # A pure data rule (concrete conjunct heads ≠ exec) must NOT be affected by the fix.
    a = _atoms("(input a)\n(input b)\n(exec 0 (, (input \$x)) (, (out \$x)))")
    @test "(out a)" in a && "(out b)" in a

    # Two-factor join, concrete heads — transitive step still correct.
    @test "(path 1 3)" in _atoms(
        "(e 1 2)\n(e 2 3)\n(exec 0 (, (e \$a \$b) (e \$b \$c)) (, (path \$a \$c)))"
    )
end
