#!/usr/bin/env julia
# examples/reachability.jl — MM2 Tutorial: Reachability
#
# Demonstrates: graph reachability via multi-pattern exec rules.
# Upstream: kernel/src/main.rs transitive reachability patterns
# Wiki: https://github.com/trueagi-io/MORK/wiki/MM2-tutorial:-Reachability
#
# Two variants:
#   P1 — directed graph: two-step transitive closure
#   P2 — undirected graph: symmetric closure then transitive closure
#
# Note: the `fixpoint` driver pattern (P3/P4 — BFS over state spaces)
# uses a self-referential exec rule similar to `zealous`. It is demonstrated
# in transition_system.jl and counter_machine.jl instead.
#
# Run from warm REPL:  include("examples/reachability.jl")

using MORK

# ── P1: Directed graph reachability ──────────────────────────────────────────
println("=== P1: Directed graph reachability ===")
s1 = new_space()
space_add_all_sexpr!(
    s1,
    raw"""
(edge a b) (edge b c) (edge c d) (edge a d) (edge b e)
; Direct reachability
(exec 0 (, (edge $x $y)) (, (reach $x $y)))
; Two-hop transitivity
(exec 0 (, (edge $x $y) (edge $y $z)) (, (reach $x $z)))
"""
)
p1_steps = space_metta_calculus!(s1, 999)
reach1 = sort(filter(l -> startswith(l, "(reach"), split(space_dump_all_sexpr(s1), "\n")))
println("Steps: $p1_steps  Reachable pairs: $(length(reach1))")
for r in reach1
    ;
    println("  $r");
end
@assert length(reach1) >= 5 "P1: expected at least 5 reachable pairs"
println("PASS\n")

# ── P2: Undirected reachability via symmetric closure ─────────────────────────
println("=== P2: Undirected graph — connected components ===")
s2 = new_space()
space_add_all_sexpr!(
    s2,
    raw"""
(edge 1 2) (edge 2 3) (edge 4 3) (edge 5 6)
; Symmetric closure — one exec fires, creates all sym edges at once
(exec 0 (, (edge $x $y)) (, (sym $x $y) (sym $y $x)))
; 2-hop connectivity (sufficient for this small graph)
(exec 1 (, (sym $x $y)) (, (conn $x $y)))
(exec 1 (, (sym $x $y) (sym $y $z)) (, (conn $x $z)))
"""
)
p2_steps = space_metta_calculus!(s2, 999)
conn2 = sort(filter(l -> startswith(l, "(conn"), split(space_dump_all_sexpr(s2), "\n")))
println("Steps: $p2_steps  Connected pairs: $(length(conn2))")
@assert any(l -> occursin("(conn 1 3)", l), conn2) "1→3 should be connected (via 2)"
@assert any(l -> occursin("(conn 4 2)", l), conn2) "4→2 should be connected (via 3)"
@assert !any(l -> occursin("(conn 1 5)", l), conn2) "1 and 5 should NOT be connected"
println("  (conn 1 3): $(any(l->occursin("(conn 1 3)",l),conn2)) ✓")
println("  (conn 4 2): $(any(l->occursin("(conn 4 2)",l),conn2)) ✓")
println("  (conn 1 5): $(any(l->occursin("(conn 1 5)",l),conn2)) (expected false) ✓")
println("PASS\n")

# ── P3: BFS reachability note ─────────────────────────────────────────────────
println("=== P3: BFS note ===")
println("BFS-style reachability using the `fixpoint` driver is shown in")
println("  examples/transition_system.jl (taxi grid planning)")
println("  examples/counter_machine.jl  (clocked fixpoint)")
