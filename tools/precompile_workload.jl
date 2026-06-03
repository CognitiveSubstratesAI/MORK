# tools/precompile_workload.jl — execution trace for PackageCompiler sysimage
# Uses only fast-terminating ground tests to trace-compile hot paths.

using MORK

# Single source — ground lookup
let s = new_space()
    space_add_all_sexpr!(
        s, "(exec 0 (, (Something specific)) (, MATCHED))\n(Something specific)\n"
    )
    space_metta_calculus!(s, 100)
    space_dump_all_sexpr(s)
end

# Single source — variable pattern, ground fact
let s = new_space()
    space_add_all_sexpr!(s, "(exec 0 (, (Something \$x)) (, MATCHED))\n(Something ok)\n")
    space_metta_calculus!(s, 100)
    space_dump_all_sexpr(s)
end

# Two source — ground facts
let s = new_space()
    space_add_all_sexpr!(s, "(exec 0 (, (A foo) (B foo)) (, (C foo)))\n(A foo)\n(B foo)\n")
    space_metta_calculus!(s, 100)
    space_dump_all_sexpr(s)
end

# Two source — variable, ground facts
let s = new_space()
    space_add_all_sexpr!(s, "(exec 0 (, (A \$x) (B \$x)) (, (C \$x)))\n(A foo)\n(B foo)\n")
    space_metta_calculus!(s, 100)
    space_dump_all_sexpr(s)
end

# Top-level match
let s = new_space()
    space_add_all_sexpr!(s, "(exec 0 (, foo) (, bar))\nfoo\n")
    space_metta_calculus!(s, 100)
    space_dump_all_sexpr(s)
end
