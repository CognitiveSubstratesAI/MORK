# ALLOCATION RATCHET — fails when a change makes the engine allocate more.
#
# ─── WHY THIS EXISTS, AND WHY THE JET RATCHET IS NOT ENOUGH ──────────────────────────────────────
# On 2026-08-20 `expr_traverseh` — the generic fold EVERY expression walk goes through — was found
# declaring its accumulator stack `Tuple{UInt8, Any}[]`, boxing every value pushed. Fixing it took
# `process_calculus` (120 steps) from 1.751 GiB to 0.750 GiB of allocation.
#
# ⚠️ THE TIMING FIGURES FIRST PUBLISHED WITH THAT FIX (11.56 s -> 5.99 s, "1.93x") WERE HAND-ROLLED
# MEDIANS OF THREE `@timed` RUNS AND WERE WRONG. Re-measured with BenchmarkTools the same day: the
# post-fix median is **4.125 s**, not 5.99 — about 45% off. The "before" was measured the same crude
# way and cannot now be re-checked, so the RATIO is unverified too. The ALLOCATION numbers are
# unaffected: BenchmarkTools' memory estimate matches `@allocated` to the decimal, which is exactly
# why this ratchet pins bytes and not seconds.
# ⇒ TIMING GOES THROUGH BenchmarkTools OR IS NOT QUOTED. `@elapsed`/`@timed` medians hide the
# variance: clique4 40x300 ranged 32.6-161.8 ms over 20 samples with GC between 0% and 72%.
# [[feedback_perf_report_3_stable_runs]]
#
# 🔴 `jet_dispatch_ratchet.jl` REPORTED 104 BEFORE AND AFTER — it could not see it. `report_opt`
# reports RUNTIME DISPATCH AT CALL SITES; this was a CONTAINER ELEMENT TYPE causing BOXING. Data,
# not dispatch. A green JET ratchet reads as "no type problems" and that is not what it means.
# The two instruments are complements:
#     JET report_opt   -> dynamic dispatch (call sites)
#     THIS FILE        -> boxing and temporaries (data)
# [[feedback_oracle_must_observe_the_defect_class]]
#
# ─── WHY A PIN IS SOUND HERE WHERE A TIMING PIN WOULD NOT BE ─────────────────────────────────────
# MEASURED 2026-08-20, five runs after warmup: **0.0% spread**, byte-identical every time.
# Allocation is deterministic in a way wall-clock is not, so this can be pinned tightly instead of
# hedged with a generous threshold that only catches catastrophes.
#
# ⚠️ SELF-CONTAINED BY CONSTRUCTION. The workloads are built inline rather than read from
# `~/csai-work/gen/` — a ratchet that silently skips when a generated file is absent is worse than
# no ratchet, and the JET one has that fallback precisely because its corpus is not checked in.

using MORK, Test

# A cyclic conjunctive query (the join path) and a chain over the same relation. Small enough to be
# fast, structured enough that the join, the fold and the exec calculus all run.
const _AR_EDGES = join(["(edge n$i n$j)" for i in 1:14 for j in 1:14 if i < j], "\n") * "\n"
const _AR_CLIQUE = _AR_EDGES *
    "(exec 0 (, (edge \$a \$b) (edge \$a \$c) (edge \$b \$c)) (, (tri \$a \$b \$c)))\n"
const _AR_CHAIN = _AR_EDGES *
    "(exec 0 (, (edge \$x \$y) (edge \$y \$z)) (, (path \$x \$z)))\n"

_ar_run(src, cap) = begin
    s = MORK.new_space()
    MORK.space_add_all_sexpr!(s, src)
    MORK.space_metta_calculus!(s, cap)
    s
end

@testset "allocation ratchet" begin

    # ANTI-VACUITY FIRST. If these produced nothing, the allocation figures below would be measuring
    # an engine that did no work, and the pin would "hold" forever.
    s1 = _ar_run(_AR_CLIQUE, 1)
    n_tri = count(l -> startswith(l, "(tri "), split(MORK.space_dump_all_sexpr(s1), '\n'))
    @test n_tri > 0
    s2 = _ar_run(_AR_CHAIN, 1)
    n_path = count(l -> startswith(l, "(path "), split(MORK.space_dump_all_sexpr(s2), '\n'))
    @test n_path > 0

    for (name, src, cap, PIN_MIB) in (
            # PINS measured 2026-08-20 AFTER the traverseh fix, five runs each:
            #   triangle  3.818 MiB, spread 0.01%
            #   chain     2.388 MiB, spread 0.00%
            # Pinned at ~1.15x measured. The headroom is for Julia/stdlib version drift, NOT for
            # slack in our own code — a regression that boxes a container or copies where it used
            # to view moves this by multiples, not by percent. My first draft pinned 40.0 from a
            # guess and the ratchet said so immediately, which is the behaviour to keep.
            ("triangle join", _AR_CLIQUE, 1, 4.4),
            ("chain join",    _AR_CHAIN,  1, 2.8),
        )
        @testset "$name" begin
            _ar_run(src, cap)                                    # warm — JIT out of the measurement
            b = @allocated _ar_run(src, cap)
            mib = b / 2^20
            # 🔴 A CEILING, NOT A TARGET. Growth means a change started allocating — a boxed
            # container, a temporary in a loop, a copy that used to be a view. That is the alarm.
            @test mib <= PIN_MIB
            if mib < PIN_MIB * 0.75
                @info "allocation IMPROVED — lower the pin in this file and say what changed" (
                    workload = name, measured_MiB = round(mib, digits = 2), pin_MiB = PIN_MIB)
            end
        end
    end

    @testset "expr_traverseh's accumulator stack stays CONCRETE" begin
        # The specific defect this file was born from, pinned directly rather than only through a
        # byte total: the fold's stack element type must come from the accumulator, never `Any`.
        # A byte pin catches the CONSEQUENCE; this catches the CAUSE, and says so when it fails.
        e = MORK.sexpr_to_expr("(f (g h) (i j k))")
        acc_types = Set{Type}()
        MORK.expr_traverseh(nothing, e, 0,
            (h, o) -> (h, nothing),                      # new_var
            (h, o, r) -> (h, nothing),                   # var_ref
            (h, o, s) -> (h, nothing),                   # symbol
            (h, o, a) -> (h, 0),                         # zero — accumulator is an Int
            (h, o, x, y) -> (push!(acc_types, typeof(x)); (h, x)),   # add
            (h, o, a) -> (h, a))                         # finalize
        @test !isempty(acc_types)                        # anti-vacuity: the walk really ran
        # Every accumulator seen must be the CONCRETE type `zero_cb` returns, never boxed as Any.
        @test all(t -> isconcretetype(t), acc_types)
    end
end
