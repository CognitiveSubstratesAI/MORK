# test/integration/upstream_conformance.jl
#
# DIFFERENTIAL CONFORMANCE vs the ACTUAL upstream Rust `mork` binary.
#
# Runs identical .mm2 programs through `mork run` (upstream) and our `mork_run` (Julia port)
# and asserts the derived GROUND state is identical (as a SET — MM2 spaces are unordered;
# var-bearing rule atoms are filtered because the two renderers name De Bruijn vars
# differently — `$a $b` upstream vs `$`/`_1` ours — while ground atoms render byte-identically).
#
# WHY THIS EXISTS: our tests validated our trie-join ≡ our own ProductZipper (self-consistency)
# and interpreter-oracle bisim on small inputs — but NOTHING ran the same program through the
# real upstream binary. That gap let a DEFAULT-ENGINE MISMATCH ship: upstream's default join is
# the coreferential-transition DFS; ours defaulted to the naive ProductZipper, which EXPLODES on
# higher-order multi-source joins (counter-machine step 2: >2M transitions vs upstream ~1k).
# See docs/tracking/session-log.md 2026-07-06 and project_mork_mm2_corpus_control08_bug.
#
# Guarded on the built binary being present (skips cleanly like z3_roundtrip.jl where absent).

using Test
using MORK

const _UP_MORK = let
    cands = [expanduser("~/JuliaAGI/dev-zone/MORK/target/release/mork"),
             expanduser("~/JuliaAGI/dev-zone/MORK/kernel/target/release/mork")]
    i = findfirst(isfile, cands); i === nothing ? nothing : cands[i]
end
const _UP_RES  = expanduser("~/JuliaAGI/dev-zone/MORK/kernel/resources")
const _FIXTURE = joinpath(@__DIR__, "..", "fixtures", "mm2")

# ground atoms only (drop var-bearing rule lines), stripped + sorted → order-independent set
_ground(dump::AbstractString) = sort!(String[s for l in split(dump, '\n')
                                             for s in (strip(l),) if !isempty(s) && !occursin('$', s)])

function _upstream(file::AbstractString, steps::Int)
    out = tempname() * ".mm2out"
    try
        run(pipeline(`$_UP_MORK run $file --steps $steps $out`; stdout = devnull, stderr = devnull))
        _ground(read(out, String))
    finally
        isfile(out) && rm(out; force = true)
    end
end

function _ours(file::AbstractString, steps::Int; coref::Bool)
    out = tempname() * ".mm2out"
    prev = MORK._USE_COREF_JOIN[]
    MORK._USE_COREF_JOIN[] = coref
    try
        MORK.mork_run(file; steps = steps, output_path = out)
        _ground(read(out, String))
    finally
        MORK._USE_COREF_JOIN[] = prev
        isfile(out) && rm(out; force = true)
    end
end

# ours on the COMPILED DEFAULT join engine (no flag manipulation) — tests whatever the default IS
# (flipped naive→coref 2026-07-06). If someone changes _USE_COREF_JOIN's default, this follows it.
function _ours_default(file::AbstractString, steps::Int)
    out = tempname() * ".mm2out"
    try
        MORK.mork_run(file; steps = steps, output_path = out)
        _ground(read(out, String))
    finally
        isfile(out) && rm(out; force = true)
    end
end

@testset "upstream conformance (differential vs built Rust `mork`)" begin
    if _UP_MORK === nothing
        @info "upstream `mork` binary not built (dev-zone/MORK/target/release/mork) — skipping differential conformance"
        @test_skip true
    else
        # (1) tractable relational join — the DEFAULT engine AND the naive opt-out both match upstream.
        jf = joinpath(_FIXTURE, "conformance_join.mm2")
        up_j = _upstream(jf, 10)
        @test !isempty(up_j)
        @test _ours_default(jf, 10) == up_j              # default (coref) conforms
        @test _ours(jf, 10; coref = false) == up_j       # naive opt-out also correct on tractable
        let g = _ours_default(jf, 10)
            # 2-hops from {0→1,1→2,2→3,1→4}: 0→1→2, 1→2→3, 0→1→4 (NOT 0→3, a 3-hop)
            @test "(path2 0 2)" in g && "(path2 1 3)" in g && "(path2 0 4)" in g
        end

        # (2) canonical Counter-Machine — higher-order 5-factor reflective join. The DEFAULT now
        #     handles it (coref) ≡ upstream (241 steps, HALTED S^47, REG3 copied=5). PRE-FLIP the
        #     naive default EXPLODED here (>2M transitions vs upstream ~1k) — this is the fix, locked.
        cm = joinpath(_UP_RES, "counter_machine_5.mm2")
        if isfile(cm)
            up_cm  = _upstream(cm, 1_000)
            our_cm = _ours_default(cm, 1_000)
            @test !isempty(up_cm)
            @test any(l -> startswith(l, "(HALTED "), our_cm)      # it actually halted
            @test our_cm == up_cm                                   # DEFAULT ≡ upstream
        else
            @test_skip "counter_machine_5.mm2 absent from upstream resources"
        end

        # (3) lte self-spawning recursion — upstream halts (~60 steps); the DEFAULT halts & conforms.
        #     Pre-flip the naive default exploded ~step 10 (misdiagnosed in the fixture header as a
        #     non-halt "exec-resurrection" bug — it was the join exploding).
        lte = joinpath(_FIXTURE, "lte_selfspawn_b6.mm2")
        if isfile(lte)
            @test _ours_default(lte, 200) == _upstream(lte, 200)
        else
            @test_skip "lte_selfspawn_b6.mm2 fixture absent"
        end

        # (4) Set_Ops_06 symmetric-difference — 4-factor conjunction + O-sink; DEFAULT ≡ upstream.
        so = joinpath(@__DIR__, "..", "..", "experiments", "mm2_programs", "programs",
                      "Set_Ops_06_Symmetric_Difference.mm2")
        if isfile(so)
            @test _ours_default(so, 1_000) == _upstream(so, 1_000)
        else
            @test_skip "Set_Ops_06 program absent"
        end

        # (5) Going-wide DEF/main-loop idiom (fork/join multi-source selection). Under the naive
        #     default these grew unbounded and never halted with (OUTPUT 1); the DEFAULT (coref)
        #     converges bounded (<100 steps) ≡ upstream byte-for-byte. _02/_11 emit (OUTPUT 1); _31
        #     is a two-program composition that legitimately emits none (upstream agrees).
        let progs = joinpath(@__DIR__, "..", "..", "experiments", "mm2_programs", "programs")
            for (name, want_out) in (("Going_Wide_02.mm2", true),
                                     ("Going_Wide_11_Macros.mm2", true),
                                     ("Going_Wide_31_Two_Programs.mm2", false))
                gw = joinpath(progs, name)
                if isfile(gw)
                    our_gw = _ours_default(gw, 2_000)
                    @test our_gw == _upstream(gw, 100_000)             # DEFAULT ≡ upstream
                    @test any(l -> occursin("(OUTPUT 1)", l), our_gw) == want_out
                else
                    @test_skip "$name absent"
                end
            end
        end
    end
end
