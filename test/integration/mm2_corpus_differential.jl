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

const _CORPUS_DIR = abspath(
    joinpath(@__DIR__, "..", "..", "experiments", "mm2_programs", "programs")
)

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
        for x in ("a", "b", "c")
            @test x in a
        end
    end
    @testset "Basics_04 predicated" begin
        _, _, a = _corpus_atoms("Basics_04_file1_file2_predicated.mm2")
        for x in ("(file1 a)", "(file1 b)", "(file2 b)", "(file2 c)")
            @test x in a
        end
    end
    @testset "Basics_05 projection → (projected a) (projected b)" begin
        _, _, a = _corpus_atoms("Basics_05_file1_file2_project.mm2")
        @test _with_prefix(a, "(projected") == ["(projected a)", "(projected b)"]
    end
    @testset "Basics_07 sources+sinks → (ab 1 3) (ab 2 3)" begin
        _, _, a = _corpus_atoms("Basics_07_Sources_Sinks.mm2")
        for x in ("(a 1)", "(a 2)", "(b 3)")
            @test x in a
        end
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
        for x in ("(Ran After)", "(case b)", "(case c)")
            @test x in a
        end
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
            "(results-in 1 <- (not 0))")
            @test x in a
        end
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
    @testset "Going_Wide_21_Larger_Programs → halts, matches upstream exactly" begin
        steps, cap, a = _corpus_atoms("Going_Wide_21_Larger_Programs.mm2", 20_000)
        @test steps == 92                 # exact vs freshly-rebuilt upstream binary (2026-07-24)
        @test length(a) == 26
        for x in ("(OUTPUT A 1)", "(OUTPUT B 1)")
            @test x in a
        end
    end

    # ── 2026-07-24 corpus-completeness sweep: 15 programs never previously exercised by this file
    #    (34-file corpus total, only 18 covered before today) — each verified against a freshly
    #    rebuilt upstream `mork` binary (exact step count + atom count + content, modulo the known
    #    cosmetic $a/$b-vs-anonymous-$/_N variable-name printing on rule/DEF echo lines). All 15
    #    matched exactly; zero divergences found. See session-log 2026-07-24 (cont'd, part 2).
    @testset "Basics_01_file1 → bare data, no rules" begin
        _, _, a = _corpus_atoms("Basics_01_file1.mm2")
        @test sort(a) == ["a", "b"]
    end
    @testset "Basics_02_file2 → bare data, no rules" begin
        _, _, a = _corpus_atoms("Basics_02_file2.mm2")
        @test sort(a) == ["b", "c"]
    end
    # Basics_06_Priority_* (6 variants): each is two `(exec <priority> (,) (,))` facts with an
    # empty pattern/template (a pure no-op transition) — only the PRIORITY TAG'S ENCODING differs
    # (bare 1/2-digit numeral, 1-tuple, 2-tuple, mixed order). All six converge to 0 data atoms
    # regardless of tag shape; this locks in that priority-tag parsing doesn't silently misparse
    # any of the encodings into something that fails to match/consume.
    for fname in ("Basics_06_Priority_00_01.mm2", "Basics_06_Priority_(0_0)_(0_1).mm2",
        "Basics_06_Priority_0_(0_0).mm2", "Basics_06_Priority_0_1.mm2",
        "Basics_06_Priority_1_00.mm2", "Basics_06_Priority_(1)_(0_0).mm2")
        @testset "$fname → 2 no-op execs consumed, 0 data atoms" begin
            steps, cap, a = _corpus_atoms(fname)
            @test steps == 2
            @test isempty(a)
        end
    end
    @testset "Control_01_Priority_Seq → 0 1 2 3" begin
        _, _, a = _corpus_atoms("Control_01_Priority_Seq.mm2")
        @test sort(a) == ["0", "1", "2", "3"]
    end
    @testset "Control_02_Exec_Chaining_Seq → 0 1 2 3" begin
        _, _, a = _corpus_atoms("Control_02_Exec_Chaining_Seq.mm2")
        @test sort(a) == ["0", "1", "2", "3"]
    end
    @testset "Control_03_Exec_Chaining_Fail_Seq → halts at 0 (chain breaks)" begin
        steps, cap, a = _corpus_atoms("Control_03_Exec_Chaining_Fail_Seq.mm2")
        @test steps == 2
        @test a == ["0"]
    end
    @testset "Control_04_Select_b_c → (case b) (case c) b c" begin
        _, _, a = _corpus_atoms("Control_04_Select_b_c.mm2")
        @test sort(a) == ["(case b)", "(case c)", "b", "c"]
    end
    @testset "Set_Ops_01_Hardcoded_Locations → ret a-f" begin
        _, _, a = _corpus_atoms("Set_Ops_01_Hardcoded_Locations.mm2")
        @test _with_prefix(a, "(arg_a") == ["(arg_a a)", "(arg_a b)", "(arg_a c)"]
        @test _with_prefix(a, "(arg_b") == ["(arg_b d)", "(arg_b e)", "(arg_b f)"]
        @test _with_prefix(a, "(ret") ==
            ["(ret a)", "(ret b)", "(ret c)", "(ret d)", "(ret e)", "(ret f)"]
    end
    @testset "Set_Ops_02_Parameterized_Locations → ret a-f + the union rule echoed" begin
        _, _, a = _corpus_atoms("Set_Ops_02_Parameterized_Locations.mm2")
        @test _with_prefix(a, "(arg_a") == ["(arg_a a)", "(arg_a b)", "(arg_a c)"]
        @test _with_prefix(a, "(arg_b") == ["(arg_b d)", "(arg_b e)", "(arg_b f)"]
        @test _with_prefix(a, "(ret") ==
            ["(ret a)", "(ret b)", "(ret c)", "(ret d)", "(ret e)", "(ret f)"]
    end
    @testset "Setup_Hello_World → (say (Hello World !))" begin
        _, _, a = _corpus_atoms("Setup_Hello_World.mm2")
        @test "(say (Hello World !))" in a
    end
end
