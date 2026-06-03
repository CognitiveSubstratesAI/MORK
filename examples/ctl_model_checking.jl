#!/usr/bin/env julia
# examples/ctl_model_checking.jl — MM2 Example: CTL Model Checking
#
# Demonstrates: Computation Tree Logic model checking via MeTTa 2 exec rules.
# Upstream: kernel/src/main.rs ctl() by Anneline Daggelinckx
# Wiki: https://github.com/trueagi-io/MORK/wiki/MM2-Example:-CTL-model-checking
#
# This example shows:
#   - Atomic satisfaction  (label ∈ state labels)
#   - EX p  (there EXists a successor satisfying p)
#
# Key: exec priorities ensure atomic sat (exec 0) fires before EX (exec 1).
# Full EF/EU/AF/AU require iterative fixpoint — see upstream ctl() in main.rs.
#
# Run from warm REPL:  include("examples/ctl_model_checking.jl")

using MORK

println("=== CTL Model Checking ===\n")

s = new_space()

# ── Kripke structure: traffic light ──────────────────────────────────────────
# s0=red, s1=red+amber, s2=green, s3=amber; cycle s0→s1→s2→s3→s0
space_add_all_sexpr!(
    s,
    raw"""
(trans s0 s1) (trans s1 s2) (trans s2 s3) (trans s3 s0)
(label s0 red) (label s1 red) (label s1 amber)
(label s2 green) (label s3 amber)

; exec 0: atomic satisfaction — must fire BEFORE exec 1 (EX)
(exec 0 (, (label $s $p) (to_check $p $s))
        (, (sat $p $s)))

; exec 1: EX p — uses (sat $p $t) from exec 0
(exec 1 (, (trans $s $t) (sat $p $t) (to_check (EX $p) $s))
        (, (sat (EX $p) $s)))
"""
)

# Add ALL queries before running — exec 0 fires first, then exec 1 can use results
for state in ("s0", "s1", "s2", "s3"), prop in ("red", "green", "amber")
    space_add_all_sexpr!(s, "(to_check $prop $state)")
end
for state in ("s0", "s1", "s2", "s3")
    space_add_all_sexpr!(s, "(to_check (EX green) $state)")
end

ctl_steps = space_metta_calculus!(s, 999)
result = space_dump_all_sexpr(s)

println("Atomic propositions (exec 0 results):")
for q in ("(sat red s0)", "(sat amber s1)", "(sat green s2)", "(sat amber s3)")
    println("  $q : $(occursin(q, result) ? "✓ SAT" : "✗")")
end
@assert occursin("(sat red s0)", result) "s0 should be red"
@assert occursin("(sat green s2)", result) "s2 should be green"
@assert !occursin("(sat green s0)", result) "s0 should NOT be green"

println("\nEX(green) — states with a green successor (exec 1 results):")
for state in ("s0", "s1", "s2", "s3")
    found = occursin("(sat (EX green) $state)", result)
    # Only s1→s2(green) means s1 satisfies EX(green)
    println("  EX(green) at $state: $(found ? "✓ SAT" : "✗ not SAT")")
end
@assert occursin("(sat (EX green) s1)", result) "s1 satisfies EX(green): s1→s2"
@assert !occursin("(sat (EX green) s0)", result) "s0 does NOT satisfy EX(green): s0→s1 not green"

println("\nSteps: $ctl_steps  PASS")
println(
    "\nNote: full EF/EU/AF/AU via iterative fixpoint — see upstream ctl() in kernel/src/main.rs"
)
