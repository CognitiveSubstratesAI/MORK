# test/integration/sink_count.jl — ports fn sink_count() in kernel/src/main.rs
# CountSink: count all three-source matches (3x2x3=18).
using MORK, Test

@testset "sink_count — CountSink fires (3-source, 18 = 3×2×3)" begin
    s = new_space()
    space_add_all_sexpr!(
        s,
        """
(foo 1) (foo 2) (foo 3)
(bar x) (bar y)
(baz P) (baz Q) (baz R)
(exec 0 (, (foo \$x) (bar \$y) (baz \$z)) (O (count (all \$k) \$k (cux \$z \$y \$x))))
    """
    )
    steps = space_metta_calculus!(s, 100_000)
    @test steps < 100_000
    result = space_dump_all_sexpr(s)
    # CountSink fires once and stores count as (all 18).
    # Upstream assert_eq! res "18\n" (dumps only the all-prefix result).
    @test occursin("(all 18)", result)
end
