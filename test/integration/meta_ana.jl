# test/integration/meta_ana.jl — ports fn meta_ana() in kernel/src/main.rs:1536
# Coalgebraic tree traversal: an anamorphism hosted in a fixed-point rewriting system via
# `(rulify ...)` multi-source O sinks, unfolding a binary tree into path-addressed leaf values.
#
# HISTORY — this file used to @test_skip the full traversal, claiming
#     "(rulify ...) multi-source O sink patterns — needs Rule-of-64 fix"
# FALSE, falsified by execution 2026-07-27: the untouched upstream workload runs to a natural
# halt at 19 steps / 9 atoms and reproduces upstream's output exactly.
#
# The surviving non-skipped testset that this replaces was ALSO unfaithful: it seeded the bare
# `(branch ...)` with no `(tree-example ...)` wrapper, whereas upstream seeds via
# `add_sexpr(input, "$", "[2] tree-example _1")` (main.rs:1566). Without the wrapper the
# `(exec (0 0) (, (tree-example $e)) ...)` seed rule never fires, so it asserted only that atoms
# had loaded — it could not have detected the traversal being broken.
#
# Program text is READ FROM THE CONFORMANCE PROBE (single source of truth); byte-exactness vs
# the upstream binary is enforced by conformance_gate.jl (probe `space/meta_ana_coalgebra`).
#
# NOTE on the assertion surface: upstream asserts on a FILTERED, ORDER-SENSITIVE dump
# (`dump_sexpr("[2] space-example $", "_1")` == a 3-line string, main.rs:1540/1580). The .mm2
# format cannot express a dump pattern, so we assert set-membership of the three results plus
# the residual-atom shape. That is order-insensitive where upstream is order-sensitive, but
# strictly stronger elsewhere: pinning all 9 atoms proves `(has changed)` was retracted, every
# `tmp` was consumed by `(exec (2 0))`, and all exec frames were burned — none of which
# upstream's assert_eq! can see.
using MORK, Test

const META_ANA_PROBE = joinpath(
    @__DIR__, "..", "conformance", "space", "meta_ana_coalgebra.mm2"
)

@testset "meta_ana — coalgebraic tree traversal via (rulify) multi-source O sinks" begin
    s = new_space()
    space_add_all_sexpr!(s, read(META_ANA_PROBE, String))

    budget = 100_000
    steps = space_metta_calculus!(s, budget)

    @test steps == 19
    @test steps < budget

    lines = [strip(l) for l in split(space_dump_all_sexpr(s), '\n') if !isempty(strip(l))]
    atoms = Set(lines)

    # The three path-addressed leaves — upstream's `desired_output` (main.rs:1540), which it
    # extracts by stripping the `space-example` wrapper. We match the wrapped form as it lands.
    @test "(space-example (value (cons (cons nil L) L) 11))" in atoms   # left-left  -> 11
    @test "(space-example (value (cons (cons nil L) R) 12))" in atoms   # left-right -> 12
    @test "(space-example (value (cons nil R) 2))" in atoms             # right      -> 2
    @test count(l -> startswith(l, "(space-example "), lines) == 3      # and NOTHING else

    # Fixpoint witness: the rewriting system drained itself.
    @test count(l -> startswith(l, "(exec "), lines) == 0
    @test count(l -> startswith(l, "(tmp "), lines) == 0                # all consumed by (exec (2 0))
    @test !("(has changed)" in atoms)                                   # retracted at fixpoint
    @test length(lines) == 9                                            # seed + 3 results + 3 coalg + 2 rulify
end
