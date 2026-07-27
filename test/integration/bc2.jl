# test/integration/bc2.jl — ports fn bc2() in kernel/src/main.rs:3645
# Backward chaining over Metamath propositional logic: from mp2b.1 : 𝜑, mp2b.2 : 𝜑→𝜓,
# mp2b.3 : 𝜓→𝜒, derive a proof of 𝜒 by chaining ax-mp (modus ponens).
#
# RE-PORTED 2026-07-27. The previous version was NOT a port of upstream's bc2() at all — it was a
# hand-simplified 3-rule variant with no `ax-mp` symbol anywhere, so it could not possibly produce
# upstream's asserted proof term and quietly asserted a different one. This now runs UPSTREAM'S
# EXACT PROGRAM (7 step rules base/abs/rev/abs2/rev2/app/app2 + the zealous driver, and the four
# Metamath axioms), extracted verbatim from the Rust source into the conformance corpus so there is
# exactly ONE copy: test/conformance/space/bc2_mm_propositional.mm2.
using MORK, Test

const BC2_PROBE = joinpath(@__DIR__, "..", "fixtures", "mm2", "bc2_mm_propositional.mm2")

@testset "bc2 — Metamath propositional proof of 𝜒 via ax-mp chaining" begin
    s = new_space()
    space_add_all_sexpr!(s, read(BC2_PROBE, String))

    # `(exec zealous …)` re-adds itself ⇒ never halts. 30 is upstream's BUDGET (main.rs:3711),
    # not a halting expectation.
    steps = space_metta_calculus!(s, 30)
    @test steps == 30

    result = space_dump_all_sexpr(s)
    # UPSTREAM'S ACTUAL ASSERTION (main.rs:3720): the ax-mp chain proving 𝜒.
    #   mp2b.1 : 𝜑 , mp2b.2 : 𝜑→𝜓  ⊢ 𝜓 , then with mp2b.3 : 𝜓→𝜒  ⊢ 𝜒
    @test occursin("(@ ax-mp (@ ax-mp mp2b.1 mp2b.2) mp2b.3)", result)

    # ⚠️ DELIBERATELY NOT ASSERTED: the atom count. At this BINDING budget our engine reaches 2354
    # atoms where the upstream binary reaches 2846 — both in 30 steps, and both reaching the proof
    # term above. That is an OPEN, CHARACTERISED divergence in exec scheduling under a bounded run
    # (see docs/session-log.md); it is invisible at exhaustion, where the two agree. Pinning 2354
    # here would lock in whichever behaviour we currently have and make the divergence look settled.
end
