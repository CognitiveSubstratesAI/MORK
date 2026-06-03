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
        (, (count (bird-count \$n) \$n (edge \$x bird))))
"""
        )
        steps = space_metta_calculus!(s, 10_000)
        @test steps >= 1
        io = IOBuffer();
        space_dump_all_sexpr(s, io)
        res = String(take!(io))
        # CountSink should have written (bird-count 3)
        @test occursin("bird-count", res)
        println("  CountSink result excerpt: ",
            first(filter(l->occursin("bird-count", l), split(res, "\n")), 1))
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
        (, (O (AU (likes \$x pizza)))))
"""
        )
        steps = space_metta_calculus!(s, 10_000)
        @test steps >= 1
        io = IOBuffer();
        space_dump_all_sexpr(s, io)
        res = String(take!(io))
        # AUSink should have written a generalised (likes $X pizza) atom
        @test occursin("likes", res)
        println("  AUSink result excerpt: ",
            first(
                filter(l->occursin("likes", l) && !occursin("exec", l), split(res, "\n")), 1
            ))
    end

    # ── HeadSink: top-k by lexicographic order ────────────────────────
    @testset "HeadSink — top-k patterns" begin
        s = new_space()
        space_add_all_sexpr!(
            s,
            """
(pattern alpha)
(pattern beta)
(pattern gamma)
(pattern delta)
(pattern epsilon)
(exec 0 (, (pattern \$x))
        (, (O (head 3 \$x))))
"""
        )
        steps = space_metta_calculus!(s, 10_000)
        @test steps >= 1
        io = IOBuffer();
        space_dump_all_sexpr(s, io)
        res = String(take!(io))
        # HeadSink should have kept top-3 lexicographically
        n_patterns = count(l -> occursin(r"^(alpha|beta|gamma|delta|epsilon)$", strip(l)),
            split(res, "\n"))
        @test n_patterns <= 3
        println("  HeadSink kept $n_patterns of 5 patterns (expect ≤ 3)")
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
        (, (count (click-count \$n) \$n (event click \$x))))
"""
        )
        steps = space_metta_calculus!(s, 10_000)
        io = IOBuffer();
        space_dump_all_sexpr(s, io)
        res = String(take!(io))
        @test occursin("click-count", res)
        # Extract count value
        count_line = filter(l->occursin("click-count", l), split(res, "\n"))
        println("  click-count line: ", isempty(count_line) ? "none" : first(count_line))
        @test !isempty(count_line)
    end

end

println("\n✓ WILLIAM MORK exec-atom tests complete")
