#!/usr/bin/env julia
# tools/viz_benchmarks.jl — MORK benchmark visualization
#
# Ports the Python pipeline from upstream kernel/bench_scripts/:
#   parse_mork_bench.py  → collect timing samples
#   render_plots.py      → distribution plots with color gradient
#   transpose_csv.py     → CSV export
#
# Usage (from packages/MORK/):
#   julia --project=benchmark tools/viz_benchmarks.jl
#   julia --project=benchmark tools/viz_benchmarks.jl --csv results.csv
#   julia --project=benchmark tools/viz_benchmarks.jl --suite canonical
#   julia --project=benchmark tools/viz_benchmarks.jl --suite both
#
# Produces terminal distribution plots (UnicodePlots) plus optional CSV export.

using BenchmarkTools
using UnicodePlots
using Statistics
using MORK

# ── CLI args ──────────────────────────────────────────────────────────────────
const ARGS_MAP = Dict{String, String}()
let i = 1
    while i <= length(ARGS)
        if ARGS[i] in ("--csv", "--suite") && i < length(ARGS)
            ARGS_MAP[ARGS[i]] = ARGS[i + 1];
            i += 2
        else
            i += 1
        end
    end
end
const SUITE_NAME = get(ARGS_MAP, "--suite", "standard")
const CSV_PATH = get(ARGS_MAP, "--csv", "")

# ── Load suite definitions ────────────────────────────────────────────────────
include(joinpath(@__DIR__, "..", "benchmark", "benchmarks.jl"))

if SUITE_NAME in ("canonical", "both")
    include(joinpath(@__DIR__, "..", "benchmark", "canonical_benchmarks.jl"))
end

# ── Run benchmarks and collect samples ───────────────────────────────────────
function collect_samples(suite::BenchmarkGroup, n_samples::Int=7)
    println("Tuning...")
    tune!(suite)
    println("Collecting $n_samples samples per benchmark...")
    results = run(suite; verbose=true, samples=n_samples, seconds=60)
    results
end

active_suite = if SUITE_NAME == "canonical"
    SUITE_CANONICAL
elseif SUITE_NAME == "both"
    merge(SUITE, SUITE_CANONICAL)
else
    SUITE
end

results = collect_samples(active_suite)

# ── Extract flat list of (label, samples_ns) ─────────────────────────────────
function flatten_results(results::BenchmarkGroup, prefix::String="")
    flat = Tuple{String, Vector{Float64}}[]
    for (name, val) in sort(collect(results); by=first)
        full = isempty(prefix) ? name : "$prefix/$name"
        if val isa BenchmarkGroup
            append!(flat, flatten_results(val, full))
        elseif val isa BenchmarkTools.BenchmarkResults
            times_ms = val.times ./ 1e6   # ns → ms
            push!(flat, (full, times_ms))
        end
    end
    flat
end

flat = flatten_results(results)

# ── Distribution plots (mirrors render_plots.py) ─────────────────────────────
#
# Upstream render_plots.py renders a horizontal scatter plot where each point
# is colored by its distance from the mean (z-score → alpha gradient).
# UnicodePlots equivalent: boxplot + dot plot side by side.

println("\n" * "═"^70)
println("  MORK Benchmark Distribution Plots")
println("═"^70)

for (label, samples) in flat
    n = length(samples)
    n < 2 && continue

    mu = mean(samples)
    med = median(samples)
    sd = std(samples)
    mn = minimum(samples)
    mx = maximum(samples)

    # Normalise to sensible unit
    unit, scale = if mu < 1.0
        "μs", 1e3
    elseif mu < 1000.0
        "ms", 1.0
    else
        "s", 1e-3
    end

    s = samples .* scale
    mu_s = mu * scale
    med_s = med * scale
    sd_s = sd * scale

    println("\n── $label ──")
    println(
        "  n=$n  median=$(round(med_s,digits=2)) $unit  mean=$(round(mu_s,digits=2)) $unit  σ=$(round(sd_s,digits=2)) $unit  range=[$(round(mn*scale,digits=2)), $(round(mx*scale,digits=2))]"
    )

    # Dot plot: samples as x, jittered y
    # Color each point by z-score distance: close to mean = bright, far = dim
    z_scores = abs.((samples .- mu) ./ max(sd, 1e-12))
    # Map z_scores → symbols (low z = dense dot, high z = sparse)
    dot_chars = ['●', '◉', '◎', '○', '·']
    dot_syms = [dot_chars[clamp(Int(floor(z * 2)) + 1, 1, 5)] for z in z_scores]

    # UnicodePlots histogram — distribution shape
    nbins = max(3, min(10, n))
    plt = histogram(s; nbins=nbins,
        title="$label",
        xlabel="Time ($unit)",
        ylabel="count",
        width=50, height=5)
    println(plt)

    # Annotated sample list (mirrors the colored scatter dots)
    sorted_idx = sortperm(samples)
    print("  samples: ")
    for i in sorted_idx
        z = z_scores[i]
        sym = dot_chars[clamp(Int(floor(z * 2)) + 1, 1, 5)]
        print("$sym$(round(samples[i]*scale, digits=1))")
        i != sorted_idx[end] && print(" ")
    end
    println()
end

# ── Summary table ─────────────────────────────────────────────────────────────
println("\n" * "═"^70)
println("  Summary Table")
println("═"^70)
println(rpad("Benchmark", 38), rpad("Median", 12), rpad("Mean", 12), "σ")
println("─"^70)
for (label, samples) in flat
    length(samples) < 1 && continue
    mu = mean(samples)
    med = median(samples)
    sd = std(samples)
    unit, scale = if mu < 1.0
        ("μs", 1e3)
    elseif mu < 1000.0
        ("ms", 1.0)
    else
        ("s", 1e-3)
    end
    fmt(x) = "$(round(x*scale, digits=1)) $unit"
    println(rpad(label, 38), rpad(fmt(med), 12), rpad(fmt(mu), 12), fmt(sd))
end

# ── CSV export (mirrors transpose_csv.py output) ──────────────────────────────
if !isempty(CSV_PATH)
    open(CSV_PATH, "w") do io
        # Header: benchmark names
        println(io, join(first.(flat), ","))
        # Rows: one row per sample index
        max_n = maximum(length(s) for (_, s) in flat)
        for i in 1:max_n
            row = [i <= length(s) ? string(round(s[i]; digits=4)) : "" for (_, s) in flat]
            println(io, join(row, ","))
        end
    end
    println("\nCSV written to: $CSV_PATH")
    println(
        "  $(length(flat)) benchmarks × up to $(maximum(length(s) for (_,s) in flat)) samples"
    )
end
