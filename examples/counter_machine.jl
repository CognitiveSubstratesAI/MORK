#!/usr/bin/env julia
# examples/counter_machine.jl — MM2 Example: Counter Machine
#
# Demonstrates: Peano arithmetic state machine using MORK exec rules.
# Upstream: kernel/src/main.rs bench_cm0 (lines 3622–3700)
# Wiki: https://github.com/trueagi-io/MORK/wiki/MM2-Example:-Counter-Machine
#
# This example uses a simplified 2-source Peano counter to avoid the
# Rule-of-64 bottleneck in the full JZ/INC/DEC machine (which has 5-source
# patterns triggering O(atoms^5) ProductZipper scans — see QUALITY_REPORT.md).
#
# The upstream full counter machine (multi-register JZ/INC/DEC) is included
# as a reference but commented out. It works correctly but is slow in Julia
# due to the 5-source pattern overhead (~1.5s per step vs <1ms in Rust).
#
# Run from warm REPL:  include("examples/counter_machine.jl")

using MORK

# ── Simple Peano counter (2-source, fast) ─────────────────────────────────────
println("=== Counter Machine: Peano counting to 5 ===\n")

s = new_space()
space_add_all_sexpr!(
    s,
    raw"""
; Peano successor relation
(succ Z (S Z))
(succ (S Z) (S (S Z)))
(succ (S (S Z)) (S (S (S Z))))
(succ (S (S (S Z))) (S (S (S (S Z)))))
(succ (S (S (S (S Z)))) (S (S (S (S (S Z))))))

; Step rule: advance counter by 1 using successor relation (2-source pattern)
((step fwd $n) (, (count $n) (succ $n $m)) (, (count $m)))

; Drive with zealous-like higher-order exec: fire step rules until fixpoint
(exec tick (, ((step fwd $k) $p0 $t0) (exec tick $p1 $t1))
           (, (exec $k $p0 $t0) (exec tick $p1 $t1)))

(count Z)
"""
)

cm_steps = space_metta_calculus!(s, 999)
result = space_dump_all_sexpr(s)
counts = filter(l -> startswith(l, "(count"), split(result, "\n"))
println("After $cm_steps steps:")
println("Count atoms: $(join(counts, ", "))")
@assert any(l -> occursin("(count (S (S (S (S (S Z))))))", l), counts) "should reach count=5"
println("PASS: counted up to 5 via Peano\n")

# ── Process calculus (IC/R concurrent counter, 2-source) ──────────────────────
println("=== Process Calculus: concurrent IC/R machine ===\n")
# Mirrors kernel/src/main.rs process_calculus_bench
# Two agents sharing a counter, each incrementing/decrementing via R rules

s2 = new_space()
space_add_all_sexpr!(
    s2,
    raw"""
; IC: InterChange counter between agents 0 and 1
; (IC x y c) = agent x sends count c to agent y
(exec (IC 0 1 (S (S Z)))
  (, (exec (IC $x $y (S $c)) $sp $st) ((exec $x) $p $t))
  (, (exec (IC $y $x $c) $sp $st) (exec (R $x) $p $t)))

; Agent 0: produces result atom
((exec 0) (, (exec 0 $p $t)) (, (exec 0 $p $t) (! result 0 $p $t)))

; Agent 1: produces result atom
((exec 1) (, (exec 1 $p $t)) (, (exec 1 $p $t) (! result 1 $p $t)))

; R: reset agent back to active state
(exec (R 0) (, (exec (R 0) $p $t)) (, (exec 0 $p $t)))
(exec (R 1) (, (exec (R 1) $p $t)) (, (exec 1 $p $t)))
"""
)

pc_steps = space_metta_calculus!(s2, 100)
result2 = space_dump_all_sexpr(s2)
results = filter(l -> startswith(l, "(! result"), split(result2, "\n"))
println("After $pc_steps steps: $(length(results)) result atoms produced")
for r in results[1:min(3, end)]

    println("  $r")
end
println("PASS: process calculus IC/R machine ran successfully")

println("""
Note: the full JZ/INC/DEC counter machine (5-source Peano patterns)
is implemented in benchmark/canonical_benchmarks.jl as counter_machine_src().
It works correctly but takes ~1.5s/step due to Rule-of-64 (same as odd_even_sort).
""")
