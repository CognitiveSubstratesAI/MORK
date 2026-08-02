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


## 6. `#135` — quote loses variable coreference. CAUSE LOCALISED; fix is a DEVIATION, not a port

Upstream issue **#135** (OPEN). `(exec 0 (,) (O (pure $r $r (tuple R (' ($a $a))))))` yields
`(R ($a $b))` where `(R ($a $a))` is expected. **Our port reproduces it exactly.**

⚠️ **There is NO upstream fix to port.** Upstream's latest commit is `45bdb9a` (2026-07-14) and the
three commits ahead of our vendored `5464713` are all linalg work; the issue was filed 2026-07-20.
Fixing this means DEVIATING from upstream on an OPEN issue.

### Cause — every stage is individually correct, which is why it is hard to see

Traced by instrumenting each stage with the real byte encodings:

```
parse (exec … (' ($a $a)))   -> …02 c0 81      NewVar + VarRef(1)   CORRECT
expr_apply on the template   -> …02 c0 81      unchanged            CORRECT
scope_eval! of (' ($a $a))   -> 02 c0 80       -> ($a $a)           CORRECT
_expr_substitute_one_de_bruijn(tpl, result)  -> (R ($a $a))         CORRECT
```

The defect is a **scope mismatch, not a corruption**. In the enclosing expression `$r` is binder 0,
so the quoted `$a` is binder **1** and its back-reference is `VarRef(1)`. The PureSink then evaluates
the formula STANDALONE — `scope_eval!(s.scope, ExprSource(formula_buf, formula_start))`
(`Sinks.jl:1065`) — where the same bytes mean something else: the NewVar is now binder **0**, so
`VarRef(1)` points one past it and renders as a second, unrelated variable.

Nothing rewrites the bytes; they are simply read in a scope with one fewer enclosing binder.

### The fix, if we decide to deviate

Re-base the formula's variable references when it is EXTRACTED, so the buffer handed to
`scope_eval!` is self-contained: subtract `_expr_newvars(formula_buf, 1, formula_start - 1)` — the
count of binders preceding the formula — from every `VarRef` in the span, and raise if any index
would go negative (that would be a reference to a binder genuinely outside the formula).

This belongs at the extraction site (`Sinks.jl:1030-1037`), NOT at the quote splice: `scope_eval!`
receives a bare `(buf, position)` and has no way to know how many enclosing binders were dropped.

✅ **APPLIED 2026-07-31** as `_expr_rebase_varrefs` (`Sinks.jl`), after one further measurement made
the case decisive: **upstream's `hash_expr` is not content-addressed.** The same expression hashed
from templates differing only in how many binders precede the call gives `bssGabbteWo` vs
`0Z2xrn_VwuU` on the release binary; ours gives one digest either way. A content hash that changes
with syntactic position defeats the op's purpose, and that is silent — a variable-free expression is
unaffected, so it hides.

The deviation is WIDER than #135's own symptom and that is recorded where it bites:
`sink_pure_advanced.jl`'s byte-parity assertion now differs from `main.rs:1201-1225` for the
expression containing a back-reference (the variable-free one still matches exactly). The expected
value was changed WITH the reason attached, not silently.

Shaped to converge: it honours the de Bruijn base `ee_args!`/`args` already thread — the same value
PR #137 extracts as `ExprEnv::subterms` — so an upstream fix should look like this one. Reconcile
when #135 or #137 lands.

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

## 7. `HashSink` digest WIDTH — ours is 8 bytes, upstream's is 16 (DELIBERATE, ours-side)

**Not an upstream defect and not a port gap — a recorded deviation of OURS**, filed here because
three conformance probes can never match the binary while it stands, and a future session will
otherwise re-open them as work.

`HashSink` emits an 8-byte digest where upstream emits 16. The decision and its three reasons are in
the code body at `src/kernel/Sinks.jl:937-950`. Semantics are UNAFFECTED — equal subtries still hash
equal, distinct ones still differ:

```
sinks/g1_hash_eq_same   ours: (ha \xd2-\x9epG\xe2\x1d\xa5)                     (8 bytes)
                    upstream: (ha /{\xda) \xf3\x84o\xd0\xfb\xd5\xd3x\x1cl(\x82) (16 bytes)
                              -> (same) IS emitted on BOTH sides. Only the width differs.
```

Permanently out of `EXPECTED_PASS.txt`: `sinks/g1_hash_eq_same`, `sinks/g1_hash_eq_diff`,
`sinks/g1_hash_varref`. Do NOT count these toward the port backlog.

⚠️ **Distinguish this from `hash_expr`**, which IS byte-exact — `3973455` ported XXH3-128 and
`test/unit_xxh3.jl` pins it against vectors generated from the `xxhash-rust 0.8.15` crate. Two
different code paths; only `HashSink` carries the width deviation.

⚠️ **DO NOT "fix" this by widening to 16.** An earlier version of this entry said widening would
close the three probes "for free" — that was written without reading the reasons in `Sinks.jl:937-950`,
and it is wrong. The decisive one:

> Upstream itself does NOT keep those bytes stable: `PathMap/src/lib.rs:14-18` substitutes an entirely
> different hand-rolled XOR/rotate hasher under `miri`/`riscv64`. Its hash values are a per-TARGET
> artifact, not a portable contract.

Byte-matching a value upstream does not guarantee across targets buys nothing. What the hash must be
is CONSISTENT, which is all its real consumer needs — `ctl_model_checking.mm2:375-376` uses it as the
EG least-fixpoint TERMINATION test, comparing hash(l+1) against hash(l) from the SAME engine.

(One reason there IS now stale: it cites porting `gxhash` bit-exactly, but `3973455` established
`cfg(gxhash)` is never defined in that workspace — upstream's live path is `xxh3_128`, which we have
ported. The merkleization-traversal cost and the per-target argument above both stand.)

---

## 8. Corpus hygiene — 7 `.expected` fixtures were UTF-8 corrupt (FIXED 2026-08-02)

Not a defect in anyone's code; recorded because it hid four real ones for six days.

Seven vendored fixtures had every non-ASCII byte replaced by U+FFFD (`ef bf bd`) — captured through
a lossy channel despite the warning at the top of this file. `g1_hash_eq_same.expected` held
`efbfbd` six times where the digest bytes `da f3 84 d0 fb d5 d3 82` belong. **No implementation could
ever have matched them**, so the probes read as "known divergences" and were never diagnosed.

Regenerated from the upstream binary built at the vendored pin `5464713`, written to a FILE.
Faithfulness was checked in the only direction that proves it: re-mangling each NEW file through a
lossy decode reproduces the OLD file exactly, so the content is unchanged and only the byte
corruption is gone.

**What the repair exposed** — the corruption was masking, not causing, the failures. Conformance did
not move (249 before, 249 after). Three probes are the width deviation above; the other four are a
REAL silent-drop defect, invisible until the fixtures told the truth. See `_redsink_parse_entry`
below.

⚠️ **The sweep is the lesson.** Searching only the probes already suspected (the hash cluster) would
have found 6. Sweeping ALL 285 found a 7th — `sinks/g2_and_compound_value`, not a hash probe at all,
and the one carrying the clearest statement of the real defect.

---

## 9. `_redsink_parse_entry` rejects a non-Symbol value slot — SILENT DROP (OURS, OPEN)

**Our defect, not upstream's.** One root cause, four failing probes.

Upstream never inspects the value's tag. `kernel/src/sinks.rs:771` (and :808) is simply:

```rust
total &= p[clen+1];        // raw byte, no type check
```

For a compound value that byte is the arity-2 expression's FIRST CHILD HEADER (`0xC1` =
`SymbolSize(1)`), and upstream folds it and emits a result. Ours (`src/kernel/Sinks.jl:464`):

```julia
tx = byte_item(p[j]); tx isa ExprSymbol || return nothing   # drops the WHOLE entry
```

`nothing` discards the entry, so the whole group is dropped and **nothing is emitted at all** — no
error, no partial result. `HashSink` shares the path via `_redsink_finalize!` (`Sinks.jl:971`), which
is why hashing a compound `($z)` yields no row while hashing a bare `$x` works.

| probe | ours | upstream |
|---|---|---|
| `sinks/g2_and_compound_value` | `(m a 3) (m a 6)` | `(m a 3) (m a 6)` **`(r \xc1)`** |
| `space/s6_hash_single` | `(p a)` | **`(H <16 bytes>)`** `(p a)` |
| `space/s6_hash_multi` | `(p a) (p b)` | **`(H <16 bytes>)`** `(p a) (p b)` |
| `space/s6_io_hash` | `(p a) (p b)` | **`(H <16 bytes>)`** `(p a) (p b)` |

⚠️ The three `s6` probes need BOTH this fix and the width deviation resolved to reach byte-exact;
`g2_and_compound_value` needs only this one, so it is the honest single-probe test of the fix.

✅ **FIXED 2026-08-02.** `_redsink_parse_entry` now hands back the payload from `j+1` when the tag is
not a Symbol, so each `acc` reads the slot the way ITS upstream branch does: `_and_acc` takes
`value[1]` (= `p[clen+1]`), `_sum_acc` parses the whole slice (= `p[clen+1..]`) and declines via
`nothing` where upstream would `unwrap()`-panic.

MEASURED against the full corpus, not the four probes that motivated it:

| | before | after |
|---|---|---|
| conformance passing | 249/285 | **250/285** |
| regressions | — | **0** |
| MORK suite | 2960/2960 | 2960/2960 |

`sinks/g2_and_compound_value` now matches the binary byte-for-byte and is in the baseline. The three
`s6` probes now EMIT THE ROW they were silently dropping —
`space/s6_hash_single` → `(H \xb9\x8d\xf2IUi\xb9\x06)` where it previously emitted nothing — and are
therefore reduced to entry 7's digest-width deviation ALONE, which is deliberate and stays.
(`s6_hash_multi` and `s6_io_hash` hash identically to each other, as consistent inputs should.)

⚠️ The four probes could not have told you the guard was safe to relax — three of them still fail.
`g2_and_compound_value` is the only one that isolates this fix, which is why it is the regression test
for it.

---

## Reporting these upstream

None of these has been filed with `trueagi-io/MORK`. Each entry above has the reproducer and the
evidence, so filing is mechanical. #2 and #5 are the ones with the strongest case: a corrupted
symbol and an expression that cannot be read back, both silent.
