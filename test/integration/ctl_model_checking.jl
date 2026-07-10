# test/integration/ctl_model_checking.jl
#
# STANDING REGRESSION — CTL model checker as an MM2 program on the MORK exec-calculus.
# Permanently gates the EU least-fixpoint / PathMap copy-on-write fix (commit 05451ee,
# "fix(cow): re-fetch children from cloned parent in write-zipper uniquify") AND the
# relational lane. Pre-05451ee the EU descent read its own post-add atoms (a CoW leak:
# _wz_ensure_write_unique! forked a stale child wrapper owned by the read snapshot), so the
# least fixpoint halted one round early. The tell is state 2 in F1: post-fix the natural
# fixpoint derives [2,6,7,8,12]; pre-fix it was [6,7,8,12] (2 dropped — it is the LAST state
# the 2-round least fixpoint propagates: EU target {7,8} -> {6,12} -> 2).
#
# Golden state-sets are the wiki oracle (MORK.wiki "MM2-Example: CTL model checking",
# author Anneline Daggelinckx; triple-backed there: to_check comments, (solution ...) facts,
# and the full-program dump). Model = the rocket example from Jamroga, "Logical Methods for
# Specification and Verification of Multi-Agent Systems", p.32.
#
# Pure MORK — NO MeTTaCore dependency (new_space() is exactly what CoreSpace wraps as .inner).
# API from src/kernel/Space.jl: new_space, space_add_all_sexpr!, space_metta_calculus!,
# space_dump_all_sexpr.
using MORK, Test

const _CTL_FIXTURE = joinpath(@__DIR__, "..", "fixtures", "mm2", "ctl_model_checking.mm2")

# States s for which the dump contains `(true <formula> s)`, sorted unique Int vector.
# Atoms render single-spaced canonical (e.g. "(true (EX (caP)) 7)"); the state is the last
# token before the closing paren. ASCII throughout -> byte-safe slicing.
function _ctl_states(atoms, formula::AbstractString)
    pref = "(true $formula "
    states = Int[]
    for a in atoms
        startswith(a, pref) || continue
        rest = a[length(pref)+1:end]      # "<state>)"
        endswith(rest, ")") || continue
        push!(states, parse(Int, rest[1:end-1]))
    end
    sort!(unique!(states))
end

@testset "CTL model checker (gates EU least-fixpoint / CoW fix 05451ee)" begin
    @test isfile(_CTL_FIXTURE)

    s = new_space()
    space_add_all_sexpr!(s, read(_CTL_FIXTURE, String))
    steps = space_metta_calculus!(s, 50_000_000)

    # The real fixpoint witness is the zero-leftover-exec assertion below (the driver halts
    # only when every (exec ...) is consumed). `steps < cap` here only proves it did not hit
    # the budget. Validated run: 54 steps / 295 atoms — NOT gated as exact numbers; step/atom
    # totals are variant- and engine-dependent (wiki reference dump = 297); the derived
    # state-sets are the portable oracle.
    @test steps < 50_000_000

    atoms = [strip(l) for l in split(space_dump_all_sexpr(s), '\n') if !isempty(strip(l))]
    @test !any(a -> startswith(a, "(exec "), atoms)   # 0 leftover execs => fixpoint reached

    # -- F1: (fuelOK) EU ((caR) & (EX (caP)))  — state 2 is THE 05451ee sentinel ------------
    f1 = _ctl_states(atoms, "((fuelOK) EU ((caR) & (EX (caP))))")
    @test 2 in f1                                     # halted-one-round-early => MISSING pre-fix
    @test f1 == [2, 6, 7, 8, 12]                      # exact set also catches over-saturation

    # -- F2: AG ((~ (fuelOK)) -> (EF (fuelOK)))  — derived-operator / relational-lane gate ---
    @test _ctl_states(atoms, "(AG ((~ (fuelOK)) -> (EF (fuelOK))))") == collect(1:12)

    # -- Intermediate labelling spot-checks (wiki full-program dump) ------------------------
    @test _ctl_states(atoms, "(caR)")                == [5, 6, 7, 8]
    @test _ctl_states(atoms, "(fuelOK)")             == [2, 4, 6, 8, 10, 12]
    @test _ctl_states(atoms, "(EX (caP))")           == [7, 8, 9, 10, 11, 12]
    @test _ctl_states(atoms, "((caR) & (EX (caP)))") == [7, 8]   # EU target set W0
end
