# Upstream defects found while porting — WRONG ANSWERS, not crashes

`upstream_panics/` records the 49 programs where `mork run` **aborts**: no output, so nothing to
compare against. This file is the other category — upstream **runs, returns, and is wrong**. Each
entry was suspected by reading and then **settled by execution**, and each says what our port does
instead and why.

Mirrors `PathMap/test/differential/UPSTREAM_BUGS.md`, which carries the same rule of thumb:

> The project's standing principle is *if upstream has it, we implement it* — we do not get to judge
> whether it matters. This file is the narrow exception: reproducing **silent data loss or
> corruption** is worse than deviating. An entry here needs a demonstrated wrong ANSWER, not a
> disagreement of taste.

To re-check any of these after an upstream rebuild:

```bash
mork run probe.mm2 probe.raw    # ALWAYS to a FILE — stdout mangles the high bytes these ops emit
```

---

## 1. `mod_i*` aborts on divisor 0 and on `typemin % -1`

`kernel/src/pure.rs`, the `mod_i8/16/32/64/128` arms. Rust's `%` panics on a zero divisor, and
`i64::MIN % -1` overflows the same way `i64::MIN / -1` does. The `op!` arms apply `%` directly with
no guard, so both shapes abort the process mid-saturation — every atom of the run is lost, not just
the offending one.

**Ours:** the op raises and the atom is skipped, matching how upstream's own `Err` paths behave for
every other failure mode in the file. Recorded in `Pure.jl` at the arm.

---

## 2. `encode_hex` corrupts at 32 bytes and aborts at 33

`pure.rs:748-760`. It writes into a fixed `[0u8; 64]` and emits `buf[..2*len]`.

* a **32-byte** input produces a 64-byte symbol — which violates the Rule of 64 (`SymbolSize` is
  1..63), so the emitted atom is structurally invalid, silently
* a **33-byte** input writes past the array and **panics** — a non-unwinding abort that kills the
  process and writes no output at all

**Ours:** raises before emitting, so the atom is skipped and the run continues. `sink_write!`
enforces the 63-byte limit independently. Documented at `_nat_encode_hex` (`Pure.jl:1192`).

---

## 3. `'` (quote) rewinds the evaluation cursor by one item

The `quote` branch of the evaluator does not advance past the item it quoted, so the next step
re-reads it. Settled by execution against the binary: our cursor position and upstream's differ by
exactly one item after a quote.

**Ours:** advances. This is the one place the port deliberately does NOT reproduce upstream's cursor
arithmetic, noted at the `_push_eval!` quote branch in `Eval.jl`.

---

## 4. `unbind` writes its own 255 sentinel as a `VarRef`

For the input `($x $x)` — `[2] $ _1` — upstream's `unbind` emits its internal 255 sentinel into the
output as a `VarRef` index. 255 is not a legal VarRef under the Rule of 64 (max 63), so the result
does not decode.

**Ours:** raises rather than emitting an undecodable index. The behaviour is pinned by a test in
`test_expr_queries.jl` ("unbind — and the `VarRef(255)` sentinel path") which records `:raised`
explicitly, so a future change of heart is visible.

---

## 5. `load_jsonl` writes the line index UNTAGGED — the document lands outside the expression

Found 2026-07-31 while porting `jsonl_to_paths`. Upstream's two JSONL writers disagree:

| | line index | site |
|---|---|---|
| `load_jsonl` | 8 bytes, **no tag** | `space.rs:628` — `wz.descend_to(lines.to_be_bytes())` |
| `jsonl_to_paths` | 8 bytes, **`SymbolSize(8)`** | `space.rs:596` |

The untagged path `[3] (5)JSONL 00*8 [2] (1)a (1)1` parses as an expression only **nine bytes**
long, rendering `(JSONL () ())`: the first two zero index bytes are consumed as two `Arity(0)`
empties, which satisfies the `Arity(3)`, and the remaining six index bytes **and the entire
document** sit outside the expression span. Verified by measuring the span, not by reading.

It survives as a trie KEY — still unique per line — which is why it works in practice for
`load_jsonl`'s own purposes. It does not read back. `jsonl_to_paths`, which writes a `.paths` stream
meant to be deserialized, tags it and is correct.

**Ours:** each of our two functions mirrors ITS OWN upstream counterpart, so we reproduce the
difference rather than silently "fixing" `space_load_jsonl!` — that would break parity with the
release binary. The difference is pinned byte-for-byte in `test_json_to_paths.jl`, including that
our `jsonl_to_paths` output spans the whole path while the `load_jsonl` shape stops early.

---

## Reporting these upstream

None of these has been filed with `trueagi-io/MORK`. Each entry above has the reproducer and the
evidence, so filing is mechanical. #2 and #5 are the ones with the strongest case: a corrupted
symbol and an expression that cannot be read back, both silent.
