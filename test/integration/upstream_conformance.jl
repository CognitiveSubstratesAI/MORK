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
# A MISSING ORACLE INPUT IS A FAILURE, NOT A SKIP (2026-07-23). Every guard below used to degrade
# to `@test_skip`, so a tree with no built Rust binary ran this file to completion, printed one
# `@info`, and reported GREEN — with ZERO differential coverage. That is the same defect class as the
# `Base.run` shadowing fixed in c543841 one commit earlier: the oracle claims coverage it does not
# have, and every downstream "the port is correct" conclusion rests on nothing. Since this is the ONLY
# check of our Julia port against real upstream behaviour, its absence must be LOUD.
#
# Escape hatch, for environments that genuinely cannot build Rust: MORK_ALLOW_MISSING_ORACLE=1
# downgrades to a warning + skip. It must be set DELIBERATELY — the default is fail-closed, because
# an unset variable should never buy silence ([[feedback_guarantee_not_convention]]).

using Test
using MORK

const _ALLOW_MISSING = get(ENV, "MORK_ALLOW_MISSING_ORACLE", "") == "1"

"""Report a missing oracle input: FAILS by default, warns+skips only under an explicit opt-out."""
function _oracle_missing(what::AbstractString, fix::AbstractString)
    if _ALLOW_MISSING
        @warn "ORACLE INPUT MISSING — differential coverage REDUCED (MORK_ALLOW_MISSING_ORACLE=1)" what fix
        @test_skip what
    else
        @error "ORACLE INPUT MISSING — this is a FAILURE, not a skip. Without it the port has NO \
                independent check against upstream. Fix it, or set MORK_ALLOW_MISSING_ORACLE=1 to \
                accept reduced coverage deliberately." what fix
        @test false
    end
end

const _UP_MORK = let
    cands = [expanduser("~/dev-zone/MORK/target/release/mork"),
        expanduser("~/dev-zone/MORK/kernel/target/release/mork")]
    i = findfirst(isfile, cands)
    i === nothing ? nothing : cands[i]
end
const _UP_RES = expanduser("~/dev-zone/MORK/kernel/resources")
const _FIXTURE = joinpath(@__DIR__, "..", "fixtures", "mm2")

# ground atoms only (drop var-bearing rule lines), stripped + sorted → order-independent set
_ground(dump::AbstractString) = sort!(
    String[
        s for l in split(dump, '\n')
        for s in (strip(l),) if !isempty(s) && !occursin('$', s)
    ]
)

function _upstream(file::AbstractString, steps::Int)
    out = tempname() * ".mm2out"
    try
        # `Base.run`, QUALIFIED deliberately. `tools/repl.jl:27` defines its own
        # `run(src::AbstractString, steps::Int)` in `Main`, which SHADOWS `Base.run` — so an
        # unqualified call here dies with `MethodError: no method matching run(::Base.CmdRedirect)`
        # whenever the suite is driven through that REPL. And `tools/repl.jl` is the warm-session
        # workflow this repo MANDATES for MORK testing, so this — our ONLY differential check
        # against the built Rust binary — was silently erroring out on every mandated run.
        # Found 2026-07-23 while auditing why a 36-function port gap had gone unnoticed.
        Base.run(
            pipeline(
                `$_UP_MORK run $file --steps $steps $out`; stdout=devnull, stderr=devnull
            )
        )
        _ground(read(out, String))
    finally
        isfile(out) && rm(out; force=true)
    end
end

function _ours(file::AbstractString, steps::Int; coref::Bool)
    out = tempname() * ".mm2out"
    prev = MORK._USE_COREF_JOIN[]
    MORK._USE_COREF_JOIN[] = coref
    try
        MORK.mork_run(file; steps=steps, output_path=out)
        _ground(read(out, String))
    finally
        MORK._USE_COREF_JOIN[] = prev
        isfile(out) && rm(out; force=true)
    end
end

# ours on the COMPILED DEFAULT join engine (no flag manipulation) — tests whatever the default IS
# (flipped naive→coref 2026-07-06). If someone changes _USE_COREF_JOIN's default, this follows it.
function _ours_default(file::AbstractString, steps::Int)
    out = tempname() * ".mm2out"
    try
        MORK.mork_run(file; steps=steps, output_path=out)
        _ground(read(out, String))
    finally
        isfile(out) && rm(out; force=true)
    end
end

@testset "upstream conformance (differential vs built Rust `mork`)" begin
    if _UP_MORK === nothing
        _oracle_missing(
            "upstream Rust `mork` binary (the ONLY differential oracle for this port)",
            "cd ~/dev-zone/MORK && cargo build --release")
    else
        # (1) tractable relational join — the DEFAULT engine AND the naive opt-out both match upstream.
        jf = joinpath(_FIXTURE, "conformance_join.mm2")
        up_j = _upstream(jf, 10)
        @test !isempty(up_j)
        @test _ours_default(jf, 10) == up_j              # default (coref) conforms
        @test _ours(jf, 10; coref=false) == up_j       # naive opt-out also correct on tractable
        let g = _ours_default(jf, 10)
            # 2-hops from {0→1,1→2,2→3,1→4}: 0→1→2, 1→2→3, 0→1→4 (NOT 0→3, a 3-hop)
            @test "(path2 0 2)" in g && "(path2 1 3)" in g && "(path2 0 4)" in g
        end

        # (2) canonical Counter-Machine — higher-order 5-factor reflective join. The DEFAULT now
        #     handles it (coref) ≡ upstream (241 steps, HALTED S^47, REG3 copied=5). PRE-FLIP the
        #     naive default EXPLODED here (>2M transitions vs upstream ~1k) — this is the fix, locked.
        cm = joinpath(_UP_RES, "counter_machine_5.mm2")
        if isfile(cm)
            up_cm = _upstream(cm, 1_000)
            our_cm = _ours_default(cm, 1_000)
            @test !isempty(up_cm)
            @test any(l -> startswith(l, "(HALTED "), our_cm)      # it actually halted
            @test our_cm == up_cm                                   # DEFAULT ≡ upstream
        else
            _oracle_missing(
                "counter_machine_5.mm2 (the higher-order 5-factor reflective join — the \
                             ONE case that caught the naive-default explosion)",
                "expected at $cm")
        end

        # (3) lte self-spawning recursion — upstream halts (~60 steps); the DEFAULT halts & conforms.
        #     Pre-flip the naive default exploded ~step 10 (misdiagnosed in the fixture header as a
        #     non-halt "exec-resurrection" bug — it was the join exploding).
        lte = joinpath(_FIXTURE, "lte_selfspawn_b6.mm2")
        if isfile(lte)
            @test _ours_default(lte, 200) == _upstream(lte, 200)
        else
            _oracle_missing("lte_selfspawn_b6.mm2 (self-spawning recursion halting check)",
                "expected at $lte")
        end

        # (4) Set_Ops_06 symmetric-difference — 4-factor conjunction + O-sink; DEFAULT ≡ upstream.
        so = joinpath(@__DIR__, "..", "..", "experiments", "mm2_programs", "programs",
            "Set_Ops_06_Symmetric_Difference.mm2")
        if isfile(so)
            @test _ours_default(so, 1_000) == _upstream(so, 1_000)
        else
            _oracle_missing(
                "Set_Ops_06_Symmetric_Difference.mm2 (4-factor conjunction + O-sink)",
                "expected at $so")
        end

        # (5) Going-wide DEF/main-loop idiom (fork/join multi-source selection). Under the naive
        #     default these grew unbounded and never halted with (OUTPUT 1); the DEFAULT (coref)
        #     converges bounded (<100 steps) ≡ upstream byte-for-byte. _02/_11 emit (OUTPUT 1); _31
        #     is a two-program composition that legitimately emits none (upstream agrees).
        let progs = joinpath(
                @__DIR__, "..", "..", "experiments", "mm2_programs", "programs"
            )
            for (name, want_out) in (("Going_Wide_02.mm2", true),
                ("Going_Wide_11_Macros.mm2", true),
                ("Going_Wide_31_Two_Programs.mm2", false))
                gw = joinpath(progs, name)
                if isfile(gw)
                    our_gw = _ours_default(gw, 2_000)
                    @test our_gw == _upstream(gw, 100_000)             # DEFAULT ≡ upstream
                    @test any(l -> occursin("(OUTPUT 1)", l), our_gw) == want_out
                else
                    _oracle_missing("$name (going-wide fork/join idiom)", "expected at $gw")
                end
            end
        end

        # ASSERTION FLOOR — the guard against this file going inert AGAIN. Counting is the only way
        # to detect an oracle that runs to completion while asserting nothing: c543841's bug produced
        # exactly that shape (a green file contributing 0 of its 15 assertions), and no amount of
        # "0 failed" can distinguish it from real coverage. If a fixture is legitimately retired,
        # LOWER this number in the same commit — deliberately, in review.
        let n = Test.get_testset().n_passed
            @test n >= 15 || error(
                "upstream conformance contributed only $n assertions (floor 15) \
                                    — the oracle has gone (partly) INERT; find out why before trusting green"
            )
        end
    end
end
