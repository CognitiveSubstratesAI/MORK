# ip_sudoku_andsink.jl — regression for the HARD ip_sudoku, now BYTE-EXACT vs upstream (2026-07-25).
#
# The HARD ip_sudoku (upstream `kernel/resources/ip_sudoku.mm2`, vendored as a fixture) drives its
# constraint propagation through the `(and (cell $c $nv) $nv $i)` AndSink over the coref SOURCE join
# — unlike the simpler embedded program in ip_sudoku.jl (which uses a PureSink and explicit exec-4
# rules, exercising neither AndSink nor the coref-source join).
#
# TWO bugs had to fall for this to match upstream, both fixed 2026-07-25:
#   1. AndSink ACCUMULATION — AndSink was not in `_is_accumulating_sink`, so it was created fresh per
#      match and finalized per match; the bitwise-AND that groups ALL of a cell's entries never ran
#      across matches. The paired `- ($src $c $i)` removed every matched cell but the AndSink re-added
#      only a few, collapsing the cell set from 16 to 4. Fix: mark "and" as accumulating.
#   2. de-Bruijn RE-BASING in the pure sink — the `(exec (4 N) …)` meta-rule respawns itself through a
#      PureSink whose template carries a region-backref. Substituting the sink's ground value for one
#      NewVar removes a binding, so every trailing VarRef must shift down by one; the old naive
#      byte-copy left them dangling (`_1`→`_2` drift), so the respawn chain produced a malformed exec
#      and the propagation loop halted early at 12 steps with under-narrowed cells. Fix: substitute via
#      the faithful port of upstream `Expr::substitute_one_de_bruijn` (ExprAlg.jl / expr/src/lib.rs:539),
#      which re-bases every other de-Bruijn variable.
#
# With both fixed, ours reproduces upstream `mork run` EXACTLY: 34 steps, 102 atoms, and the full
# atom set is byte-identical (verified against the release binary; the reference is vendored as
# `ip_sudoku_hard.expected`, which is upstream's dump minus the `--timing` profiling atoms). The 4x4
# puzzle is NOT fully solved by propagation alone (no backtracking) — several cells stay at 0x0f — but
# our result matches upstream cell-for-cell.
using MORK, Test

const _IPS_HARD_FIXTURE  = joinpath(@__DIR__, "..", "fixtures", "mm2", "ip_sudoku_hard.mm2")
const _IPS_HARD_EXPECTED = joinpath(@__DIR__, "..", "fixtures", "mm2", "ip_sudoku_hard.expected")

@testset "ip_sudoku hard — byte-exact vs upstream (fixes 2026-07-25)" begin
    prev = MORK._USE_COREF_JOIN[]
    MORK._USE_COREF_JOIN[] = true      # the hard version needs the coref source join
    try
        s = MORK.new_space()
        MORK.space_add_all_sexpr!(s, read(_IPS_HARD_FIXTURE, String))
        steps = MORK.space_metta_calculus!(s, 100_000_000)
        atoms = sort!([strip(l) for l in split(MORK.space_dump_all_sexpr(s), '\n') if !isempty(strip(l))])

        # Step-count parity: the de-Bruijn re-basing fix takes the respawn chain from a truncated 12
        # steps to the full 34 upstream reaches.
        @test steps == 34

        # Byte-exact atom set vs the upstream-verified reference (102 atoms, whole set).
        expected = sort!([strip(l) for l in eachline(_IPS_HARD_EXPECTED) if !isempty(strip(l))])
        @test length(atoms) == 102
        @test length(expected) == 102
        @test atoms == expected

        # Explicit accumulation guard (pre-fix #1 this collapsed to 4): all 16 grid cells persist.
        cells = filter(l -> startswith(l, "(cell "), atoms)
        @test length(cells) == 16
        for r in 0:3, c in 0:3
            @test any(l -> startswith(l, "(cell ($r $c) "), cells)
        end
    finally
        MORK._USE_COREF_JOIN[] = prev
    end
end
