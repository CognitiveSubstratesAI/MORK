#!/usr/bin/env julia
# port_inventory.jl — PORT COVERAGE RATCHET: which upstream symbols does our Julia port not have?
#
# WHY THIS EXISTS (2026-07-29). After 30+ days of MORK/PathMap porting, with a 2436-test suite, a
# 277-probe byte-exact differential against the upstream binary, and a PathMap differential, an ENTIRE
# upstream op family was found missing by accident: all 42 typed comparison ops in `kernel/src/pure.rs`
# (`eq_/ne_/lt_/lte_/gt_/gte_` x `i8/i16/i32/i64/i128/f32/f64`). Worse, a substitute had been built
# (`ifnz(sub(max(x,y),x),T,E)`) and written into CODEMAP as though derivation were the only option,
# which made the hole look like a design decision.
#
# 🔴 THE REASON EVERY EXISTING GATE MISSED IT — this is the whole point of this file:
#
#   A BEHAVIOURAL DIFFERENTIAL CANNOT SEE ABSENCE. It compares outputs, so both sides must be able to
#   EXPRESS the program. For a WRONG op, both run and the diff catches it. For a MISSING op there is
#   nothing to run — you would have to author an MM2 probe calling `lt_i64`, and nobody writes a probe
#   for an op their engine does not have. The corpus is self-selecting.
#
#   Two further traps made it invisible:
#     * The conformance gate is a RATCHET, not a coverage measure. `EXPECTED_PASS` records which probes
#       match upstream TODAY; it is silent about what is not probed. `test/conformance/pure_ops/README.md`
#       measured the real figure on 2026-07-28 — 18 of 360 pure ops probed, 5% — and that measurement
#       sat next to an UNWIRED harness (`cmp_pure.jl` needs `ENV["PROBES"]`; nothing calls it).
#     * OUR OP COUNT IS HIGHER THAN UPSTREAM'S — 490 `PURE_OPS` keys vs 371 upstream registrations. Any
#       "do we have enough?" sanity check REASSURES. A superset by count can still be missing a family.
#
# So absence needs a different instrument from divergence: an INVENTORY DIFF over symbol NAMES.
#
# USAGE
#   julia --project=. tools/port_inventory.jl              # report against the vendored baseline
#   julia --project=. tools/port_inventory.jl --update     # re-vendor the baseline (review the diff!)
#   MORK_UPSTREAM=/path/to/MORK julia … tools/port_inventory.jl --extract   # re-extract from Rust
#
# The upstream symbol list is VENDORED into `test/conformance/PORT_INVENTORY.txt` exactly as the
# conformance gate vendors its `.expected` files, so the ratchet runs with no Rust tree present.
# Re-extract only against a known upstream commit, and say which commit in the commit message.

using Printf

const UPSTREAM = get(ENV, "MORK_UPSTREAM", expanduser("~/JuliaAGI/dev-zone/MORK"))
const HERE     = normpath(joinpath(@__DIR__, ".."))
const BASELINE = joinpath(HERE, "test", "conformance", "PORT_INVENTORY.txt")
const CRATES   = ["kernel", "expr", "frontend", "interning", "linalg"]

# ── extraction ────────────────────────────────────────────────────────────────────────────────────

"Public + macro-generated symbol names an upstream .rs file offers."
function rust_symbols(text::AbstractString)
    fns = Set{String}()
    # `pub fn`, `pub(crate) fn`, `pub unsafe fn`, `pub extern "C" fn`, `pub const fn`
    for m in eachmatch(r"\bpub(?:\(crate\))?\s+(?:unsafe\s+|extern\s+\"C\"\s+|const\s+)*fn\s+(\w+)", text)
        push!(fns, m.captures[1])
    end
    # macro-generated numeric ops: `op!(num binary lt_i64(…))`, `op!(num from_string i64_from_string<i64>)`
    for m in eachmatch(r"op!\s*\(\s*(?:num\s+)?\w+\s+(\w+)", text); push!(fns, m.captures[1]); end
    # explicit registrations: `scope.add_func("lt_i64", …)`
    for m in eachmatch(r"add_func\(\s*\"([^\"]+)\"", text); push!(fns, m.captures[1]); end
    delete!(fns, "\$1")            # macro-expansion artifact, not a real op
    tys = Set{String}()
    for m in eachmatch(r"\bpub\s+(?:struct|enum|trait|type)\s+(\w+)", text); push!(tys, m.captures[1]); end
    fns, tys
end

"Names our Julia port defines: functions, Dict-registered op keys, and types."
function julia_symbols(root::AbstractString)
    names, tys = Set{String}(), Set{String}()
    for (dir, _, files) in walkdir(root), f in files
        endswith(f, ".jl") || continue
        text = read(joinpath(dir, f), String)
        for m in eachmatch(r"^\s*function\s+([A-Za-z_][\w!]*)"m, text); push!(names, m.captures[1]); end
        for m in eachmatch(r"^\s*([a-z_][\w!]*)\s*\("m, text);          push!(names, m.captures[1]); end
        for m in eachmatch(r"\"([A-Za-z_][\w]*)\"\s*=>", text);         push!(names, m.captures[1]); end
        for m in eachmatch(r"^\s*(?:mutable\s+)?struct\s+(\w+)"m, text); push!(tys, m.captures[1]); end
        for m in eachmatch(r"^\s*abstract\s+type\s+(\w+)"m, text);       push!(tys, m.captures[1]); end
        for m in eachmatch(r"^\s*@enum\s+(\w+)"m, text);                 push!(tys, m.captures[1]); end
        # ⚠️ ALSO `const X = Union{…}` / `const X = SomeType`. MISSING THIS produced a FALSE 35% type
        # coverage on 2026-07-29 and reported `ASink`, `ASource`, `AFactor`, `HeadTailSink`,
        # `ParDataParser`, `SourceItem`, `Tag` as unported when all seven are present. The port maps
        # Rust ENUM dispatch wrappers onto Julia UNION ALIASES on purpose — `Sinks.jl:1363` is
        # literally "ASink — dispatch union" — so a type diff that only knows `struct` invents gaps.
        # Inventing a gap is worse than missing one: it sends people to re-port working code.
        for m in eachmatch(r"^\s*const\s+([A-Z]\w*)\s*=", text);          push!(tys, m.captures[1]); end
        # last resort: a type NAME mentioned anywhere in our source counts as present. Deliberately
        # lenient — this instrument exists to prove ABSENCE, so it must under-report gaps, never
        # fabricate them.
        for m in eachmatch(r"\b([A-Z]\w{2,})\b", text);                   push!(tys, m.captures[1]); end
    end
    names, tys
end

# Our port renames deliberately: upstream's `impl Space { fn query_multi }` is our
# `space_query_multi`, `Expr::unify` is `expr_unify`, and `!`-suffixes mark mutation. So a LITERAL
# name diff reports every space function as missing. Accept those conventions — and note this makes
# the check LENIENT: a coincidental suffix match counts as present, so the reported coverage is a
# CEILING. A name this accepts may still be a different function; only a behavioural probe proves
# equivalence. Absence is what this instrument is for.
function port_has(name::AbstractString, ours::Set{String})
    (name in ours || name * "!" in ours) && return true
    for p in ("space_", "expr_", "ez_", "sink_", "source_", "act_", "trie_", "_")
        (p * name in ours || p * name * "!" in ours) && return true
    end
    any(o -> endswith(o, "_" * name) || endswith(o, "_" * name * "!"), ours)
end

# ── report ────────────────────────────────────────────────────────────────────────────────────────

function extract_upstream()
    isdir(UPSTREAM) || error("upstream not found at $UPSTREAM — set MORK_UPSTREAM")
    out = Pair{String, Tuple{Vector{String}, Vector{String}}}[]
    for crate in CRATES
        d = joinpath(UPSTREAM, crate)
        isdir(d) || continue
        for (dir, _, files) in walkdir(d), f in sort(files)
            endswith(f, ".rs") || continue
            fns, tys = rust_symbols(read(joinpath(dir, f), String))
            (isempty(fns) && isempty(tys)) && continue
            push!(out, "$crate/$f" => (sort(collect(fns)), sort(collect(tys))))
        end
    end
    sort!(out; by = first)
end

function write_baseline(rows)
    open(BASELINE, "w") do io
        println(io, "# PORT_INVENTORY — upstream MORK symbol inventory, VENDORED.")
        println(io, "# Regenerate: MORK_UPSTREAM=<path> julia --project=. tools/port_inventory.jl --extract")
        println(io, "# Format:  <crate/file>\\tFN|TY\\t<name>")
        for (file, (fns, tys)) in rows
            for n in fns; println(io, file, "\t", "FN", "\t", n); end
            for n in tys; println(io, file, "\t", "TY", "\t", n); end
        end
    end
    println("wrote $(BASELINE)  ($(sum(length(v[1]) + length(v[2]) for (_, v) in rows)) symbols)")
end

function read_baseline()
    isfile(BASELINE) || error("no vendored baseline at $BASELINE — run with --extract")
    rows = Dict{String, Tuple{Vector{String}, Vector{String}}}()
    for line in eachline(BASELINE)
        (isempty(line) || startswith(line, "#")) && continue
        file, kind, name = split(line, '\t')
        f, t = get!(rows, file, (String[], String[]))
        kind == "FN" ? push!(f, name) : push!(t, name)
    end
    sort!(collect(rows); by = first)
end

"Return (missing_fns, missing_tys) per file, plus totals. Pure — the test wraps this."
function coverage()
    ours_names, ours_tys = julia_symbols(joinpath(HERE, "src"))
    rows = read_baseline()
    report = Pair{String, Tuple{Vector{String}, Vector{String}}}[]
    tf = tfm = tt = ttm = 0
    for (file, (fns, tys)) in rows
        fm = sort([n for n in fns if !port_has(n, ours_names)])
        tm = sort([n for n in tys if !(n in ours_tys)])
        push!(report, file => (fm, tm))
        tf += length(fns); tfm += length(fm); tt += length(tys); ttm += length(tm)
    end
    (; report, fns_total = tf, fns_missing = tfm, tys_total = tt, tys_missing = ttm)
end

function main(args)
    if "--extract" in args
        write_baseline(extract_upstream()); return
    end
    c = coverage()
    println(rpad("upstream file", 36), lpad("fns MISSING", 12), lpad("types MISSING", 15))
    println("-"^63)
    for (file, (fm, tm)) in c.report
        nf = length(fm); nt = length(tm)
        (nf == 0 && nt == 0) && continue
        println(rpad(file, 36), lpad(nf, 5), lpad(nt, 6))
    end
    println("-"^63)
    @printf("TOTAL  functions %d/%d (%d%%)   types %d/%d (%d%%)\n",
            c.fns_total - c.fns_missing, c.fns_total,
            100 * (c.fns_total - c.fns_missing) ÷ max(c.fns_total, 1),
            c.tys_total - c.tys_missing, c.tys_total,
            100 * (c.tys_total - c.tys_missing) ÷ max(c.tys_total, 1))
    println("\n⚠️  LENIENT by construction (see port_has): reported coverage is a CEILING.")
    println("    Absence is proof of a gap; presence is NOT proof of equivalence.")
end

if abspath(PROGRAM_FILE) == abspath(@__FILE__)
    main(ARGS)
end
