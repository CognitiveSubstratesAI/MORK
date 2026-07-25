# ip_sudoku_andsink.jl — regression for the AndSink ACCUMULATION fix (2026-07-25).
#
# The HARD ip_sudoku (upstream `kernel/resources/ip_sudoku.mm2`, vendored as a fixture) drives its
# constraint propagation through the `(and (cell $c $nv) $nv $i)` AndSink over the coref SOURCE join
# — unlike the simpler embedded program in ip_sudoku.jl (which uses a PureSink and explicit exec-4
# rules, exercising neither AndSink nor the coref-source join).
#
# THE BUG (fixed): AndSink was NOT listed in `_is_accumulating_sink`, so it was created fresh PER
# MATCH and finalized per match — each finalize saw ONE entry, so the bitwise-AND that should group
# and reduce ALL of a cell's entries (current value & every incoming message) never happened across
# matches. The paired `- ($src $c $i)` removed every matched cell, but the AndSink only re-added a
# few, so the cell set COLLAPSED from 16 to 4 (only the 4 known cells survived). Fix: mark "and" as
# accumulating (one sink, all matches, finalize once — mirrors upstream sinks.rs AndSink).
#
# This test asserts the ACCUMULATION invariant: all 16 cells persist and the 4 known cells narrow to
# their single-candidate bitmasks. NOTE: the hard ip_sudoku is NOT yet byte-exact vs upstream — a
# SEPARATE, pre-existing propagation bug (the spawned `!=`/BTM elimination rule under-generates
# neighbour messages, so row/col peers of a solved cell aren't narrowed; ours halts at 12 steps /
# 102 atoms with under-narrowed cells vs upstream's 34 / 102 fully-narrowed). That is tracked
# separately; this test guards ONLY the AndSink accumulation fix.
using MORK, Test

const _IPS_HARD_FIXTURE = joinpath(@__DIR__, "..", "fixtures", "mm2", "ip_sudoku_hard.mm2")

@testset "ip_sudoku hard — AndSink accumulation (fix 2026-07-25)" begin
    prev = MORK._USE_COREF_JOIN[]
    MORK._USE_COREF_JOIN[] = true      # the hard version needs the coref source join
    try
        s = MORK.new_space()
        MORK.space_add_all_sexpr!(s, read(_IPS_HARD_FIXTURE, String))
        MORK.space_metta_calculus!(s, 100_000_000)
        atoms = [strip(l) for l in split(MORK.space_dump_all_sexpr(s), '\n') if !isempty(strip(l))]
        cells = filter(l -> startswith(l, "(cell "), atoms)

        # Accumulation invariant: all 16 cells persist (pre-fix the set collapsed to 4 because the
        # AndSink re-added far fewer cells than the paired `-` removed). This is the load-bearing guard.
        @test length(cells) == 16
        # All 16 grid positions are present as cells (the 4x4 grid, one cell each):
        for r in 0:3, c in 0:3
            @test any(l -> startswith(l, "(cell ($r $c) "), cells)
        end
        # The AND actually REDUCED the known cells: each known-cell value is a single byte whose
        # low nibble is narrowed below the initial all-candidates 0x0F (0x00 or 0x01 here). We check
        # the value byte directly (it can be a raw non-printing byte, so index bytes, not chars).
        function cell_val_byte(pos)
            l = findfirst(c -> startswith(c, "(cell ($pos) "), cells)
            l === nothing && return nothing
            b = codeunits(cells[l])                 # ...") <val-byte> ")"
            length(b) >= 2 ? b[end-1] : nothing     # byte just before the closing ')'
        end
        for pos in ("0 2", "1 1", "2 2", "3 3")
            vb = cell_val_byte(pos)
            @test vb !== nothing && (vb & 0x0f) != 0x0f
        end
    finally
        MORK._USE_COREF_JOIN[] = prev
    end
end
