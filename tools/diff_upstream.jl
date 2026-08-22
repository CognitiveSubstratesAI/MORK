# tools/diff_upstream.jl — differential testing against upstream Rust MORK
#
# Two modes:
#   1. RECORD mode: run Julia port, save outputs as golden fixtures
#   2. DIFF mode:   compare current Julia output against fixtures
#      If Rust MORK binary is available, also diff against live Rust output.
#
# Usage (from warm REPL):
#   include("tools/diff_upstream.jl")          # diff mode (default)
#   include("tools/diff_upstream.jl"); record_fixtures()  # update fixtures

using MORK

const FIXTURE_FILE = joinpath(@__DIR__, "upstream_fixtures.jl")

# Canonical test inputs from upstream kernel/src/main.rs
const UPSTREAM_INPUTS = [
    (
        "lookup",
        "(exec 0 (, (Something (very specific))) (, MATCHED))\n(Something (very specific))\n"
    ),
    (
        "positive",
        "(exec 0 (, (Something \$unspecific)) (, MATCHED))\n(Something (very specific))\n"
    ),
    (
        "positive_equal",
        "(exec 0 (, (Something \$r \$r)) (, MATCHED))\n(Something (very specific) (very specific))\n"
    ),
    (
        "negative",
        "(exec 0 (, (Something (very specific))) (, MATCHED))\n(Something \$unspecific)\n"
    ),
    (
        "negative_equal",
        "(exec 0 (, (Something (very specific) (very specific))) (, MATCHED))\n(Something \$rep \$rep)\n"
    ),
    (
        "bipolar",
        "(exec 0 (, (Something (very \$u))) (, MATCHED))\n(Something (\$u specific))\n"
    ),
    ("top_level", "(exec 0 (, foo) (, bar))\nfoo\n"),
    (
        "two_positive_equal",
        "(exec 0 (, (Something \$x \$x) (Else \$y \$y)) (, MATCHED))\n(Something (foo bar) (foo bar))\n(Else (bar baz) (bar baz))\n"
    ),
    (
        "two_positive_equal_crossed",
        "(exec 0 (, (Something \$x \$y) (Else \$x \$y)) (, MATCHED))\n(Something (foo bar) (bar baz))\n(Else (foo bar) (bar baz))\n"
    ),
    (
        "two_bipolar_equal_crossed",
        "(exec 0 (, (Something \$x \$y) (Else \$x \$y)) (, (MATCHED \$x \$y)))\n(Something (foo \$x) (foo \$x))\n(Else (\$x bar) (\$x bar))\n"
    ),
    ("variable_priority", "(A Z)\n(exec \$p (, (A \$x)) (, (B \$x)))\n"),
    ("variables_in_priority", "(A Z)\n(exec (0 \$p) (, (A \$x)) (, (B \$x)))\n"),
    (
        "func_type_unification",
        "(a (: \$a A))\n(b (: f (-> A)))\n(exec 0 (, (a (: (\$f) A)) (b (: \$f (-> A)))) (, (c OK)))\n"
    ),
    (
        "issue_43",
        "(data (0 1))\n(l \$a \$a)\n(((. \$a) \$a) lp 0 1)\n(exec 2 (, (((. (lp \$a)) \$a) lp 0 1)) (, T))\n"
    )
]

function run_julia(src::String, cap::Int=100_000)
    s = new_space()
    space_add_all_sexpr!(s, src)
    steps = space_metta_calculus!(s, cap)
    (steps=steps, result=space_dump_all_sexpr(s), terminated=steps<cap)
end

function record_fixtures()
    open(FIXTURE_FILE, "w") do f
        println(f, "# Auto-generated upstream fixtures — do not edit manually")
        println(f, "# Regenerate with: record_fixtures() in tools/diff_upstream.jl")
        println(f, "const UPSTREAM_FIXTURES = Dict{String,String}(")
        for (name, src) in UPSTREAM_INPUTS
            r = run_julia(src)
            println(f, "  $(repr(name)) => $(repr(r.result)),")
        end
        println(f, ")")
    end
    println("Fixtures written to $FIXTURE_FILE")
end

function diff_upstream(; rust_bin::String="")
    if !isfile(FIXTURE_FILE)
        println("No fixtures found — run record_fixtures() first, then verify manually.")
        return nothing
    end
    include(FIXTURE_FILE)

    pass = 0
    fail = 0
    crash = 0
    println("\n=== Differential test (Julia vs recorded fixtures) ===\n")

    for (name, src) in UPSTREAM_INPUTS
        local r
        try
            r = run_julia(src)
        catch e
            println("CRASH $name  ($(typeof(e)): $(sprint(showerror, e)))")
            crash += 1
            continue
        end
        expected = get(UPSTREAM_FIXTURES, name, nothing)
        if expected === nothing
            println("MISS  $name  (not in fixtures)")
        elseif r.result == expected
            println("PASS  $name")
            pass += 1
        else
            println("FAIL  $name")
            println("  expected: $(repr(expected[1:min(80,end)]))")
            println("  got:      $(repr(r.result[1:min(80,end)]))")
            fail += 1
        end
    end

    # Optional: diff against live Rust binary (requires cargo build --release)
    if !isempty(rust_bin) && isfile(rust_bin)
        println("\n=== Differential test (Julia vs live Rust binary) ===\n")
        for (name, src) in UPSTREAM_INPUTS
            input_file = tempname()
            write(input_file, src)
            rust_out = read(pipeline(`$rust_bin`; stdin=input_file), String)
            rm(input_file)
            julia_out = run_julia(src).result
            println(julia_out == rust_out ? "MATCH $name" : "DIFF  $name")
        end
    else
        println(
            "\n(Tip: install Rust and build: cd ~/JuliaAGI/dev-zone/MORK && cargo build --release"
        )
        println(
            "      Then: diff_upstream(rust_bin=\"~/JuliaAGI/dev-zone/MORK/target/release/kernel\")"
        )
    end

    println("\n$(pass) match  $(fail) differ  $(crash) crashes")
end

# Run diff by default when included
diff_upstream()
