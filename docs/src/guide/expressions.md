# Expression Encoding

MORK represents all atoms as **byte-encoded expressions** stored in the
PathMap trie.  Understanding this encoding is useful when working with
the low-level `ExprZipper` API or implementing custom parsers.

---

## Overview

Each expression is encoded as a contiguous byte sequence using a
**tag–payload** scheme.  This allows expressions of arbitrary nesting
depth to be stored as flat byte strings and compared structurally using
trie operations.

### Tag Bytes

The first byte of every sub-expression is a **tag** that indicates its
kind:

| Tag | Hex | Meaning |
|-----|-----|---------|
| `Symbol` | `0x01` | Atom symbol (followed by interned symbol ID) |
| `Var` | `0x02` | Variable (followed by variable index) |
| `Expr` | `0x03` | Compound expression (followed by arity, then children) |
| `Int` | `0x04` | Integer literal |
| `Float` | `0x05` | Float literal |

### Interning

Symbol names are **interned**: each unique string is assigned a compact
integer ID, and the ID is stored in the byte sequence rather than the
full string.  The mapping is maintained in the global intern table.

```julia
using MORK

id  = intern("alice")         # register or look up "alice"
str = unintern(id)            # "alice"

tbl = interning_table()       # inspect the full table
```

---

## ExprZipper

`ExprZipper` is a cursor into a byte-encoded expression buffer.  It
navigates the structure byte-by-byte, providing access to tags, arities,
and payload values.

### Creating

```julia
# From a byte buffer
ez = ExprZipper(buffer, start_offset)

# From an s-expression string (parse → encode → zipper)
expr_bytes = sexpr_to_bytes("(isa alice human)")
ez = ExprZipper(expr_bytes, 1)
```

### Navigation

```julia
ez_tag(ez)            # current tag byte
ez_arity(ez)          # arity if current node is an Expr
ez_symbol_id(ez)      # symbol ID if current node is a Symbol
ez_var_index(ez)      # variable index if current node is a Var
ez_int_val(ez)        # integer value if current node is Int
ez_float_val(ez)      # float value if current node is Float

ez_descend!(ez)       # enter first child of current Expr
ez_next!(ez)          # move to next sibling
ez_at_end(ez)         # true if no more siblings
```

### Building Expressions

```julia
buf = UInt8[]
eb  = ExprBuilder(buf)

eb_open!(eb)                        # start compound expression
eb_symbol!(eb, intern("isa"))       # add symbol
eb_symbol!(eb, intern("alice"))     # add symbol
eb_symbol!(eb, intern("human"))     # add symbol
eb_close!(eb)                       # close compound → (isa alice human)
```

---

## Parsing

MORK includes multiple frontend parsers, each targeting a different
input format:

### S-Expression Parser

The default format for humans and most tooling:

```julia
expr = parse_sexpr("(isa alice human)")
text = expr_to_sexpr(expr)       # round-trip
```

Supported syntax:
- Symbols: `word`, `kebab-case`, `snake_case`, `CamelCase`
- Variables: `$name`
- Numbers: `42`, `-3.14`
- Nested: `(f (g x) y)`
- Comments: `;; this is a comment`

### HE Parser (Hyperon Encoding)

Compact encoding used by upstream MORK for efficient serialization:

```julia
expr = parse_he(he_bytes)
```

### CZ2 / CZ3 Parsers

Columnar-zipper formats optimised for parallel parsing of large corpora:

```julia
expr = parse_cz2(buffer)
expr = parse_cz3(buffer)
```

### Rosetta Parser

Cross-format translation parser:

```julia
expr = parse_rosetta(text)
```

---

## Conversion Utilities

```julia
# Text ↔ expression ↔ bytes
text  = "(isa alice human)"
expr  = sexpr_to_expr(text)         # parse to internal Expr type
bytes = expr_to_bytes(expr)         # encode to byte sequence
expr2 = bytes_to_expr(bytes)        # decode back
text2 = expr_to_sexpr(expr2)        # format as s-expression

# Direct text ↔ bytes
bytes = sexpr_to_bytes(text)
text  = bytes_to_sexpr(bytes)
```

---

## Content Addressing

Expressions support **content-addressed IDs** — a deterministic hash
derived from the expression's byte encoding:

```julia
cid = content_id(expr_bytes)     # UInt64 content-addressed identifier
```

Two structurally identical expressions always produce the same CID,
regardless of how or when they were created.  MORK uses CIDs internally
to deduplicate atoms.

---

## Performance Notes

- Symbol interning means expression comparisons are O(1) for symbols
  (integer comparison, not string comparison).
- The byte-encoding layout is chosen to maximise prefix sharing in the
  PathMap trie — structurally similar expressions share trie prefixes,
  reducing both storage and query cost.
- `ExprZipper` operates on a raw byte slice with no allocation —
  suitable for high-frequency inner loops.
