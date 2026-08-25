#!/bin/bash
# run_tests.sh — run MORK's suite in the MANDATED warm REPL and EXIT WITH THE RESULT.
#
# WHY THIS EXISTS (2026-07-23). The documented invocation
#     printf 'include("test/runtests.jl");exit()\n' | julia --project=. -i tools/repl.jl
# ALWAYS EXITS 0 — regardless of failures OR errors. `julia -i` with piped stdin is interactive, and
# interactive mode SWALLOWS exceptions: the throw is printed, the REPL continues, and the trailing
# `exit()` returns 0. Measured:
#     piped -i, error then exit()      -> 0
#     piped -i, error, no exit()       -> 0
#     piped -i, FAILING @testset       -> 0        <-- a red suite reporting success
#     non-interactive `julia file.jl`  -> 1        <-- correct
# So the warm-REPL workflow this repo MANDATES (hook-enforced, to avoid cold-start cost) could not
# fail a build. That is how MORK's ONLY upstream differential check (`upstream_conformance.jl`) sat
# ERRORING on every run without anyone noticing — see commit c543841. An `errored` line among 1848
# passes reads as noise; an exit code does not.
#
# The fix keeps the warm REPL and makes the status real: guard the include, and exit with a code
# computed from whether it threw. A Julia testset throws `Some tests did not pass: …` when anything
# failed OR errored, so this catches both.
#
# AND `< /dev/null`, WHICH IS LOAD-BEARING — not tidiness. Aqua's `test_persistent_tasks` spawns
# via `run(cmd, stdin, stdout, stderr; wait=false)` (Aqua persistent_tasks.jl:114), handing it the
# CURRENT stdin as an explicit stdio handle. Piping the driver in (`printf '…' | julia -i`) leaves
# stdin a PipeEndpoint that printf has ALREADY CLOSED — `isopen(stdin) == false` — and libuv rejects
# a closed handle with EINVAL. That is why both MORK and PathMap showed a permanent `1 errored` under
# the piped form. Isolated to the stdio argument, not the environment: default-stdio spawn OK,
# explicit-stdio spawn EINVAL, explicit-stdio spawn under `< /dev/null` OK (stdin is then an open
# IOStream). So the driver goes in a FILE and stdin stays open. `-i` is kept so `isinteractive()` is
# true and tools/repl.jl loads exactly as it does in the mandated warm workflow — including its
# `run(::AbstractString, ::Int)` definition, which SHADOWS `Base.run`. Keeping that shadow present is
# the point: it is what silently killed upstream_conformance (c543841), and this runner must be able
# to catch its like again.
#
# Usage:  tools/run_tests.sh            # whole suite
#         tools/run_tests.sh path.jl    # one file
# Exit:   0 = all green · 1 = failure/error
set -uo pipefail
# 🔴 RESOLVE THE SCRIPT DIR *BEFORE* THE cd, AND ABSOLUTELY. `$0` is relative to the caller's
# cwd, so after this `cd` every later `$(dirname "$0")` points somewhere that no longer exists when
# the script is invoked as `MORK/tools/run_tests.sh` from the repo root — the form CLAUDE.md RULE 0
# documents. MEASURED 2026-08-23: the docstring lint on line ~90 then failed to OPEN its own script
# and the runner printed "docstring interpolation lint FAILED — fix before running the suite", so a
# WRONG-DIRECTORY INVOCATION reported itself as a SOURCE DEFECT and the suite never ran at all.
# The lint passed standalone the whole time. A guard that reports someone else's failure as yours is
# worse than no guard, so the path is now pinned once, absolute, before anything moves.
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR/.."
TARGET="${1:-test/runtests.jl}"

ROOT="$PWD"
case "$TARGET" in /*) ABS_TARGET="$TARGET" ;; *) ABS_TARGET="$ROOT/$TARGET" ;; esac

# ABSOLUTE paths inside the driver, and the repl load INSIDE the guard. Both are scar tissue: the
# first cut used `include("tools/repl.jl")` from a driver in /tmp, and `include` in a script resolves
# relative to the SCRIPT'S directory — so it looked for /tmp/tools/repl.jl, threw at top level, got
# swallowed by `-i` (the very bug this file exists to close), and BOTH a passing and a failing target
# exited 0. Under `-i` nothing outside an explicit try/exit can be trusted to fail the build.
DRIVER="$(mktemp "${TMPDIR:-/tmp}/mork_run_tests_XXXXXX.jl")"

# ─── MACHINE-READABLE VERDICT — because a WRAPPER'S EXIT CODE IS NOT AN OBSERVATION ────────────
#
# 🔴 MEASURED 2026-08-25: a suite killed by SIGTERM mid-run was reported by its harness wrapper as
# "completed (exit code 0)" while the log's own last line read `EXIT=143`. Trusting the wrapper
# would have landed a commit on a run that never finished. This is the same class as a green suite
# that ran against a stale tree, or a grep over a still-buffered log finding no failures: AN
# INSTRUMENT REPORTING SUCCESS IT DID NOT OBSERVE.
#
# So the suite now records its OWN verdict, and `tools/suite_result.sh` is the only thing that
# answers "did it pass?". A run that dies on a signal writes KILLED rather than leaving the last
# PASS standing, and the checker independently reports STALE when any source file is newer than
# the verdict — the exact error that nearly shipped today, a suite run against the pre-edit file.
RESULT_FILE="$SCRIPT_DIR/.last_suite_result"
# 🔴 THE VERDICT RECORDS **WHAT WAS RUN**, NOT JUST THE OUTCOME.
# MEASURED 2026-08-25 in the MorkSupercompiler copy of this runner: two single-file PROBE runs
# (`run_tests.sh /tmp/probe.jl`) overwrote the full suite's verdict with their own PASS, and the
# checker then reported "PASS, tree unchanged" while the suite's log was 0 BYTES. A commit was one
# step from landing on a green that described two lines of scratch code — the exact wrapper-exit-0
# failure this file exists to prevent, inside the instrument built to prevent it.
_write_result() {
  { echo "VERDICT=$2"
    echo "RC=$1"
    echo "TARGET=$TARGET"
    echo "LANE=${MORK_LEAPFROG_DISPATCH:-0}"
    echo "WHEN=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  } > "$RESULT_FILE" 2>/dev/null || true
}
_write_result - RUNNING
_on_exit() {
  rc=$?
  rm -f "$DRIVER" "$DRIVER.smoke"
  if [ "${_SUITE_SIGNALLED:-0}" = "1" ]; then _write_result "$rc" KILLED
  elif [ "$rc" -eq 0 ]; then                  _write_result 0 PASS
  else                                        _write_result "$rc" FAIL
  fi
}
# Trap the signals explicitly: the shell would otherwise die WITHOUT running the EXIT trap, leaving
# the previous run's PASS in place — a stale green, which is worse than no verdict at all.
trap '_SUITE_SIGNALLED=1; exit 143' TERM
trap '_SUITE_SIGNALLED=1; exit 130' INT
trap _on_exit EXIT
cat > "$DRIVER" <<EOF
ok = try
    include(raw"$ROOT/tools/repl.jl")
    include(raw"$ABS_TARGET")
    true
catch e
    showerror(stderr, e); println(stderr)
    false
end
exit(ok ? 0 : 1)
EOF

# --threads: ALSO load-bearing. The suite's concurrency tests guard REAL fixes — the intern
# write-path race (audit I-2) leaked 192 orphan `to_bytes` entries in a 4-thread/8-task/300-word
# stress before it was fixed — and they degrade to `@test_skip` below 2 threads because
# single-threaded they would pass VACUOUSLY. Julia defaults to 1 thread, so under every invocation
# this repo documented, that guard asserted NOTHING while the suite read green. The inert-testset
# check in test/runtests.jl is what surfaced it. Override with JULIA_TEST_THREADS.
# ── MEMORY CEILING — the test process must die BEFORE the machine does ──────────────────────────
#
# THE SAME GUARD AS `Core/tools/run_tests.sh`, added the same day and for the same measured reason
# (these three runners are one lineage; this one is a separate repo, so it is a copy and not an
# include). MEASURED 2026-08-10 in Core: a test evaluated a space-wide `match` with a variable
# pattern, the process grew past the box's 17 GB, and the kernel OOM-killer chose its victim by score
# — it killed the VS Code SERVER, not the runaway. A bad test in one process cost the developer their
# editor session.
#
# A cgroup scope fixes the blast radius: the runaway hits ITS OWN ceiling, dies with 137, and nothing
# outside the scope is a candidate. `MemorySwapMax=0` matters as much as `MemoryMax` — without it the
# process thrashes swap for minutes first. `--heap-size-hint` is the cooperative half, set BELOW the
# hard cap so Julia's GC gets its chance before the kernel does.
#
# Override:       MORK_TEST_MEM_MAX=12G tools/run_tests.sh
# Escape hatch:   MORK_TEST_MEM_MAX=none tools/run_tests.sh
# 🔴 DOCSTRING `$` LINT — BEFORE the suite, because this defect breaks PRECOMPILE: the module never
# loads, so the suite cannot report it and you get a stacktrace instead of a test failure. FOURTH
# occurrence on 2026-08-21. Local grep by choice — `Core/bin/health` has the correct shared lint, but
# coupling two repos for a thirty-line check is the wrong trade at this count.
if ! python3 "$SCRIPT_DIR/lint_docstring_interp.py" "$SCRIPT_DIR/../src"; then
  echo "run_tests.sh: docstring interpolation lint FAILED — fix before running the suite." >&2
  exit 1
fi
# ─── COLD-LOAD SMOKE CHECK — fails in ~seconds on a DEFINITION error, before the suite ─────────
#
# 🔴 MEASURED 2026-08-25: SIX definition-level errors in one session, every one invisible to the
# warm :7702 server and every one found only by a cold load — docstring interpolation (x2, one
# caught by the lint above), a function defined ABOVE the struct its signature names, an unqualified
# cross-module call, two adjacent docstrings (the first documents the second and Julia refuses), and
# a predicate bug. `isdefined(...)` returned TRUE for the first of those while a fresh process could
# not compile the file AT ALL: Revise had evaluated the function into a module where the type
# already existed. A warm module can only tell you about FUNCTION BODIES — ordering, docstring
# parsing and cross-module resolution are all settled during `include`, which never re-runs.
#
# The rule "cold-load before the full suite" was stated and then not followed at hour fourteen, so
# it lives here instead of in someone's memory. Costs one short process; saves a 7-minute round trip
# per definition error. Skip with MORK_SKIP_SMOKE=1 when iterating on test files only.
if [ "${MORK_SKIP_SMOKE:-0}" != "1" ]; then
  if ! julia --project=. -e 'using MORK' >/dev/null 2>"$DRIVER.smoke"; then
    echo "run_tests.sh: COLD LOAD FAILED — a definition error, not a test failure." >&2
    echo "  (the warm server cannot see this class: ordering, docstrings, cross-module names)" >&2
    # 🔴 SURFACE THE ROOT CAUSE FIRST. The unify path runs inside SPAWNED QUERY TASKS, including in
    # the PrecompileTools workload, so a definition error there arrives as a bare
    # `TaskFailedException` whose actual cause sits below a long stacktrace — off the end of any
    # fixed head/tail window. MEASURED 2026-08-25: `length(encountered)` referenced in a `finally`
    # (a `try` introduces a scope in Julia, so it was not visible) produced 27 lines of frames and
    # no cause. Grep for the cause lines before printing the head.
    if grep -qE "UndefVarError|MethodError|BoundsError|TypeError|syntax:|cannot document" "$DRIVER.smoke"; then
        echo "  ── root cause ──" >&2
        grep -nE "UndefVarError|MethodError|BoundsError|TypeError|syntax:|cannot document" "$DRIVER.smoke" | head -5 >&2
    elif grep -q "TaskFailedException" "$DRIVER.smoke"; then
        echo "  ── TaskFailedException: the cause was swallowed by a spawned task ──" >&2
        echo "  Julia did not print the nested exception. Re-run the failing code OUTSIDE a task," >&2
        echo "  or set JULIA_NUM_THREADS=1 so the query path runs inline and the error surfaces." >&2
    fi
    sed -n '1,25p' "$DRIVER.smoke" >&2
    rm -f "$DRIVER.smoke"
    exit 1
  fi
  rm -f "$DRIVER.smoke"
fi

MEM_MAX="${MORK_TEST_MEM_MAX:-8G}"
HEAP_HINT="${MORK_TEST_HEAP_HINT:-6G}"
JL=(julia --project=. --threads="${JULIA_TEST_THREADS:-4}" --heap-size-hint="$HEAP_HINT"
    -i "$DRIVER")

if [ "$MEM_MAX" = "none" ]; then
  echo "run_tests.sh: memory ceiling DISABLED (MORK_TEST_MEM_MAX=none)" >&2
  "${JL[@]}" < /dev/null
elif command -v systemd-run >/dev/null 2>&1 &&
     systemd-run --user --scope -p MemoryMax=256M --quiet true >/dev/null 2>&1; then
  # `--scope` runs it as a child of THIS shell, so stdin/stdout and the exit code pass through
  # unchanged — which the `< /dev/null` discipline above depends on.
  systemd-run --user --scope -p MemoryMax="$MEM_MAX" -p MemorySwapMax=0 --quiet \
      "${JL[@]}" < /dev/null
  rc=$?
  [ $rc -eq 137 ] && echo "run_tests.sh: KILLED at the ${MEM_MAX} ceiling — a test allocated without
  bound. Find it before raising MORK_TEST_MEM_MAX." >&2
  exit $rc
else
  echo "run_tests.sh: WARNING — systemd-run --user --scope unavailable; running WITHOUT a memory
  ceiling. A runaway test can OOM-kill unrelated processes on this machine." >&2
  "${JL[@]}" < /dev/null
fi
# allow-cold-start: full-suite runner; a suite run is a cold run by nature
