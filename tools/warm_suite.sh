#!/usr/bin/env bash
# warm_suite.sh — run MORK's suite (or ONE file) in a PERSISTENT warm session, with a REAL exit code.
#
#   tools/warm_suite.sh start                         boot the daemon (idempotent)
#   tools/warm_suite.sh file test/integration/x.jl    ONE file, warm — the edit→verify loop
#   tools/warm_suite.sh run                           full suite, real exit code
#   tools/warm_suite.sh run-cold                      the always-fresh path; the ARBITER when a warm
#                                                     failure looks implausible
#   tools/warm_suite.sh restart | status | stop
#
# ─── WHY ─────────────────────────────────────────────────────────────────────────────────────────
# MORK has 8 161 tests in one `runtests.jl`, so the edit→verify cycle was ~6 MINUTES OR NOTHING.
# MEASURED 2026-08-21: that absence drove SEVEN cold starts in one hour, every one a workaround for
# a missing fast path, until the cold-start limiter refused. A slow loop is not a nuisance; it is
# what makes the sanctioned path get bypassed.
#
# ⚠️ PORTED FROM `Core/tools/warm_suite.sh`, WHICH ALREADY SOLVED THIS. Its measured numbers:
# cold 575 s · warm 161 s. Every 🔴 below is one of its hard-won invariants, kept because each was
# learned by losing hours to it. Read them before editing this file.
#
# ⚠️⚠️ WARMTH DEGRADES. Core measured: warm-after-~15-probes went to 26 MINUTES and was still going
# when killed. A long-lived daemon accumulates state and eventually becomes SLOWER than cold. That
# is why `restart` and `run-cold` exist. If a warm run feels wrong, `run-cold` is the arbiter —
# never argue with a warm result you cannot reproduce cold.
#
# ⚠️ NOT the MettaJam server on :7702. That is PROBES ONLY — running a SUITE there executes inside
# the live server and pollutes state every other probe reads. This gets its OWN port.
set -u
MORK="$(cd "$(dirname "$0")/.." && pwd)"
PORT="${MORK_WARM_PORT:-3011}"                        # file lane   (Core uses 3001 — do not collide)
SUITE_PORT="${MORK_WARM_GATE_PORT:-3012}"             # suite lane  (Core uses 3002)
RUNDIR="$HOME/csai-work/mork_warm"
PIDFILE="$RUNDIR/daemon.$PORT.pid"
READYFILE="$RUNDIR/daemon.$PORT.ready"
MEM_MAX="${MORK_TEST_MEM_MAX:-8G}"
mkdir -p "$RUNDIR"

_use_lane() { PORT="$1"; PIDFILE="$RUNDIR/daemon.$PORT.pid"; READYFILE="$RUNDIR/daemon.$PORT.ready"; }

_alive() {
    [ -f "$PIDFILE" ] && kill -0 "$(cat "$PIDFILE")" 2>/dev/null && [ -f "$READYFILE" ] \
        && ss -ltn 2>/dev/null | grep -q ":$PORT "
}

_start() {
    if _alive; then echo "  warm_suite: already up (pid $(cat "$PIDFILE"), port $PORT)"; return 0; fi
    echo "  warm_suite: booting daemon on port $PORT (one-time JIT cost — later runs reuse it)…"
    rm -f "$READYFILE"

    # 🔴 PRECOMPILE FIRST, WITH THE LANE STOPPED. Revise reloads function bodies and struct fields on
    # 1.12, but it cannot re-initialise a const global whose struct changed — so a daemon that
    # outlives a struct edit strands every const container typed on it in the old world age
    # (Revise #1116, OPEN: "revise() runs in a frozen world, and on 1.12 globals are
    # world-partitioned"). Precompiling here leaves Revise no struct diff to apply at load.
    # ⚠️ NEVER precompile while a daemon is live against that image.
    ( cd "$MORK" && julia --project=. -e 'using Pkg; Pkg.precompile()' >/dev/null 2>&1 ) || true

    # 🔴 `setsid`, NOT bare `nohup &`. A backgrounded child stays in the caller's PROCESS GROUP, so a
    # timeout on the wrapping shell takes the daemon with it — and `start` then probes a corpse.
    # 🔴 `using Revise` BEFORE the package. Revise tracks what loads AFTER it; reversing the order
    # SILENTLY DISABLES hot reload, and the symptom is stable-looking measurements of code that never
    # changed. ⚠️ If you touch this order, verify with `isdefined` on a NEW symbol — never a timing.
    # 🔴 `serve(port, true)` — THE `shared` FLAG IS LOAD-BEARING. Without it DaemonMode evaluates
    # each file in a fresh `Main.anonymous` module, where the daemon's own `using` statements are
    # INVISIBLE: the first run died with "UndefVarError: \`PathMap\` not defined in
    # \`Main.anonymous\`" even though PathMap was loaded, because `runtests.jl` and its includes
    # expect the module-level environment they get under a normal `julia test/runtests.jl`.
    # ⚠️ The trade is real and is why Core warns about state pollution: shared Main means one file
    # CAN leak state into the next. `run-cold` is the arbiter, and `restart` clears it.
    # 🔴 PRELOAD WHAT THE SUITE EXPECTS. `runtests.jl` opens with `using Test, MORK, PathMap`; the
    # daemon must hold the same, or a `file` run resolves names the full suite would have had.
    setsid julia --project="$MORK" -e "
        using Revise
        using MORK, PathMap, Test
        using DaemonMode
        write(raw\"$READYFILE\", string(getpid()))
        serve($PORT, true)
    " >"$RUNDIR/daemon.$PORT.log" 2>&1 &
    echo $! > "$PIDFILE"

    for _ in $(seq 1 240); do _alive && break; sleep 1; done
    if _alive; then echo "  warm_suite: UP (pid $(cat "$PIDFILE"), port $PORT)"; return 0; fi
    echo "  warm_suite: FAILED to boot — see $RUNDIR/daemon.$PORT.log"; tail -5 "$RUNDIR/daemon.$PORT.log"; return 1
}

_run_driver() {
    local body="$1" verdict="$RUNDIR/verdict.$PORT"
    rm -f "$verdict"

    # DaemonMode SERIALISES. A second concurrent client queues silently rather than going faster, so
    # say so instead of appearing to hang.
    local busy
    busy=$(pgrep -f "runfile.*port=$PORT" 2>/dev/null | grep -v "^$$\$" | head -3)
    if [ -n "$busy" ]; then
        echo "  warm_suite: ⛔ a client is ALREADY running against port $PORT (pids: $busy)"
        echo "     DaemonMode serialises — wait, or: kill $busy"
        exit 1
    fi

    local drv="$RUNDIR/driver.$$.$RANDOM.jl"
    # 🔴 THE VERDICT FILE IS THE EXIT CODE. `julia -i` with piped stdin ALWAYS exits 0 — that is how
    # MORK's only upstream differential once sat ERRORING on every run unnoticed (commit c543841).
    # The daemon's own exit status tells us nothing about the tests, so the driver writes the verdict
    # and a MISSING verdict is a FAILURE, never a pass.
    cat > "$drv" <<JULIA
# WARNING: Main.Revise, NOT bare Revise. DaemonMode's runfile evaluates in Main.anonymous, so the
# daemon's own 'using Revise' is NOT in scope here — a bare reference dies with
# "UndefVarError: Revise not defined in Main.anonymous" before a single test runs.
# Guarded with isdefined so a daemon booted without Revise degrades to "no hot reload".
#
# NO BACKTICKS ANYWHERE IN THIS HEREDOC. It is deliberately UNQUOTED so \$body/\$MORK/\$verdict
# interpolate — which means bash also runs BACKTICKS AS COMMAND SUBSTITUTION. A comment written with
# backticks around 'using Revise' made bash execute 'using' and print
# "warm_suite.sh: line 105: using: command not found" on every single run.
isdefined(Main, :Revise) && Main.Revise.revise()
cd(raw"$MORK")
let
    ok = try
        $body
        true
    catch e
        showerror(stderr, e); println(stderr)
        false
    end
    write(raw"$verdict", ok ? "0" : "1")
end
JULIA
    stdbuf -oL -eL julia -e "using DaemonMode; runfile(raw\"$drv\"; port=$PORT)" 2>&1 | tee "$RUNDIR/last.$PORT.log"
    rm -f "$drv"
    [ -f "$verdict" ] && exit "$(cat "$verdict")"
    echo "  warm_suite: NO VERDICT WRITTEN — treating as FAILURE (daemon died?)"; exit 1
}

case "${1:-run}" in
  start) _start ;;

  stop)
     # 🔴🔴 KILL BY PORT, NOT ONLY BY PIDFILE. Core measured this invalidating FOUR consecutive
     # experiments: RUNDIR moved, the running daemon kept its OLD pidfile path, `stop` reported "not
     # running", and a 3.3-hour-old process went on serving every result. The PORT is the resource
     # that matters, so free the port.
     # ⚠️ NOT `pkill -f DaemonMode` — that pattern matches the killing command's own cmdline.
     killed=""
     if [ -f "$PIDFILE" ] && kill -0 "$(cat "$PIDFILE")" 2>/dev/null; then
       kill "$(cat "$PIDFILE")" 2>/dev/null && killed="$(cat "$PIDFILE")"
     fi
     for orphan in $(ss -lptnH "sport = :$PORT" 2>/dev/null | grep -oP 'pid=\K[0-9]+' | sort -u); do
       kill "$orphan" 2>/dev/null && killed="$killed $orphan"
     done
     rm -f "$PIDFILE" "$READYFILE"
     for _ in 1 2 3 4 5 6 7 8 9 10; do
       ss -lntH "sport = :$PORT" 2>/dev/null | grep -q . || break
       sleep 0.3
     done
     if ss -lntH "sport = :$PORT" 2>/dev/null | grep -q .; then
       echo "  warm_suite: ⚠️ PORT $PORT STILL HELD after kill — refusing to pretend we restarted"; exit 1
     fi
     [ -n "$killed" ] && echo "  warm_suite: stopped ($killed)" || echo "  warm_suite: not running" ;;

  stop-all) "$0" stop; MORK_WARM_PORT="$SUITE_PORT" "$0" stop ;;

  restart)
     # do NOT swallow stop's exit code — a restart that stopped nothing is the bug above.
     "$0" stop || { echo "  warm_suite: restart ABORTED — the old daemon is still serving"; exit 1; }
     _start ;;

  status)
     if _alive; then
       echo "  warm_suite: UP (pid $(cat "$PIDFILE"), port $PORT)"
       echo "  ℹ️  Revise reloads function bodies AND struct fields on 1.12."
       echo "     BUT a const container typed on a changed struct is stranded (Revise #1116, open)"
       echo "     — restart if you changed a struct something holds."
     else echo "  warm_suite: DOWN"; fi ;;

  file)
     _start || exit 1
     [ -n "${2:-}" ] || { echo "  usage: warm_suite.sh file <path>"; exit 2; }
     # ⚠️ An ABSOLUTE path must not be prefixed with $MORK — that produced "$MORK/home/…" in Core and
     # a SystemError that read like a missing file.
     case "$2" in /*) tgt="$2" ;; *) tgt="$MORK/$2" ;; esac
     [ -f "$tgt" ] || { echo "  warm_suite: no such file: $tgt"; exit 2; }
     # 🔴 THE FILE LANE MUST NOT SHARE A GLOBAL WITH THE SUITE. In Core, a first cut created
     # `SUITE_FAILED` as a plain global here, which then made `runtests.jl`'s `const SUITE_FAILED`
     # fail with "cannot declare constant; it was already declared global" — so ONE `file` run
     # poisoned every later `run` in the same daemon. A failing `@testset` THROWS, so `include`
     # raising IS the failure signal; no shared name is needed.
     _run_driver "include(raw\"$tgt\")" ;;

  run)
     _use_lane "$SUITE_PORT"
     _start || exit 1
     _run_driver "include(raw\"$MORK/test/runtests.jl\")" ;;

  run-cold)
     # The arbiter. Delegates to the cgroup-capped cold runner, which is the only path with a memory
     # ceiling — ⚠️ a runaway test OOM-kills the EDITOR, not itself, so never remove that cap.
     echo "  warm_suite: cold run via tools/run_tests.sh (memory cap ${MEM_MAX})"
     exec "$MORK/tools/run_tests.sh" ${2:+"$2"} ;;

  *) echo "  usage: warm_suite.sh start|stop|stop-all|restart|status|file <path>|run|run-cold"; exit 2 ;;
esac
