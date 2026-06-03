#!/usr/bin/env julia
# examples/backward_chaining.jl — MM2 Example: Testing Your Code
#
# Demonstrates: proof search via the `zealous` fixpoint driver, typed
# application proofs, and modus-ponens chains (bc0 pattern).
# Upstream: kernel/src/main.rs bc0 (lines 3350–3400)
# Wiki: https://github.com/trueagi-io/MORK/wiki/MM2-Example:-Testing-Your-Code
#
# The `zealous` driver fires every registered (step ...) rule until no new
# proofs emerge — a fixpoint strategy for combined forward/backward search.
#
# Note: the `abs` rule generates MP instantiations at every goal depth,
# producing many specialisations of MP. This is intentional (it mirrors
# the upstream behaviour). Step cap = 50 matches upstream bc0 exactly.
#
# Run from warm REPL:  include("examples/backward_chaining.jl")

using MORK

println("=== bc0: prove C from A via A→B→C (zealous backward chaining) ===")
s = new_space()
space_add_all_sexpr!(
    s,
    raw"""
((step base) (, (goal (: $proof $conclusion)) (kb (: $proof $conclusion)))
             (, (ev (: $proof $conclusion))))
((step abs)  (, (goal (: $proof $conclusion)))
             (, (goal (: $lhs (-> $synth $conclusion)))))
((step rev)  (, (ev (: $lhs (-> $a $r))) (goal (: $k $r)))
             (, (goal (: $rhs $a))))
((step app)  (, (ev (: $lhs (-> $a $r))) (ev (: $rhs $a)))
             (, (ev (: (@ $lhs $rhs) $r))))
(exec zealous (, ((step $x) $p0 $t0) (exec zealous $p1 $t1))
              (, (exec $x $p0 $t0) (exec zealous $p1 $t1)))
(kb (: a A)) (kb (: ab (R A B))) (kb (: bc (R B C)))
(kb (: MP (-> (R $p $q) (-> $p $q))))
(goal (: $proof C))
"""
)
bc_elapsed = @elapsed bc_steps = space_metta_calculus!(s, 50)
result = space_dump_all_sexpr(s)
evs = filter(l -> startswith(l, "(ev"), split(result, "\n"))

println(
    "Steps: $bc_steps  Time: $(round(bc_elapsed, digits=2))s  Evidence atoms: $(length(evs))"
)
println("\nKey proofs found:")
for e in filter(e -> occursin("(@ (@ MP", e), evs)
    println("  $e")
end

@assert any(e -> occursin("(@ (@ MP bc) (@ (@ MP ab) a))", e), evs) "proof of C not found"
println("\nPASS: proof (@ (@ MP bc) (@ (@ MP ab) a)) : C found")
