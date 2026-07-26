# sink_and_sum_branches.jl — AndSink / SumSink three-branch conformance vs the upstream binary.
#
# Upstream's accumulating sinks (kernel/src/sinks.rs) are all ONE shape with THREE branches, dispatched
# per grouped context inside `finalize`:
#
#   1. SIZES fixed-literal   (sinks.rs:757-789 And / :867-898 Sum) — the <source> slot holds a LITERAL
#      symbol; walk `child_mask() & SIZES`, reduce the group, and emit the payload IFF the literal equals
#      the reduced value. A mismatch emits NOTHING (that asymmetry is what the *_miss probes below pin —
#      a port that always emitted would pass the positive cases).
#   2. NewVar ignored guard  (:791-798 / :900-907) — the <source> slot holds a bare NewVar; emit the path
#      minus that NewVar byte.
#   3. VarRef(k)             (:799-826 / :908-935) — the <source> slot is a backref into the result
#      template; reduce the group and splice the value in via `substitute_one_de_bruijn(k, value)`, which
#      substitutes AT INDEX k and RE-BASES every trailing de-Bruijn var.
#
# And vs Sum differ ONLY in (init, accumulate, encode): And = 0xFF / `&=` over the raw value byte /
# 1 raw byte; Sum = 0 / `+=` over the parsed decimal / decimal string.
#
# WHAT WAS WRONG (fixed 2026-07-26). Our two sinks had implemented COMPLEMENTARY HALVES of this port,
# and neither was complete:
#   * AndSink had only branch 3, and it was doubly wrong: it replaced the FIRST NewVar it met rather than
#     the one at index k (wrong slot), and it hand-rolled a byte-copy that left trailing VarRefs
#     un-rebased (dangling `_2`) — the very defect fixed in the PureSink the day before (ExprAlg.jl
#     `_expr_substitute_one_de_bruijn`). Branches 1 and 2 were absent, so a literal <source> slot made
#     `_and_parse_entry` bail and SILENTLY DROP every entry.
#   * SumSink had only branch 1; a variable <source> slot returned `nothing` and silently dropped.
#
# None of this was caught by the existing gate: `ip_sudoku_hard.mm2` is the only corpus fixture using an
# AND sink, and its shape `(and (cell $c $nv) $nv $i)` puts the substituted NewVar LAST with nothing
# trailing — the one case where the old and new code agree. Hence these probes.
#
# GROUND TRUTH: every expectation below was produced by running the program through the upstream release
# binary (`mork run <file>.mm2`, built 2026-07-25) and transcribing its dump. Upstream renders variables
# as `$a`/`$b`; we render a NewVar as `$` and a VarRef(i) as `_{i+1}` — so upstream `(r $a 1)` is our
# `(r $ 1)`, and upstream `(r 1 $a $a)` (a NewVar plus a backref to it) is our `(r 1 $ _1)`.
using MORK, Test

# (name, program, expected FULL sorted atom set as upstream produces it, branch under test)
const _SINK_BRANCH_PROBES = Tuple{String,String,Vector{String},String}[
    ("and/varref: substitute at index k, NOT the first NewVar",
     """
     (m k1 3)
     (m k2 5)
     (exec 0 (, (m \$k \$v)) (O (and (r \$p \$nv) \$nv \$v)))
     """,
     ["(m k1 3)", "(m k2 5)", "(r \$ 1)"],
     "branch 3 — the result template has TWO NewVars and <source> names the SECOND; 0x33 & 0x35 = 0x31 ('1')"),

    ("and/varref: re-base trailing de-Bruijn refs",
     """
     (m k1 3)
     (m k2 5)
     (exec 0 (, (m \$k \$v)) (O (and (r \$nv \$x \$x) \$nv \$v)))
     """,
     ["(m k1 3)", "(m k2 5)", "(r 1 \$ _1)"],
     "branch 3 — substituting at index 0 removes a binding, so the trailing coref must shift _2 -> _1"),

    ("and/sizes: fixed literal MATCHES the reduced value",
     """
     (m k1 3)
     (m k2 5)
     (exec 0 (, (m \$k \$v)) (O (and (ok) 1 \$v)))
     """,
     ["(m k1 3)", "(m k2 5)", "(ok)"],
     "branch 1 — literal '1' equals the AND, so the payload is emitted"),

    ("and/sizes: fixed literal MISMATCHES — emit nothing",
     """
     (m k1 3)
     (m k2 5)
     (exec 0 (, (m \$k \$v)) (O (and (nope) 9 \$v)))
     """,
     ["(m k1 3)", "(m k2 5)"],
     "branch 1 (negative) — discriminates a real guard from an unconditional emit"),

    ("and/newvar: ignored guard",
     """
     (m k1 3)
     (m k2 5)
     (exec 0 (, (m \$k \$v)) (O (and (ig) \$ig \$v)))
     """,
     ["(ig)", "(m k1 3)", "(m k2 5)"],
     "branch 2 — bare NewVar in <source>; emit the path minus that byte"),

    ("sum/varref: variable <source> is reduced and spliced",
     """
     (foo 1)
     (foo 2)
     (foo 3)
     (exec 0 (, (foo \$x)) (O (sum (total \$n) \$n \$x)))
     """,
     ["(foo 1)", "(foo 2)", "(foo 3)", "(total 6)"],
     "branch 3 — SumSink's missing half; 1+2+3 = 6"),

    ("sum/sizes: fixed literal MATCHES",
     """
     (foo 1)
     (foo 2)
     (foo 3)
     (exec 0 (, (foo \$x)) (O (sum (six) 6 \$x)))
     """,
     ["(foo 1)", "(foo 2)", "(foo 3)", "(six)"],
     "branch 1 — the one branch SumSink already had; guards against regressing it"),

    ("sum/sizes: fixed literal MISMATCHES — emit nothing",
     """
     (foo 1)
     (foo 2)
     (foo 3)
     (exec 0 (, (foo \$x)) (O (sum (nope) 99 \$x)))
     """,
     ["(foo 1)", "(foo 2)", "(foo 3)"],
     "branch 1 (negative)"),

    ("sum/newvar: ignored guard",
     """
     (foo 1)
     (foo 2)
     (exec 0 (, (foo \$x)) (O (sum (ig) \$ig \$x)))
     """,
     ["(foo 1)", "(foo 2)", "(ig)"],
     "branch 2"),
]

function _sink_branch_run(program::String)
    s = MORK.new_space()
    MORK.space_add_all_sexpr!(s, program)
    MORK.space_metta_calculus!(s, 1000)
    sort!([strip(l) for l in split(MORK.space_dump_all_sexpr(s), '\n') if !isempty(strip(l))])
end

@testset "AndSink/SumSink three-branch conformance (vs upstream binary)" begin
    for (name, program, expected, branch) in _SINK_BRANCH_PROBES
        @testset "$name" begin
            got = _sink_branch_run(program)
            # Full-set equality: catches BOTH a missing emit and a spurious/malformed one
            # (e.g. a dangling `_2`, which a "contains" assertion would happily accept).
            @test got == sort(expected)
        end
    end
end
