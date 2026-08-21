#!/usr/bin/env python3
"""Flag UNESCAPED `$` inside Julia docstrings under src/ — they INTERPOLATE and break precompile.

WHY A LOCAL GREP AND NOT `Core/bin/health`'s LINT. Core has one, and running it from here would be
the "correct shared" fix — but it couples two repos for a defect whose local form is thirty lines.
FOURTH OCCURRENCE (2026-08-21: `(data $w)`, `(rel $w)`, `(e $u $u)`, `(pair $x $x)`), each costing a
precompile failure and, twice, a ~2min rebuild. Past that count the cheap local version wins.

A `$x` in a docstring is not documentation — Julia evaluates it, so an undefined `x` is
`UndefVarError` AT MODULE LOAD. MeTTa docs are full of `$var`, which is exactly why this repo keeps
hitting it. Escape as `\\$x`.

Escape hatch: `# allow-docstring-interp: <reason>` anywhere in the file (for deliberate
`$(...)` splices).
"""
import re, sys, pathlib

# ⚠️ BARE `$name` ONLY — NOT `$(EXPR)`. The accident is always a MeTTa variable pasted into prose
# (`$w`, `$u`, `$x`); the deliberate form is a parenthesised splice, e.g. DyckZipper's "up to
# $(DYCK_MAX_LEAVES) leaves". A first version caught both and would have trained the next reader to
# add escape hatches.
# 🔴 THE EXEMPTION IS FOR SPLICES WHOSE BINDING IS KNOWN-LIVE — NOT for parenthesised forms as such.
# `$(NOT_DEFINED)` in a docstring breaks precompile exactly as `$w` does and passes this lint. That
# hole is deliberate and narrow: closing it means resolving names at lint time, which is a type
# checker, not a grep. If a `$(...)` splice is added, confirm the name is defined at module load.
BAD = re.compile(r'(?<!\\)\$(?=[A-Za-z_])')
root = pathlib.Path(sys.argv[1] if len(sys.argv) > 1 else "src")
hits = []
for f in sorted(root.rglob("*.jl")):
    text = f.read_text(encoding="utf-8", errors="replace")
    if "# allow-docstring-interp:" in text:
        continue
    # Walk `"""` blocks. Docstrings are the ones IMMEDIATELY FOLLOWED by a definition, but any
    # triple-quoted string interpolates identically, so every block is checked — a false positive
    # here costs one escape, a false negative costs a load failure.
    inside, start = False, 0
    for i, line in enumerate(text.splitlines(), 1):
        for _ in range(line.count('"""')):
            inside = not inside
            if inside:
                start = i
        if inside or '"""' in line:
            for m in BAD.finditer(line):
                # a `$` inside a line that is itself the opening/closing fence still interpolates
                hits.append((f, i, line.strip()[:100]))
                break

if hits:
    print("🔴 UNESCAPED `$` IN A DOCSTRING — this INTERPOLATES and will break precompile:",
          file=sys.stderr)
    for f, i, line in hits:
        print(f"   {f}:{i}: {line}", file=sys.stderr)
    print("   Escape as \\$name, or add `# allow-docstring-interp: <reason>` to the file.",
          file=sys.stderr)
    sys.exit(1)
