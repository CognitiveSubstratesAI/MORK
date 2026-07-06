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

@testset "upstream conformance (differential vs built Rust `mork`)" begin
    if _UP_MORK === nothing
        @info "upstream `mork` binary not built (dev-zone/MORK/target/release/mork) — skipping differential conformance"
        @test_skip true
    else
        # (1) tractable relational join — our NAIVE DEFAULT must match upstream default exactly.
        #     Positive coverage that the default engine is correct where it is tractable.
        jf = joinpath(_FIXTURE, "conformance_join.mm2")
        up_j   = _upstream(jf, 10)
        our_j  = _ours(jf, 10; coref = false)
        @test !isempty(up_j)
        @test our_j == up_j
        # 2-hops from {0→1,1→2,2→3,1→4}: 0→1→2, 1→2→3, 0→1→4 (NOT 0→3, which is a 3-hop)
        @test "(path2 0 2)" in our_j && "(path2 1 3)" in our_j && "(path2 0 4)" in our_j

        # (2) canonical Counter-Machine — our COREF engine ≡ upstream default (byte-identical
        #     derived state: 241 steps, HALTED at clock S^47, REG3 copied = 5).
        cm = joinpath(_UP_RES, "counter_machine_5.mm2")
        if isfile(cm)
            up_cm    = _upstream(cm, 1_000)
            our_cm   = _ours(cm, 1_000; coref = true)
            @test !isempty(up_cm)
            @test any(l -> startswith(l, "(HALTED "), our_cm)      # it actually halted
            @test our_cm == up_cm                                   # coref conforms to upstream

            # our NAIVE default EXPLODES here (>2M transitions on step 2's higher-order 5-factor
            # join vs upstream ~1k) — so it is NOT executed (would OOM CI). Locked as the tracked
            # gap until higher-order/hov conjunctions route to coref by default.
            @test_skip "counter_machine on NAIVE default: intractable (naive-vs-coref default-engine gap)"
        else
            @test_skip "counter_machine_5.mm2 absent from upstream resources"
        end
    end
end
