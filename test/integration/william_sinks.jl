# WILLIAM on MORK — tests AUSink / CountSink / HeadSink exec atoms directly
using MORK, Test

@testset "WILLIAM on MORK — exec atom sinks" begin

    # ── CountSink: pattern frequency counting ─────────────────────────
    @testset "CountSink — william-count equivalent" begin
        s = new_space()
        space_add_all_sexpr!(
            s,
            """
(edge robin bird)
(edge sparrow bird)
(edge eagle bird)
(edge dog mammal)
(exec 0 (, (edge \$x bird))
        (O (count (bird-count \$n) \$n (edge \$x bird))))
"""
        )
        steps = space_metta_calculus!(s, 10_000)
        @test steps >= 1
        io = IOBuffer();
        space_dump_all_sexpr(s, io)
        res = String(take!(io))
        # CountSink writes (bird-count 3): robin/sparrow/eagle are bird edges, dog isn't.
        # Firing form is `(O (count …))`; a `(, (count …))` wrapper makes it a literal.
        @test occursin("(bird-count 3)", res)
    end

    # ── AUSink: least-general generalisation ──────────────────────────
    @testset "AUSink — william-lgg equivalent" begin
        s = new_space()
        space_add_all_sexpr!(
            s,
            """
(= (likes alice pizza) True)
(= (likes bob pizza) True)
(exec 0 (, (= (likes \$a pizza) True) (= (likes \$b pizza) True))
        (O (AU (likes \$x pizza))))
"""
        )
        steps = space_metta_calculus!(s, 10_000)
        @test steps >= 1
        io = IOBuffer();
        space_dump_all_sexpr(s, io)
        res = String(take!(io))
        # AUSink writes the least-general generalisation of the matched (likes …)
        # terms: alice/bob differ → a variable in that slot → (likes _1 pizza).
        # Upstream's AU sink emits a NewVar here, which serializes as `$` — verified with
        # RUST_LOG=sink=trace: "AU anti-unified expression '[3] likes $ pizza'".
        # `_1` is a VarRef BACK-REFERENCE to the 0th introduced variable; this generalisation
        # introduces none before that slot (likes/pizza are symbols), so `_1` would be a DANGLING
        # VarRef. (`_N` IS legitimate elsewhere — e.g. conformance g7_au_repeat emits `(f $a $b $a)`.)
        # This expectation was hard-coded in 4f57120, the commit that first made the sink fire —
        # it was never green, so this is not an engine regression.
        @test occursin("(likes \$ pizza)", res)
    end

    # ── HeadSink: top-k by lexicographic order ────────────────────────
    # NB the firing form is `(O (head N $x))` — the template functor must be `O`
    # (no_sink=false) to dispatch to the sink. A `(, (O …))` wrapper makes the
    # template functor `,` (direct set) and the sink never runs (the old test here
    # did that and passed vacuously, keeping 0). head/tail also had to be added to
    # `_is_accumulating_sink` or they cap nothing (fresh-per-match).
    kept_letters(out) = sort([strip(l) for l in split(out, '\n') if strip(l) in ["a","b","c","d","e"]])
    function run_topk(sink, n)
        s = new_space()
        space_add_all_sexpr!(s, """
(pattern a) (pattern b) (pattern c) (pattern d) (pattern e)
(exec 0 (, (pattern \$x)) (O ($sink $n \$x)))
""")
        steps = space_metta_calculus!(s, 10_000)
        @test steps >= 1
        io = IOBuffer(); space_dump_all_sexpr(s, io)
        kept_letters(String(take!(io)))
    end

    @testset "HeadSink — keep N lexicographically smallest" begin
        @test run_topk("head", 3) == ["a", "b", "c"]
        @test run_topk("head", 2) == ["a", "b"]
        @test run_topk("head", 1) == ["a"]
    end

    @testset "TailSink — keep N lexicographically largest" begin
        @test run_topk("tail", 3) == ["c", "d", "e"]
        @test run_topk("tail", 2) == ["d", "e"]   # fill→capacity transition (max≥2)
        @test run_topk("tail", 1) == ["e"]
        @test run_topk("tail", 4) == ["b", "c", "d", "e"]
    end

    # ── Combined: WILLIAM.gain via MORK primitives ────────────────────
    @testset "Combined — frequency × size → MDL gain" begin
        s = new_space()
        # Add 4 matching atoms and count them
        space_add_all_sexpr!(
            s,
            """
(event click btn-a)
(event click btn-b)
(event click btn-c)
(event hover menu-1)
(exec 0 (, (event click \$x))
        (O (count (click-count \$n) \$n (event click \$x))))
"""
        )
        steps = space_metta_calculus!(s, 10_000)
        io = IOBuffer();
        space_dump_all_sexpr(s, io)
        res = String(take!(io))
        # 3 click events (btn-a/b/c), hover is not click → (click-count 3).
        @test occursin("(click-count 3)", res)
    end

end

println("\n✓ WILLIAM MORK exec-atom tests complete")
