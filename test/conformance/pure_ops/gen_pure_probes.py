#!/usr/bin/env python3
"""Generate MM2 conformance probes for every PURE OP — MANY input points per op, one FILE per op.

WHY THIS WAS REWRITTEN (2026-07-30). The previous version emitted exactly ONE probe per op: a single
literal per type (`3` for every integer, `2.5` for every float) and, for nary ops, exactly TWO
arguments. It reported "338 of 341 AGREE" — and every one of the 52 bodies that had drifted from
upstream's `op!` arms was inside that green, because:

  * `min_/max_/sum_/product_` are NARY FOLDS FROM A SEED. Probed with two args, a binary
    transcription reading `a[1]`/`a[2]` looks correct. `(max_i32 1 4 9)` gave 4, not 9; `(max_i32)`
    gave nothing, not `i32::MIN`.
  * `u*_shl/shr` are `checked_shl`. Probed with shift 3, a total Julia `<<` looks correct. At
    shift == WIDTH upstream returns Err and emits nothing while we FABRICATED a 0.
  * `signum_f*` is a SIGN-BIT test. Probed with 2.5 it looks correct; only ±0.0 separates it from
    Julia's `sign`.
  * `pow_i*` casts the exponent `as u32` FIRST. Probed with a positive exponent it looks correct;
    only a negative one shows the wrap.
  * float `min_/max_` IGNORE NaN. Only a NaN input shows it.

⇒ THE RULE THIS FILE ENCODES: an op's defect lives at the EDGE of its input domain — arity 0/1/3,
zero, ±1, typemin/typemax, NaN, ±0.0, and shift == width. One interior point per op is not a
differential, it is a smoke test.

METHOD (unchanged, and it is what makes width observable):
  * Emit the op's RAW result symbol, with NO `*_to_string` wrapper. The symbol's BYTE LENGTH is the
    result width, so this observes width directly instead of assuming a type. That is how
    `u8_leading_zeros` returning u32 (FOUR bytes, not one) is caught.
  * Feed arguments by BYTE WIDTH. Upstream has no unsigned `from_string`, so a `u8` parameter is fed
    by `i8_from_string` — `consume::<u8>` just reads the symbol's bytes. For unsigned EDGE values
    this is essential: u64::MAX is fed as `i64_from_string -1`, the same 8 bytes.

ONE FILE PER OP, and that is a correctness requirement, not tidiness. A panic inside upstream's
`extern "C"` is a NON-UNWINDING ABORT: the process dies and NO output file is written. Grouped by
family, one aborting op would silently erase every other op in its file, and a missing `.raw` reads
as "skipped" rather than "lost". `run_probes.sh` reports aborts explicitly; `cmp_pure.jl` counts a
missing `.raw` as ABORTED rather than skipping it.

DELIBERATELY NOT PROBED — the three shapes that ABORT upstream (recorded in CODEMAP as intentional
deviations; probing them would destroy the run and prove nothing we do not already know):
  * `mod_i*` with divisor 0     — upstream `x % y` is BARE (pure.rs:549)
  * `clamp_*` with lo > hi      — `Ord::clamp`/`f*::clamp` assert `min <= max`
  * `*_ternarylogic` entirely   — the `quaternary` arm checks `items != 3` then consumes FOUR
                                  operands, so the op is unreachable upstream at every arity

Usage:  python3 gen_pure_probes.py <outdir>
"""
import re, sys, os, collections

PURE_RS = os.path.expanduser("~/dev-zone/MORK/kernel/src/pure.rs")
OUT = sys.argv[1]

FEEDER = {
    "u8": "i8_from_string",    "i8": "i8_from_string",
    "u16": "i16_from_string",  "i16": "i16_from_string",
    "u32": "i32_from_string",  "i32": "i32_from_string",
    "u64": "i64_from_string",  "i64": "i64_from_string",
    "u128": "i128_from_string", "i128": "i128_from_string",
    "f32": "f32_from_string",  "f64": "f64_from_string",
}

# Edge values as (tag, literal). Unsigned types reuse the SIGNED list of the same byte width: the
# feeder writes bytes, and `-1` is the all-ones pattern that is also uN::MAX.
_INT_EDGES = {
    8:   [("z", "0"), ("p1", "1"), ("n1", "-1"), ("mn", "-128"), ("mx", "127"), ("k3", "3")],
    16:  [("z", "0"), ("p1", "1"), ("n1", "-1"), ("mn", "-32768"), ("mx", "32767"), ("k3", "3")],
    32:  [("z", "0"), ("p1", "1"), ("n1", "-1"), ("mn", "-2147483648"),
          ("mx", "2147483647"), ("k3", "3")],
    64:  [("z", "0"), ("p1", "1"), ("n1", "-1"), ("mn", "-9223372036854775808"),
          ("mx", "9223372036854775807"), ("k3", "3")],
    128: [("z", "0"), ("p1", "1"), ("n1", "-1"),
          ("mn", "-170141183460469231731687303715884105728"),
          ("mx", "170141183460469231731687303715884105727"), ("k3", "3")],
}
# `mn` is the most-negative FINITE value, not -inf: `pairs`/`ternary` use `mn`/`mx` as the ordered
# extremes for every type, and a clamp range of [-inf, inf] would not exercise a bound at all.
_FLOAT_EDGES = {
    "f32": [("z", "0"), ("nz", "-0"), ("p1", "1"), ("n1", "-1"), ("k3", "2.5"), ("nan", "NaN"),
            ("inf", "inf"), ("ninf", "-inf"), ("mx", "3.4028235e38"), ("mn", "-3.4028235e38"),
            ("tiny", "1e-40")],
    "f64": [("z", "0"), ("nz", "-0"), ("p1", "1"), ("n1", "-1"), ("k3", "2.5"), ("nan", "NaN"),
            ("inf", "inf"), ("ninf", "-inf"), ("mx", "1.7976931348623157e308"),
            ("mn", "-1.7976931348623157e308"), ("tiny", "1e-320")],
}

# KEY CONTRACT, enforced rather than assumed. Every type must define these, because the case builders
# below index them by name for EVERY type — a missing key surfaced as a `KeyError` from inside a
# comprehension, which says nothing about which type or which builder. Fail here instead, with names.
_REQUIRED = ("z", "p1", "n1", "mn", "mx", "k3")
WIDTH = {"u8": 8, "i8": 8, "u16": 16, "i16": 16, "u32": 32, "i32": 32,
         "u64": 64, "i64": 64, "u128": 128, "i128": 128}


def edges(t):
    return _FLOAT_EDGES[t] if t in _FLOAT_EDGES else _INT_EDGES[WIDTH[t]]


for _t in list(_FLOAT_EDGES) + list(WIDTH):
    _have = dict(edges(_t))
    _miss = [k for k in _REQUIRED if k not in _have]
    assert not _miss, f"edge-value contract broken for {_t}: missing {_miss}"


def arg(t, lit):
    return f"({FEEDER[t]} {lit})"


def pairs(t):
    """Curated 2-arg cases: each one targets a specific arm behaviour, not a grid."""
    e = dict(edges(t))
    out = [("z_z", e["z"], e["z"]), ("p1_z", e["p1"], e["z"]), ("z_p1", e["z"], e["p1"]),
           ("n1_p1", e["n1"], e["p1"]), ("mn_n1", e["mn"], e["n1"]),
           ("mx_p1", e["mx"], e["p1"]), ("mn_mx", e["mn"], e["mx"]), ("k3_p1", e["k3"], e["p1"])]
    if t in _FLOAT_EDGES:
        out += [("nan_k3", e["nan"], e["k3"]), ("k3_nan", e["k3"], e["nan"]),
                ("nan_nan", e["nan"], e["nan"]), ("inf_ninf", e["inf"], e["ninf"]),
                ("nz_z", e["nz"], e["z"]), ("mx_mx", e["mx"], e["mx"])]
    return out


src = open(PURE_RS).read()
rows = []
for m in re.finditer(r'^op!\((num|str)\s+(\w+)\s+(\w+)\s*\(([^)]*)\)', src, re.M):
    kind, arity, name, params = m.groups()
    # ⚠️ REQUIRE AN IDENTIFIER BEFORE THE COLON. A bare `:\s*(\w+)` scan also matches the `::` in a
    # `nary` arm's SEED EXPRESSION — `op!(num nary max_i8(i8::MIN, t: i8, x: i8) => …)` yielded types
    # `['MIN','i8','i8']`, which the unfeedable-type guard then rejected. That silently dropped 14 ops
    # — and they were `min_/max_` × 7, i.e. PRECISELY the family that had drifted (D1). Caught only
    # because this script PRINTS its skip list; a silent `continue` would have shipped a widened
    # differential whose headline number omitted the most defect-prone ops in the file.
    types = [t for _, t in re.findall(r'(\w+)\s*:\s*([A-Za-z0-9_]+)', params)]
    rows.append((kind, arity, name, types))

# `from_string`/`to_string` arms declare their type as a generic `<T>`, not a param list.
for m in re.finditer(r'^op!\(num (from_string|to_string)\s+(\w+)<(\w+)>', src, re.M):
    which, name, t = m.groups()
    rows.append(("num", which, name, [t]))

cases_by_op, skipped = {}, []
for kind, arity, name, types in rows:
    if arity == "quaternary":                      # unreachable upstream at every arity
        skipped.append((name, "quaternary arm checks items!=3 then consumes 4"))
        continue
    if any(t not in FEEDER for t in types if t not in ("i8", "i16", "i32", "i64", "i128",
                                                       "u8", "u16", "u32", "u64", "u128",
                                                       "f32", "f64")):
        skipped.append((name, f"unfeedable types {types}"))
        continue

    cs = []
    if arity == "nulary":
        cs = [("a0", [])]

    elif arity == "unary":
        t = types[0]
        cs = [(tag, [arg(t, lit)]) for tag, lit in edges(t)]

    elif arity == "binary":
        tx, ty = types[0], types[1]
        if name.endswith("_shl") or name.endswith("_shr"):
            # y is u32 at EVERY operand width. checked_shl returns None once y >= BITS, so
            # shift==width and width+1 are the cases that separate a checked shift from Julia's
            # total `<<`. THIS is the pair the old single-point probe could not see.
            w = WIDTH[tx]
            cs = [(f"sh{s}", [arg(tx, "-1"), arg("i32", str(s))])
                  for s in (0, 1, w - 1, w, w + 1)]
            cs += [(f"k3_sh{s}", [arg(tx, "3"), arg("i32", str(s))]) for s in (1, w)]
        elif name.startswith("pow_"):
            # exponent is cast `as u32` BEFORE the call, so a negative one wraps rather than
            # raising. Only a negative exponent shows that.
            cs = [(f"e{tag}", [arg(tx, "3"), arg(ty, lit)])
                  for tag, lit in [("z", "0"), ("p1", "1"), ("p2", "2"), ("n1", "-1"),
                                   ("mn", dict(edges(ty))["mn"])]]
        elif name.startswith("powi_"):
            cs = [(f"e{e}", [arg(tx, "1.1"), arg("i32", e)])
                  for e in ("0", "1", "-1", "2", "10", "-2147483648")]
        elif name.startswith("mod_"):
            # `mod_i*` has TWO abort cases, not one. Upstream's `x % y` is BARE (pure.rs:493/521/
            # 549/577/605), so BOTH of Rust's division traps fire as process aborts:
            #   * divisor 0
            #   * typemin % -1 — division OVERFLOW, which rustc checks even in RELEASE because the
            #     LLVM instruction is UB otherwise
            # MEASURED: excluding only divisor 0 still aborted all five `mod_i*` probes. `div_i*` is
            # `checked_div` and returns Err for both, which is why it survives — the asymmetry
            # recorded in CODEMAP as an upstream bug is WIDER than the divisor-0 case it names.
            mn = dict(edges(tx))["mn"]
            cs = [(tag, [arg(tx, a), arg(ty, b)]) for tag, a, b in pairs(tx)
                  if b != "0" and not (a == mn and b == "-1")]
        else:
            cs = [(tag, [arg(tx, a), arg(ty, b)]) for tag, a, b in pairs(tx)]

    elif arity == "ternary":
        t = types[0]
        e = dict(edges(t))
        # clamp asserts lo <= hi, so only ORDERED ranges (an inverted one aborts the process).
        trip = [("lo", e["mn"], e["z"], e["mx"]), ("in", e["k3"], e["z"], e["mx"]),
                ("hi", e["mx"], e["mn"], e["z"]), ("eq", e["p1"], e["p1"], e["p1"]),
                ("atlo", e["z"], e["z"], e["mx"]), ("athi", e["mx"], e["mn"], e["mx"])]
        if t in _FLOAT_EDGES:
            trip += [("nanx", e["nan"], e["z"], e["p1"]), ("nzlo", e["nz"], e["nz"], e["p1"])]
        cs = [(tag, [arg(t, x), arg(t, lo), arg(t, hi)]) for tag, x, lo, hi in trip]

    elif arity == "nary":
        # THE BLIND SPOT. The arm folds over EVERY consumed item from a CONSTANT seed and emits NO
        # arity check: 0 args must emit the seed, N args must fold all N. The old probe fed exactly
        # two, so 28 ops that ignored args 3+ and threw on 0 read as AGREEING.
        t = types[-1]
        e = dict(edges(t))
        cs = [("a0", []),
              ("a1", [arg(t, e["k3"])]),
              ("a2", [arg(t, e["p1"]), arg(t, e["k3"])]),
              ("a3", [arg(t, e["p1"]), arg(t, e["k3"]), arg(t, e["mx"])]),
              ("a4", [arg(t, e["mn"]), arg(t, e["p1"]), arg(t, e["k3"]), arg(t, e["mx"])]),
              ("a3n", [arg(t, e["n1"]), arg(t, e["mn"]), arg(t, e["mx"])])]
        if t in _FLOAT_EDGES:
            # Rust's f*::max/min IGNORE NaN; Julia's propagate. Only a NaN element shows it, and its
            # POSITION matters (first vs middle) because the fold is sequential.
            cs += [("nan1", [arg(t, e["nan"]), arg(t, e["k3"])]),
                   ("nan2", [arg(t, e["k3"]), arg(t, e["nan"])]),
                   ("nan3", [arg(t, e["k3"]), arg(t, e["nan"]), arg(t, e["p1"])]),
                   ("infs", [arg(t, e["inf"]), arg(t, e["ninf"])]),
                   ("zs", [arg(t, e["nz"]), arg(t, e["z"])])]

    elif arity == "to_string":
        t = types[0]
        cs = [(tag, [arg(t, lit)]) for tag, lit in edges(t)]
        if t in _FLOAT_EDGES:                      # Debug `{:?}` switches notation at 1e-4 / 1e16
            cs += [("e16", [arg(t, "1e16")]), ("e15", [arg(t, "1e15")]),
                   ("em4", [arg(t, "1e-4")]), ("em5", [arg(t, "1e-5")]),
                   ("i61", [arg(t, "61")])]

    elif arity == "from_string":
        # The ARGUMENT is a bare symbol, not a fed value: this probes the PARSER's grammar. Rust is
        # `[+-]?[0-9]+` for integers; Julia's `parse` also accepts 0x/0b/0o prefixes.
        lits = ["0", "1", "-1", "+5", "007", "0x10", "0b101", "0o17", "1_000", "5abc", "abc"]
        if types[0] in _FLOAT_EDGES:
            lits = ["0", "-0", "1", "-1", "2.5", "1e3", "1E3", "NaN", "nan", "inf", "-inf",
                    "infinity", "Infinity", ".5", "5.", "0x10", "1_0", "abc"]
        cs = [(f"s{i}", [lit]) for i, lit in enumerate(lits)]

    if cs:
        cases_by_op[name] = cs

os.makedirs(OUT, exist_ok=True)
for f in os.listdir(OUT):
    if f.endswith((".mm2", ".raw")):
        os.remove(os.path.join(OUT, f))

total = 0
for name, cs in sorted(cases_by_op.items()):
    lines = [f"; PURE OP probe — {name}, {len(cs)} input points.",
             "; Emits each result's RAW symbol: its BYTE LENGTH is the result width.",
             "; Generated by gen_pure_probes.py from upstream kernel/src/pure.rs.",
             "(n 1)"]
    for tag, args in cs:
        body = f"({name} {' '.join(args)})" if args else f"({name})"
        lines.append(f"(exec 0 (, (n $x))\n  (O (pure ({name}__{tag} $r) $r {body}))\n)")
    with open(os.path.join(OUT, f"op_{name}.mm2"), "w") as fh:
        fh.write("\n".join(lines) + "\n")
    total += len(cs)

print(f"{len(cases_by_op)} ops, {total} input points, one file per op -> {OUT}")
print(f"skipped {len(skipped)}:")
for n, why in skipped[:8]:
    print(f"    {n}: {why}")
if len(skipped) > 8:
    print(f"    ... and {len(skipped) - 8} more")
