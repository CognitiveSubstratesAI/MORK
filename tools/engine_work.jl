# engine_work.jl — LEAPFROG vs ProductZipper, in DETERMINISTIC units.
#
#   julia --project=. tools/engine_work.jl
#
# ─── WHY THIS EXISTS ALONGSIDE `upstream_speed.jl` ───────────────────────────────────────────────
# That tool ranks programs by WALL CLOCK, and wall clock on this corpus is not quotable: repeated
# n=9 runs of `mm1_forward_full_proof` disagreed on whether the time gap even survives its own
# spread (one run "SPREAD EXCEEDS GAP", the next "gap survives spread"). A ranking built from ONE
# sample per program therefore cannot be trusted to identify which program is the outlier — and
# mm1's position at the head of that tail was exactly such a sample.
#
# 🔑 SO RANK ON SOMETHING DETERMINISTIC. Occurs INVOCATIONS and allocated BYTES are identical on
# every run and every machine — measured here at spread 0.0 across 9 runs for both engines. n=1 is
# sufficient, a later session can compare without owning this laptop, and no "quiet box" caveat
# applies.
#
# ─── THE UPSTREAM COMPARABLE ────────────────────────────────────────────────────────────────────
# Upstream `cfa8abf` reports "the re-solving cost 11.6x the ProductZipper's unification work
# (1,423,278 occurs calls vs 122,933 at 2000 axioms)".
#
# ⚠️ THAT IS A CROSS-ENGINE RATIO — leapfrog:ProductZipper — NOT a before/after-trail figure. It
# will never show up as a trail speedup, and upstream's own before/after was 0.821/0.816, FLAT.
# (Our trail was likewise flat in time at -20% allocation, which AGREES with upstream rather than
# diverging from it. An earlier session read the 11.6x as a speedup, failed to see one, and
# invented a binding-set-size explanation for a discrepancy that did not exist.)
#
# ⚠️ AND THE UNIT IS ONE `occurs` MACRO INVOCATION — a single non-recursive `traverseh!` fold
# upstream-side. Ours recurses, so counting node visits measures a DIFFERENT quantity: on mm1 the
# node-visit ratio is 43.85x and the invocation ratio is 18.19x. Only the latter is comparable.
#
# ─── WHAT IT FOUND, 2026-08-21, mm1_forward_full_proof at 2000 steps ────────────────────────────
#     occurs invocations   leapfrog 61 913 : ProductZipper 3 404  =  18.19x     (upstream: 11.6x)
#     allocated bytes      leapfrog 500.7 MiB : 193.1 MiB         =   2.59x     (spread 0.0)
#     answers              127 886 chars BOTH engines — identical
#
# 🔴 WE DO 18.19x WHERE UPSTREAM DOES 11.6x, on the same unit. Ours is ~1.57x less economical, and
# that gap is the actionable finding — not the wall clock. Two upstream mechanisms we lack, both
# from the `expr-opt` PR merged at 06cdcf3 and both in the occurs path:
#   1. `ExprEnv::ground_skip: u16` — a GROUND STAMP. Upstream skips the occurs walk outright when
#      the subterm holds no variable (`dt2.ground_skip == 0 && step!(occurs vx, dt2)`). Our ExprEnv
#      has no such field, so we walk terms upstream never looks at. Sound for us too: a genuinely
#      ground subterm cannot contain the checked variable under any dereference.
#   2. upstream's `occurs` is an ALLOCATION-FREE `traverseh!` fold; ours builds `ExprEnv[]` per
#      compound node, recursively, per call — which is why `_occurs_check` tops the allocation
#      profile. The cost is the child vector, not the occurs logic.
#
# ⚠️ mm1 IS A >4-SOURCE QUERY and trips `query_multi: 5 sources (>4) may be slow — Rule of 64`.
# That warning fires BEFORE the engine dispatch and its text describes the ProductZipper's N^M path
# iteration, so it is not evidence of a leapfrog slow path. The leapfrog ROUTES all 8 bodies here
# (ROUTED=8, DECLINED=0). Read it the other way: this is the many-factor regime a worst-case-optimal
# join exists to win, and it loses — which makes the 18.19x more interesting, not less.
#
# ─── PROVENANCE ─────────────────────────────────────────────────────────────────────────────────
#   upstream 06cdcf3 · Julia 1.12.7 · steps 2000 · counts are machine-independent by construction
using MORK, Printf

const DIRS = [joinpath(homedir(), "code/CognitiveSubstratesAI/MORK/test/conformance", d)
              for d in ("space", "sinks")]
const STEPS = 2000

"Occurs invocations, allocated MiB and answer size for one program at one dispatch setting."
function work(path, on::Bool)
    prev = MORK.LEAPFROG_DISPATCH[]
    MORK.LEAPFROG_DISPATCH[] = on
    try
        MORK.occurs_calls_reset!()
        local chars = 0
        bytes = @allocated begin
            s = MORK.new_space()
            MORK.space_add_all_sexpr!(s, read(path, String))
            MORK.space_metta_calculus!(s, STEPS)
            chars = length(MORK.space_dump_all_sexpr(s))
        end
        (MORK.OCCURS_CALLS[], bytes / 2^20, chars)
    catch
        nothing
    finally
        MORK.LEAPFROG_DISPATCH[] = prev
    end
end

rows = Tuple{Float64, Int, Int, Float64, Float64, String}[]
disagree = String[]
for d in DIRS, f in sort(readdir(d))
    endswith(f, ".mm2") || continue
    p = joinpath(d, f)
    off = work(p, false); off === nothing && continue
    on  = work(p, true);  on  === nothing && continue
    # 🔴 ANSWERS MUST MATCH. A work ratio between engines that disagree is meaningless, and a
    # cheaper engine that answers differently is a DEFECT reported as an improvement.
    off[3] == on[3] || push!(disagree, basename(f))
    off[1] == 0 && continue                          # no unification work: nothing to compare
    push!(rows, (on[1] / off[1], on[1], off[1], on[2], off[2], basename(f)))
end

# 🔴 ZERO ROWS IS A HARD FAILURE, NOT A QUIET ZERO — the defect class that made `upstream_speed`
# report success having measured nothing. Assert against the program count and name the shortfall.
n_programs = sum(count(f -> endswith(f, ".mm2"), readdir(d)) for d in DIRS)
if isempty(rows)
    error("ZERO programs produced a work ratio out of $n_programs — the comparison measured NOTHING")
elseif length(rows) < n_programs
    @warn "only $(length(rows))/$n_programs programs compared — a missing tail may hide the outlier"
end
isempty(disagree) || error("ENGINES DISAGREE on $(length(disagree)) programs: $(join(disagree, ", "))")

sort!(rows; rev = true)
@printf("%-42s %10s %10s %8s %10s %10s\n", "program", "lf occurs", "pz occurs", "ratio", "lf MiB", "pz MiB")
for r in first(rows, 15)
    @printf("%-42s %10d %10d %7.2fx %10.1f %10.1f\n", r[6], r[2], r[3], r[1], r[4], r[5])
end
@printf("\n%d programs compared, answers identical on all. Ratios are DETERMINISTIC: n=1 suffices.\n",
        length(rows))
