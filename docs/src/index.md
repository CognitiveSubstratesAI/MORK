# MORK.jl

A Julia implementation of the **MORK** metagraph rewriting engine — the
high-performance, trie-native substrate for symbolic computation, built on
[PathMap.jl](https://github.com/CognitiveSubstratesAI/PathMap).

MORK is an independent Julia port of the Rust
[MORK](https://github.com/trueagi-io/MORK) kernel, hardened by a deep
Rust→Julia porting audit (intern races, numeric-primitive width, COW discipline,
operator-precedence transpilation defects).

## Features

- **Expression engine** — byte-encoded s-expressions over a `PathMap{UnitVal}`
  substrate, with prefix-scoped multi-space queries.
- **Transform / exec** — pattern→template rewriting, sinks (Count/Head/AU/…),
  and the metta-calculus step.
- **Concurrent symbol interning** — thread-safe bucket-map symbol table.
- **Numeric primitives** — full u8…u128 / i8…i128 / f32 / f64 op suite.

## Installation

```julia
using Pkg
Pkg.add(url="https://github.com/CognitiveSubstratesAI/MORK")
```

## Contents

```@contents
Pages = [
    "guide/expressions.md",
    "guide/zipper_queries.md",
    "guide/space_rules.md",
    "guide/sinks.md",
    "guide/server.md",
]
Depth = 1
```
