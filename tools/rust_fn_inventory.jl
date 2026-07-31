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
#   julia --project=. tools/rust_fn_inventory.jl <upstream.rs> [our_source_glob ...]
#   julia --project=. tools/rust_fn_inventory.jl ~/JuliaAGI/dev-zone/MORK/expr/src/lib.rs src/expr src/kernel

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

"Delete every `#[cfg(test)]` item, brace-matched — test-only code is not port surface."
function drop_cfg_test(src::AbstractString)::String
    s = src
    while true
        m = findfirst("#[cfg(test)]", s)
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

snake(n) = lowercase(replace(n, r"(?<!^)(?=[A-Z])" => "_"))

function main(args)
    isempty(args) && (println("usage: rust_fn_inventory.jl <upstream.rs> [our_dirs...]"); return)
    rs = args[1]
    dirs = length(args) > 1 ? args[2:end] : ["src"]

    clean = drop_cfg_test(strip_comments(read(rs, String)))
    names = sort(unique(String[m.captures[1] for m in eachmatch(r"\bpub fn\s+([A-Za-z_][A-Za-z0-9_]*)", clean)]))

    ours = IOBuffer()
    for d in dirs, (root, _, files) in walkdir(d), f in files
        endswith(f, ".jl") && write(ours, read(joinpath(root, f), String), "\n")
    end
    body = String(take!(ours))
    defs = Set{String}(m.captures[1] for m in
        eachmatch(r"^\s*(?:function\s+|const\s+)?([A-Za-z_][A-Za-z0-9_!]*)\s*(?:\(|=)"m, body))

    function present(n)
        bases = Set{String}([n, snake(n), lstrip(n, '_'), lstrip(snake(n), '_')])
        for b in bases, pre in ("", "expr_", "ez_", "ee_", "_expr_")
            (pre * b in defs || pre * b * "!" in defs) && return true
        end
        false
    end

    missing_ = filter(!present, names)
    println("upstream `pub fn` (comments stripped, cfg(test) dropped): ", length(names))
    println("no definition found under our naming conventions:        ", length(missing_))
    println()
    for m in missing_
        println("    ", m)
    end
    println()
    println("⚠️  CANDIDATES, NOT VERDICTS — filter by hand for renames, deliberate non-ports, and")
    println("    constructs with no Julia function (see this file's header).")
end

main(ARGS)
