`load_jsonl` writes the line index UNTAGGED, so the document falls outside the expression

---
The two JSONL writers disagree on how the line index is stored, and only one produces a readable
expression.

| function | line index | site |
|---|---|---|
| `load_jsonl` | 8 bytes, **no tag** | space.rs:628 — `wz.descend_to(lines.to_be_bytes())` |
| `jsonl_to_paths` | 8 bytes, **`SymbolSize(8)`** | space.rs:596 |

## What the untagged form produces

The path `[3] (5)JSONL 00*8 [2] (1)a (1)1` parses as an expression only **nine bytes** long,
rendering `(JSONL () ())` — the first two zero index bytes are consumed as two `Arity(0)` empties,
which satisfies the `Arity(3)`, and the remaining six index bytes **and the entire document** sit
outside the expression span.

It still works as a trie KEY, since it is unique per line, which is presumably why it has gone
unnoticed. It does not read back as an expression.

`jsonl_to_paths` tags the same field and is correct — it writes a `.paths` stream intended to be
deserialized. Making `load_jsonl` match it would be a one-line change.
