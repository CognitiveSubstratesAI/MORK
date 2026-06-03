# HTTP Server Guide

MORK.jl includes a built-in HTTP server that exposes a MORK space over
the network.  It is a 1:1 port of the upstream Rust `server/` crate.

---

## Starting the Server

```julia
using MORK

resource_dir = "/tmp/mork-resources"
mkpath(resource_dir)

ss     = ServerSpace(resource_dir)
server = MorkServer(ss, "0.0.0.0", 8080, Ref(false), Ref(0))
println("MORK server on http://0.0.0.0:8080")
serve!(server)    # blocking — use a Task or separate process for non-blocking
```

Or from the command line:

```bash
cd packages/MORK
MORK_SERVER_PORT=8080 julia --project=. tools/mork_server.jl
```

### Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `MORK_SERVER_PORT` | `8080` | Bind port |
| `MORK_SERVER_ADDR` | `0.0.0.0` | Bind address |
| `MORK_RESOURCE_DIR` | `/tmp/mork-resources` | Resource storage directory |

---

## Health Check

```bash
curl http://localhost:8080/status/-
# {"status":"pathClear","message":""}
```

---

## Endpoint Reference

All endpoints accept and return JSON.

### `GET /status/{path}`

Check whether a path in the space is clear (no atoms).

```bash
curl http://localhost:8080/status/my-namespace
# {"status":"pathClear","message":""}
# or
# {"status":"pathOccupied","message":"3 atoms"}
```

### `POST /metta_thread`

Execute a metta calculus step.  Runs `space_metta_calculus!` with the
given parameters.

```bash
curl -X POST http://localhost:8080/metta_thread \
  -H "Content-Type: application/json" \
  -d '{"path": "computation", "max_steps": 10000}'
```

Response:
```json
{"steps_taken": 42, "converged": true}
```

### `POST /metta_thread_suspend`

Suspend a running calculus thread.

```bash
curl -X POST http://localhost:8080/metta_thread_suspend \
  -H "Content-Type: application/json" \
  -d '{"path": "computation"}'
```

### `POST /transform`

Apply a pattern→template transformation to the space.

```bash
curl -X POST http://localhost:8080/transform \
  -H "Content-Type: application/json" \
  -d '{
    "pattern":  "(input $x)",
    "template": "(output $x)",
    "path":     "my-namespace"
  }'
```

### `POST /explore`

Query atoms matching a pattern.

```bash
curl -X POST http://localhost:8080/explore \
  -H "Content-Type: application/json" \
  -d '{"pattern": "(person $name $age)", "path": "people"}'
```

Response:
```json
{
  "matches": [
    {"$name": "alice", "$age": "30"},
    {"$name": "bob",   "$age": "25"}
  ]
}
```

### `POST /import`

Import atoms into a namespace from a pattern over the existing space.

```bash
curl -X POST http://localhost:8080/import \
  -H "Content-Type: application/json" \
  -d '{
    "pattern":  "(raw-data $x)",
    "template": "(processed $x)",
    "source":   "raw",
    "dest":     "clean"
  }'
```

### `POST /export`

Export atoms from a namespace as a pattern-template mapping.

```bash
curl -X POST http://localhost:8080/export \
  -H "Content-Type: application/json" \
  -d '{
    "pattern":  "(result $x)",
    "template": "(archived $x)",
    "source":   "results",
    "dest":     "archive"
  }'
```

### `POST /copy`

Copy a subtrie from one path to another.

```bash
curl -X POST http://localhost:8080/copy \
  -H "Content-Type: application/json" \
  -d '{"from": "source-path", "to": "dest-path"}'
```

### `POST /count`

Count atoms matching a pattern.

```bash
curl -X POST http://localhost:8080/count \
  -H "Content-Type: application/json" \
  -d '{"pattern": "(person $name $age)", "path": "people"}'
# {"count": 3}
```

### `POST /upload`

Upload a resource file to the resource store.

```bash
curl -X POST http://localhost:8080/upload \
  -H "Content-Type: application/octet-stream" \
  --data-binary @my-data.act \
  "http://localhost:8080/upload?name=my-dataset"
```

### `GET /stop`

Graceful shutdown.

```bash
curl http://localhost:8080/stop
```

---

## Status Streaming

`GET /status_stream/{path}` returns a Server-Sent Events stream that
emits a status event whenever the path changes:

```bash
curl -N http://localhost:8080/status_stream/my-namespace
```

---

## Resource Store

The server maintains a **resource store** in the configured directory.
Resources are persistent ACT (ArenaCompact Trie) files that survive
server restarts.

```bash
# List available resources
ls /tmp/mork-resources/

# Resources are referenced by name in import/export operations
```

---

## Julia Client

MORK.jl includes a Julia client that mirrors the upstream Python client:

```julia
using MORK

client = MorkClient("http://localhost:8080")

# Status
client_status(client, "my-namespace")

# Transform
client_transform(client,
    pattern  = "(raw \$x)",
    template = "(clean \$x)",
    path     = "pipeline")

# Explore
matches = client_explore(client, "(person \$name \$age)", "people")
```
