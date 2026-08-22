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
# 🔴🔴 THE 18.19x AND UPSTREAM'S 11.6x ARE OVER DIFFERENT WORKLOADS — THE COMPARISON IS OPEN.
# Ours is `mm1_forward_full_proof` at 2000 STEPS; upstream's is a big.metta self-join at 2000
# AXIOMS. A first version of this header concluded "~1.57x less economical", which does not follow:
# THE RATIO IS A PROPERTY OF THE WORKLOAD, and this tool's own sweep shows it spanning 18.19x down
# to 1.00x across 267 programs. Resolving the pair and the unit is not enough while the PROGRAM is
# still unresolved — that is the same error one level up.
# ⚠️ AND IT IS NOT CHEAPLY CLOSED: upstream's tree has NO harness for that measurement. The only
# trace of it is the prose at `kernel/src/leapfrog.rs:2294`; `kernel/resources/big.metta` is 100 001
# `(axiom (= ...))` lines with no accompanying self-join query, so the figure came from an ad-hoc
# instrumented run that cannot be replayed. To close it, replicate the query — do not compare across.
#
# What DOES stand without the cross-workload step: on mm1 the leapfrog does 18.19x the
# ProductZipper's occurs invocations for identical answers, and that is the actionable finding —
# not the wall clock. Two upstream mechanisms we lack, both
# from the `expr-opt` PR merged at 06cdcf3 and both in the occurs path:
#   1. `ExprEnv::ground_skip: u16` — a GROUND STAMP. Upstream skips the occurs walk outright when
#      the subterm holds no variable (`dt2.ground_skip == 0 && step!(occurs vx, dt2)`). Our ExprEnv
#      has no such field, so we walk terms upstream never looks at.
#      🔴 DO NOT PORT THE SKIP BEFORE READING WHAT *SETS* THE STAMP. The soundness argument — "a
#      genuinely ground subterm cannot contain the checked variable under any dereference" — is a
#      claim about what `ground_skip` MEANS, and it holds only if the stamp means "contains no
#      variable" rather than "ground as far as this traversal needed to look".
#      ⚠️ OUR OCCURS CHECK IS DEREF-AWARE AND UPSTREAM'S IS NOT, and that difference is LOAD-BEARING:
#      it was a soundness fix (ADR-057, the BFC `exec(3 3)` over-generation) forced by our pair
#      generation being recursive `ee_args!` child-pairing where upstream's is `match2`-based, so
#      upstream catches cross-namespace cycles by BINDING ORDER that we cannot rely on. A stamp
#      written under upstream's assumptions and consumed under our different order could discard
#      exactly the check ADR-057 added — and the failure would present as a malformed proof
#      ACCEPTED, with no error, which is how that defect presented the first time.
#      ⇒ Establish the stamp's invariant from `expr/src/lib.rs` (it is written around :2066/:2086
#        and read at :2441/:2447) BEFORE porting the skip, not after.
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

const DIRS = [
    joinpath(homedir(), "code/CognitiveSubstratesAI/MORK/test/conformance", d)
    for d in ("space", "sinks")
]
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

"Occurs invocations, allocated MiB and answer size for one program at one dispatch setting."
function work(path, on::Bool)
    prev = MORK.LEAPFROG_DISPATCH[]
    MORK.LEAPFROG_DISPATCH[] = on
    try
        # ⚠️ WARM FIRST, UNTIMED. Allocation is deterministic WITHIN a harness, not across them: an
        # unwarmed first touch absorbs JIT allocation. This tool printed 522.9 MiB for mm1 where a
        # warmed probe printed 500.7 MiB — a 4% gap that is pure harness, and it was quoted as a
        # machine-independent result. Counts are immune (identical either way); bytes are not.
        _wf, _wd = MORK.Leapfrog.UNIFY_FAILURES[], MORK.Leapfrog.UNIFY_FAILURES_DIRTY[]
        let s = MORK.new_space()
            MORK.space_add_all_sexpr!(s, read(path, String))
            MORK.space_metta_calculus!(s, STEPS)
            MORK.space_dump_all_sexpr(s)
        end
        # ⚠️ THE WARM-UP MUST NOT COUNT. These accumulate across the whole sweep, so a warmed
        # program contributed its failures TWICE — which is exactly how "4 failures" was really
        # 2 events double-counted. Snapshot across the warm pass.
        MORK.Leapfrog.UNIFY_FAILURES[] = _wf
        MORK.Leapfrog.UNIFY_FAILURES_DIRTY[] = _wd
        MORK.occurs_calls_reset!()
        on && (MORK.LEAPFROG_ROUTED[] = 0)
        local chars = 0
        bytes = @allocated begin
            s = MORK.new_space()
            MORK.space_add_all_sexpr!(s, read(path, String))
            MORK.space_metta_calculus!(s, STEPS)
            chars = length(MORK.space_dump_all_sexpr(s))
        end
        (MORK.OCCURS_CALLS[], bytes / 2^20, chars, on ? MORK.LEAPFROG_ROUTED[] : 0)
    catch
        nothing
    finally
        MORK.LEAPFROG_DISPATCH[] = prev
    end
end

rows = Tuple{Float64, Int, Int, Float64, Float64, String}[]
disagree = String[]
# 🔴 IS `match_candidate!`'s FAILURE BRANCH EVER TAKEN? A mutant deleting its unwind survived all
# four trail suites and the full 8153 — because on mm1 the branch is never reached. Accumulate
# across the WHOLE corpus so the answer is a measurement rather than a mechanism story.
# ⚠️ Ref, NOT a bare global. `x += 1` inside a TOP-LEVEL `for` rebinds a global from soft scope and
# throws UndefVarError — which is precisely how the corpus reachability probe earlier today ran every
# program, threw at the counter, and reported 0 through a bare `catch`. Hit again writing this line.
const routed_programs = Ref(0)
const routed_bodies = Ref(0)
MORK.Leapfrog.UNIFY_FAILURES[] = 0
MORK.Leapfrog.UNIFY_FAILURES_DIRTY[] = 0
errored = String[]
for d in DIRS, f in sort(readdir(d))
    endswith(f, ".mm2") || continue
    p = joinpath(d, f)
    # ⚠️ NO BARE `catch`. A reachability probe run earlier today swallowed every program's error and
    # printed a count as though it had measured them — the third swallowed-error incident in one
    # session. `work` returns nothing on failure and the name is RECORDED, never silently dropped.
    off = work(p, false)
    off === nothing && (push!(errored, basename(f)); continue)
    on = work(p, true)
    on === nothing && (push!(errored, basename(f)); continue)
    # 🔴 ANSWERS MUST MATCH. A work ratio between engines that disagree is meaningless, and a
    # cheaper engine that answers differently is a DEFECT reported as an improvement.
    off[3] == on[3] || push!(disagree, basename(f))
    # 🔑 THE DENOMINATOR FOR THE FAILURE-BRANCH COUNT BELOW. `UNIFY_FAILURES` only increments inside
    # `match_candidate!`, which only runs when the leapfrog is DISPATCHED — so "4 failures across 267
    # programs" would be a much weaker statement than it sounds if most programs never route. Most of
    # this corpus does single-digit occurs invocations, i.e. barely touches the join at all.
    on[4] > 0 && (routed_programs[] += 1; routed_bodies[] += on[4])
    off[1] == 0 && continue                          # no unification work: nothing to compare
    push!(rows, (on[1] / off[1], on[1], off[1], on[2], off[2], basename(f)))
end

# 🔴 ZERO ROWS IS A HARD FAILURE, NOT A QUIET ZERO — the defect class that made `upstream_speed`
# report success having measured nothing. Assert against the program count and name the shortfall.
n_programs = sum(count(f -> endswith(f, ".mm2"), readdir(d)) for d in DIRS)
if isempty(rows)
    error(
        "ZERO programs produced a work ratio out of $n_programs — the comparison measured NOTHING"
    )
elseif length(rows) < n_programs
    @warn "only $(length(rows))/$n_programs programs compared — a missing tail may hide the outlier"
end
isempty(disagree) ||
    error("ENGINES DISAGREE on $(length(disagree)) programs: $(join(disagree, ", "))")

sort!(rows; rev=true)
@printf(
    "%-42s %10s %10s %8s %10s %10s\n",
    "program",
    "lf occurs",
    "pz occurs",
    "ratio",
    "lf MiB",
    "pz MiB"
)
for r in first(rows, 15)
    @printf("%-42s %10d %10d %7.2fx %10.1f %10.1f\n", r[6], r[2], r[3], r[1], r[4], r[5])
end
@printf(
    "\n%d programs compared, answers identical on all. Ratios are DETERMINISTIC: n=1 suffices.\n",
    length(rows))
isempty(errored) || @printf("⚠️ %d programs ERRORED and were excluded: %s\n",
    length(errored), join(first(errored, 8), ", "))
# 🔑 THREE DENOMINATORS, BECAUSE ONLY THE THIRD IS THE REAL ONE. Programs that route says how BROAD
# the exercise is; bodies says how many joins ran; CANDIDATES REACHING THE BINDER says how many
# chances the failure branch actually had. One occurs invocation == one candidate through
# `match_candidate!`, so the leapfrog column sums to exactly that.
# ⚠️ AND IT IS CONCENTRATED: mm1 alone is 61 913 of them. A broad routing count can still describe a
# corpus whose unification volume lives in one program.
total_cands = sum(r[2] for r in rows)
@printf(
    "🔑 match_candidate! FAILURE BRANCH: %d failures, %d dirty — over %d/%d programs routing \
(%d bodies, %d candidates through the binder; mm1 alone is %d of them).\n",
    MORK.Leapfrog.UNIFY_FAILURES[], MORK.Leapfrog.UNIFY_FAILURES_DIRTY[],
    routed_programs[], length(rows), routed_bodies[], total_cands, rows[1][2])
MORK.Leapfrog.UNIFY_FAILURES[] == 0 &&
    println(
        "   ⇒ NEVER TAKEN on this corpus. The unwind there is exercised ONLY by the " *
        "hand-written case in leapfrog_layer3d.jl. Dead-but-correct, and now labelled."
    )
