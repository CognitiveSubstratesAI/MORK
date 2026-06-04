#!/usr/bin/env julia
# tools/repl.jl — development REPL
#
# Interactive (recommended — hot-reload, full REPL features):
#   julia --project=. -i tools/repl.jl
#
# Scripted (pipe expressions):
#   printf 'include("test/runtests.jl")\n' | julia --project=. tools/repl.jl
#   printf 't()\n' | julia --project=. tools/repl.jl
#
# NEVER cold-start julia for iteration — each restart costs ~60-90s JIT warmup.

try
    using Revise
catch
end

using MORK
using PathMap

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
