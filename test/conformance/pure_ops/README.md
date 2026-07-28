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

    ops compared 341 · AGREE 338 · we produce nothing 0 · differing 3 · upstream errors 5

Closed here: the 16 silently-absent ops (float->int `as` saturation, domain-error NaN), the
`space_dump_all_sexpr` byte-encoding defect (~92 apparent divergences, ONE cause), plus:

| op | was | cause |
|---|---|---|
| `round_f32` / `round_f64` | 2.0 for input 2.5 | Rust rounds ties AWAY FROM ZERO; Julia's `round` defaults to ties-to-EVEN. Pinned on all four sign/parity combinations (2.5→3, −2.5→−3, 3.5→4, −3.5→−4) |
| `atanh_f32` / `atanh_f64` | +NaN | Rust yields a NEGATIVE NaN out of domain (it goes through a log of a negative quantity, so libm's sign carries) while `acos`/`asin` yield a POSITIVE one. Verified for both input signs |
| `to_degrees_f32` | 1 ULP low | Rust multiplies by a precomputed f32 constant; Julia's `rad2deg` performs the DIVISION in Float32 and rounds twice. `to_degrees_f64` and both `to_radians` already agreed |

### The 3 remaining are libm, not logic

`cbrt_f64`, `sin_f64`, `sinh_f32` — each differs in the LAST BIT only (…ed/…ee, …b0/…b1, F/G).
Julia links openlibm; Rust uses the system libm. Matching bit-for-bit would mean reimplementing one
of them inside the port. **Recorded as an accepted deviation, not a TODO** — and note the contrast
with `to_degrees_f32`, which LOOKED like the same 1-ULP class but was arithmetic and exactly
fixable. Do not assume a last-bit difference is libm without checking whether the op is actually a
libm call.

### `upstream nothing = 5` — the `*_ternarylogic` family

We emit, upstream ERRORS. Upstream's `quaternary` macro arm checks `if items != 3` and then
consumes FOUR arguments, where `ternary` checks 3 and consumes 3 (kernel/src/pure.rs macro, ~line
25). So a 4-arg call is rejected and a 3-arg call reads a fourth operand that was never supplied —
the op is unreachable either way upstream. Ours accepts the 4-arg form and computes it.
Uncharacterised beyond that; on shapes where upstream cannot run, "match upstream" has no meaning.

### ⚠️ A Julia trap this exercise surfaced

`_rust_domain` was briefly written as `f(x, nan::T = T(NaN)) where {F, T<:AbstractFloat}`. It
compiles, but the TWO-ARG form then returns GARBAGE — measured `_rust_domain(acos, 2.5f0)` =
`90ee1e60` instead of `7fc00000`, while the three-arg form was correct. A default argument that
constructs a value from a `where`-bound type parameter is not safe here. Two explicit methods.
