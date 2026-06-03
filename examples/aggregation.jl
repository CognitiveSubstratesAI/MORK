#!/usr/bin/env julia
# examples/aggregation.jl — Numeric aggregation using float-reduction sinks
#
# Demonstrates fmin, fmax, fsum sinks and the remove sink (-).
# Mirrors the upstream MORK kernel/resources/ float-reduction examples.
#
# Run:
#   julia --project=. examples/aggregation.jl

using MORK

# ── Temperature sensor readings ────────────────────────────────────────
s = new_space()
space_add_all_sexpr!(
    s,
    """
    (reading 12.5)
    (reading 18.3)
    (reading  9.1)
    (reading 24.7)
    (reading 15.0)
"""
)

space_add_all_sexpr!(
    s,
    """
    ;; Aggregate all readings into running statistics
    (exec 0
        (, (reading \$x))
        (O
            (fmin  (stats:min \$c) \$c \$x)
            (fmax  (stats:max \$c) \$c \$x)
            (fsum  (stats:sum \$c) \$c \$x)
        )
    )

    ;; Remove source readings after aggregation
    (exec 1
        (, (reading \$x))
        (O (- (reading \$x)))
    )
"""
)

steps = space_metta_calculus!(s, 100_000)
result = space_dump_all_sexpr(s)

println("=== Temperature Aggregation ===")
println("Converged in $steps steps\n")

for line in sort(split(strip(result), "\n"))
    startswith(line, "(stats:") && println("  $line")
end

@assert occursin("(stats:min 9.1)", result) "min should be 9.1"
@assert occursin("(stats:max 24.7)", result) "max should be 24.7"
@assert !occursin("(reading ", result) "source readings should be consumed"
println("\n✓ All assertions passed")

# ── Factorial via fprod ────────────────────────────────────────────────
println("\n=== Factorial via fprod ===")
s2 = new_space()
space_add_all_sexpr!(
    s2,
    """
    (n 1) (n 2) (n 3) (n 4) (n 5)
    (exec 0
        (, (n \$x))
        (O (fprod (factorial \$c) \$c \$x))
    )
"""
)
space_metta_calculus!(s2, 10_000)
result2 = space_dump_all_sexpr(s2)
m = match(r"\(factorial (\S+)\)", result2)
println("5! = ", m === nothing ? "?" : m.captures[1])
@assert occursin("(factorial 120", result2) "5! should be 120"
println("✓ Correct")
