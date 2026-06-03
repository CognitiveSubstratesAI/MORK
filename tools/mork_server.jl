#!/usr/bin/env julia
# tools/mork_server.jl — Persistent MORK HTTP server
#
# Usage:
#   julia --project=. tools/mork_server.jl
#
# Environment:
#   MORK_SERVER_PORT  — port (default 8080)
#   MORK_SERVER_ADDR  — bind address (default 0.0.0.0)
#   MORK_RESOURCE_DIR — ResourceStore directory (default /tmp/mork-resources)

using MORK

const PORT = parse(Int, get(ENV, "MORK_SERVER_PORT", "8080"))
const ADDR = get(ENV, "MORK_SERVER_ADDR", "0.0.0.0")
const RESOURCE_DIR = get(ENV, "MORK_RESOURCE_DIR", "/tmp/mork-resources")

mkpath(RESOURCE_DIR)

ss = ServerSpace(RESOURCE_DIR)
server = MorkServer(ss, ADDR, PORT, Ref(false), Ref(0))

println("MORK server starting on http://$ADDR:$PORT")
println("  Resource dir : $RESOURCE_DIR")
println("  Health check : curl http://localhost:$PORT/status/-")
println("  Stop         : curl http://localhost:$PORT/stop")
println()

serve!(server)
