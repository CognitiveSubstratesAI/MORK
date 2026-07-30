#!/usr/bin/env julia
# port_inventory.jl — PORT COVERAGE RATCHET: which upstream symbols does our Julia port not have?
#
# WHY THIS EXISTS (2026-07-29). After 30+ days of MORK/PathMap porting, with a 2436-test suite, a
# 277-probe byte-exact differential against the upstream binary, and a PathMap differential, symbol
# ABSENCE had no instrument at all. A behavioural differential compares OUTPUTS, so it can only see
# ops both sides can express; nothing measured what upstream offers and we never registered.
#
# 🔴🔴 THIS FILE'S OWN MOTIVATING EXAMPLE WAS FALSE — CORRECTED 2026-07-30. The header used to say the
# 42 typed comparison ops (`eq_/ne_/lt_/lte_/gt_/gte_` x `i8/i16/i32/i64/i128/f32/f64`) were missing.
# THEY WERE ALREADY PORTED, in `a1fef45` (2026-07-26), and verified by `pure_comparison_ops.jl`
# (79/79, wired at test/runtests.jl:4557). Proof by execution, not by grep:
#     julia --project=. -e 'using MORK; println(count(o -> haskey(MORK.PURE_OPS, o),
#       [n*"_"*t for n in ("lt","gt","lte","gte","eq","ne")
#                for t in ("i8","i16","i32","i64","i128","f32","f64")]))'   # => 42
#
# HOW THIS TOOL MANUFACTURED THAT FALSE ABSENCE — the defect it must never repeat:
#   `julia_symbols` harvested op keys by REGEXING SOURCE TEXT for literal `"name" =>` pairs. Our 42
#   keys are STRING-INTERPOLATED at load time (`PURE_OPS["$(name)_$(suffix)"]`, Pure.jl:1002), so
#   `grep -rn lt_i64 src/` returns ZERO HITS while the runtime Dict holds all 42. A source-text
#   scanner cannot see a name that no source line contains.
#   The count was sitting in plain view and went unreconciled: 490 literal pairs, 532 runtime keys.
#   532 - 490 = 42, the exact "gap".
#   Worse, the false number was then FROZEN AS A TEST EXPECTATION (`@test length(cmpops) == 42`), so
#   the suite asserted the ops were missing while `pure_comparison_ops.jl` in the SAME suite asserted
#   they worked — both green, asserting opposite facts. It also propagated into CODEMAP and into
#   commit `d700db3`, which UN-CORRECTED a correct row.
#
# ⇒ THE STRUCTURAL FIX, below: op keys are harvested from the LIVE REGISTRIES (`MORK.PURE_OPS`,
#   `MORK.GROUNDED_REGISTRY`), never from source text. A registry is the authority on its own keys.
#   An inventory tool whose job is proving ABSENCE must never guess at presence with a regex.
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
# 🔴 `experiments/eval` ADDED 2026-07-30 — it was missing, and it is where the EVALUATOR lives.
# `EvalScope`, `FuncType{Macro,Pure}`, `Func`, `StackFrame`, `add_func`, `push_eval`, `eval_impl` and
# the `alloc_pool` are all defined there (`experiments/eval/src/lib.rs`, 151 lines). `pure.rs` REGISTERS
# INTO that scope — `scope.add_func("lt_i64", …, FuncType::Pure)` — so the tool was reporting
# "kernel/pure.rs: 0 missing" while never once looking at the structure those 370 registrations target.
# Found by the user, not by the tool. Same blind-spot class as the interpolated-key bug: the
# instrument's SCOPE was wrong, so its green meant less than it appeared to.
const CRATES   = ["kernel", "expr", "frontend", "interning", "linalg", "experiments/eval"]

# ── extraction ────────────────────────────────────────────────────────────────────────────────────

"""
    strip_rust_comments(text) → String

Blank out `//` line comments and `/* … */` block comments, preserving line structure so any
line-numbered reporting stays honest. String and char literals are skipped, so a `"https://…"` is
NOT mistaken for a comment.

🔴 WHY: `rust_symbols` matched against RAW SOURCE, so **commented-out code counted as upstream API**.
`pure.rs:858-868` is a commented-out `// pub extern "C" fn nth_expr(…)`, which upstream registers
ZERO times — and the vendored baseline duly listed `kernel/pure.rs FN nth_expr`. We then carried an
`nth_expr` op to satisfy a symbol upstream does not have, and deleting it FAILED the inventory test.
An absence-prover that reads dead code manufactures obligations.

⚠️ This is the RULE for a defect that was already fixed as an INSTANCE: the line below used to be
`delete!(fns, "\$1")`, deleting exactly one artifact that came from the commented-out registration
template `// scope.add_func("\$1", \$1, …)` (:927). Same cause, same file, patched one name at a
time. Stripping comments subsumes it — `\$1` can no longer be produced, and neither can the next one.
[[feedback_recurring_defect_derive_the_rule]]
"""
function strip_rust_comments(text::AbstractString)
    out = IOBuffer()
    chars = collect(text)
    i, n = 1, length(chars)
    while i <= n
        c = chars[i]
        if c == '"'                                   # string literal — copy verbatim
            write(out, c); i += 1
            while i <= n
                if chars[i] == '\\' && i < n
                    write(out, chars[i]); write(out, chars[i + 1]); i += 2; continue
                end
                write(out, chars[i]); i += 1
                chars[i - 1] == '"' && break
            end
        elseif c == '/' && i < n && chars[i + 1] == '/'      # line comment
            while i <= n && chars[i] != '\n'; i += 1; end
        elseif c == '/' && i < n && chars[i + 1] == '*'      # block comment
            i += 2
            while i <= n && !(chars[i] == '*' && i < n && chars[i + 1] == '/')
                chars[i] == '\n' && write(out, '\n')         # keep line count
                i += 1
            end
            i += 2
        else
            write(out, c); i += 1
        end
    end
    String(take!(out))
end

"Public + macro-generated symbol names an upstream .rs file offers."
function rust_symbols(raw::AbstractString)
    text = strip_rust_comments(raw)
    fns = Set{String}()
    # `pub fn`, `pub(crate) fn`, `pub unsafe fn`, `pub extern "C" fn`, `pub const fn`
    for m in eachmatch(r"\bpub(?:\(crate\))?\s+(?:unsafe\s+|extern\s+\"C\"\s+|const\s+)*fn\s+(\w+)", text)
        push!(fns, m.captures[1])
    end
    # macro-generated numeric ops: `op!(num binary lt_i64(…))`, `op!(num from_string i64_from_string<i64>)`
    for m in eachmatch(r"op!\s*\(\s*(?:num\s+)?\w+\s+(\w+)", text); push!(fns, m.captures[1]); end
    # explicit registrations: `scope.add_func("lt_i64", …)`
    for m in eachmatch(r"add_func\(\s*\"([^\"]+)\"", text); push!(fns, m.captures[1]); end
    # (`delete!(fns, "$1")` used to live here. It is now unreachable by construction — the artifact
    #  came from a COMMENTED-OUT template, which strip_rust_comments removes. See that docstring.)
    tys = Set{String}()
    for m in eachmatch(r"\bpub\s+(?:struct|enum|trait|type)\s+(\w+)", text); push!(tys, m.captures[1]); end
    fns, tys
end

"""
Keys of the LIVE op registries — the authority on what our port actually answers to.

🔴 Read as a correction to a real defect: this replaces a source-text regex for `"name" =>` pairs that
reported all 42 interpolated comparison-op keys ABSENT while the runtime Dict held them (see header).
Source text is not the registry. Ask the registry.

Loading MORK is deliberate: it is the only way to observe a key that no source line spells out.

🔴 AND IT IS DELIBERATELY FATAL — no try/catch. The first version of this function swallowed a load
error and fell back to the text scan, which re-fabricated the exact same false 42-op gap, with only a
`@warn` between a broken tool and a wrong number written into CODEMAP. A tool whose entire purpose is
proving absence must FAIL LOUDLY rather than degrade into guessing. If this throws, fix the load.
"""
function runtime_op_keys()
    keys_ = Set{String}()
    # `Base.require` returns the Module VALUE, so there is no new global binding to resolve and no
    # world-age barrier. `@eval Main using MORK` + `Main.MORK` does NOT work here: the binding is
    # created in a newer world than the running method, and the getfield throws
    # "The binding may be too new: running in world age N, while current world is N+11".
    mork = isdefined(Main, :MORK) ? Base.invokelatest(getglobal, Main, :MORK) :
                                    Base.require(Main, :MORK)
    for reg in (:PURE_OPS, :GROUNDED_REGISTRY)
        d = Base.invokelatest(getglobal, mork, reg)
        for k in Base.invokelatest(keys, d); push!(keys_, String(k)); end
    end
    # SPECIAL FORMS are implemented in the evaluator, not the table — `ifnz` and `'` control their own
    # argument evaluation, so they can never be table-dispatched (see `PURE_SPECIAL_FORMS`). Without
    # this union, removing a dead `PURE_OPS["ifnz"]` entry makes a correctly-implemented conditional
    # read as an unported op.
    for k in Base.invokelatest(getglobal, mork, :PURE_SPECIAL_FORMS); push!(keys_, String(k)); end
    keys_
end

"Names our Julia port defines: functions, live registry op keys, and types."
function julia_symbols(root::AbstractString)
    names, tys = Set{String}(), Set{String}()
    union!(names, runtime_op_keys())     # ← authoritative; the regexes below are best-effort backup
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

"""
    upstream_revision() -> String

The upstream git branch + commit the baseline is being taken FROM, or "UNKNOWN" if the tree is not a
git checkout.

⚠️ THIS IS NOT DECORATION. A port-coverage baseline with no upstream revision is UNFALSIFIABLE: you
cannot tell a real gap from upstream having moved. The first cut of this file omitted it, and the
consequence showed up immediately — all 42 typed comparison ops in `kernel/src/pure.rs` read as "we
missed them for 30+ days" when in fact they landed upstream on 2026-07-02 (commits d57b312, c574be2,
debeba3; PR #125 `add-comparison`, which is main's HEAD). Our own Pure.jl work three weeks LATER
counted "338 of 341" against a 341-op picture while upstream registered 371 — a 30-op drift nobody
could see, because nothing recorded what "upstream" meant.

Branch matters as much as commit: our port draws from BOTH `main` and `server`, and `server` is ~55
days staler. The release binary the 277-probe differential grades us against is built from MAIN, so
MAIN is the anchor. A baseline extracted from a `server` checkout would silently grade us against
code upstream has moved past.
"""
function upstream_revision()::String
    isdir(joinpath(UPSTREAM, ".git")) || return "UNKNOWN (not a git checkout)"
    try
        br = strip(read(`git -C $UPSTREAM rev-parse --abbrev-ref HEAD`, String))
        sha = strip(read(`git -C $UPSTREAM rev-parse --short HEAD`, String))
        dt = strip(read(`git -C $UPSTREAM log -1 --format=%ad --date=short`, String))
        "$br @ $sha ($dt)"
    catch
        "UNKNOWN (git query failed)"
    end
end

function write_baseline(rows)
    rev = upstream_revision()
    open(BASELINE, "w") do io
        println(io, "# PORT_INVENTORY — upstream MORK symbol inventory, VENDORED.")
        println(io, "# UPSTREAM: ", rev)
        println(io, "#   ^ REQUIRED. Without it this file cannot distinguish a port gap from upstream drift.")
        println(io, "#     Our port draws from main AND server; the differential binary is built from MAIN,")
        println(io, "#     so MAIN is the anchor. See `upstream_revision` in tools/port_inventory.jl.")
        println(io, "# Regenerate: MORK_UPSTREAM=<path> julia --project=. tools/port_inventory.jl --extract")
        println(io, "# Format:  <crate/file>\\tFN|TY\\t<name>")
        for (file, (fns, tys)) in rows
            for n in fns; println(io, file, "\t", "FN", "\t", n); end
            for n in tys; println(io, file, "\t", "TY", "\t", n); end
        end
    end
    println("wrote $(BASELINE)  ($(sum(length(v[1]) + length(v[2]) for (_, v) in rows)) symbols)")
end

"The UPSTREAM revision recorded in the vendored baseline, or a loud marker if absent."
function baseline_revision()::String
    isfile(BASELINE) || return "NO BASELINE"
    for line in eachline(BASELINE)
        startswith(line, "# UPSTREAM: ") && return strip(line[13:end])
        startswith(line, "#") || break
    end
    "UNPINNED — regenerate with --extract"
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
    println("baseline UPSTREAM: ", baseline_revision())
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
