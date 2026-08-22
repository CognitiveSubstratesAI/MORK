#!/usr/bin/env julia
# tools/repl.jl — development REPL
#
# Interactive (recommended — hot-reload, full REPL features):
#   julia --project=. -i tools/repl.jl
#
# Scripted / CI — USE THE RUNNER, it is the only form that can fail:
#   tools/run_tests.sh              # whole suite, exits 0 green / 1 red
#   tools/run_tests.sh path/to.jl   # one file
#
# DO NOT test via the two forms this header advertised until 2026-07-23. Both report success
# unconditionally:
#   printf 'include("test/runtests.jl")\n' | julia --project=. tools/repl.jl     # NEVER RAN THEM —
#       without `-i`, julia executes the script argument and never reads stdin, so the piped
#       `include` is silently discarded. Measured: 0 output lines, 0 test summaries, exit 0.
#   printf 'include("test/runtests.jl");exit()\n' | julia --project=. -i tools/repl.jl   # ALWAYS 0 —
#       `-i` with piped stdin is interactive, and interactive mode SWALLOWS exceptions; the throw
#       prints, the REPL continues, `exit()` returns 0. A failing testset exits 0 this way and 1
#       under plain `julia file.jl`. This is how `upstream_conformance.jl` — our ONLY differential
#       check against the built Rust binary — sat ERRORING on every run unnoticed (c543841): the
#       `run` shortcut defined below SHADOWS `Base.run`, and nothing propagated the failure.
#
# For ITERATION (not verification) the warm interactive REPL above is still right — NEVER cold-start
# julia per probe; each restart costs ~60-90s JIT warmup.

try
    using Revise
catch
end

using MORK
using PathMaps

# ── Shortcuts ─────────────────────────────────────────────────────────────────

# Run the full test suite
t(path=joinpath(@__DIR__, "..", "test", "runtests.jl")) = include(path)

# Evaluate MeTTa in a fresh space; return the dump string
function run(src::AbstractString, steps::Int=999_999)
    s = new_space()
    space_add_all_sexpr!(s, src)
    space_metta_calculus!(s, steps)
    space_dump_all_sexpr(s)
end

# Quick s-expression count in a space
count_atoms(src::AbstractString) = begin
    s = new_space()
    space_add_all_sexpr!(s, src)
    space_val_count(s)
end

if isinteractive()
    println("MORK v", MORK.version(), " loaded.")
    println("  t()            — run full test suite")
    println("  run(src)       — eval MeTTa, return dump")
    println("  count_atoms(s) — count atoms in expression string")
end
