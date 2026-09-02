#!/usr/bin/env julia
# packages/MORK/repl/server.jl — MORK persistent HTTP server with Revise hot-reload.
#
# Companion to packages/Core/repl/server.jl.  Same pattern, same justification:
# boot the runtime ONCE so iterative testing doesn't pay 30-90s JIT per cycle.
#
# Differs from packages/MORK/tools/mork_server.jl (the production entrypoint):
#   - Revise tracks MeTTaCore... no wait, MORK source.  Edits to packages/MORK/src/
#     hot-reload via Revise.revise() called at each request boundary.
#   - Logging via stderr (line-buffered) + READY sentinel on stdout (for client.sh).
#
# Endpoints (these are MORK's native HTTP surface — see Commands.jl):
#   GET  /status/<expr>              path status
#   POST /upload/<pat>/<tpl>         upload MeTTa source as atoms
#   GET  /explore/<expr>             BFS token exploration (returns cnt + expr)
#   GET  /clear/<expr>               clear atoms under path
#   GET  /copy/<src>/<dst>           graft src subtrie into dst
#   GET  /count/<expr>               count atoms matching pattern
#   GET  /export/<pat>/<tpl>         export atoms in chosen format
#   GET  /import/<file>/<pat>/<tpl>  import from file
#   POST /transform                  transform atoms (body = transform expr)
#   POST /metta_thread/<loc>/<id>    spawn MeTTa exec thread
#   POST /metta_thread_suspend/<exec>/<suspend>  suspend running thread
#   GET  /status_stream/<expr>       SSE stream of status changes
#   POST /stop                       graceful shutdown
#
# Boot:
#   julia --project=packages/MORK packages/MORK/repl/server.jl
#     (prints "READY" on stdout when accepting requests)

using Revise          # MUST be before `using MORK` for source tracking
using MORK
using HTTP
using JSON3
using Test            # needed for /include endpoint to host test files

# Explicit track for cases where MORK was loaded from precompile cache.
try
    Revise.track(MORK)
catch e
    @warn "Revise.track(MORK) failed — Julia edits will require restart" exception=e
end

const PORT = parse(Int, get(ENV, "MORK_SERVER_PORT", "8080"))
const ADDR = get(ENV, "MORK_SERVER_ADDR", "127.0.0.1")
const RESOURCE_DIR = get(ENV, "MORK_RESOURCE_DIR", "/tmp/mork-resources-dev")

mkpath(RESOURCE_DIR)

function logln(msg)
    println(stderr, msg)
    flush(stderr)
end

logln("[mork-server] phase=startup begin")
logln("[mork-server] phase=using-mork done")
logln("[mork-server] phase=revise-track done")
logln("[mork-server] phase=make-serverspace begin resource_dir=$RESOURCE_DIR")

ss = ServerSpace(RESOURCE_DIR)
server = MorkServer(ss, ADDR, PORT, Ref(false), Ref(0))

logln("[mork-server] phase=make-serverspace done")
logln("[mork-server] phase=http-bind begin addr=$ADDR port=$PORT")
println(stdout, "READY")   # client.sh watches for this
flush(stdout)

# ─────────────────────────────────────────────────────────────────────────────
# Dev-only auxiliary HTTP service on the same port — handles /include and
# /eval requests so test files can be `include()`d in THIS warm process
# (zero cold-start cost, Revise picks up MORK source edits live).
#
# Important: this is a DEV-ONLY surface.  tools/mork_server.jl (production
# entrypoint) does NOT expose this.  repl/server.jl does, because the entire
# point of repl/ is dev iteration.
# ─────────────────────────────────────────────────────────────────────────────

# Run `body()` and return (result, error_str_or_nothing).
# We DON'T capture stdout/stderr — they go to the server's stdout (= server.log).
# Trying to capture via redirect_stdio + Pipe kept breaking in Julia 1.12
# (IOBuffer is not accepted; Pipe has lifecycle pitfalls under repeated use).
# Simpler is better here: tests that print can have their output read from
# server.log via `client.sh log`, and the return value is what callers usually want.
function _safe_run(body)
    try
        (result=body(), error=nothing)
    catch e
        (result=nothing, error=sprint(showerror, e, catch_backtrace()))
    end
end

# Start a second HTTP listener for /dev/include and /dev/eval — same logic
# as MorkServer's router but added on top.  We add the routes AFTER serve!
# starts by wrapping MorkServer's handler.
#
# Actually simpler: bind a second HTTP server on PORT+1 (e.g. 8081) for dev
# endpoints.  Keeps the production-style port 8080 surface uncluttered.
const DEV_PORT = PORT + 1

@async begin
    sleep(0.5)  # let main server bind first
    HTTP.serve("127.0.0.1", DEV_PORT) do req
        try
            # Apply pending Revise patches before each request — same pattern
            # as Core/repl/server.jl.
            try

                Revise.revise()
            catch e

                @warn "Revise.revise() failed" exception=e
            end

            if req.method == "POST" && req.target == "/include"
                path = String(req.body)
                snap = _safe_run(() -> include(path))
                return HTTP.Response(
                    200,
                    ["Content-Type" => "application/json"],
                    JSON3.write((
                        ok=snap.error === nothing,
                        error=snap.error,
                        hint="stdout went to server.log — use `client.sh log` to read it"
                    ))
                )
            elseif req.method == "POST" && req.target == "/eval"
                code = String(req.body)
                snap = _safe_run(() -> Base.eval(Main, Meta.parseall(code)))
                return HTTP.Response(
                    200,
                    ["Content-Type" => "application/json"],
                    JSON3.write((result=sprint(show, snap.result), error=snap.error))
                )
            elseif req.method == "GET" && req.target == "/health"
                return HTTP.Response(
                    200,
                    ["Content-Type" => "application/json"],
                    JSON3.write((status="ok", dev_port=DEV_PORT, mork_port=PORT))
                )
            end
            HTTP.Response(404, "Not Found: $(req.method) $(req.target)")
        catch e
            bt = sprint(showerror, e, catch_backtrace())
            HTTP.Response(
                500, ["Content-Type" => "application/json"], JSON3.write((error=bt,))
            )
        end
    end
end

logln(
    "[mork-server] dev endpoints will be available on port $DEV_PORT (POST /include, POST /eval, GET /health)"
)

serve!(server)
