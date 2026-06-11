#!/usr/bin/env python3
# Extract upstream main.rs test fixtures (input + contains-asserts) → a Julia fixtures file.
import re, subprocess, os, sys

MORK = os.path.expanduser("~/JuliaAGI/dev-zone/MORK")
src = subprocess.check_output(["git", "-C", MORK, "show", "main:kernel/src/main.rs"]).decode("utf-8", "replace")

# tests upstream comments out in main() (WIP / failing / known-faulty) — mark, don't treat as bugs
WIP = {"variable_priority", "variables_in_priority", "func_type_unification", "logic_query",
       "source_cmp_eq_var_constraint", "sink_hash_spaces", "bench_pattern_mining_lensy"}
# skip the heavy/benchmark/IO tests (huge inputs, file/perf, not engine conformance)
SKIP = {"bench_flybase", "bench_lr", "bench_tile_puzzle_states", "bench_pattern_mining_lensy",
        "bench_taxi_lts",
        "ip_sudoku", "meta_ana", "meta_ana_exec", "pattern_mining", "pattern_mining_lensy",
        "formula_execution", "process_calculus_reverse", "basic", "roman_disjoin_initial",
        "roman_disjoin_final", "source_map_oom",
        # heavy backward-chaining / lens — not quick conformance, run separately if needed:
        "bc0", "bc1", "bc2", "bc3", "lens_composition"}

# split into top-level functions: lines starting "fn NAME() {"
parts = re.split(r"(?m)^fn ([a-z_][a-z0-9_]*)\(\)\s*\{", src)
# parts = [pre, name1, body1, name2, body2, ...]
fixtures = []
for i in range(1, len(parts), 2):
    name = parts[i]
    body = parts[i + 1]
    if name in SKIP:
        continue
    # input: the raw string r#" ... "#
    m = re.search(r'r#"(.*?)"#', body, re.DOTALL)
    if not m:
        continue
    inp = m.group(1).strip("\n")
    # asserts: uncommented assert!(res.contains("...."))  (string may span lines, may have escapes)
    asserts = []
    for am in re.finditer(r'assert!\(res\.contains\(\s*"((?:[^"\\]|\\.)*)"\s*\)', body):
        # skip if this assert line is commented out
        line_start = body.rfind("\n", 0, am.start()) + 1
        if body[line_start:am.start()].lstrip().startswith("//"):
            continue
        raw = am.group(1)
        # unescape Rust string escapes → actual value
        val = raw.replace("\\n", "\n").replace("\\t", "\t").replace('\\"', '"').replace("\\\\", "\\")
        asserts.append(val)
    if not asserts:
        continue
    fixtures.append((name, inp, asserts, name in WIP))

def jl(s):
    s = s.replace("\\", "\\\\").replace('"', '\\"').replace("$", "\\$").replace("\n", "\\n").replace("\t", "\\t")
    return '"' + s + '"'

out = ["# Auto-extracted from upstream kernel/src/main.rs (git main) — regenerate via",
       "# /tmp/extract_fixtures.py. Each: (name, input, contains-asserts, wip?).",
       "const MAIN_RS_FIXTURES = ["]
for name, inp, asserts, wip in fixtures:
    al = ", ".join(jl(a) for a in asserts)
    out.append(f'    (name = "{name}", input = {jl(inp)}, asserts = [{al}], wip = {str(wip).lower()}),')
out.append("]")
open(sys.argv[1], "w").write("\n".join(out) + "\n")
print(f"Extracted {len(fixtures)} fixtures → {sys.argv[1]}")
for name, inp, asserts, wip in fixtures:
    print(f"  {'[wip] ' if wip else '      '}{name}: {len(asserts)} assert(s)")
