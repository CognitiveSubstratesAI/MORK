# MORK API Reference

Complete index of exported symbols from `MORK.jl`.

For prose guides see `docs/guide/`:

- [expressions.md](../guide/expressions.md) — byte-encoding layout
- [space_rules.md](../guide/space_rules.md) — writing rules + the calculus
- [sinks.md](../guide/sinks.md) — output combinators (`+`, `-`, `fsum`, `count`, ...)
- [server.md](../guide/server.md) — HTTP server surface
- [zipper_queries.md](../guide/zipper_queries.md) — direct PathMap zipper-algebra
  queries (use when you want reads / traversals over an existing trie
  without the rule engine; works polymorphically over `.act` mmap'd snapshots)

The trie substrate lives in a separate package:
[**PathMap.jl**](https://github.com/sivaji1012/PathMap) — byte-keyed,
prefix-compressed, structurally-shared trie with first-class zipper
algebra and `.act` mmap serialization.  See its
[`docs/guide/`](https://github.com/sivaji1012/PathMap/tree/main/docs/guide)
for the substrate API.

---

## Space — Core Container

| Symbol | Description |
|--------|-------------|
| `new_space()` | Create a new empty Space |
| `space_add_sexpr!(s, text)` | Add one atom from s-expr text |
| `space_add_all_sexpr!(s, text)` | Add multiple atoms from s-expr text |
| `space_has_sexpr(s, text)` | True if atom exists |
| `space_remove_sexpr!(s, text)` | Remove an atom |
| `space_dump_all_sexpr(s)` | Return all atoms as s-expr string |
| `space_atom_count(s)` | Number of atoms in space |
| `space_metta_calculus!(s, max_steps)` | Run calculus to fixed point |
| `space_query_sexpr(s, pattern)` | Match a pattern, return bindings |
| `space_query_multi_i(s, patterns)` | Multi-pattern query |
| `space_backup(s)` | Snapshot the space |
| `space_restore!(s, snapshot)` | Restore a snapshot |

---

## Expression Encoding

| Symbol | Description |
|--------|-------------|
| `expr_to_bytes(expr)` | Encode expression to bytes |
| `bytes_to_expr(bytes)` | Decode bytes to expression |
| `sexpr_to_expr(text)` | Parse s-expr text to expression |
| `expr_to_sexpr(expr)` | Format expression as s-expr text |
| `ExprZipper` | Cursor into a byte-encoded expression |
| `ez_*` functions | ExprZipper navigation and mutation |

---

## Sinks

| Symbol | Description |
|--------|-------------|
| `RemoveSink` | `-` operator — removes matched atoms |
| `AddSink` | `+` operator — asserts atoms |
| `FloatReductionSink` | `fmin`/`fmax`/`fsum`/`fprod` aggregators |
| `CountSink` | Counting sink |
| `BipolarSink` | Dual +/- sink |

---

## Sources

| Symbol | Description |
|--------|-------------|
| `CmpSource` | Comparison source (deferred) |
| `space_query_multi_i` | Multi-source query driver |

---

## HTTP Server

| Symbol | Description |
|--------|-------------|
| `ServerSpace(dir)` | Create a server-backed space |
| `MorkServer(ss, addr, port, ...)` | Create HTTP server |
| `serve!(server)` | Start serving (blocking) |

---

## Parsers

| Symbol | Description |
|--------|-------------|
| `parse_sexpr(text)` | S-expression parser |
| `parse_he(text)` | HE (Hyperon Encoding) parser |
| `parse_cz2(text)` | CZ2 parser |
| `parse_cz3(text)` | CZ3 parser |
| `parse_rosetta(text)` | Rosetta parser |

---

## Utilities

| Symbol | Description |
|--------|-------------|
| `version()` | Package version |
| `MorkL` | MorkL interpreter module |
| `interning_table()` | Global symbol intern table |
