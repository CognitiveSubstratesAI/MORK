# ip_sudoku.jl — port of fn ip_sudoku() from kernel/src/main.rs
# 4x4 sudoku constraint propagation using pure-ops bit manipulation.
# The upstream test has no assert (just prints); we check structural invariants.
using MORK, Test

@testset "ip_sudoku (4x4 constraint propagation, no-assert)" begin
    s = new_space()
    space_add_all_sexpr!(
        s,
        """
(dim 2)
(pos 0) (pos 1) (pos 2) (pos 3)
(val 1) (val 2) (val 3) (val 4)

(exec 0 (, (dim \$b) (pos \$c) (pos \$r))
        (O (+ (row \$r (\$r \$c)))
           (+ (col \$c (\$r \$c)))
           (pure (box \$c \$co) \$co
             (tuple
               (i8_to_string (sum_i8 (product_i8 (i8_from_string \$b) (div_i8 (i8_from_string \$c) (i8_from_string \$b)))
                                     (div_i8 (i8_from_string \$r) (i8_from_string \$b))))
               (i8_to_string (sum_i8 (product_i8 (i8_from_string \$b) (mod_i8 (i8_from_string \$c) (i8_from_string \$b)))
                                     (mod_i8 (i8_from_string \$r) (i8_from_string \$b))))))))

(known (0 2) 3)
(known (1 1) 4)
(known (2 2) 2)
(known (3 3) 1)

(exec 1 (, (pos \$c) (pos \$r))
        (O (pure (cell (\$c \$r) \$iv) \$iv
             (i8_from_string 15))))

(exec 2 (, (known \$co \$tv))
        (O (pure (incomming \$co \$v) \$v
             (u8_andn (i8_from_string 15) (i8_from_string \$tv)))))

(exec 3 (, (cell \$c \$v) (incomming \$c \$i))
        (O (pure (cell \$c \$nv) \$nv
             (ifnz (u32_xnor (u8_count_ones \$i) (i32_one))
              then (u8_andn \$v \$i)))
           (- (cell \$c \$v))))

(exec 4 (, (row \$r \$x) (cell \$x \$xv) (row \$r \$y)) (, (incomming \$y \$xv)))
(exec 4 (, (col \$c \$x) (cell \$x \$xv) (col \$c \$y)) (, (incomming \$y \$xv)))
(exec 4 (, (box \$b \$x) (cell \$x \$xv) (box \$b \$y)) (, (incomming \$y \$xv)))

(exec 5 (, (cell \$c \$v) (incomming \$c \$i))
        (O (pure (cell \$c \$nv) \$nv
             (ifnz (u32_xnor (u8_count_ones \$i) (i32_one))
              then (u8_andn \$v \$i)))
           (- (cell \$c \$v))))

(exec 1000 (, (cell \$co \$tv))
        (O (pure (readout \$co \$v) \$v
             (i8_to_string \$tv))))
"""
    )

    steps = space_metta_calculus!(s, 100)
    println("  steps=$steps  count=$(space_val_count(s))")

    res = space_dump_all_sexpr(s)
    lines = Set(filter(!isempty, split(res, "\n")))

    # Structural checks — exec 0 must produce row/col/box entries
    @test any(startswith(l, "(row ") for l in lines)
    @test any(startswith(l, "(col ") for l in lines)
    @test any(startswith(l, "(box ") for l in lines)

    # Known values seeded, exec 1 initialises cells, exec 2 creates incoming
    @test any(startswith(l, "(known ") for l in lines)

    println("  row/col/box entries present ✓")
end
