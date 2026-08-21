# Leapfrog RANKING — `rank_parts`, the principle the join is NAMED after.
#
# Ports upstream `rank_parts` (`kernel/src/leapfrog.rs:1610`). Upstream states the point plainly:
#
#     "The leapfrog principle: lead with the smallest domain so the leading factor enumerates few
#      candidates and the rest seek. This is what makes a selective factor, say `(e a $y)` with a
#      few edges, drive the join instead of the whole relation."
#
# 🔴 WITHOUT IT, SYNTACTIC FACTOR ORDER DECIDES. `parts` is gathered in factor order, so conjunct 1
# leads no matter how large its domain is. MEASURED on this file's skewed shape BEFORE the ranking
# existed: **303 candidates enumerated to produce 3 answers** — `big` enumerating 300 first-column
# values so that `sel`, which has 3, could reject 297 of them.
#
# ⚠️ THE ASSERTION IS A COUNT, NOT A TIMING, AND THAT IS DELIBERATE. "It got faster" varies with GC
# and the box; "it enumerated 303 candidates where 6 suffice" is the MECHANISM and is deterministic.
# A timing that improved while this count stayed flat would mean the win came from somewhere else.
# [[feedback_run_the_check_before_making_the_claim]] · [[feedback_no_perf_attribution_without_profiling]]
#
# 🔑 AND THE ANSWERS MUST NOT MOVE. Ranking reorders which factor leads; it cannot change the answer
# SET. The engine is the judge here as everywhere in this port — `leapfrog_differential.jl` (603
# generated shapes) and `leapfrog_wiring.jl` (300 generated bodies) are the real net, and these
# assertions add the one thing they cannot see: how much work was done to get the same answers.

using MORK, Test
const _RK = MORK.Leapfrog

_rk_space(src) = (s = MORK.new_space(); MORK.space_add_all_sexpr!(s, src); s)

"Answers and candidates-enumerated for one body, through the leapfrog."
function _rk_measure(s, body::AbstractString)
    pe = MORK.sexpr_to_expr(body)
    _RK._LF_TRACE[] = true
    _RK._LF_CANDIDATES[] = 0
    n = try
        MORK.space_query_multi_leapfrog(s.btm, pe, (_b, _l) -> true)
    finally
        _RK._LF_TRACE[] = false          # a thrown probe must not leave tracing on for other files
    end
    (n, _RK._LF_CANDIDATES[])
end

function _rk_engine(s, body::AbstractString)
    n = Ref(0)
    MORK.space_query_multi(s.btm, MORK.sexpr_to_expr(body), (_b, _l) -> (n[] += 1; true))
    n[]
end

@testset "leapfrog ranking — lead with the smallest domain" begin

    @testset "🔑 A SELECTIVE FACTOR DRIVES THE JOIN, even when written second" begin
        # `big` has 300 distinct first-column values; `sel` has 3. Syntactic order puts `big` first.
        src = join(["(big n$i v$i)" for i in 1:300], "\n") * "\n" *
              join(["(sel n$i c)" for i in 1:3], "\n") * "\n"
        s = _rk_space(src)
        body = "(, (big \$x \$y) (sel \$x c))"

        (n, cand) = _rk_measure(s, body)
        @test n == _rk_engine(s, body)
        @test n == 3                      # anti-vacuity: there really are answers to find

        # MEASURED 2026-08-21: 303 before ranking, and the smallest domain is 3, so a ranked join
        # enumerates 3 at the join level plus one per surviving answer. The bound is deliberately
        # loose enough not to pin an implementation detail, and far below 303.
        @test cand <= 20
    end

    @testset "…and the SAME query with the factors written the other way round agrees" begin
        # If ranking works, factor order stops mattering — same answers AND comparable work.
        src = join(["(big n$i v$i)" for i in 1:300], "\n") * "\n" *
              join(["(sel n$i c)" for i in 1:3], "\n") * "\n"
        s = _rk_space(src)
        a = _rk_measure(s, "(, (big \$x \$y) (sel \$x c))")
        b = _rk_measure(s, "(, (sel \$x c) (big \$x \$y))")
        @test a[1] == b[1]                            # same answers
        @test a[1] == _rk_engine(s, "(, (big \$x \$y) (sel \$x c))")
        @test max(a[2], b[2]) <= 4 * max(min(a[2], b[2]), 1)   # …and comparable work either way
    end

    @testset "the ranking is EXACT for an exhausted cursor, not an estimate" begin
        # Upstream's round robin stops at the end of the round in which SOME cursor runs out, so
        # that cursor's count is its true domain size and always sorts first. A capped
        # count-to-N estimate could not tell 100 from 100 000 — that is the defect it replaced.
        for k in (1, 2, 5)
            src = join(["(big n$i v$i)" for i in 1:200], "\n") * "\n" *
                  join(["(sel n$i c)" for i in 1:k], "\n") * "\n"
            s = _rk_space(src)
            body = "(, (big \$x \$y) (sel \$x c))"
            (n, cand) = _rk_measure(s, body)
            @test n == _rk_engine(s, body)
            @test n == k
            @test cand <= 4 * k + 8       # scales with the SMALL domain, not the 200-value one
        end
    end

    @testset "equal domains keep syntactic order — the sort is STABLE" begin
        # Not cosmetic: an unstable sort makes the join's visit order depend on the sort's internals,
        # so a differential that passes today could reorder tomorrow for no reason anyone can see.
        src = join(["(rel$r n$i c)" for r in 1:2 for i in 1:5], "\n") * "\n"
        s = _rk_space(src)
        body = "(, (rel1 \$x c) (rel2 \$x c))"
        (n, _) = _rk_measure(s, body)
        @test n == _rk_engine(s, body)
        @test n == 5                      # anti-vacuity
    end

    @testset "🔑 THE MUTUAL-SEEK LEAP — the case ranking structurally CANNOT fix" begin
        # `rank_parts` picks the smallest domain to lead. When BOTH domains are large and the
        # INTERSECTION is tiny, there is no small domain to pick: whichever leads still enumerates
        # its whole column. That is what `fill_lead_candidates` is for — seek each restrictor to the
        # candidate and, when it answers with a LARGER value, leap the lead straight there instead
        # of walking (and unifying, binding, unwinding) every value in between.
        #
        # MEASURED 2026-08-21 with ranking but WITHOUT the leap: 1000 candidates for 3 answers.
        # The skewed shape above measured 6, so the two mechanisms address different shapes and
        # neither subsumes the other.
        #
        # 🔴 SOUNDNESS — WHY THIS MAY PRUNE AT ALL. This join UNIFIES, so a stored value can MATCH a
        # candidate without EQUALLING it, and an exact intersection would silently drop answers.
        # Pruning is legal ONLY where unifiability IS equality: symbol-headed candidates are ground,
        # and a restrictor's column holds no stored variable, so only the same symbol unifies there.
        # Symbol bytes sort ABOVE every compound and variable byte, so those candidates form a
        # SUFFIX — everything before it (wildcards, schematic compounds) is pushed UNFILTERED and
        # the seek never skips over any of it. [[reference_wfs_bottom_propagation_semantics]]
        N = 1000
        src = join(["(pa n$i x)" for i in 1:N], "\n") * "\n" *
              join(["(pb n$i y)" for i in (N - 2):(2N - 3)], "\n") * "\n"   # overlap = exactly 3
        s = _rk_space(src)
        body = "(, (pa \$x x) (pb \$x y))"

        (n, cand) = _rk_measure(s, body)
        @test n == _rk_engine(s, body)
        @test n == 3                       # anti-vacuity: there really are 3 answers
        # Was 1000 before the leap. The bound is loose enough not to pin an implementation detail
        # and far below the domain size — if this regresses to ~1000 the leap stopped working.
        @test cand <= 60
    end

    @testset "🔴 AN INVERTED FACTOR COSTS 100x — the acceptance criterion for RE-INDEXING" begin
        # Upstream's `is_inverted` (leapfrog.rs:727) flags a factor whose columns mention variables
        # OUT OF SCHEDULE ORDER and permutes them into a private re-indexed map so it can be SOUGHT
        # rather than enumerated. We do not port that yet — the last documented omission.
        #
        # `(, (edge $x $y) (edge $z $x))`: `$z` is id 2, `$x` is id 0, so at `$x`'s level factor 2
        # is NOT EVEN A PARTICIPANT — its current step is `$z`. It cannot be sought, so its whole
        # column is enumerated once per `$x`.
        #
        # MEASURED 2026-08-21 on a 300-edge chain: ORDERED 900 candidates, INVERTED 90 600 — 100.7x,
        # which is ~300 x 302. Answers are CORRECT either way (299 == engine); this is purely work.
        #
        # ⚠️ THIS TEST IS WRITTEN TO FAIL WHEN RE-INDEXING LANDS, like the `!occursin` pins beside
        # it. If the ratio collapses, delete the inequality and pin the new number — do not widen it.
        N = 300
        chain = join(["(edge n$i n$(i + 1))" for i in 1:N], "\n") * "\n"
        s = _rk_space(chain)

        ordered = _rk_measure(s, "(, (edge \$x \$y) (edge \$x \$z))")
        inverted = _rk_measure(s, "(, (edge \$x \$y) (edge \$z \$x))")

        # ANSWERS FIRST, and anti-vacuity — a shape with no answers would "prove" anything.
        @test ordered[1] == _rk_engine(s, "(, (edge \$x \$y) (edge \$x \$z))")
        @test inverted[1] == _rk_engine(s, "(, (edge \$x \$y) (edge \$z \$x))")
        @test inverted[1] > 0
        @test ordered[1] > 0

        # …and the cost, pinned. Currently ~100x; the assertion is deliberately conservative.
        @test inverted[2] > 20 * ordered[2]
    end

    @testset "ranking does not disturb the shapes the differential already pins" begin
        # A cheap re-run of the two cases most likely to break under reordering: a stored wildcard
        # (which must never be pruned) and a repeated variable (which needs catch_up).
        s1 = _rk_space("(edge a b)\n(edge \$w b)\n(edge b c)\n")
        b1 = "(, (edge \$x \$y) (edge \$y \$z))"
        @test _rk_measure(s1, b1)[1] == _rk_engine(s1, b1)

        s2 = _rk_space("(edge a a)\n(edge a b)\n(edge b b)\n")
        b2 = "(, (edge \$x \$x))"
        @test _rk_measure(s2, b2)[1] == _rk_engine(s2, b2)
    end

    @testset "tracing is OFF after these tests" begin
        # The counter is global. A test that left it on would slow every later file and, worse,
        # make its own measurements depend on what ran before it.
        @test _RK._LF_TRACE[] == false
    end
end
