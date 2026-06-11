# MM2 corpus — robustness / differential testing

Runs the canonical **MM2_Structuring_Code** tutorial programs (Clarke Remy — see
[`SOURCE.md`](SOURCE.md)) through the Julia MORK port. These exercise predication,
sources/sinks, priority, control flow, recursion, set ops, fork/join and macros — paths the
small `main.rs` unit tests don't cover.

## Run
```
cd ~/code/CognitiveSubstratesAI/MORK
printf 'include("experiments/mm2_programs/run.jl"); exit()\n' | julia --project=. -i tools/repl.jl
```
`run.jl` runs each `programs/*.mm2` under a 10 000-step cap and writes a dated table to
`results/`. Status: **OK** (terminated) · **CAP** (hit the step cap) · **CRASH** (port error).

## Latest result — 2026-06-11
**32 OK · 2 CAP · 0 CRASH** of 34 — see [`results/2026-06-11_mm2_smoke.md`](results/2026-06-11_mm2_smoke.md).

The engine runs the entire corpus with **zero crashes**. The two CAPs:

| program | verdict |
|---|---|
| `Control_07_Recursive` | **expected** — a self-replicating quine `(exec 0 (, (exec 0 $p $t)) (, (exec 0 $p $t)))`; intentional infinite loop, the cap bounds it. |
| `Control_08_Halts_on_fail` | 🔴 **bug** — should fail-and-halt at `counter=Z` (~4 steps) but loops forever. Phantom conjunction matches; state-dependent. See [`findings/control_08_phantom_conjunction.md`](findings/control_08_phantom_conjunction.md). Repro: [`probe_control08.jl`](probe_control08.jl). |

## Layout
- `programs/` — 34 unmodified `.mm2` files from the upstream tutorial.
- `run.jl` — the smoke/robustness runner.
- `probe_control08.jl` — repro at the metta-calculus level (decrement vs fresh + binding dump).
- `diag_remove.jl` — read-only diagnostic: shows the `(-)` removal IS durable (`val_count`/`get_val_at`).
- `diag_pathmap.jl` — minimal substrate repro: add 2 / `remove_val_at!` 1 / conjunction still matches it.
- `findings/` — written-up divergences.
- `results/` — dated run tables.
