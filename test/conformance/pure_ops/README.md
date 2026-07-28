# PURE OP differential — per-op coverage against the upstream binary

## Why this exists

The conformance corpus covers **18 of upstream's 360 pure ops (5%)**, and the recurring
width / arity / truncation defect class lives exactly there. Measured 2026-07-28:

```
$ for o in <every op! name>; do grep -q "\b$o\b" <corpus>; done
covered=18   UNCOVERED=342
```

## Method

`gen_pure_probes.py` parses upstream's macro-generated `op!(...)` table
(`kernel/src/pure.rs`) for name, arity class and parameter types, then emits one MM2 probe per
type family exercising every op.

Two things make it work:

* **The result symbol is emitted RAW — no `*_to_string` wrapper.** Its BYTE LENGTH is the result
  width, so this observes width directly instead of assuming a type. That matters because the
  macro writes `($e).to_be_bytes()`, so the width is that of the Rust *expression*:
  `u8_leading_zeros(x: u8)` returns `u32` and emits **four** bytes, not one.
* **Arguments are fed by BYTE WIDTH.** Upstream has no unsigned `from_string`, so a `u8`
  parameter is fed by `i8_from_string` — `consume::<u8>` just reads the symbol's bytes.

## ⚠️ Pin ground truth to a FILE, never stdout

    mork run probe.mm2 probe.raw      # correct — raw bytes preserved
    mork run probe.mm2 > probe.raw    # WRONG — lossy

Upstream's stdout dump replaces invalid UTF-8: byte `0xFE` prints as `EF BF BD`. Existing probes
survive only because their control bytes (`0x00`, `0x0f`) are valid single-byte UTF-8. Most pure
ops produce high bytes, so stdout cannot be ground truth for them.

## Running

    python3 gen_pure_probes.py <outdir>
    cd ~/JuliaAGI/dev-zone/MORK
    for f in <outdir>/*.mm2; do ./target/release/mork run $f ${f%.mm2}.raw; done
    PROBES=<outdir> julia --project=. test/conformance/pure_ops/cmp_pure.jl

## Status 2026-07-28

    ops compared 341 · AGREE 241 · we produce nothing 0 · differing 100 · upstream errors 5

**The 100 are NOT 100 op defects.** Verified on `acosh_f32`: Julia computes bits `3f c8 8c e1`,
byte-identical to upstream — the VALUE is right and `space_dump_all_sexpr` corrupts the
RENDERING, mangling non-ASCII three different ways in one symbol
(`c8` → UTF-8 `c3 88`; `8c` → the literal text `\x8c`; `e1` → `c3 a1`) where upstream writes raw
bytes. The 241 that agree are simply the ops whose results are pure ASCII.
**Fix the dump encoding before reading anything more into that number.**

`upstream nothing = 5`: we emit where upstream ERRORS — the `*_ternarylogic` family. Upstream's
`quaternary` macro arm checks `if items != 3` and then consumes FOUR arguments, where `ternary`
checks 3 and consumes 3. That looks like an upstream copy-paste bug; not yet characterised.
