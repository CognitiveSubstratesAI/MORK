# JET DISPATCH RATCHET — fails when a change ADDS runtime dispatch to the exec hot path.
#
# ─── WHY THIS EXISTS ─────────────────────────────────────────────────────────────────────────────
# Type instability is invisible until someone profiles, and by then it is archaeology. On 2026-08-20
# `space_transform_multi_multi!` was found iterating a BARE `Vector` — element type `Any`, so every
# `sink_finalize!` was a runtime dispatch — by running JET *after* a workload turned out slow. The
# annotation had been there for a long time and nothing in the repo would ever have said so.
#
# 🔴 THE USER'S POINT, AND IT IS THE RIGHT ONE: enforcement after the fact is not the same as
# practice. The write-loop check is `@report_opt` on the function you just touched, and it takes
# seconds. This file is the part of that a SUITE can remember — it converts "I should have run JET"
# into "the suite ran JET".
#
# ─── WHAT IT COUNTS, AND WHY NOT EVERYTHING ──────────────────────────────────────────────────────
# `@report_opt` over the whole exec path reports ~285 dispatches, but most are NOT ours: `show`,
# `AssertionError` message construction, `eltype(::DataType)` — Base internals reached through error
# and display paths, which we cannot fix and which would drown the signal. So the pin counts only
# dispatches whose enclosing frame is in `MORK/src` or `PathMap/src`.
#
# ⚠️ ABSTRACT-TYPE DISPATCH IS NOT THE SAME DEFECT AS `Any`. `node_is_empty(%::AbstractTrieNode{…})`
# is polymorphism over PathMap's node types — deliberate, and the cost of a trait-style design.
# `PathMap.Int(%4::Any)` is a genuine hole. Both count here, because both are dispatch, but only the
# second is a bug; the pin is a REGRESSION guard, not a target to drive to zero.
# [[feedback_no_any_typed_containers]] · [[feedback_perf_diagnosis_typeinstability_first]]

using MORK, JET, Test

@testset "JET dispatch ratchet — exec hot path" begin
    src_path = joinpath(homedir(), "csai-work", "gen", "process_calculus_60p60.mm2")
    # The corpus program is generated, not checked in. Fall back to an inline body so the ratchet
    # still runs in a fresh clone — a gate that silently skips is worse than no gate.
    src = isfile(src_path) ? read(src_path, String) :
          "(edge a b)\n(edge b c)\n(exec 0 (, (edge \$x \$y) (edge \$y \$z)) (, (path \$x \$z)))\n"

    s = MORK.new_space(); MORK.space_add_all_sexpr!(s, src)
    report = @report_opt MORK.space_metta_calculus!(s, 5)
    txt = sprint(show, report)

    # ANTI-VACUITY. If JET's output format changes, or the report comes back empty, every count
    # below would be 0 and the ratchet would pass while measuring nothing.
    @test !isempty(txt)
    @test occursin("runtime dispatch detected", txt)

    ours = 0
    frame = ""
    for ln in split(txt, '\n')
        occursin("@ ", ln) && (frame = ln)          # the frame line carries the file path
        if occursin("runtime dispatch detected", ln)
            (occursin("MORK/src", frame) || occursin("PathMap/src", frame)) && (ours += 1)
        end
    end
    @test ours > 0                                   # …and that the attribution actually matched

    # PIN, measured 2026-08-20 on this exact program at 5 steps.
    #   104 — after typing `persistent_sinks` as `Vector{Union{Nothing,AbstractSink}}`, which removed
    #         the `(A::Vector)[i::Int64]::Any` iteration entirely (verified 0 by literal substring
    #         count, not by a regex that could fake a zero).
    # A count that GROWS means a change introduced runtime dispatch — that is the alarm.
    # A count that SHRINKS means something got typed; lower the pin and say what.
    PIN = 104
    @test ours <= PIN
    if ours < PIN
        @info "JET dispatch IMPROVED — lower the pin in this file and record what was typed" ours = ours pin = PIN
    end

    # 🔴 A HARD ZERO ON THE CLASS OUR OWN RULE FORBIDS: indexing an untyped container. This is not a
    # ratchet — it must stay at zero. It is the exact shape that was found on 2026-08-20, and unlike
    # abstract dispatch it is never deliberate.
    @test !occursin("(A::Vector)[i::Int64]::Any", txt)
    @test !occursin("(A::Dict)[", txt)
end
