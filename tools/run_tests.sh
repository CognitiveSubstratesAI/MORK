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
cd "$(dirname "$0")/.."
TARGET="${1:-test/runtests.jl}"

ROOT="$PWD"
case "$TARGET" in /*) ABS_TARGET="$TARGET" ;; *) ABS_TARGET="$ROOT/$TARGET" ;; esac

# ABSOLUTE paths inside the driver, and the repl load INSIDE the guard. Both are scar tissue: the
# first cut used `include("tools/repl.jl")` from a driver in /tmp, and `include` in a script resolves
# relative to the SCRIPT'S directory — so it looked for /tmp/tools/repl.jl, threw at top level, got
# swallowed by `-i` (the very bug this file exists to close), and BOTH a passing and a failing target
# exited 0. Under `-i` nothing outside an explicit try/exit can be trusted to fail the build.
DRIVER="$(mktemp "${TMPDIR:-/tmp}/mork_run_tests_XXXXXX.jl")"
trap 'rm -f "$DRIVER"' EXIT
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
julia --project=. --threads="${JULIA_TEST_THREADS:-4}" -i "$DRIVER" < /dev/null
# allow-cold-start: full-suite runner; a suite run is a cold run by nature
