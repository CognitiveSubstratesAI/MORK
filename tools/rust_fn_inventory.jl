#!/usr/bin/env julia
# rust_fn_inventory.jl — WHICH `pub fn` OF A RUST FILE HAVE NO DEFINITION ON OUR SIDE?
#
# WHY THIS EXISTS (2026-07-31). `port_inventory.jl` answers the same question for pure.rs's
# RUNTIME-REGISTERED op names, which is a different instrument: it set-compares registry keys. There
# was nothing for "is this Rust FILE fully ported", and the cost of not having it was measured on
# expr/src/lib.rs the day this was written --- after three batches and 154 targeted tests, a
# definition-site sweep still found FIVE genuinely absent functions (`leaves`, `expressions`,
# `symbols`, `difference`, `unifiable`) plus `traverse`. None had been noticed by reading.
#
# 🔴 IT ALSO REPORTS FALSE POSITIVES BY DESIGN, and that is the point: it lists candidates for a
# HUMAN to filter, it does not pronounce. The three filters that must be applied to its output, all
# of which have burned this port before:
#
#   1. RENAMES the heuristic cannot derive. `execute_loop` is ported as `expr_traverseh`;
#      `_unify` as `expr_unify`. Nothing textual connects those. (It DOES handle camelCase ->
#      snake_case, so `transformData` -> `expr_transform_data` resolves.)
#   2. DELIBERATE non-ports. `with_seed`/`finish_u128` are the GxHasher stub, which is test-only in
#      this crate --- porting them would add API with no consumer.
#   3. CONSTRUCTS WITH NO JULIA FUNCTION. `new` is a Julia constructor; `hash` resolves to XXH3.
#
# It already applies the three filters that are MECHANICAL, and each of those was a real defect
# source: comments are STRIPPED (a commented-out `nth_expr` was once counted as upstream API), and
# `#[cfg(test)]` modules are DROPPED brace-matched (test-only code is not port surface).
#
# USAGE
#   julia --project=. tools/rust_fn_inventory.jl <upstream.rs> [our_dirs ...]
#   julia --project=. tools/rust_fn_inventory.jl ~/JuliaAGI/dev-zone/MORK/expr/src/lib.rs src
#
# PREFIXES. Our port names a ported method by its OWNER, not its file: space.rs's `add_all_sexpr`
# is `space_add_all_sexpr!`, expr/lib.rs's `variables` is `expr_variables`. The default prefix set
# below covers every convention in this repo. Getting it wrong is loud, not silent --- the first run
# of this tool against space.rs reported 39 of 40 "missing" because `space_` was not in the list.

function strip_comments(src::AbstractString)::String
    out = IOBuffer(); i = 1; n = lastindex(src)
    while i <= n
        if i + 1 <= n && src[i] == '/' && src[i + 1] == '/'
            j = findnext('\n', src, i); i = j === nothing ? n + 1 : j
        elseif i + 1 <= n && src[i] == '/' && src[i + 1] == '*'
            j = findnext("*/", src, i); i = j === nothing ? n + 1 : last(j) + 1
        else
            write(out, src[i]); i = nextind(src, i)
        end
    end
    String(take!(out))
end

"""
Delete every item gated on `attr`, brace-matched.

Used for `#[cfg(test)]` (test-only code is not port surface) and for `#[cfg(feature="…")]`, whose
functions are only port surface if the feature is in the crate's DEFAULT set. Getting this wrong is
how `GxHasher` was once ported by mistake: the gate sat at MODULE level, above a three-line lookback.
"""
function drop_gated(src::AbstractString, attr::AbstractString)::String
    s = src
    while true
        m = findfirst(attr, s)
        m === nothing && return s
        b = findnext('{', s, last(m))
        b === nothing && return s
        d = 0; k = b
        while k <= lastindex(s)
            s[k] == '{' && (d += 1)
            s[k] == '}' && (d -= 1; d == 0 && break)
            k = nextind(s, k)
        end
        s = s[1:prevind(s, first(m))] * s[nextind(s, k):end]
    end
end

"""
The crate's DEFAULT feature set, from the nearest Cargo.toml above `path`.

🔴 THIS LOOKUP IS THE WHOLE POINT. A `#[cfg(feature="x")]` function is port surface exactly when `x`
is enabled by default; excluding every feature-gated function hides real gaps. Caught while writing
this tool: `transform_multi_multi_{,_i,_o}` are gated on `specialize_io`, which IS in
`default = ["grounding", "specialize_io"]` --- so they are LIVE, and a blanket exclusion would have
buried three genuine absences behind an "excluded" label.
"""
function default_features(path::AbstractString)::Set{String}
    d = dirname(abspath(path))
    while true
        f = joinpath(d, "Cargo.toml")
        if isfile(f)
            m = match(r"^\s*default\s*=\s*\[([^\]]*)\]"m, read(f, String))
            m === nothing && return Set{String}()
            return Set{String}(strip(x, [' ', '"', '\t']) for x in split(m.captures[1], ",") if !isempty(strip(x)))
        end
        nd = dirname(d)
        nd == d && return Set{String}()
        d = nd
    end
end

"`pub fn`s under a cfg(feature=…) gate, split into enabled-by-default (port surface) and not."
function feature_gated(src::AbstractString, defaults::Set{String})
    on, off = String[], String[]
    for m in eachmatch(r"#\[cfg\(feature\s*=\s*\"([^\"]+)\"\)\]\s*(?:pub )?fn\s+([A-Za-z_][A-Za-z0-9_]*)", src)
        feat, fn = m.captures[1], m.captures[2]
        push!(feat in defaults ? on : off, fn * "  (feature=\"" * feat * "\")")
    end
    sort!(unique!(on)), sort!(unique!(off))
end

snake(n) = lowercase(replace(n, r"(?<!^)(?=[A-Z])" => "_"))

# Every owner-prefix convention this port uses. See the PREFIXES note in the header.
const PREFIXES = ("", "expr_", "ez_", "ee_", "_expr_", "space_", "_space_", "sink_", "_sink_",
                  "source_", "_source_", "pure_", "_pure_", "scope_", "eval_", "trie_", "morkl_",
                  "fe_", "sexpr_", "json_", "dyck_", "zipper_", "_")

function main(args)
    isempty(args) && (println("usage: rust_fn_inventory.jl <upstream.rs> [our_dirs...]"); return)
    rs = args[1]
    dirs = length(args) > 1 ? args[2:end] : ["src"]

    raw = strip_comments(read(rs, String))
    defaults = default_features(rs)
    gated_on, gated_off = feature_gated(raw, defaults)
    clean = drop_gated(raw, "#[cfg(test)]")
    names = sort(unique(String[m.captures[1] for m in eachmatch(r"\bpub fn\s+([A-Za-z_][A-Za-z0-9_]*)", clean)]))

    ours = IOBuffer()
    for d in dirs, (root, _, files) in walkdir(d), f in files
        endswith(f, ".jl") && write(ours, read(joinpath(root, f), String), "\n")
    end
    body = String(take!(ours))
    defs = Set{String}(m.captures[1] for m in
        eachmatch(r"^\s*(?:function\s+|const\s+)?([A-Za-z_][A-Za-z0-9_!]*)\s*(?:\(|=)"m, body))

    function present(n)
        # strip BOTH a leading and a trailing underscore: upstream's `_unify` is `expr_unify`, and
        # its `transform_multi_multi_` is `space_transform_multi_multi!`.
        bases = Set{String}([n, snake(n), strip(n, '_'), strip(snake(n), '_'),
                             lstrip(n, '_'), lstrip(snake(n), '_')])
        for b in bases, pre in PREFIXES
            (pre * b in defs || pre * b * "!" in defs) && return true
        end
        false
    end

    # ONLY non-default features are excluded; a default-on gate is ordinary port surface.
    off_names = Set{String}(first(split(g, "  ")) for g in gated_off)
    missing_ = filter(n -> !present(n) && !(n in off_names), names)
    println("upstream `pub fn` (comments stripped, cfg(test) dropped): ", length(names))
    println("no definition found under our naming conventions:        ", length(missing_))
    println()
    for m in missing_
        println("    ", m)
    end
    println()
    println("Cargo.toml default features: ", isempty(defaults) ? "(none found)" : join(sort(collect(defaults)), ", "))
    if !isempty(gated_on)
        println("cfg(feature=…) gates that are ON by default — PORT SURFACE, listed above if absent:")
        for g in gated_on
            println("    ", g)
        end
    end
    if !isempty(gated_off)
        println("cfg(feature=…) gates OFF by default — excluded:")
        for g in gated_off
            println("    ", g)
        end
    end
    println()
    println("⚠️  CANDIDATES, NOT VERDICTS — filter by hand for renames, deliberate non-ports, and")
    println("    constructs with no Julia function (see this file's header).")
end

main(ARGS)
