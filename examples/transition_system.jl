#!/usr/bin/env julia
# examples/transition_system.jl — MM2 Example: Transition System
#
# Demonstrates: LTS (Labelled Transition System) state exploration,
# pre/post-condition actions, and hash-based state deduplication.
# Upstream: kernel/src/main.rs bench_taxi_lts (lines 4979–5220)
# Wiki: https://github.com/trueagi-io/MORK/wiki/MM2-Example:-Transition-System
#
# Models a simple taxi cab on a 3×3 grid with a passenger.
# Actions: north/south/east/west (movement), pick-up, drop-off.
# State space explored via BFS fixpoint; states hashed for deduplication.
#
# Run from warm REPL:  include("examples/transition_system.jl")

using MORK

println("=== Transition System: Taxi on 3×3 grid ===\n")

s = new_space()
space_add_all_sexpr!(
    s,
    raw"""
; Grid adjacency (3×3, wrapping not allowed)
(northoff (0 1) (0 0)) (northoff (1 1) (1 0)) (northoff (2 1) (2 0))
(northoff (0 2) (0 1)) (northoff (1 2) (1 1)) (northoff (2 2) (2 1))
(southoff (0 0) (0 1)) (southoff (1 0) (1 1)) (southoff (2 0) (2 1))
(southoff (0 1) (0 2)) (southoff (1 1) (1 2)) (southoff (2 1) (2 2))
(eastoff  (0 0) (1 0)) (eastoff  (0 1) (1 1)) (eastoff  (0 2) (1 2))
(eastoff  (1 0) (2 0)) (eastoff  (1 1) (2 1)) (eastoff  (1 2) (2 2))
(westoff  (1 0) (0 0)) (westoff  (1 1) (0 1)) (westoff  (1 2) (0 2))
(westoff  (2 0) (1 0)) (westoff  (2 1) (1 1)) (westoff  (2 2) (1 2))

; Pickup/dropoff locations
(loc R (0 0)) (loc G (2 0)) (loc Y (0 2)) (loc B (2 2))

; Actions: (action-name preconditions positive-effects negative-effects)
(pre (north $l1 $l2) $s (, (state $s (taxi-at $l1)) (northoff $l1 $l2)))
(pos-eff (north $l1 $l2) (taxi-at $l2))
(neg-eff (north $l1 $l2) (taxi-at $l1))

(pre (south $l1 $l2) $s (, (state $s (taxi-at $l1)) (southoff $l1 $l2)))
(pos-eff (south $l1 $l2) (taxi-at $l2))
(neg-eff (south $l1 $l2) (taxi-at $l1))

(pre (east $l1 $l2) $s (, (state $s (taxi-at $l1)) (eastoff $l1 $l2)))
(pos-eff (east $l1 $l2) (taxi-at $l2))
(neg-eff (east $l1 $l2) (taxi-at $l1))

(pre (west $l1 $l2) $s (, (state $s (taxi-at $l1)) (westoff $l1 $l2)))
(pos-eff (west $l1 $l2) (taxi-at $l2))
(neg-eff (west $l1 $l2) (taxi-at $l1))

(pre (pick-up $l) $s (, (state $s (taxi-at $l)) (state $s (passenger-at $l))))
(pos-eff (pick-up $l) (in-taxi))
(neg-eff (pick-up $l) (passenger-at $l))

(pre (drop-off $l) $s (, (state $s (taxi-at $l)) (state $s (in-taxi)) (loc $c $l)))
(pos-eff (drop-off $l) (passenger-at $l))
(neg-eff (drop-off $l) (in-taxi))

; Initial state: taxi at (0,0), passenger at (2,0), destination R=(0,0)
(state init (taxi-at (0 0)))
(state init (passenger-at (2 0)))
(state init (destination R))

; Phase 0: apply applicable actions — generate successor states (hashed)
(exec 0 (, (state init $prop)) (O (hash (hash init $h) $h $prop)))
(exec 1 (, (hash init $h) (state init $prop)) (, (state $h $prop) (new $h)))

; Phase 2: expand frontier
(exec 2
  (, (new $s) (pre ($action $a1 $a2) $s) (state $s (in-taxi)))
  (O (hash (hash $s $ns) $ns (taxi-at $a2))
     (hash (hash $s $ns) $ns (in-taxi))
     (hash (hash $s $ns) $ns (destination $d))))

; Simple BFS step counter
(step-count 0)
(exec 3 (, (new $s)) (, (reached $s)))
"""
)

steps = space_metta_calculus!(s, 9999)
result = space_dump_all_sexpr(s)
reached = filter(l -> startswith(l, "(reached"), split(result, "\n"))
println("Steps: $steps")
println("States reached: $(length(reached))")
println("\nInitial state props:")
init_props = filter(l -> startswith(l, "(state init"), split(result, "\n"))
for p in init_props
    ;
    println("  $p");
end
println("\nDone!")
