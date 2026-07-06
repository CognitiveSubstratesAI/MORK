# test/integration/mm2_corpus_differential.jl
#
# DIFFERENTIAL GATE — run each MM2_Structuring_Code corpus program through metta_calculus and
# assert the tutorial's stated UPSTREAM `mork` output (ground truth: the tutorial author ran the
# upstream binary; cross-confirmed here against a locally-built `mork`).
#
# This is what caught the O-sink set-difference bug (8f0d182): a halting check passes while the
# OUTPUT is wrong, so we assert the actual atoms AND — for set-producing programs — that there are
# NO EXTRA atoms of the salient predicate (the phantom `(ret c)` the difference bug produced).
# Locks in the difference / nested-exec var-hygiene (7908fbd) / _pat_overlaps over-read (e59a16b)
# fixes and flags any future divergence.
#
# Programs live in experiments/mm2_programs/programs/ (the ClarkeRemy corpus).
using MORK, Test

const _CORPUS_DIR = abspath(joinpath(@__DIR__, "..", "..", "experiments", "mm2_programs", "programs"))

# run a corpus program to a fixpoint (cap guards against the never-halting quine) → dumped atoms
function _corpus_atoms(fname::AbstractString, cap::Int=20_000)
    s = new_space()
    space_add_all_sexpr!(s, read(joinpath(_CORPUS_DIR, fname), String))
    steps = space_metta_calculus!(s, cap)
    atoms = [strip(l) for l in split(space_dump_all_sexpr(s), '\n') if !isempty(strip(l))]
    (steps, cap, atoms)
end

# all atoms whose s-expr starts with `prefix` (e.g. "(ret" )
_with_prefix(atoms, prefix) = sort([a for a in atoms if startswith(a, prefix)])

@testset "MM2 corpus differential (vs upstream `mork` outputs)" begin
    @test isdir(_CORPUS_DIR)

    # ── Basics ────────────────────────────────────────────────────────────────
    @testset "Basics_03 union → a b c" begin
        _, _, a = _corpus_atoms("Basics_03_file1_file2.mm2")
        for x in ("a", "b", "c"); @test x in a; end
    end
    @testset "Basics_04 predicated" begin
        _, _, a = _corpus_atoms("Basics_04_file1_file2_predicated.mm2")
        for x in ("(file1 a)", "(file1 b)", "(file2 b)", "(file2 c)"); @test x in a; end
    end
    @testset "Basics_05 projection → (projected a) (projected b)" begin
        _, _, a = _corpus_atoms("Basics_05_file1_file2_project.mm2")
        @test _with_prefix(a, "(projected") == ["(projected a)", "(projected b)"]
    end
    @testset "Basics_07 sources+sinks → (ab 1 3) (ab 2 3)" begin
        _, _, a = _corpus_atoms("Basics_07_Sources_Sinks.mm2")
        for x in ("(a 1)", "(a 2)", "(b 3)"); @test x in a; end
        @test _with_prefix(a, "(ab") == ["(ab 1 3)", "(ab 2 3)"]
    end
    @testset "Basics_08 sink removal → a (removed atom gone)" begin
        _, _, a = _corpus_atoms("Basics_08_Sink_Removal.mm2")
        @test "a" in a
    end

    # ── Set operations (the salient `(ret …)` set must match EXACTLY — no phantoms) ──────
    @testset "Set_Ops_03 union → ret a b c d" begin
        _, _, a = _corpus_atoms("Set_Ops_03_Union.mm2")
        @test _with_prefix(a, "(ret") == ["(ret a)", "(ret b)", "(ret c)", "(ret d)"]
    end
    @testset "Set_Ops_04 intersection → ret b c" begin
        _, _, a = _corpus_atoms("Set_Ops_04_Intersection.mm2")
        @test _with_prefix(a, "(ret") == ["(ret b)", "(ret c)"]
    end
    @testset "Set_Ops_05 difference → ret a (NO phantom ret c — regression 8f0d182)" begin
        _, _, a = _corpus_atoms("Set_Ops_05_Difference.mm2")
        @test _with_prefix(a, "(ret") == ["(ret a)"]
    end
    @testset "Set_Ops_06 symmetric difference → ret a d" begin
        _, _, a = _corpus_atoms("Set_Ops_06_Symmetric_Difference.mm2")
        @test _with_prefix(a, "(ret") == ["(ret a)", "(ret d)"]
    end

    # ── Control flow ────────────────────────────────────────────────────────────
    @testset "Control_05 select-first-data → b" begin
        _, _, a = _corpus_atoms("Control_05_Select_First_Data.mm2")
        @test "b" in a
    end
    @testset "Control_06 select-first-exec" begin
        _, _, a = _corpus_atoms("Control_06_Select_First_Exec.mm2")
        for x in ("(Ran After)", "(case b)", "(case c)"); @test x in a; end
    end
    @testset "Control_07 recursive quine → RUNAWAY (intentional, hits cap)" begin
        steps, cap, _ = _corpus_atoms("Control_07_Recursive.mm2", 2_000)
        @test steps == cap          # self-replicating exec never halts
    end
    @testset "Control_08 halts-on-fail → halts, (counter Z)" begin
        steps, cap, a = _corpus_atoms("Control_08_Halts_on_fail.mm2", 2_000)
        @test steps < cap
        @test "(counter Z)" in a
    end
    @testset "Control_09 halts-on-success → halts, (counter Z)" begin
        steps, cap, a = _corpus_atoms("Control_09_Halts_on_success.mm2", 2_000)
        @test steps < cap
        @test "(counter Z)" in a
    end

    # ── Going wide (finite function works; the DEF/main-loop programs are DEFERRED) ──────
    @testset "Going_Wide_01 finite function" begin
        _, _, a = _corpus_atoms("Going_Wide_01_Finite_Function.mm2")
        for x in ("(results-in 1 <- (and 1 1))", "(results-in 1 <- (or 1 1))",
                  "(results-in 1 <- (not 0))"); @test x in a; end
    end
    # Going_Wide_02 / _11_Macros / _31_Two_Programs use the DEF/main-loop idiom. The resurrection
    # bug was fixed (e59a16b) so they PROGRESS; the remaining "convergence/explosion" (they grew
    # unbounded and never halted with (OUTPUT 1)) was the NAIVE ProductZipper join over-generating
    # the multi-source (fork/join) selection. Under the coreferential-transition join default (MORK
    # 921c05c) all three now converge, bounded, byte-identical to the upstream binary — verified via
    # test/integration/upstream_conformance.jl. _02 and _11 halt with (OUTPUT 1); _31_Two_Programs
    # legitimately halts WITHOUT (OUTPUT 1) (upstream produces none either — it is a two-program
    # composition whose output predicate differs). cap=2_000 (they converge in <100 steps).
    @testset "Going_Wide_02 DEF/main-loop → halts, (OUTPUT 1)" begin
        steps, cap, a = _corpus_atoms("Going_Wide_02.mm2", 2_000)
        @test steps < cap                 # bounded convergence (was: unbounded growth under naive join)
        @test "(OUTPUT 1)" in a
    end
    @testset "Going_Wide_11_Macros DEF/main-loop → halts, (OUTPUT 1)" begin
        steps, cap, a = _corpus_atoms("Going_Wide_11_Macros.mm2", 2_000)
        @test steps < cap
        @test "(OUTPUT 1)" in a
    end
    @testset "Going_Wide_31_Two_Programs DEF/main-loop → halts (no OUTPUT 1, matches upstream)" begin
        steps, cap, a = _corpus_atoms("Going_Wide_31_Two_Programs.mm2", 2_000)
        @test steps < cap
        @test !any(x -> occursin("(OUTPUT 1)", x), a)
    end
end
