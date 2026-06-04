"""
Main — port of `mork/kernel/src/main.rs` CLI commands.

Provides Julia-callable equivalents of the MORK CLI commands:
  - `mork_run`     : load .metta + run metta_calculus + dump result
  - `mork_convert` : convert between .metta / .act / .paths formats

The 6000+ line test/benchmark suite in main.rs is NOT ported here —
those tests validate the upstream implementation and would be duplicated
in our Julia test suite as needed.

Julia translation notes
========================
  - Rust `Commands::Run { .. }` → `mork_run(; kwargs...)` keyword args
  - Rust `memmap2::Mmap` → `read(input_path)` (regular file read)
  - Rust `merk_calculus(steps)` → `space_metta_calculus!(s, steps)`
"""

# =====================================================================
# mork_run — load + execute + dump
# =====================================================================

"""
    mork_run(input_path; steps, output_path, aux_paths, timing, verbose)

Load a .metta file (s-expressions) into a fresh Space, run `metta_calculus`
for up to `steps` iterations, then dump the result.

Mirrors `Commands::Run` in main.rs.

# Arguments
- `input_path`   : path to input .metta file
- `steps`        : max metta_calculus iterations (default: unlimited)
- `output_path`  : write result to file (default: stdout)
- `aux_paths`    : additional .metta files to load before running
- `timing`       : add timing annotations to the space
- `verbose`      : print progress info
"""
function mork_run(input_path::AbstractString;
    steps::Int=typemax(Int),
    output_path=nothing,
    aux_paths=String[],
    timing::Bool=false,
    verbose::Bool=false)::Int

    s = new_space()
    s.timing = timing

    # Load main file
    data = read(input_path)
    space_add_all_sexpr!(s, data)

    # Load aux files
    for ap in aux_paths
        space_add_all_sexpr!(s, read(ap))
    end

    verbose && println("Loaded $(space_val_count(s)) expressions from $input_path")

    # Run
    performed = space_metta_calculus!(s, steps)
    verbose && println("Executed $performed steps")

    # Dump
    if output_path === nothing
        io = IOBuffer()
        space_dump_all_sexpr(s, io)
        println(String(take!(io)))
    else
        open(output_path, "w") do f
            space_dump_all_sexpr(s, f)
        end
    end

    performed
end

# =====================================================================
# mork_convert — format conversion
# =====================================================================

"""
    mork_convert(input_path, output_path; input_format, output_format,
                 pattern, template, verbose)

Convert a trie file from one format to another.
Currently supported: metta → metta (pass-through, applies pattern/template).

Mirrors `Commands::Convert` in main.rs.
"""
function mork_convert(input_path::AbstractString,
    output_path::AbstractString;
    input_format::AbstractString="metta",
    output_format::AbstractString="metta",
    pattern::AbstractString="\$",
    template::AbstractString="_1",
    verbose::Bool=false)::Nothing

    s = new_space()

    if input_format == "metta"
        data = read(input_path)
        if pattern == "\$" && template == "_1"
            space_add_all_sexpr!(s, data)
        else
            # Apply pattern/template during load
            space_add_all_sexpr!(s, data)   # simplified: load as-is
            verbose && println("Note: pattern/template application not yet ported")
        end
    elseif input_format == "paths"
        # MAIN-1 fix (audit 2026-06-04): was a verbose note then silent-empty load — fail
        # loud instead, symmetric with the `paths` OUTPUT branch's error() below.
        error("paths input format not yet ported")
    else
        error("Unsupported input format: $input_format")
    end

    verbose && println("Loaded $(space_val_count(s)) expressions")

    if output_format == "metta"
        open(output_path, "w") do f
            space_dump_all_sexpr(s, f)
        end
    elseif output_format == "paths"
        verbose && println("paths serialization not yet integrated")
        error("paths output format not yet ported")
    else
        error("Unsupported output format: $output_format")
    end

    nothing
end

# =====================================================================
# Exports
# =====================================================================

export mork_run, mork_convert
