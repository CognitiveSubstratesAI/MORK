# test/integration/mm1_forward.jl — ports fn mm1_forward() in kernel/src/main.rs:5419
# MM1: forward-chain a Metamath-style proof of ⊢ (t = t).
#
# HISTORY — this file used to @test_skip the full proof, claiming
#     "multi-source patterns (3-4 sources) exceed single-factor ProductZipper limit"
# That claim (added 92124ea, 2026-04-24, as a Rule-of-64 *precaution* — not an observed
# wrong answer) is FALSE and was falsified by execution on 2026-07-27: the program's two
# 4-source execs `(2 derive-P-to-Q-direct3)` / `(3 assemble-final-proof-direct)` and its
# 3-source `(1 a1-instantiate-PtoQ)` all fire, and we reach a fixpoint byte-identical to
# the upstream binary (1598 atoms, 8 steps). A 4-source pattern was in fact ALREADY being
# asserted by the green roman_disjoin_initial.jl in the same directory.
#
# The program text is READ FROM THE CONFORMANCE PROBE so there is exactly one copy:
# byte-exactness vs the upstream binary is enforced by test/integration/conformance_gate.jl
# (probe `space/mm1_forward_full_proof`); this file asserts the SEMANTIC targets and the
# fixpoint witness, which a full-dump equality diff does not make legible.
#
# NOTE — upstream's fn is a PRINTER with zero assert!s, is not wired into main(), and its two
# `dump_sexpr(expr!(...))` queries are VACUOUS: expr! parses `(=)` as a 3-byte symbol while the
# program's `((=) $x $y)` has head `[1] =`, so they always match nothing. They are deliberately
# NOT ported — porting them verbatim would port a bug. The `want_*` needles below are upstream's,
# except `want_final` which is written with the closing paren upstream's needle is missing
# (upstream compares it with starts_with, making it a weaker prefix test).
using MORK, Test

const MM1_PROBE = joinpath(
    @__DIR__, "..", "conformance", "space", "mm1_forward_full_proof.mm2"
)

@testset "mm1_forward — full proof of ⊢ (t = t) (3- and 4-source execs)" begin
    s = new_space()
    space_add_all_sexpr!(s, read(MM1_PROBE, String))

    budget = 100_000
    steps = space_metta_calculus!(s, budget)

    # Exhaustion, not truncation: a step-count assert alone cannot tell a fixpoint from a
    # silently-capped run, so pin the count AND require it to be far below the budget.
    @test steps == 8
    @test steps < budget

    lines = [strip(l) for l in split(space_dump_all_sexpr(s), '\n') if !isempty(strip(l))]

    # Fixpoint witness, independent of the step count: every exec frame was consumed.
    @test count(l -> startswith(l, "(exec "), lines) == 0
    @test length(lines) == 1598

    atoms = Set(lines)
    # Upstream's want_* targets (main.rs:5493-5504), matched as EXACT lines, not occursin.
    want_term_tplus0 = "(ev (: ((+) (t) (0)) (term)))"
    want_wff_p = "(ev (: ((=) ((+) (t) (0)) (t)) (wff)))"
    want_wff_q = "(ev (: ((=) (t) (t)) (wff)))"
    want_proof_p = "(ev (: ((=) ((+) (t) (0)) (t)) (|-)))"
    want_proof_ptoq = "(ev (: ((->) ((=) ((+) (t) (0)) (t)) ((=) (t) (t))) (|-)))"
    want_proof_ptoptoq = "(ev (: ((->) ((=) ((+) (t) (0)) (t)) ((->) ((=) ((+) (t) (0)) (t)) ((=) (t) (t)))) (|-)))"
    want_final = "(ev (: ((=) (t) (t)) (|-)))"

    @test want_term_tplus0 in atoms          # tpl-apply, 2-source
    @test want_wff_p in atoms                # weq-apply, 2-source
    @test want_wff_q in atoms
    @test want_proof_p in atoms              # a2-instantiate-t
    @test want_proof_ptoptoq in atoms        # a1-instantiate-PtoQ, 3-SOURCE
    @test want_proof_ptoq in atoms           # derive-P-to-Q-direct3, 4-SOURCE
    @test want_final in atoms                # assemble-final-proof-direct, 4-SOURCE — the goal
end
