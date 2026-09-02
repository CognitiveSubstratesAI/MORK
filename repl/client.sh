#!/bin/bash
# packages/MORK/repl/client.sh
#
# Companion to packages/Core/repl/client.sh — wrapper around the MORK
# persistent HTTP server (packages/MORK/repl/server.jl, port 8080 default).
#
# Boot ONCE per dev session; subsequent test runs are pure HTTP (no JIT).
#
# USAGE:
#   client.sh start                      Boot server in background
#   client.sh stop                       Graceful shutdown via HTTP (fallback: SIGTERM)
#   client.sh status [<path>]            Server health + path status
#   client.sh upload pat tpl < file      POST atoms (stdin)
#   client.sh explore '(node $x)'        BFS exploration
#   client.sh clear '(node $x)'          Clear matching atoms
#   client.sh copy src dst               Copy
#   client.sh count '(...)'              Count atoms matching pattern
#   client.sh transform body             POST transform expression
#   client.sh log [-n N]                 Tail server log
#   client.sh test                       Run all integration tests against this server
#
# Set MORK_SERVER_PORT to override default 8080.

set -euo pipefail

PORT="${MORK_SERVER_PORT:-8080}"
BASE="http://127.0.0.1:$PORT"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MORK_PROJECT="$(cd "$SCRIPT_DIR/.." && pwd)"
SERVER_LOG="${SCRIPT_DIR}/server.log"
PID_FILE="${SCRIPT_DIR}/server.pid"

# URL-encode a string via python3 (already a dep — used in Core's client.sh).
urlenc() {
    python3 -c "import urllib.parse, sys; print(urllib.parse.quote(sys.argv[1], safe=''))" "$1"
}

cmd="${1:-help}"

case "$cmd" in
  start)
    if [ -f "$PID_FILE" ] && kill -0 "$(cat "$PID_FILE")" 2>/dev/null; then
      echo "MORK server already running (PID $(cat "$PID_FILE"))"
      exit 0
    fi
    echo "Starting MORK server on port $PORT..."
    nohup julia --project="$MORK_PROJECT" "$SCRIPT_DIR/server.jl" \
      > "$SERVER_LOG" 2>&1 &
    echo $! > "$PID_FILE"
    echo "  PID $(cat "$PID_FILE"), log $SERVER_LOG"
    echo "Waiting for READY (timeout 300s)..."
    for i in $(seq 1 300); do
      if grep -q "^READY" "$SERVER_LOG" 2>/dev/null; then
        echo "Ready after ${i}s."
        exit 0
      fi
      sleep 1
    done
    echo "Timed out waiting for READY (300s). Last log lines:"
    tail -20 "$SERVER_LOG"
    exit 1
    ;;

  stop)
    if curl -s -m 5 -X POST "$BASE/stop" 2>/dev/null; then
      echo " (graceful shutdown initiated)"
      sleep 1
      rm -f "$PID_FILE"
      exit 0
    fi
    if [ -f "$PID_FILE" ]; then
      pid=$(cat "$PID_FILE")
      kill -0 "$pid" 2>/dev/null && kill "$pid" && echo "Stopped PID $pid (SIGTERM)"
      rm -f "$PID_FILE"
    else
      echo "No PID file and server not responding"
    fi
    ;;

  status)
    path="${2:--}"
    curl -s -m 5 "$BASE/status/$(urlenc "$path")"
    echo
    ;;

  upload)
    shift
    pat="${1:-\$}"
    tpl="${2:-\$}"
    curl -s -X POST "$BASE/upload/$(urlenc "$pat")/$(urlenc "$tpl")" \
      -H 'Content-Type: text/plain' --data-binary @-
    echo
    ;;

  explore)
    shift
    expr="${1:-}"
    [ -z "$expr" ] && { echo "Usage: $0 explore '<expr>'" >&2; exit 1; }
    curl -s -m 10 "$BASE/explore/$(urlenc "$expr")"
    echo
    ;;

  clear)
    shift
    expr="${1:-}"
    [ -z "$expr" ] && { echo "Usage: $0 clear '<expr>'" >&2; exit 1; }
    curl -s "$BASE/clear/$(urlenc "$expr")"
    echo
    ;;

  copy)
    shift
    src="${1:-}"; dst="${2:-}"
    [ -z "$src" ] || [ -z "$dst" ] && { echo "Usage: $0 copy <src_expr> <dst_expr>" >&2; exit 1; }
    curl -s "$BASE/copy/$(urlenc "$src")/$(urlenc "$dst")"
    echo
    ;;

  count)
    shift
    expr="${1:-}"
    [ -z "$expr" ] && { echo "Usage: $0 count '<expr>'" >&2; exit 1; }
    curl -s "$BASE/count/$(urlenc "$expr")"
    echo
    ;;

  transform)
    shift
    body="${1:-}"
    [ -z "$body" ] && { echo "Usage: $0 transform '<transform_expr>'" >&2; exit 1; }
    curl -s -X POST "$BASE/transform" -H 'Content-Type: text/plain' --data-binary "$body"
    echo
    ;;

  log)
    n=50
    if [ "${2:-}" = "-n" ]; then n="${3:-50}"; fi
    tail -n "$n" "$SERVER_LOG"
    ;;

  test)
    # Run tests IN the server's warm Julia process via dev endpoint /include.
    # Zero JIT cost — the server already has MORK, HTTP, JSON3, Test loaded
    # and Revise tracks source edits for hot-reload between runs.
    if ! curl -s -m 3 "$BASE/status/-" >/dev/null 2>&1; then
      echo "MORK server not responding on $BASE — start it first ('$0 start')"
      exit 1
    fi
    DEV_PORT=$((PORT + 1))
    if ! curl -s -m 3 "http://127.0.0.1:$DEV_PORT/health" >/dev/null 2>&1; then
      echo "Dev endpoint not responding on port $DEV_PORT — restart server to pick up dev surface ('$0 stop && $0 start')"
      exit 1
    fi
    test_file="${2:-$MORK_PROJECT/test/integration/run_all.jl}"
    echo "Running tests via warm REPL (port $DEV_PORT): $test_file"
    response=$(curl -s -m 600 -X POST "http://127.0.0.1:$DEV_PORT/include" \
      -H 'Content-Type: text/plain' \
      --data-binary "$test_file")
    # Extract and print captured output, then error if any.
    python3 -c "
import json, sys
try:
    r = json.loads(sys.argv[1])
    print(r.get('output', ''), end='')
    if r.get('error'):
        print('\n--- ERROR ---', file=sys.stderr)
        print(r['error'], file=sys.stderr)
        sys.exit(1)
except Exception as e:
    print('failed to parse server response:', e, file=sys.stderr)
    print('raw:', sys.argv[1][:1000], file=sys.stderr)
    sys.exit(2)
" "$response"
    ;;

  eval-jl)
    # Run arbitrary Julia code in the server's warm process (dev only).
    shift
    code="${1:-}"
    [ -z "$code" ] && { echo "Usage: $0 eval-jl 'julia_code'" >&2; exit 1; }
    DEV_PORT=$((PORT + 1))
    curl -s -X POST "http://127.0.0.1:$DEV_PORT/eval" \
      -H 'Content-Type: text/plain' --data-binary "$code"
    echo
    ;;

  help|--help|-h)
    sed -n '4,32p' "$0" | sed 's/^# \{0,1\}//'
    ;;

  *)
    echo "Unknown command: $cmd" >&2
    echo "Try: $0 help" >&2
    exit 1
    ;;
esac
