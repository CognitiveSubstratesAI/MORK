#!/usr/bin/env julia
# examples/hexlife.jl — MM2 Tutorial: Hexlife
#
# Demonstrates: Conway's Game of Life on a hexagonal grid using MORK.
# Uses CountSink to accumulate neighbour counts, then apply/remove sinks
# to compute the next generation.
# Upstream: kernel/src/main.rs sink_hexlife_symbolic (lines 2980–3032)
# Wiki: https://github.com/trueagi-io/MORK/wiki/MM2-tutorial:-Hexlife
#
# Hexagonal coordinate system: axial (q, r, s) with q+r+s = const.
# Neighbour relation encoded as data; life/death rules via CountSink.
#
# Run from warm REPL:  include("examples/hexlife.jl")

using MORK

println("=== Hexlife: Conway's Game of Life on hexagonal grid ===\n")

s = new_space()
space_add_all_sexpr!(
    s,
    raw"""
; Hexagonal neighbour pairs (axial coordinates using Peano naturals)
(neighbors ($q $r (S $s)) ($q (S $r) $s))
(neighbors ($q $r (S $s)) ((S $q) $r $s))
(neighbors ($q (S $r) $s) ((S $q) $r $s))
(neighbors ($q (S $r) $s) ($q $r (S $s)))
(neighbors ((S $q) $r $s) ($q (S $r) $s))
(neighbors ((S $q) $r $s) ($q $r (S $s)))

; Hexagonal life rules: a cell lives with 2 neighbours, is born with 2 dead neighbours
(cell dies  0) (cell dies  1) (cell lives 2)
(cell dies  3) (cell dies  4) (cell dies  5) (cell dies  6)

; Initial alive cells (glider-like configuration)
(alive ((S (S Z)) (S Z) (S Z)))
(alive ((S Z) (S (S Z)) (S Z)))
(alive ((S Z) (S (S (S Z))) Z))

; Phase 0: count alive neighbours of alive cells
(exec 0 (, (alive $co) (neighbors $co $nco) (alive $nco))
        (O (count (anbs $co $k) $k $nco)))

; Phase 0: count alive neighbours of dead-but-adjacent cells (candidates for birth)
(exec 0 (, (alive $co) (neighbors $co $nco) (neighbors $nco $nnco) (alive $nnco))
        (O (count (adnbs $nco $k) $k $nnco)))

; Phase 1: ensure alive cells without neighbours get zero count
(exec 1 (, (alive $co)) (, (anbs $co 0)))

; Phase 1: clean up dead-neighbour counts for cells that are alive
(exec 1 (, (anbs $co $k1) (adnbs $co $k2)) (O (- (adnbs $co $k2))))

; Phase 2: kill cells that die according to the life rule
(exec 2 (, (anbs $co $c) (cell dies $c)) (O (- (alive $co))))

; Phase 3: birth cells with the right neighbour count
(exec 3 (, (adnbs $co $c) (cell lives $c)) (O (+ (alive $co))))

; Phase 4: clean up counting atoms
(exec 4 (, (anbs  $co $c)) (O (- (anbs  $co $c))))
(exec 4 (, (adnbs $co $c)) (O (- (adnbs $co $c))))
"""
)

println("Initial alive cells:")
initial = filter(l -> startswith(l, "(alive"), split(space_dump_all_sexpr(s), "\n"))
for c in initial

    println("  $c")
end

# Hexlife converges in O(alive_cells) steps — numbered execs (0-4) are not self-referential
hl_elapsed = @elapsed steps = space_metta_calculus!(s, 9999)
result = space_dump_all_sexpr(s)
alive_after = filter(l -> startswith(l, "(alive"), split(result, "\n"))

println("\nAfter $steps steps ($(round(hl_elapsed*1000, digits=1)) ms):")
println("Alive cells: $(length(alive_after))")
for c in alive_after

    println("  $c")
end
println("\nDone!")
