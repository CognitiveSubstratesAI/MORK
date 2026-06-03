# tools/verify_upstream.jl — diff Julia port output against upstream main.rs tests
#
# Usage (from warm REPL):
#   include("tools/verify_upstream.jl")
#
# For each upstream test case, runs both our Julia port and records
# whether the expected output is present. Any divergence is flagged.
#
# The upstream test cases come directly from kernel/src/main.rs.

using MORK

function mc_check(src::String, expected_pattern, cap::Int=100_000)
    s = new_space()
    space_add_all_sexpr!(s, src)
    steps = space_metta_calculus!(s, cap)
    result = space_dump_all_sexpr(s)
    terminated = steps < cap
    matched = if expected_pattern isa Regex
        occursin(expected_pattern, result)
    else
        occursin(expected_pattern, result)
    end
    (terminated=terminated, matched=matched, steps=steps, result=result)
end

# All test cases from upstream kernel/src/main.rs
const UPSTREAM_TESTS = [
    ("lookup",
        "(exec 0 (, (Something (very specific))) (, MATCHED))\n(Something (very specific))\n",
        "MATCHED"),
    ("positive",
        "(exec 0 (, (Something \$unspecific)) (, MATCHED))\n(Something (very specific))\n",
        "MATCHED"),
    ("positive_equal",
        "(exec 0 (, (Something \$r \$r)) (, MATCHED))\n(Something (very specific) (very specific))\n",
        "MATCHED"),
    ("negative",
        "(exec 0 (, (Something (very specific))) (, MATCHED))\n(Something \$unspecific)\n",
        "MATCHED"),
    ("negative_equal",
        "(exec 0 (, (Something (very specific) (very specific))) (, MATCHED))\n(Something \$rep \$rep)\n",
        "MATCHED"),
    ("bipolar",
        "(exec 0 (, (Something (very \$u))) (, MATCHED))\n(Something (\$u specific))\n",
        "MATCHED"), ("top_level",
        "(exec 0 (, foo) (, bar))\nfoo\n",
        "bar"),
    ("two_positive_equal",
        "(exec 0 (, (Something \$x \$x) (Else \$y \$y)) (, MATCHED))\n(Something (foo bar) (foo bar))\n(Else (bar baz) (bar baz))\n",
        "MATCHED"),
    ("two_positive_equal_crossed",
        "(exec 0 (, (Something \$x \$y) (Else \$x \$y)) (, MATCHED))\n(Something (foo bar) (bar baz))\n(Else (foo bar) (bar baz))\n",
        "MATCHED"),
    ("two_bipolar_equal_crossed",
        "(exec 0 (, (Something \$x \$y) (Else \$x \$y)) (, (MATCHED \$x \$y)))\n" *
        "(Something (foo \$x) (foo \$x))\n(Else (\$x bar) (\$x bar))\n",
        "(MATCHED (foo bar) (foo bar))"), ("variable_priority",
        "(A Z)\n(exec \$p (, (A \$x)) (, (B \$x)))\n",
        "(B Z)"),
    ("variables_in_priority",
        "(A Z)\n(exec (0 \$p) (, (A \$x)) (, (B \$x)))\n",
        "(B Z)"),
    ("func_type_unification",
        "(a (: \$a A))\n(b (: f (-> A)))\n" *
        "(exec 0 (, (a (: (\$f) A)) (b (: \$f (-> A)))) (, (c OK)))\n",
        "(c OK)"),
    ("issue_43",
        "(data (0 1))\n(l \$a \$a)\n(((. \$a) \$a) lp 0 1)\n" *
        "(exec 2 (, (((. (lp \$a)) \$a) lp 0 1)) (, T))\n",
        x -> !occursin("\nT\n", x))   # negative assertion
]

pass = 0;
fail = 0;
loop = 0;
crash = 0
println("\n=== Upstream verification ($(length(UPSTREAM_TESTS)) tests) ===\n")
for (name, src, expected) in UPSTREAM_TESTS
    local r
    try
        r = mc_check(src, expected isa Function ? "." : expected)
    catch e
        println("CRASH $name  ($(typeof(e)): $(sprint(showerror, e)))")
        global crash += 1
        continue
    end
    if !r.terminated
        println("LOOP  $name  (hit $(r.steps)-step cap — infinite loop)")
        global loop += 1
    elseif (expected isa Function ? expected(r.result) : r.matched)
        println("PASS  $name  ($(r.steps) steps)")
        global pass += 1
    else
        println("FAIL  $name  ($(r.steps) steps)")
        println("      got: $(repr(r.result[1:min(80,end)]))")
        global fail += 1
    end
end

println("\n$(pass) passed  $(fail) failed  $(loop) loops  $(crash) crashes")
println(loop > 0 ? "⚠ Infinite loops detected" : "")
println(fail > 0 ? "⚠ Output diverges from upstream" : "")
println(crash > 0 ? "⚠ Crashes — unhandled errors in metta_calculus" : "")
(pass == length(UPSTREAM_TESTS)) && println("✓ All upstream tests match")
pass == length(UPSTREAM_TESTS) && println("\n✓ All upstream tests match")
