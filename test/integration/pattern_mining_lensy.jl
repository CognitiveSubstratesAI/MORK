# pattern_mining_lensy.jl — port of pattern_mining_lensy from kernel/src/main.rs
using MORK, Test

@testset "pattern_mining_lensy (lens-based structural extraction)" begin
    s = new_space()
    space_add_all_sexpr!(
        s,
        """
(data (Outer (Inner "capybara")))
(data (Outer (Inner "piranha")))

(lensOf (\$x) \$x \$i (\$i))
(lensOf (\$x \$y) \$x \$i (\$i \$y))
(lensOf (\$x \$y) \$y \$i (\$x \$i))
(lensOf (\$x \$y \$z) \$x \$i (\$i \$y \$z))
(lensOf (\$x \$y \$z) \$y \$i (\$x \$i \$z))
(lensOf (\$x \$y \$z) \$z \$i (\$x \$y \$i))

(exec 0 (, (data \$e) (lensOf \$e \$se \$x \$xc))
        (, (peel0 \$se \$x \$xc) ))

(exec 1 (, (peel0 \$e \$yc \$xc) (lensOf \$e \$se \$y \$yc))
        (, (peel1 \$se \$y \$xc) ))

(exec 2 (, (peel1 \$x \$x \$y))
        (, (rest \$y) ))

(exec 3 (, (peel1 "capybara" "capybara" \$y))
        (, (found_capybara \$y) ))

(exec 4 (, (peel0 (Inner \$x) \$q \$y))
        (O (count (found Inner \$y \$c) \$c \$x)))
"""
    )

    space_metta_calculus!(s)

    io = IOBuffer()
    space_dump_all_sexpr(s, io)
    res = String(take!(io))

    @test contains(res, "(rest (Outer (Inner \"piranha\")))")
    @test contains(res, "(rest (Outer (Inner \"capybara\")))")
    @test contains(res, "(found_capybara (Outer (Inner \"capybara\")))")
    # CountSink now accumulates across all matches → count=2 matches upstream assert
    @test contains(res, "found Inner (Outer") && any(
        contains(l, "2") for l in filter(l->contains(l, "found Inner"), split(res, "\n"))
    )
end
