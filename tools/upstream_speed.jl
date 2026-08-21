# upstream_speed.jl — PER-PROGRAM wall clock vs the upstream Rust binary.
#
#   MORK_UPSTREAM=<path> julia --project=. tools/upstream_speed.jl     # (or via tools/run_tests.sh)
#
# ─── WHAT IT FOUND, 2026-08-21 ───────────────────────────────────────────────────────────────────
# 285 programs. The MEDIAN ratio is NOT a result — upstream runs as a separate PROCESS (~5 ms spawn)
# while ours runs in-process, so on small programs upstream's 0.007 s is mostly startup. Read the
# TAIL, where compute dominates:
#
#     mm1_forward_full_proof   upstream 0.057s   ours 0.572s   10.1x    ← and 23.9x WITH the leapfrog
#     g1_hash_ctl_eg_fixpoint  upstream 0.024s   ours 0.125s    5.2x    (leapfrog helps: 2.5x)
#     meta_ana_coalgebra       upstream 0.012s   ours 0.023s    2.0x    (leapfrog helps: 0.7x)
#
# 🔴 THE LEAPFROG IS 1.83x SLOWER THAN OUR OWN ProductZipper on mm1_forward_full_proof — 3.30x the
# allocation, identical answers (1598 atoms both ways). Profiled: `_occurs_check` (ExprAlg.jl:498,
# :501) is the dominant allocator, inside `expr_unify`, which `unified_bindings` calls ONCE PER
# CANDIDATE re-solving every equation from scratch. That is the pre-trail design ported on purpose;
# upstream replaced it in `cfa8abf` and measured the old one at "11.6x the ProductZipper's
# unification work" on big.metta. ⇒ the undo trail is the next real lever, and
# `leapfrog_end_to_end.jl`'s cyclic-capture tests are its acceptance criterion (they pass TODAY
# because re-solving everything sees a chain-borne occurs violation; a trail loses that and needs
# upstream's explicit `cycled` check).
#
# ⚠️ WHY PER-PROGRAM AND NOT AN AGGREGATE. Julia loses to Rust on constant factors, and averaging
# that over 285 programs is unactionable. A DISPROPORTIONATE gap on ONE program is the signature of
# an ALGORITHMIC divergence — which is how the 1182x intermediate blowup was found. The median is
# the language tax; the outliers are the bugs.
#
# ⚠️ NEEDS THE BOX QUIET, and compares RATIOS so moderate contention affects both sides alike.
# A 45%-off figure was once reported here from hand-rolled timing under load.
#
# 🔴 THE AGGREGATE IS THE WRONG QUESTION. Julia will lose to Rust on constant factors — GC, boxing,
# dispatch — and averaging that over 285 programs tells us nothing we can act on. What IS actionable
# is a DISPROPORTIONATE gap on particular programs: that is the signature of an ALGORITHMIC
# divergence, i.e. a porting mistake. That is exactly how the 1182x intermediate blowup was found —
# not from "we are slower", but from one shape being slower than everything around it.
#
# So: time each program on both engines, sort by RATIO, and read the tail. The median ratio is the
# language tax; the outliers are the bugs.
#
# ⚠️ NEEDS THE BOX TO ITSELF. A 45%-off timing was reported earlier in this project from hand-rolled
# measurement under contention. [[feedback_perf_report_3_stable_runs]]
using MORK, Printf
# ⚠️ `Base.run` — `run` is SHADOWED by the MORK test REPL helper `run(src)`. Known trap:
# `upstream_conformance.jl:68` already uses `Base.run` and its header records the same fix (c543841).

const UP = get(ENV, "MORK_UPSTREAM_BIN",
                expanduser("~/JuliaAGI/dev-zone/MORK/target/release/mork"))
const DIRS = [joinpath(homedir(), "code/CognitiveSubstratesAI/MORK/test/conformance", d)
              for d in ("space", "sinks")]
const STEPS = 2000

isfile(UP) || error("no upstream binary at $UP — the comparison has no oracle")

"Wall seconds for the upstream binary on one program (best of 2)."
function up_time(path)
    out = tempname()
    best = Inf
    for _ in 1:2
        t0 = time_ns()
        try
            Base.run(pipeline(`$UP run $path --steps $STEPS $out`; stdout = devnull, stderr = devnull))
        catch
            return nothing                      # aborts/panics are not a timing
        end
        best = min(best, (time_ns() - t0) / 1e9)
    end
    isfile(out) && rm(out; force = true)
    best
end

"Wall seconds for OUR engine on one program (best of 2), at the given dispatch setting."
function our_time(path, on::Bool)
    prev = MORK.LEAPFROG_DISPATCH[]
    MORK.LEAPFROG_DISPATCH[] = on
    try
        best = Inf
        for _ in 1:2
            t0 = time_ns()
            try
                s = MORK.new_space()
                MORK.space_add_all_sexpr!(s, read(path, String))
                MORK.space_metta_calculus!(s, STEPS)
            catch
                return nothing
            end
            best = min(best, (time_ns() - t0) / 1e9)
        end
        best
    finally
        MORK.LEAPFROG_DISPATCH[] = prev
    end
end

rows = Tuple{Float64, Float64, Float64, Float64, String}[]   # ratio_off, ratio_on, up, ours_off, name
for d in DIRS, f in sort(readdir(d))
    endswith(f, ".mm2") || continue
    p = joinpath(d, f)
    u = up_time(p);  u === nothing && continue
    o = our_time(p, false); o === nothing && continue
    n = our_time(p, true);  n === nothing && continue
    u < 1e-4 && continue                                     # too fast to compare meaningfully
    push!(rows, (o / u, n / u, u, o, basename(f)))
end

sort!(rows; by = first, rev = true)
med_off = rows[max(1, length(rows) ÷ 2)][1]
med_on  = sort([r[2] for r in rows])[max(1, length(rows) ÷ 2)]

@printf("\nprograms compared : %d\n", length(rows))
@printf("MEDIAN ratio ours/upstream : %.1fx (dispatch off)   %.1fx (leapfrog on)\n", med_off, med_on)
println("  ⇒ the median is the LANGUAGE TAX. The outliers below are where to look for a port defect.\n")
@printf("%-42s %10s %10s %10s %10s\n", "program", "upstream", "ours-off", "ratio", "ratio-on")
for r in rows[1:min(15, length(rows))]
    @printf("%-42s %9.3fs %9.3fs %9.1fx %9.1fx\n", r[5], r[3], r[4], r[1], r[2])
end
@printf("\nWORST ratio is %.0fx the median — %s\n", rows[1][1] / med_off,
        rows[1][1] / med_off > 5 ? "🔴 DISPROPORTIONATE: read that program" :
                                   "in line with the language tax, no single outlier")
