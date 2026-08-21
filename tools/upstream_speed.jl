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
# 🔴 DO NOT QUOTE A TIME RATIO FROM THIS TOOL — USE `tools/engine_work.jl` INSTEAD.
# Two repeated n=9 runs of mm1 disagreed on whether the leapfrog:ProductZipper TIME gap survives its
# own spread (one "SPREAD EXCEEDS GAP", the next "gap survives spread"). Every leapfrog time ratio
# ever quoted here — 1.83x, 2.37x, 1.99x, 2.26x — is inside that noise. What IS deterministic, at
# spread 0.0 over 9 runs and machine-independent by construction, is occurs INVOCATIONS and
# allocated BYTES; `engine_work.jl` ranks the whole corpus on those and needs only n=1.
#
# ⇒ THE DETERMINISTIC RESULT: mm1 is leapfrog:ProductZipper 18.19x occurs invocations and 2.59x
# allocation, answers identical. It is a TRUE ISOLATED OUTLIER — the next program in 267 is 2.00x —
# so its position at the head of this tail is real and not an artifact of one sample.
# ⚠️ Upstream's 11.6x is over a DIFFERENT WORKLOAD (big.metta self-join at 2000 axioms, vs our mm1
# at 2000 steps) and the ratio is workload-dependent — 18.19x to 1.00x across our own 267. No
# "less economical than upstream" conclusion follows; see `engine_work.jl`. COMPARISON OPEN.
#
# ⚠️ TWO PREDICTIONS THAT STOOD HERE WERE WRONG, AND BOTH WERE WRITTEN AS FACT:
#   1. "the undo trail is the next real lever" — the trail landed (cfa8abf ported). Result: -20%
#      allocation, time FLAT. That AGREES with upstream, whose own before/after was 0.821/0.816.
#      The 11.6x was never a trail speedup: it is a CROSS-ENGINE ratio. Misreading it as before/after
#      produced a hunt for a missing win that was never promised.
#   2. "a trail loses [chain-visible occurs] and needs upstream's explicit `cycled` check" — the
#      cyclic-capture tests ALL PASS with the trail live. The stub that predicted otherwise removed
#      prior bindings entirely; the trail keeps the map LIVE, so derefs still see the chain. The
#      stub modelled something strictly weaker than the thing it was predicting about.
#
# ⚠️ WHY PER-PROGRAM AND NOT AN AGGREGATE. Julia loses to Rust on constant factors, and averaging
# that over 285 programs is unactionable. A DISPROPORTIONATE gap on ONE program is the signature of
# an ALGORITHMIC divergence — which is how the 1182x intermediate blowup was found. The median is
# the language tax; the outliers are the bugs.
#
# ─── PROVENANCE — WITHOUT THIS, 0.057s IS NOT COMPARABLE TO ANYTHING MEASURED LATER ─────────────
#   upstream   06cdcf3  (2026-08-17, "Merge pull request #146 from trueagi-io/expr-opt")
#   binary     target/release/mork built 2026-08-20 11:28
#   machine    Intel i7-3630QM @ 2.40GHz, 4 cores, 23 GiB, Julia 1.12.7
#   steps      2000
# Re-state these whenever the numbers above are refreshed; a ratio to an unnamed baseline is a
# number, not a measurement.
#
# ⚠️ NEEDS THE BOX QUIET, and compares RATIOS so moderate contention affects both sides alike.
# A 45%-off figure was once reported here from hand-rolled timing under load.
#
# ⚠️ AND REPEAT BEFORE QUOTING A MAGNITUDE. mm1's ratio was quoted as 1.83x from one run and 2.37x
# from another — the same workload measured 0.572s and 0.748s ~30% apart. Over n=9: median 1.81x,
# min/min 2.21x, max/max 2.55x, and the SPREAD EXCEEDS THE GAP, so no single figure is quotable.
# What IS robust is that the distributions do not OVERLAP (min-on 1.226s > max-off 0.793s): the
# DIRECTION is certain, the magnitude is a range (~1.55x-3.6x). Report direction, bound magnitude.
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
#
# ✅ THE RUNS ARE STEP-ALIGNED WITH UPSTREAM. Upstream's `metta_calculus` is a DO-WHILE —
# `while { BODY; done < steps } { done += 1 }` (`space.rs:1945`) evaluates the body INSIDE the
# condition, so it performs steps+1 interprets while REPORTING steps. Ours matched it on 2026-08-19:
# `Space.jl` is now `while true` with the TEST BEFORE THE INCREMENT, which is where the ordering
# lives. Reporting is unchanged (`metta_calculus(N)` still returns N); one more exec is interpreted.
# ⚠️ RECORDED BECAUSE A STALE INDEX SAYS OTHERWISE. `workflows/CODEMAP.md` still carried this as
# "NOT FIXED ... surfaced for a decision", written the SAME DAY the fix landed, and it was reported
# as an open decision on 2026-08-21 before the code was read. CODEMAP's own row warns that a row is
# a MEASUREMENT AT A TIME; this is that failure. Read `Space.jl` before re-opening this.
# 🔑 It was invisible on any program reaching fixpoint below the cap — both engines leave through the
# same arm — which is why 96 of 104 passed with it live. MEASURED 2026-08-21 across all 285 corpus
# programs: EVERY ONE converges by 50 steps (0 programs step-sensitive at caps 50/60/100/200), so
# STEPS=2000 was never near the boundary.

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

# 🔴 AN EMPTY RESULT SET IS A HARD FAILURE, NOT A QUIET ZERO. The first run of this tool produced
# ZERO rows and exited 0 — every program had been silently skipped because `run` is shadowed by the
# MORK test REPL's `run(src)` helper, so `run(pipeline(...))` threw MethodError into a bare `catch`.
# Fixing the shadowing was NOT the fix: the DEFECT was that nothing-measured reported as success.
# The next cause will be different — a moved binary, a renamed corpus, a permissions change — and it
# must announce itself the same way. So: assert the row count against the PROGRAM count, and name
# what was dropped rather than averaging over what survived. [[feedback_verify_the_oracle_runs]]
n_programs = sum(count(f -> endswith(f, ".mm2"), readdir(d)) for d in DIRS)
if isempty(rows)
    error("upstream_speed: ZERO programs timed out of $n_programs — the comparison measured " *
          "NOTHING. Check the binary at $UP, and remember `run` is shadowed: use `Base.run`.")
end
if length(rows) < n_programs
    @warn "upstream_speed: not every program produced a timing — the tail may be missing the " *
          "very outlier this tool exists to find" timed = length(rows) programs = n_programs \
          dropped = n_programs - length(rows)
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
