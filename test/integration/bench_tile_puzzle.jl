# bench_tile_puzzle.jl — port of fn bench_tile_puzzle_states() from kernel/src/main.rs
# 8-puzzle (3x3 sliding tile) BFS state exploration.
# Upstream: no assert, counts reachable states. We verify rules load +
# state1 entries (valid initial configurations) are generated.
using MORK, Test

@testset "bench_tile_puzzle — rules load + state1 generated" begin
    s = new_space()

    # Move rules: (move <board> <direction> <new_board>)
    space_add_all_sexpr!(
        s,
        """
(move (___ \$_2 \$_3
       \$_4 \$_5 \$_6
       \$_7 \$_8 \$_9) R (\$_2 ___ \$_3
                       \$_4 \$_5 \$_6
                       \$_7 \$_8 \$_9))
(move (___ \$_2 \$_3
       \$_4 \$_5 \$_6
       \$_7 \$_8 \$_9) D (\$_4 \$_2 \$_3
                       ___ \$_5 \$_6
                       \$_7 \$_8 \$_9))
(move (\$_1 ___ \$_3
       \$_4 \$_5 \$_6
       \$_7 \$_8 \$_9) L (___ \$_1 \$_3
                       \$_4 \$_5 \$_6
                       \$_7 \$_8 \$_9))
(move (\$_1 ___ \$_3
       \$_4 \$_5 \$_6
       \$_7 \$_8 \$_9) R (\$_1 \$_3 ___
                       \$_4 \$_5 \$_6
                       \$_7 \$_8 \$_9))
(move (\$_1 ___ \$_3
       \$_4 \$_5 \$_6
       \$_7 \$_8 \$_9) D (\$_1 \$_5 \$_3
                       \$_4 ___ \$_6
                       \$_7 \$_8 \$_9))
"""
    )

    # Inequality facts for a 3-tile subset (1 ≠ 2, 1 ≠ 3, 2 ≠ 3)
    space_add_all_sexpr!(s, "(1 != 2) (1 != 3) (2 != 1) (2 != 3) (3 != 1) (3 != 2)")

    # empty mapping: given 8 tiles, place ___ at position N
    space_add_all_sexpr!(
        s,
        """
(empty \$_1 \$_2 \$_3 \$_4 \$_5 \$_6 \$_7 \$_8 1 (___ \$_1 \$_2 \$_3 \$_4 \$_5 \$_6 \$_7 \$_8))
(empty \$_1 \$_2 \$_3 \$_4 \$_5 \$_6 \$_7 \$_8 2 (\$_1 ___ \$_2 \$_3 \$_4 \$_5 \$_6 \$_7 \$_8))
(empty \$_1 \$_2 \$_3 \$_4 \$_5 \$_6 \$_7 \$_8 9 (\$_1 \$_2 \$_3 \$_4 \$_5 \$_6 \$_7 \$_8 ___))
"""
    )

    space_add_all_sexpr!(s, "(square 1) (square 2) (square 3)")

    # Simplified exec 0: generate state1 for 3 distinct values
    space_add_all_sexpr!(
        s,
        """
(exec 0
  (, (\$_1 != \$_2)
     (\$_2 != \$_3) (\$_3 != \$_1)
     (empty \$_1 \$_2 \$_3 \$_4 \$_5 \$_6 \$_7 \$_8 \$x \$state))
  (, (state1 \$state)))
"""
    )

    steps = space_metta_calculus!(s, 1000)
    println("  steps=$steps  count=$(space_val_count(s))")

    res = space_dump_all_sexpr(s)
    lines = filter(!isempty, split(res, "\n"))

    # Move rules should be in space (not exec rules, so they stay)
    @test any(startswith(l, "(move ") for l in lines)
    # exec fired at least once
    @test steps > 0
    # state1 entries generated (valid permutations of 3 tiles)
    state1_count = count(l -> startswith(l, "(state1 "), lines)
    println("  state1 entries: $state1_count")
    @test state1_count > 0
end
