# main's `timing` instrumentation (kernel/src/space.rs:1710-1718), ported 2026-07-30.
#
# WHY THIS TEST EXISTS. We declared `Space.timing::Bool` to mirror upstream's struct field
# (space.rs:44) but NOTHING READ IT — so setting it did nothing, silently. A field that looks like a
# switch and is not one is worse than an absent field: the absence is discoverable, the no-op is not.
# Found by diffing our server-sourced `space_metta_calculus!` against main's `metta_calculus`.
#
# Upstream builds `construct!("timing" xe done_str start_str)`:
#     [Arity(4)] [Sym "timing"] <exec bytes, spliced RAW> [Sym done] [Sym nanos]
# and inserts it into the trie. This pins the three details that are easy to get wrong, since none of
# them would fail loudly:
#   1. default OFF — otherwise every existing probe's dump gains atoms and the 277-probe differential
#      breaks. This is the assertion that protects the conformance gate.
#   2. `done` is the PRE-increment count, so the FIRST step records 0 (upstream's `done += 1` runs in
#      the while-body, after the timing block).
#   3. it must not collide with the exec scan. `_EXEC_PREFIX` is [Arity(4)][SymbolSize(4)]exec, this
#      is [Arity(4)][SymbolSize(6)]timing — they diverge at byte 2. If they ever collided the engine
#      would re-execute its own timing atoms forever, so this is a liveness guard, not a nicety.
using Test

@testset "space timing instrumentation (main space.rs:1710)" begin
    prog = "(foo a)\n(exec 0 (, (foo \$x)) (, (bar \$x)))\n"

    @testset "DEFAULT OFF — the dump is unchanged (protects the 277-probe gate)" begin
        s = MORK.new_space()
        @test s.timing == false                       # mirrors upstream's `timing: false` (space.rs:448)
        MORK.space_add_all_sexpr!(s, prog)
        MORK.space_metta_calculus!(s, 100)
        dump = MORK.space_dump_all_sexpr(s)
        @test occursin("(bar a)", dump)                # the exec ran
        @test !occursin("timing", dump)                # …and emitted NO instrumentation
    end

    @testset "ON — one timing atom per step, shaped as upstream's construct!" begin
        s = MORK.new_space()
        s.timing = true
        MORK.space_add_all_sexpr!(s, prog)
        steps = MORK.space_metta_calculus!(s, 100)
        dump = MORK.space_dump_all_sexpr(s)

        @test occursin("(bar a)", dump)                # the exec still ran
        lines = filter(l -> occursin("timing", l), split(dump, '\n'))
        @test length(lines) == steps                   # exactly one per executed step
        @test steps >= 1

        # PRE-increment: the first (and here only) step records done == 0.
        @test any(l -> occursin("timing", l) && occursin(" 0 ", l), lines)

        # The exec expression is spliced RAW, so its own head survives inside the timing atom.
        @test any(l -> occursin("timing", l) && occursin("exec", l), lines)
    end

    @testset "timing atoms are NOT re-executed (liveness)" begin
        # If the timing atom's prefix collided with _EXEC_PREFIX the calculus would consume its own
        # output forever. Bounded step budget + a second call that finds nothing proves it terminates.
        s = MORK.new_space()
        s.timing = true
        MORK.space_add_all_sexpr!(s, prog)
        first_run = MORK.space_metta_calculus!(s, 100)
        second_run = MORK.space_metta_calculus!(s, 100)
        @test first_run >= 1
        @test second_run == 0                          # nothing left to execute — no self-feeding
    end
end
