# MORK.jl

[![CI](https://github.com/CognitiveSubstratesAI/MORK/actions/workflows/CI.yml/badge.svg)](https://github.com/CognitiveSubstratesAI/MORK/actions/workflows/CI.yml)
[![Docs (stable)](https://img.shields.io/badge/docs-stable-blue.svg)](https://cognitivesubstratesai.github.io/MORK/stable/)
[![Docs (dev)](https://img.shields.io/badge/docs-dev-blue.svg)](https://cognitivesubstratesai.github.io/MORK/dev/)
[![Code Style: Blue](https://img.shields.io/badge/code%20style-blue-4495d1.svg)](https://github.com/invenia/BlueStyle)
[![Aqua QA](https://raw.githubusercontent.com/JuliaTesting/Aqua.jl/master/badge.svg)](https://github.com/JuliaTesting/Aqua.jl)
[![Julia 1.12+](https://img.shields.io/badge/Julia-1.12%2B-blue)](https://julialang.org)

A Julia implementation of the MORK knowledge-graph engine —
the high-performance, trie-native substrate for
[Hyperon](https://wiki.opencog.org/w/Hyperon) / MeTTa systems.

Inspired by the Rust [`trueagi-io/MORK`](https://github.com/trueagi-io/MORK).
This is an independent Julia implementation with full 1:1 parity coverage
of upstream's `main` and `server` branches.

---

## What is MORK?

MORK is a **space engine** — a reactive, rule-driven computation system
built on top of a compressed, structurally-shared trie substrate
([PathMap.jl](../PathMap)).

A MORK **space** is a collection of MeTTa-style s-expressions (atoms).
The engine drives computation by repeatedly applying rewrite rules to
matching patterns, accumulating output atoms into the space until a
fixed point is reached.

```julia
using MORK

s = new_space()
space_add_all_sexpr!(s, """
    (isa dog  animal)
    (isa cat  animal)
    (isa frog amphibian)
    (exec 0
        (, (isa \$x animal))
        (O (+ (count \$c) \$c 1))
    )
""")
space_metta_calculus!(s, 100_000)  # run until fixed point
println(space_dump_all_sexpr(s))   # (count 2)
```

---

## Status

| Metric | Value |
|--------|-------|
| Unit tests | **1566 / 1566** pass |
| Upstream integration tests | **14 / 14** pass |
| Integration test files | **28** (one per upstream function) |
| Upstream branches covered | `main` + `server` |

---

## Installation

```julia
using Pkg
Pkg.develop(path = "/path/to/MORK")
```

Requires Julia ≥ 1.10.
Dependencies: `PathMap.jl` (bundled), `HTTP.jl`, `JSON3.jl`, `SHA.jl`.

> **Note**: MORK.jl is not yet registered in the Julia General Registry.
> Clone the repo and use `Pkg.develop` as shown above.

## Benchmarks

Run the included benchmark suite:

```bash
julia --project=. benchmarks/benchmarks.jl
```

Covers space construction, ground/variable pattern matching (10–100 atoms),
two-source join, float-reduction sinks, and expression parsing.
Pass `--tune` for longer calibration.

---

## Quick Start

### Building a Space

```julia
using MORK

s = new_space()

# Add atoms from s-expression text
space_add_all_sexpr!(s, """
    (fact 1)
    (fact 2)
    (fact 3)
""")

# Add a single atom
space_add_sexpr!(s, "(fact 4)")
```

### Writing Rules

Rules use the `exec` form:

```julia
space_add_all_sexpr!(s, """
    (exec PRIORITY
        MATCH_PATTERN
        OUTPUT_PATTERN
    )
""")
```

| Field | Description |
|-------|-------------|
| `PRIORITY` | Integer or tuple — lower fires first |
| `MATCH_PATTERN` | `,` combinator over source patterns |
| `OUTPUT_PATTERN` | `O` combinator over output atoms |

### Running the Calculus

```julia
steps = space_metta_calculus!(s, 100_000)  # max 100k steps
# returns number of steps taken; < max => fixed point reached
```

### Querying Results

```julia
# Dump all atoms as s-expression text
println(space_dump_all_sexpr(s))

# Check if an atom exists
space_has_sexpr(s, "(fact 3)")   # true/false

# Count atoms
space_atom_count(s)
```

---

## Sink Operators

Sinks are special output combinators that aggregate matched values.

### Comparison Sinks

```julia
(exec 0 (, (n $x)) (O (- (n $x))))    # remove matched atoms
(exec 0 (, (n $x)) (O (+ (n $x))))    # assert (keep) matched atoms
```

### Float Reduction Sinks

Aggregate numeric values across all rule firings:

```julia
(exec 0
    (, (measurement $x))
    (O
        (fmin  (stats:min  $c) $c $x)   ;; running minimum
        (fmax  (stats:max  $c) $c $x)   ;; running maximum
        (fsum  (stats:sum  $c) $c $x)   ;; running sum
        (fprod (stats:prod $c) $c $x)   ;; running product
    )
)
```

### Bipolar Sinks

```julia
(exec 0 (, (signal $x)) (O (+ (positive $x))))   ;; assert positive
(exec 0 (, (signal $x)) (O (- (negative $x))))   ;; remove negative
```

---

## HTTP Server

MORK includes a built-in HTTP server for networked access:

```julia
using MORK

ss     = ServerSpace("/tmp/mork-resources")
server = MorkServer(ss, "0.0.0.0", 8080, Ref(false), Ref(0))
serve!(server)
```

Available endpoints:

| Method | Path | Description |
|--------|------|-------------|
| `GET` | `/status/-` | Health check |
| `POST` | `/metta_thread` | Execute a MeTTa calculus step |
| `POST` | `/transform` | Apply a pattern-template transformation |
| `POST` | `/explore` | Query matching atoms |
| `POST` | `/copy` | Copy a subtrie |
| `POST` | `/import` | Import atoms from pattern |
| `POST` | `/export` | Export atoms to pattern |
| `POST` | `/count` | Count matching atoms |
| `GET` | `/stop` | Graceful shutdown |

See [Server Guide](docs/guide/server.md) for full API.

---

## Development Workflow

### Warm REPL (recommended)

```bash
# Start once — pays the precompile cost once (~60s)
cd packages/MORK
julia --project=. -i tools/mork_repl.jl
```

Inside the REPL:

```julia
t()                          # run full test suite (1566 tests)
t("test/my_test.jl")         # run a specific test file
mc("(exec 0 (, foo) (O bar))\nfoo")  # eval s-expressions
include("/tmp/scratch.jl")   # run a scratch file
```

Write any file in `src/` and Revise reloads it automatically.
No restart needed for function-body changes.

### Cold-Start Verification

Before committing, verify with a fresh Julia process:

```bash
printf 't()\n' | julia --project=. tools/mork_repl.jl
```

### Linting

```bash
bash tools/lint.sh     # 4 static checks (oz.loc, ez.loc, sub_ez, step-cap)
```

---

## Package Layout

```
src/
├── MORK.jl               # module entry point
├── expr/                 # Byte-tag encoding, ExprZipper, unification
├── kernel/               # Space, Sinks, Sources, Pure, metta_calculus
├── frontend/             # Parsers: s-expr, cz2, cz3, he, rosetta
├── interning/            # Symbol interning
├── server/               # HTTP server, commands, resource store
├── client/               # HTTP client
├── morkl/                # MorkL interpreter
├── distributed/          # Dagger.jl / MPI scaling (PRIMUS extension)
└── runtime/              # ZipperVM, reflection

test/
├── runtests.jl           # 1566 unit tests
└── integration/          # 28 integration test files

tools/
├── mork_repl.jl          # warm development REPL
├── mork_server.jl        # standalone HTTP server
├── verify_upstream.jl    # 14 upstream integration case validator
├── diff_upstream.jl      # diff against Rust upstream
└── lint.sh               # static analysis
```

---

## Documentation

| Document | Description |
|----------|-------------|
**Guides**

| Document | Description |
|----------|-------------|
| [Space & Rules](docs/guide/space_rules.md) | Writing rules, patterns, multi-pattern match |
| [Sinks](docs/guide/sinks.md) | All sink operators with worked examples |
| [HTTP Server](docs/guide/server.md) | All endpoints, client API, resource store |
| [Expression Encoding](docs/guide/expressions.md) | Byte-tag format, parsers, content addressing |

**Reference**

| Document | Description |
|----------|-------------|
| [API Reference](docs/api/README.md) | Full exported symbol index |

---

## Relationship to PathMap.jl

MORK.jl depends on [PathMap.jl](../PathMap) as its trie substrate.
Every `Space` is backed by a `PathMap` that stores atoms as byte-encoded
paths.  PathMap's structural sharing and path algebra are what make
MORK's set-based calculus efficient.

---

## Relationship to Upstream

MORK.jl is inspired by the Rust
[`trueagi-io/MORK`](https://github.com/trueagi-io/MORK) codebase.
The core semantics follow upstream exactly.

**Extensions beyond upstream:**
- Full PathMap.jl integration (lazy COW, Policy API, hybrid cata)
- Distributed scaling via Dagger.jl + MPI (`distributed/`)
- Julia HTTP client mirroring upstream's Python client

---

## License

Apache 2.0 — see [LICENSE](LICENSE).
