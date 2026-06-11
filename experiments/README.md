# MORK experiments — differential & benchmark tracing

Traceable experiment scripts and their **committed results**, so divergences and performance
can be tracked over time. This complements (does not replace) `test/` (CI unit/integration) and
`tools/` (the reusable harnesses).

## Layout

```
experiments/
  upstream_diff/        # differential testing vs upstream Rust MORK (behavioral parity)
    run.jl              # runs the fixtures through the Julia port, writes a dated result file
    data_in_mork.jl     # fixtures from the Data-in-MORK wiki (storage/query/transform patterns)
    results/            # committed, dated result files — the trace
  benchmarks/           # performance tracing
    run.jl              # runs benchmark/ workloads, writes a dated result file
    results/            # committed, dated benchmark numbers — the trace
```

## Why this exists

A port can mirror upstream's structure and still drift behaviorally (e.g. `SumSink` read/wrote
binary-BE while upstream uses decimal-string — caught 2026-06-11 only by reading `sinks.rs`).
Differential testing against upstream behavior is the systematic way to catch such divergences.
The reusable engine is `tools/diff_upstream.jl` (RECORD/DIFF modes); these scripts drive it and
**persist the results** so a regression or a newly-discovered divergence is traceable to a date.

## How to run (warm REPL — never cold-start)

```bash
cd ~/code/CognitiveSubstratesAI/MORK
printf 'include("experiments/upstream_diff/run.jl"); exit()\n' | julia --project=. -i tools/repl.jl
printf 'include("experiments/benchmarks/run.jl");   exit()\n' | julia --project=. -i tools/repl.jl
```

(Background Julia + polling is hook-blocked; foreground synchronous only.)

## Results convention

Each run writes `results/<YYYY-MM-DD>_<kind>.md` and commits it. A run never overwrites a prior
date's file silently — the directory is the audit trail. The headline line (`N PASS / M FAIL`)
makes regressions greppable across dates.

## Differential against the LIVE Rust binary (optional, strongest)

`diff_upstream.jl` can also diff against a compiled upstream kernel:
`cargo build --release` in `~/JuliaAGI/dev-zone/MORK`, then pass `rust_bin=…`. The committed
fixtures are the golden outputs when the live binary isn't built.
