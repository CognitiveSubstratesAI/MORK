# upstream_issues.jl — every BEHAVIOURAL issue on trueagi-io/MORK, run against our port.
#
# WHY THIS FILE EXISTS. The 2026-07-31 cross-check ran each issue's reproducer by hand and threw the
# probes away. That verified a moment, not a property: nothing stopped a later change from silently
# reintroducing a bug upstream had already closed. These are the same programs, kept.
#
# THREE CLASSES, and the distinction matters when one goes red:
#
#   CLOSED upstream  -> we assert the FIXED behaviour. A failure here is OUR regression.
#   OPEN upstream    -> we pin our CURRENT behaviour, which today equals upstream's. A failure means
#                       upstream's bug changed shape, or we drifted; either way, re-read the issue
#                       before "fixing" anything.
#   DIVERGENCE       -> upstream aborts where we skip. Pinned so the difference stays deliberate.
#
# ⚠️ ISSUE TITLES LIE ABOUT RESOLUTION. #133 reads like a fixed bug and was recorded as a gap in our
# port on that basis. It was closed as USAGE — the argument must be quoted, `(tuple S $x (' $y))` —
# and the unquoted program still yields one atom in BOTH engines. Read the comments, not the title.
#
# Every expectation below was MEASURED on our engine and cross-read against the issue thread; the
# `_trace` helper prints the program, step count and resulting atoms on every run, so a failure is
# diagnosable without re-deriving the case.
using MORK, Test

const _ISSUE_TRACE = get(ENV, "MORK_ISSUE_TRACE", "1") != "0"

"""Run an MM2 program, print a trace, and return its atoms as a sorted Vector{String}."""
function _issue_run(tag::String, src::AbstractString; cap::Int = 4000)
    s = MORK.new_space()
    MORK.space_add_all_sexpr!(s, src)
    steps = MORK.space_metta_calculus!(s, cap)
    out = MORK.space_dump_all_sexpr(s)
    atoms = sort(filter(!isempty, split(strip(out), "\n")))
    if _ISSUE_TRACE
        println("\n  ── $tag ── steps=$steps  atoms=$(length(atoms))")
        for a in atoms
            println("       ", a)
        end
    end
    String.(atoms)
end

"True when `needle` appears as a whole atom."
_has(atoms, needle) = any(a -> a == needle, atoms)
_any_containing(atoms, frag) = any(a -> occursin(frag, a), atoms)

@testset "upstream MORK issues — behavioural reproducers" begin

    @testset "CLOSED upstream — a failure here is OUR regression" begin

        @testset "#22 MM2 removal not working" begin
            a = _issue_run("#22", "(exec 0 (, (foo \$x)) (O (- (foo \$x)) (+ (bar \$x))))\n(foo a)")
            @test _has(a, "(bar a)")
            @test !_has(a, "(foo a)")          # the RemoveSink must actually remove
        end

        @testset "#29 decreasing pattern specificity skips valid unifications" begin
            a = _issue_run("#29", "(: \$a A)\n(: f (-> A))\n(exec 0 (, (: (\$f) \$t) (: \$f (-> \$t))) (, OK))")
            @test _has(a, "OK")
        end

        @testset "#37 variable introduction in templates breaks internal references" begin
            # exec 0 uses DIFFERENT template vars ($k,$j); exec 1 uses the SAME ($k,$k).
            # The bug produced `(count0-2 (count0-2 $a))` for the differing-vars case.
            a = _issue_run("#37", """
                (item a)
                (item b)
                (item c)
                (item2 a)
                (item2 b)
                (item2 c)
                (item2 d)
                (exec 0 (, (item \$x) (item2 \$y))
                  (O (count (count0-1 \$k) \$k \$x) (count (count0-2 \$j) \$j \$y)))
                (exec 1 (, (item \$x) (item2 \$y))
                  (O (count (count1-1 \$k) \$k \$x) (count (count1-2 \$k) \$k \$y)))
                """)
            @test _has(a, "(count0-1 3)")
            @test _has(a, "(count0-2 4)")      # the bug gave (count0-2 (count0-2 $a))
            @test _has(a, "(count1-1 3)")
            @test _has(a, "(count1-2 4)")
            @test !_any_containing(a, "(count0-2 (count0-2")
        end

        @testset "#43 out of bounds error with coreferential_transition" begin
            # The report is a CRASH. Reaching the assertions at all is most of the test.
            a = _issue_run("#43", "(data (0 1))\n(exec (0) (, (data (\$i \$g))) (, (((. \$x) \$x) lp \$i \$g)))")
            @test _has(a, "(data (0 1))")
            @test _any_containing(a, "lp 0 1")   # the transition fired instead of aborting
        end

        @testset "#53 tail sink returns the wrong set for N >= 2 (filed from this port)" begin
            # HeadTailSink's fill branch tracked the MAX boundary for both head and tail. Sunk out of
            # ascending order, tail kept the wrong set. head and `tail 1` were never affected.
            t2 = _issue_run("#53 tail2", "(v 1 e)\n(v 2 a)\n(v 3 b)\n(exec 0 (, (v \$i \$x)) (O (tail 2 (g \$x))))")
            @test _has(t2, "(g b)") && _has(t2, "(g e)")
            @test !_has(t2, "(g a)")             # the bug kept {a,e}

            h2 = _issue_run("#53 head2", "(v 1 e)\n(v 2 a)\n(v 3 b)\n(exec 0 (, (v \$i \$x)) (O (head 2 (g \$x))))")
            @test _has(h2, "(g a)") && _has(h2, "(g b)")   # control: head was never wrong
            @test !_has(h2, "(g e)")

            t3 = _issue_run("#53 tail3", "(v 1 e)\n(v 2 a)\n(v 3 c)\n(v 4 b)\n(v 5 d)\n" *
                                          "(exec 0 (, (v \$i \$x)) (O (tail 3 (g \$x))))")
            @test _has(t3, "(g c)") && _has(t3, "(g d)") && _has(t3, "(g e)")
            @test !_has(t3, "(g a)") && !_has(t3, "(g b)")  # the bug kept {a,c,e}
        end

        @testset "#133 pure `tuple` ignores tuple arguments — closed as USAGE, not a code fix" begin
            base = "(R 0 Z)\n(R 1 (S Z))\n"
            # UNQUOTED: one atom, in ours AND upstream. This is NOT a gap — see the file header.
            un = _issue_run("#133 unquoted", base * "(exec 0 (, (R \$x \$y)) (O (pure \$s \$s (tuple S \$x \$y))))")
            @test _has(un, "(S 0 Z)")
            @test !_has(un, "(S 1 (S Z))")
            # QUOTED: the accepted resolution from the issue thread.
            q = _issue_run("#133 quoted", base * "(exec 0 (, (R \$x \$y)) (O (pure \$s \$s (tuple S \$x (' \$y)))))")
            @test _has(q, "(S 0 Z)")
            @test _has(q, "(S 1 (S Z))")
        end
    end

    @testset "OPEN upstream — pinned parity, re-read the issue before changing" begin

        @testset "#135 quotation does not handle variable references correctly" begin
            # Upstream yields (R ($a $b)) where ($a $a) is expected: quotation treats every variable
            # as new. WE REPRODUCE IT. Faithful parity, and NOT a defect introduced here.
            # ⚠️ If this flips to (R ($a $a)), upstream likely fixed #135 — port the fix, do not
            # "correct" this assertion.
            a = _issue_run("#135", "(exec 0 (,) (O (pure \$r \$r (tuple R (' (\$a \$a))))))")
            @test _any_containing(a, "(R (")
            @test _has(a, "(R (\$a \$b))")
        end

        @testset "#136 pure fails to capture an output pattern" begin
            # Upstream PANICS ("unrecognized sink", sinks.rs:1309). We produce no atoms and do not
            # abort — strictly better, since we never take down a saturation run.
            a = _issue_run("#136 pattern capture", "(exec 0 (,) (O (pure (R \$x \$y) (\$x \$y) (tuple 1 2))))")
            @test !_has(a, "(R 1 2)")            # neither engine achieves the expected result
            @test isempty(a)                     # and we fail QUIETLY rather than aborting

            # The single-variable capture in the same issue DOES work, on both sides.
            b = _issue_run("#136 single var", "(exec 0 (,) (O (pure (R \$x) \$x (tuple 1 2))))")
            @test _has(b, "(R (1 2))")
        end
    end

    @testset "DIVERGENCE — upstream aborts where we skip" begin

        @testset "#47 variable in an exec priority" begin
            # Closed upstream by making this ASSERT (`loc.variables() == 0`, commit 28da5f9). We skip
            # the exec instead. Same family as test/conformance/upstream_panics/: we never abort
            # mid-saturation, so "match upstream" has no useful meaning on this shape.
            a = _issue_run("#47", "(A Z)\n(exec \$p (, (A \$x)) (, (B \$x)))")
            @test _has(a, "(A Z)")
            @test !_has(a, "(B Z)")              # the exec does not fire
            @test !_any_containing(a, "(B \$")   # and emits no half-instantiated atom either
        end
    end
end
