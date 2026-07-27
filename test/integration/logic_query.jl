# test/integration/logic_query.jl — ports fn logic_query() in kernel/src/main.rs
# Equational logic: bi-directional equation search. Fixpoint = 24 atoms, VERIFIED against the
# upstream binary (`mork run` -> "dumping 24 expressions", byte-identical dump).
using MORK, Test

@testset "logic_query — equational logic fixpoint = 24 atoms (matches upstream binary)" begin
    s = new_space()
    space_add_all_sexpr!(
        s,
        """
(exec 0 (, (axiom (= \$lhs \$rhs)) (axiom (= \$rhs \$lhs))) (, (reversed \$lhs \$rhs)))
    """
    )
    # Load axioms tagged under (axiom ...)
    axioms = """
(= (L \$x \$y \$z) (R \$x \$y \$z))
(= (L 1 \$x \$y) (R 1 \$x \$y))
(= (R \$x (L \$x \$y \$z) \$w) \$x)
(= (R \$x (R \$x \$y \$z) \$w) \$x)
(= (R \$x (L \$x \$y \$z) \$x) (L \$x (L \$x \$y \$z) \$x))
(= (L \$x \$y (\\ \$y \$z)) (L \$x \$y \$z))
(= (L \$x \$y (* \$z \$y)) (L \$x \$y \$z))
(= (L \$x \$y (\\ \$z 1)) (L \$x \$z \$y))
(= (L \$x \$y (\\ \$z \$y)) (L \$x \$z \$y))
(= (L \$x 1 (\\ \$y 1)) (L \$x \$y 1))
(= (T \$x (L \$x \$y \$z)) \$x)
(= (T \$x (R \$x \$y \$z)) \$x)
(= (T \$x (a \$x \$y \$z)) \$x)
(= (T \$x (\\ (a \$x \$y \$z) \$w)) (T \$x \$w))
(= (T \$x (* \$y \$y)) (T \$x (\\ (a \$x \$z \$w) (* \$y \$y))))
(= (R (/ 1 \$x) \$x (\\ \$x 1)) (\\ \$x 1))
(= (\\ \$x 1) (/ 1 (L \$x \$x (\\ \$x 1))))
(= (L \$x \$x \$x) (* (K \$x (\\ \$x 1)) \$x))
    """
    for line in split(strip(axioms), "\n")
        isempty(strip(line)) && continue
        space_add_all_sexpr!(s, "(axiom $line)\n")
    end
    steps = space_metta_calculus!(s, 100_000)
    @test steps < 100_000
    # 24, measured from the UPSTREAM BINARY on this exact program:
    #     mork run logic_query.mm2  ->  "executing 1 steps", "dumping 24 expressions"
    # and our dump matches it. Two stale numbers previously lived here:
    #   * 79 — from upstream's `assert_eq!(btm.val_count(), 79)` (main.rs:3498), inside a function
    #     upstream itself DISABLES as "// possibly faulty test" (main.rs:6184). Never re-measured.
    #   * 63 — NOT invented, but measured off OUR OWN ENGINE while it had a soundness bug, then
    #     rationalised with a "45 symmetric pairs / 324 pairs / 18 cycles" narrative that no longer
    #     described anything. A number measured off a buggy engine and then explained is worse than
    #     no number: it locks the bug in and reads as verified.
    @test space_val_count(s) == 24
end
