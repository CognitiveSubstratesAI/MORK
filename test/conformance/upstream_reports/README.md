# Upstream defect reports for `trueagi-io/MORK` — ready to submit

Five defects found while porting, each reduced to a minimal reproducer and confirmed by EXECUTION
against the built release binary (`mork run probe.mm2 probe.raw` — always to a FILE, since stdout
mangles the high bytes these ops emit). **Not yet filed**: `gh` is not installed on this machine.

Each file's first line is the issue TITLE; everything after the `---` is the BODY.

```bash
for f in mork-*.md; do
  gh issue create -R trueagi-io/MORK -t "$(head -1 $f)" -F <(tail -n +3 $f)
done
```

⚠️ The PathMap defects go to a DIFFERENT upstream — `Adam-Vandervorst/PathMap`, see
`PathMap/test/differential/upstream_reports/`.

## Ranked by severity

| | file | defect |
|---|---|---|
| silent corruption | `mork-2` | `encode_hex` emits a Rule-of-64-violating 64-byte symbol at 32 bytes in, ABORTS at 33 |
| silent corruption | `mork-5` | `load_jsonl` writes the line index untagged; the path parses as a 9-byte expression with the document outside its span |
| abort | `mork-1` | `mod_i*` aborts on a zero divisor and on `typemin % -1` |
| **comment, not a new issue** | `mork-135-comment` | **#135 already exists** — this adds an independent confirmation, the CAUSE (a scope mismatch at `sinks.rs:1165`, not a corruption), two verified predictions, and a candidate fix |
| wrong answer | `mork-3` | `'` (quote) rewinds the evaluation cursor by one item. ⚠️ **Folded into the #135 comment as a "possibly related" note** — file separately ONLY if the maintainer asks to split it out |
| wrong answer | `mork-4` | `unbind` emits its internal 255 sentinel as a `VarRef`, which cannot decode |

Full write-ups, including what we do instead and why, are in `../UPSTREAM_BUGS.md`.
