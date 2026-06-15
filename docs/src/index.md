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

## Worked example: the fly connectome

A full real-world build — the **FAFB v783 _Drosophila_ connectome** (≈139 k
neurons, 3.73 M synapses) organized as persisted per-Space `.act` snapshots, with
the *Nature* 2024 Fig-6 information-flow model run over them:
[**Fly connectome (FAFB v783)**](examples/fly_connectome.md).

It showcases the substrate end-to-end: prefix-scoped multi-Space queries,
cold-mmap `.act` reads (~0.25 ms open of a 41.7 MB snapshot), and the
zipper-frontier traversal from the
[Zipper Queries](guide/zipper_queries.md) guide — validated node-for-node against
an independent oracle.

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
