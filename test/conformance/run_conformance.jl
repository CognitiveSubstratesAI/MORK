# run_conformance.jl — differential conformance gate against the upstream `mork` binary.
#
# WHY THIS EXISTS. Between 2026-07-25 and 07-26 a whole-file cross-check of upstream's `sinks.rs`,
# `space.rs` and `pure.rs` found NINE silent defects — wrong answers and one crash — NONE of which the
# then-1933-test suite could catch, because no fixture exercised the shapes. Every one was found by
# running a small MM2 program through BOTH engines and diffing the dumps. This directory is that
# corpus, vendored so the check survives: 277 probes, each paired with the output of the upstream
# release binary (`mork run <probe>.mm2`), re-pinned by hand rather than taken on trust.
#
# WHAT IT GUARDS. `EXPECTED_PASS` records exactly which probes match upstream TODAY.
#   * a probe in that list that stops matching  -> FAILS the suite (a regression)
#   * a probe outside it that starts matching   -> logs, and asks you to move it into the list
# So the gate is green at the current conformance level and gets strictly tighter over time. It does
# NOT demand 277/277: the probes outside the list are KNOWN divergences, catalogued in
# `KNOWN_DIVERGENCE` below with the reason each is still open.
#
# RENDERING. Upstream prints variables as `$a`/`$b` (coreference by NAME); we print `$` for a fresh
# NewVar and `_N` for a back-reference. `(f $a $a)` and `(f $ _1)` are THE SAME ATOM. Comparing raw
# text therefore reports divergences that do not exist — an early run of this corpus read 65/150 before
# canonicalisation and 81/150 after. `_conf_canon` normalises both notations to V0,V1,… by first
# occurrence, so only STRUCTURAL differences count. Non-printable bytes are escaped as `\xNN`, matching
# our dump.
#
# The upstream binary is NOT required to run this gate — its output is vendored in the `.expected`
# files. Regenerate them only against a freshly built upstream binary:  mork run <probe>.mm2
using MORK, Test

const _CONF_DIR = @__DIR__

# Canonicalise one dumped atom: upstream `$a`/`$b` (named, coref by name) and our `$`/`_N` (de Bruijn)
# both become V0,V1,… by first occurrence. Symbols/numbers/operators pass through untouched.
function _conf_canon(s::AbstractString)::String
    toks = collect(eachmatch(r"\$[a-zA-Z][a-zA-Z0-9_]*|\$|_\d+|\(|\)|[^\s()]+", s))
    out = String[]; named = Dict{String,String}(); newvars = String[]; nk = Ref(0)
    fresh() = (v = "V$(nk[])"; nk[] += 1; v)
    for m in toks
        t = m.match
        if t == "(" || t == ")"
            push!(out, t)
        elseif occursin(r"^\$[a-zA-Z]", t)                    # upstream named var
            haskey(named, t) || (named[t] = fresh(); push!(newvars, named[t]))
            push!(out, named[t])
        elseif t == "\$"                                       # our fresh NewVar
            v = fresh(); push!(newvars, v); push!(out, v)
        elseif occursin(r"^_\d+$", t)                          # our back-reference
            n = parse(Int, t[2:end])
            push!(out, 1 <= n <= length(newvars) ? newvars[n] : t)
        else
            push!(out, t)
        end
    end
    r = IOBuffer()
    for tk in out
        if tk == "("
            print(r, "(")
        elseif tk == ")"
            print(r, ")")
        else
            p = position(r)
            p > 0 && (seek(r, p - 1); c = read(r, UInt8); seekend(r); c != UInt8('(') && print(r, " "))
            print(r, tk)
        end
    end
    String(take!(r))
end

# The `.expected` files hold upstream's RAW bytes; our dump escapes non-printables as `\xNN`.
_conf_norm_bytes(b::Vector{UInt8}) =
    join(map(c -> (0x20 <= c < 0x7f) ? string(Char(c)) : "\\x" * string(c; base = 16, pad = 2), b))

_conf_sorted(lines) = sort!([_conf_canon(strip(l)) for l in lines if !isempty(strip(l))])

function _conf_run_probe(path::AbstractString)::Union{Vector{String}, Nothing}
    try
        s = MORK.new_space()
        MORK.space_add_all_sexpr!(s, read(path, String))
        MORK.space_metta_calculus!(s, 2000)     # cap: several probes are non-halting BY DESIGN
        # Normalise OUR bytes exactly as `_conf_expected` normalises upstream's. Our dump now
        # emits symbol bytes VERBATIM (matching upstream, whose escaping never round-tripped —
        # see expr_serialize), so the escaping has to happen HERE, on both sides, rather than
        # being baked into the dump. Comparing a verbatim dump against normalised expectations
        # would fail on escaping style rather than on content.
        lines = split(MORK.space_dump_all_sexpr(s), '\n')
        _conf_sorted([_conf_norm_bytes(Vector{UInt8}(codeunits(l))) for l in lines])
    catch
        nothing                                  # a throw is never a pass — reported as divergent
    end
end

function _conf_expected(path::AbstractString)::Vector{String}
    # Read as BYTES (not text): upstream writes raw control bytes for e.g. ip_sudoku's bitmasks, which
    # are not valid UTF-8. Split on newline manually, then escape each line the way our dump does.
    raw = read(path)
    lines = Vector{String}()
    start = 1
    for i in eachindex(raw)
        if raw[i] == UInt8('\n')
            i > start && push!(lines, _conf_norm_bytes(raw[start:(i - 1)]))
            start = i + 1
        end
    end
    start <= length(raw) && push!(lines, _conf_norm_bytes(raw[start:end]))
    _conf_sorted(lines)
end

"Run every vendored probe; return (passing::Set{String}, total::Int, orphans::Vector{String}).\n`orphans` are .mm2 files with NO .expected — they run nothing and must be reported, not skipped."
function conformance_results()
    passing = Set{String}(); total = 0; orphans = String[]
    for group in ("sinks", "space")
        dir = joinpath(_CONF_DIR, group)
        isdir(dir) || continue
        for f in sort(readdir(dir))
            endswith(f, ".mm2") || continue
            name = group * "/" * f[1:(end - 4)]
            exp_path = joinpath(dir, f[1:(end - 4)] * ".expected")
            # A .mm2 with no .expected used to `continue` BEFORE `total += 1`, so it vanished from
            # the corpus silently — never run, never counted, never reported. That is strictly worse
            # than a missing probe: the count still looks healthy. It bit a probe added 2026-07-27
            # within hours. Record it and let the gate SHOUT instead of skipping.
            if !isfile(exp_path)
                push!(orphans, name)
                continue
            end
            total += 1
            got = _conf_run_probe(joinpath(dir, f))
            got !== nothing && got == _conf_expected(exp_path) && push!(passing, name)
        end
    end
    (passing, total, orphans)
end
