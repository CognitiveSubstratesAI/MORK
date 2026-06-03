#!/usr/bin/env julia
# tools/profile_space.jl — Profile hot paths in MORK's space calculus
#
# Usage (from warm REPL):
#   include("tools/profile_space.jl")
#
# Or from interactive mork_repl.jl:
#   include("tools/profile_space.jl")
#
# Requires ProfileView for flamegraph (optional):
#   julia> using ProfileView; ProfileView.view()

using MORK, Profile

# ── Workloads ──────────────────────────────────────────────────────────

function workload_ground_match(n=200)
    s = new_space()
    for i in 1:n
        space_add_all_sexpr!(s, "(fact item_$i)")
    end
    space_add_all_sexpr!(
        s,
        """
    (exec 0 (, (fact \$x)) (O (processed \$x)))
    (exec 1 (, (fact \$x)) (O (- (fact \$x))))
"""
    )
    s
end

function workload_two_source(n=100)
    s = new_space()
    for i in 1:n
        space_add_all_sexpr!(s, "(A item_$i)\n(B item_$i)")
    end
    space_add_all_sexpr!(s, "(exec 0 (, (A \$x) (B \$x)) (O (C \$x)))")
    s
end

function workload_float_sinks(n=100)
    s = new_space()
    vals = join(["(n $(rand() * 100))" for _ in 1:n], "\n")
    space_add_all_sexpr!(s, vals)
    space_add_all_sexpr!(
        s,
        """
    (exec 0
        (, (n \$x))
        (O (fsum (total \$c) \$c \$x) (fmax (peak \$c) \$c \$x))
    )
    (exec 1 (, (n \$x)) (O (- (n \$x))))
"""
    )
    s
end

# ── Profile runner ────────────────────────────────────────────────────

function run_profile(label, build_fn, max_steps=100_000)
    println("\n=== Profiling: $label ===")
    s = build_fn()

    # Warm up (avoids profiling JIT)
    s_warm = build_fn()
    space_metta_calculus!(s_warm, 100)

    # Profile
    Profile.clear()
    @profile space_metta_calculus!(s, max_steps)

    # Text summary (top 20 frames by count)
    println("\nTop frames (text profile):")
    Profile.print(; maxdepth=8, mincount=5, sortedby=:count)
end

# ── Main ──────────────────────────────────────────────────────────────

println("MORK Space Calculus Profiler")
println("============================")
println("Julia version: ", VERSION)
println()
println("Available workloads:")
println("  run_profile(\"ground_match\", workload_ground_match)")
println("  run_profile(\"two_source\",  workload_two_source)")
println("  run_profile(\"float_sinks\", workload_float_sinks)")
println()
println("After profiling, view flamegraph with:")
println("  using ProfileView; ProfileView.view()")
println("  using PProf; pprof()   # web-based")
println()

# Run default profile
run_profile("ground_match_200", () -> workload_ground_match(200))
