# Direct Zipper-Algebra Queries

MORK is a rule-driven engine — for most workloads you write rules and
let `space_metta_calculus!` evaluate them.  But for **large relational
queries** over an existing trie (knowledge-graph reachability,
prefix-narrowed aggregations, frontier-style graph traversals), the
calculus's match → output → rewrite loop is the wrong abstraction.

In those cases you reach *under* the calculus and call the underlying
[**PathMap.jl**](https://github.com/sivaji1012/PathMap) substrate's
zipper-algebra primitives directly on `space.btm`.  This is the same
substrate path the calculus uses internally, minus the rule rewriting,
output combinators and fixed-point machinery.  It is also the pattern
upstream MORK's `aunt-kg` benchmark uses; the Julia port exposes it
identically.

---

## When to use which layer

| Workload | Use |
|----------|-----|
| Generates new atoms via rules | calculus (`space_metta_calculus!`) |
| Multiple rules whose outputs feed each other | calculus |
| Per-key aggregations (`fsum`, `fmax`, `count`) | calculus (see [sinks.md](sinks.md)) |
| Pure reads / traversals over an existing trie | direct zipper algebra |
| Recursive frontier walks (reachability, transitive closure) | direct zipper algebra |
| Queries hitting a `.act` mmap'd snapshot | direct zipper algebra |

The two compose: bulk-build via byte-level `set_val_at!`, query via
zipper algebra, then drop into the calculus for any generative step.

---

## The pattern: bulk byte-load + prefix-narrowed walk

The query layer has two pieces.  First, ingest atoms by encoding their
byte path directly into the trie — skipping the s-expr parser:

```julia
using MORK
using PathMap: read_zipper_at_path, zipper_to_next_val!, zipper_path, set_val_at!

# Encode (rel A B) directly as bytes and insert into space.btm
function bulk_load_pairs!(s::Space, tsv_path::AbstractString) :: Int
    btm = s.btm
    sb  = codeunits("rel")
    buf = UInt8[]
    n   = 0
    for line in eachline(tsv_path)
        a, b = split(line, '\t')
        ab = codeunits(a); bb = codeunits(b)
        empty!(buf)
        push!(buf, item_byte(ExprArity(UInt8(3))))                  # (_ _ _) arity-3
        push!(buf, item_byte(ExprSymbol(UInt8(3)))); append!(buf, sb)
        push!(buf, item_byte(ExprSymbol(UInt8(length(ab))))); append!(buf, ab)
        push!(buf, item_byte(ExprSymbol(UInt8(length(bb))))); append!(buf, bb)
        set_val_at!(btm, buf, MORK.UNIT_VAL)
        n += 1
    end
    n
end
```

See [expressions.md](expressions.md) for the byte-layout invariants
the path bytes must satisfy.

Second, write a query-time prefix and `read_zipper_at_path` into the
subtrie below it.  Iteration via `zipper_to_next_val!` then walks
**only that subtrie** — O(matching atoms), not O(space):

```julia
# Prefix for "all (rel A *) atoms"
function rel_prefix(a::AbstractString) :: Vector{UInt8}
    sb = codeunits("rel"); ab = codeunits(a)
    buf = UInt8[]
    push!(buf, item_byte(ExprArity(UInt8(3))))
    push!(buf, item_byte(ExprSymbol(UInt8(3)))); append!(buf, sb)
    push!(buf, item_byte(ExprSymbol(UInt8(length(ab))))); append!(buf, ab)
    buf
end

function neighbors(btm, a::String) :: Vector{String}
    rz  = read_zipper_at_path(btm, rel_prefix(a))
    out = String[]
    while zipper_to_next_val!(rz)
        rel = collect(zipper_path(rz))
        tag = byte_item(rel[1])
        tag isa ExprSymbol || continue
        push!(out, String(@view rel[2 : 1 + Int(tag.size)]))
    end
    out
end
```

`read_zipper_at_path` descends in O(prefix-length) and
`zipper_to_next_val!` is O(1) amortised per emitted value — for
sparse relational data, total work is exactly the number of matching
atoms.

---

## Frontier-iterated traversal (reachability)

The transitive-closure pattern is a loop of prefix-narrowed walks,
one per frontier element:

```julia
function reach(btm, seeds::Vector{String}) :: Set{String}
    reached  = Set{String}(seeds)
    frontier = collect(seeds)
    while !isempty(frontier)
        next = String[]
        for a in frontier, b in neighbors(btm, a)
            b in reached && continue
            push!(reached, b); push!(next, b)
        end
        frontier = next
    end
    reached
end
```

Each `neighbors(btm, a)` costs O(out-degree of `a`).  Total work is
O(|edges-walked|) — every edge is walked at most once because once
its source is in `reached`, it is never re-walked.  This is the
standard relational-traversal complexity, achieved at the substrate
level without rule-engine overhead.

---

## Substrate polymorphism — same code on `.act` snapshots

`space.btm` (an in-RAM `PathMap`) and an mmap'd `ArenaCompactTree` are
**interchangeable under `read_zipper_at_path`** — see
[PathMap.jl](https://github.com/sivaji1012/PathMap), guide
[`zippers.md`](https://github.com/sivaji1012/PathMap/blob/main/docs/guide/zippers.md)
section "Trie-Format Polymorphism".

The entire query module above works unchanged whether you pass it
`s.btm` (in-RAM) or `tree = act_open_mmap("data.act")` (cold-opened
sub-millisecond, ~0 RSS, lazily faulted by the OS):

```julia
# Same call shape, different backend
reach(s.btm,        seeds)   # in-RAM
reach(act_open_mmap("data.act"), seeds)   # mmap'd .act
```

See PathMap's
[`serialization.md`](https://github.com/sivaji1012/PathMap/blob/main/docs/guide/serialization.md)
section "Load-Once / Mmap-Forever Workflow" for the snapshot pattern
that makes this practical for large datasets.

---

## Worked example — full FAFB v783 connectome

A complete realisation of this pattern lives in
[`packages/Core/examples/connectome/`](../../../Core/examples/connectome/):

- `info_flow_zipper.jl` — single-modality reach-flow on the in-RAM
  trie (3.73 M edges, ~3 min load, then µs-scale per query).
- `info_flow_all_modalities.jl` — all 7 afferent modalities on an
  mmap'd `.act` snapshot.  41.7 MB on disk, 0.25 ms cold-open,
  ~14 s total across all modalities.

Both files use the same `read_zipper_at_path` / `zipper_to_next_val!`
core loop documented above, differing only in the backend they open.

---

## When to reach back to the calculus

If a traversal needs:

- new atoms emitted into the space → use rules with `(O ...)`
- per-key sums / maxes during the walk → use rules with `fsum` /
  `fmax` (see [sinks.md](sinks.md))
- per-firing dependency on other rule outputs → use the calculus's
  priority + fixed-point machinery

Direct zipper algebra is **read-only** by design.  As soon as your
query needs to write into the same space it's reading, the
calculus is the right layer — its match → output → fixed-point loop
exists precisely to serialise those interactions safely.

---

## See also

- [expressions.md](expressions.md) — byte-layout your prefixes must match
- [sinks.md](sinks.md) — aggregation primitives inside the calculus
- [space_rules.md](space_rules.md) — when to write a rule instead
- [PathMap.jl](https://github.com/sivaji1012/PathMap) — substrate package
  - [`zippers.md`](https://github.com/sivaji1012/PathMap/blob/main/docs/guide/zippers.md) — full zipper API
  - [`serialization.md`](https://github.com/sivaji1012/PathMap/blob/main/docs/guide/serialization.md) — `.act` workflow
