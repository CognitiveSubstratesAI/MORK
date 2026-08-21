# PURE-OP DIFFERENTIAL — every pure op, at the EDGES of its input domain, against the upstream binary.
#
# 🔴 THIS HARNESS EXISTED AND NOTHING RAN IT. `test/conformance/pure_ops/cmp_pure.jl` computed a real
# byte-level differential and asserted nothing; it required `ENV["PROBES"]` and had no caller. Its
# README carried the measurement that justified it —
#
#     "341 points to 2792 and surfaced 56 divergences where the narrow set had shown 3"
#     "⇒ An op's defect lives at the EDGE of its input domain."
#
# — next to a harness that never executed. That is the defect class `test_port_inventory.jl`'s header
# names: knowledge that nothing executes changes nothing. This file is the caller.
# [[feedback_verify_the_oracle_runs]] · [[feedback_enforcement_works_prose_memory_does_not]]
#
# ⚠️ FAIL-CLOSED ON A MISSING ORACLE, and that is not paranoia — it is a repeat. `upstream_conformance.jl`
# records the same mistake being made and fixed: a tree with no built Rust binary "ran this file to
# completion, printed one `@info`, and reported GREEN — with ZERO differential coverage." A skip that
# reads as a pass is worse than no test. The opt-out must be set DELIBERATELY.
#
# ── REGENERATING THE CORPUS (needs the upstream release binary) ──────────────────────────────────
#   python3 test/conformance/pure_ops/gen_pure_probes.py  ~/csai-work/pure_probes
#   bash    test/conformance/pure_ops/run_probes.sh       ~/csai-work/pure_probes
# Ground truth goes to FILES, never stdout — upstream's stdout dump replaces invalid UTF-8, and most
# pure ops emit high bytes, so stdout cannot be ground truth (run_probes.sh header).

using MORK, Test

include(joinpath(@__DIR__, "..", "conformance", "pure_ops", "cmp_pure.jl"))   # defines compare_probes

const _PO_DIR = get(ENV, "MORK_PURE_PROBES", joinpath(homedir(), "csai-work", "pure_probes"))
const _PO_ALLOW_MISSING =
    lowercase(get(ENV, "MORK_ALLOW_MISSING_ORACLE", "")) in ("1", "true", "yes", "on")

@testset "pure-op differential vs the upstream binary" begin
    have = isdir(_PO_DIR) && !isempty(filter(f -> endswith(f, ".raw"), readdir(_PO_DIR)))

    if !have && _PO_ALLOW_MISSING
        @warn "PURE-OP ORACLE MISSING — differential coverage REDUCED " *
              "(MORK_ALLOW_MISSING_ORACLE=1)" dir = _PO_DIR
        @test_skip "pure-op probe corpus"
    elseif !have
        @error "PURE-OP ORACLE MISSING — this is a FAILURE, not a skip. Without the corpus this \
                file proves nothing about the 355 ported ops." dir = _PO_DIR fix =
               "gen_pure_probes.py <dir> && run_probes.sh <dir>, or set MORK_ALLOW_MISSING_ORACLE=1"
        @test false
    else
        r = compare_probes(_PO_DIR)

        # ANTI-VACUITY FIRST. Every count below is meaningless if the corpus shrank — a differential
        # over 3 points would report zero divergences and read exactly like a clean one.
        @test r.compared >= 2711          # measured 2026-08-21: 2711 points over 355 ops
        @test r.agree > 2000

        # 🔴 THE SERIOUS CLASSES, PINNED AT ZERO. A differing VALUE is a bug in an op we have; a
        # MISSING one is an op we do not implement, or one we emit where upstream errors. They are
        # counted apart on purpose — one number would hide which.
        @test r.miss_ours == 0            # we produce nothing where upstream does
        @test r.miss_up == 0              # we emit where upstream errors

        # THE RATCHET. Measured 2026-08-21: 4, all of them ONE-ULP transcendental differences —
        # Rust's libm vs Julia's, last bit only:
        #     atan2_f32__mn_n1   ours \xbf\xc9\x0f\xdb   upstream \xbf\xc9\x0f\xda
        #     cbrt_f64__k3       ours ?\xf5\xb7 \x95W\xb0\xed  upstream ...\xee
        #     sin_f64__k3        ours ?\xe3&\xaf\x0d\xcf\xca\xb0  upstream ...\xb1
        #     sinh_f32__k3       ours @\xc1\x9bF          upstream @\xc1\x9bG
        # These are NOT logic errors, and the July audit's 56 have otherwise been closed.
        # ⚠️ A count that GROWS is the alarm. A count that SHRINKS means one was fixed — lower the
        # pin and say which, so progress is recorded rather than silently absorbed.
        @test r.wrong <= 4

        # …and the four are IDENTIFIED, so a NEW divergence cannot hide inside the allowance. This is
        # the assertion that makes the ratchet specific rather than merely numeric.
        known = Set(["atan2_f32", "cbrt_f64", "sin_f64", "sinh_f32"])
        unexpected = [t for t in r.report if !(split(t[1], "__")[1] in known)]
        if !isempty(unexpected)
            for (op, ours, up, file) in unexpected
                println("  🔴 UNEXPECTED DIVERGENCE  ", rpad(op, 26),
                        " ours=", rpad(ours, 26), " upstream=", up, "   [", file, "]")
            end
        end
        @test isempty(unexpected)

        @info "pure-op differential" points = r.compared agree = r.agree wrong = r.wrong
    end
end
