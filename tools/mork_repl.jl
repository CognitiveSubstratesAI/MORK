#!/usr/bin/env julia
# tools/mork_repl.jl — MORK development REPL
#
# Interactive (recommended — hot-reload + full REPL):
#   julia --project=. -i tools/mork_repl.jl
#
# Scripted (agent/CI — pipe one expression per line):
#   echo 'include("/tmp/test.jl")' | julia --project=. tools/mork_repl.jl

# Revise: optional hot-reload — src/ changes reload without restarting
try
    ;
    using Revise;
catch
    ;
end

using MORK

mc(src, n=999_999) = (
    s=new_space();
    space_add_all_sexpr!(s, src);
    space_metta_calculus!(s, n);
    space_dump_all_sexpr(s)
)
t(path=joinpath(@__DIR__, "..", "test", "runtests.jl")) = include(path)

if isinteractive()
    println("MORK v", MORK.version(), " loaded.")
    println("  t()            — run full test suite")
    println("  t(\"path\")      — run specific test file")
    println("  mc(src)        — eval s-expr through metta_calculus")
    println("  Ctrl-D         — quit")
else
    local failed = false
    for line in eachline(stdin)
        isempty(strip(line)) && continue
        try
            result = eval(Meta.parse(line))
            result !== nothing && println(result)
        catch e
            println("ERROR: ", e)
            failed = true
        end
    end
    exit(failed ? 1 : 0)
end
