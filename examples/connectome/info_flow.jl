# info_flow.jl — Drosophila Fig-6 information-flow on the PERSISTED connectome store.
#
# The debt-free successor to info_flow_zipper.jl / info_flow_all_modalities.jl:
#   - reads S_rule.act (synapses) + S_ent.act (ontology) from the manifest store
#     (cold-mmap, instant) — NOT /tmp/fafb.act, NOT a re-ingested TSV;
#   - DERIVES seeds from S_ent via query_seeds — NOT /tmp/seed_<mod>.txt;
#   - keeps the validated zipper-frontier flow (the measured-scalable path);
#   - ships an INDEPENDENT in-Julia oracle (naive full-rescan each round) and
#     asserts flow == oracle — the regression, re-derived from the persisted store.
#
# Run via the warm MORK REPL (include this file), then `validate(manifest(), "thermosensory")`.

using MORK
using MORK: ExprArity, ExprSymbol, item_byte, byte_item
using PathMap: read_zipper_at_path, zipper_to_next_val!, zipper_path

const _CDIR = @__DIR__
include(joinpath(_CDIR, "manifest.jl"))
include(joinpath(_CDIR, "load_ent.jl"))    # query_seeds, build_s_ent!
include(joinpath(_CDIR, "load_rule.jl"))   # build_s_rule!
using .ConnectomeManifest

# ── byte helpers (syn pre post cnt), shared with the loaders' encoding ────────
const SYN_PREFIX = vcat(UInt8[item_byte(ExprArity(UInt8(4))), item_byte(ExprSymbol(UInt8(3)))],
                        codeunits("syn"))

@inline function syn_pre_prefix(r::AbstractString)::Vector{UInt8}
    n = ncodeunits(r); rb = codeunits(r); sb = codeunits("syn")
    buf = Vector{UInt8}(undef, 6 + n)
    buf[1] = item_byte(ExprArity(UInt8(4))); buf[2] = item_byte(ExprSymbol(UInt8(3)))
    @inbounds for i in 1:3; buf[2+i] = sb[i]; end
    buf[6] = item_byte(ExprSymbol(UInt8(n)))
    @inbounds for i in 1:n; buf[6+i] = rb[i]; end
    buf
end

@inline function _parse_post_cnt(rel::Vector{UInt8})
    isempty(rel) && return nothing
    t1 = byte_item(rel[1]); t1 isa ExprSymbol || return nothing
    plen = Int(t1.size); pos = 2 + plen; pos > length(rel) && return nothing
    post = String(@view rel[2:1+plen])
    t2 = byte_item(rel[pos]); t2 isa ExprSymbol || return nothing
    clen = Int(t2.size); pos + clen > length(rel) && return nothing
    cnt = tryparse(Int, String(@view rel[pos+1:pos+clen])); cnt === nothing && return nothing
    (post, cnt)
end

@inline function _parse_pre_post_cnt(rel::Vector{UInt8})
    isempty(rel) && return nothing
    t1 = byte_item(rel[1]); t1 isa ExprSymbol || return nothing
    plen = Int(t1.size); pos = 2 + plen; pos > length(rel) && return nothing
    pc = _parse_post_cnt(rel[pos:end]); pc === nothing && return nothing
    (String(@view rel[2:1+plen]), pc[1], pc[2])
end

# ── total-in per post (one Σ pass over all syn atoms) ─────────────────────────
function compute_tin(btm)
    tin = Dict{String, Int}()
    rz = read_zipper_at_path(btm, SYN_PREFIX)
    while zipper_to_next_val!(rz)
        pc = _parse_pre_post_cnt(collect(zipper_path(rz))); pc === nothing && continue
        _, post, cnt = pc; tin[post] = get(tin, post, 0) + cnt
    end
    tin
end

# ── zipper-frontier flow (the validated, scalable path) ───────────────────────
function _apply_frontier!(rin::Dict{String,Int}, btm, frontier::Vector{String})
    for r in frontier
        rz = read_zipper_at_path(btm, syn_pre_prefix(r))
        while zipper_to_next_val!(rz)
            pc = _parse_post_cnt(collect(zipper_path(rz))); pc === nothing && continue
            post, cnt = pc; rin[post] = get(rin, post, 0) + cnt
        end
    end
end

function flow_ranks(btm, seeds::Vector{String}, tin::Dict{String,Int};
                    threshold::Float64=0.3, max_rounds::Int=30)
    reached = Set{String}(seeds)
    ranks   = Dict{String,Int}(sd => 0 for sd in seeds)
    rin     = Dict{String,Int}()
    _apply_frontier!(rin, btm, collect(seeds))
    for k in 1:max_rounds
        next = String[]
        for (post, sr) in rin
            post in reached && continue
            st = get(tin, post, 0); st <= 0 && continue
            sr / st >= threshold || continue
            push!(next, post); push!(reached, post); ranks[post] = k
        end
        isempty(next) && break
        _apply_frontier!(rin, btm, next)
    end
    ranks
end

# ── INDEPENDENT oracle: build full adjacency, naive full-rescan each round ────
# Deliberately NOT the frontier optimization — recomputes reached-in from the
# whole edge list every round, so agreement validates the zipper-frontier path.
function build_adjacency(btm)
    out = Dict{String, Vector{Tuple{String,Int}}}()
    tin = Dict{String, Int}()
    rz = read_zipper_at_path(btm, SYN_PREFIX)
    while zipper_to_next_val!(rz)
        pc = _parse_pre_post_cnt(collect(zipper_path(rz))); pc === nothing && continue
        pre, post, cnt = pc
        push!(get!(out, pre, Tuple{String,Int}[]), (post, cnt))
        tin[post] = get(tin, post, 0) + cnt
    end
    (out, tin)
end

function oracle_ranks(out, tin, seeds::Vector{String}; threshold::Float64=0.3, max_rounds::Int=30)
    reached = Set{String}(seeds)
    ranks   = Dict{String,Int}(sd => 0 for sd in seeds)
    for k in 1:max_rounds
        rin = Dict{String,Int}()                       # recompute from scratch
        for r in reached, (post, cnt) in get(out, r, ())
            rin[post] = get(rin, post, 0) + cnt
        end
        next = String[]
        for (post, sr) in rin
            post in reached && continue
            st = get(tin, post, 0); st <= 0 && continue
            sr / st >= threshold || continue
            push!(next, post); ranks[post] = k
        end
        isempty(next) && break
        union!(reached, next)
    end
    ranks
end

# ── public API ────────────────────────────────────────────────────────────────
"Open the persisted store (builds on first call) → (s_rule_tree, s_ent_tree)."
function open_store(m = ConnectomeManifest.manifest())
    (build_s_rule!(m), build_s_ent!(m))
end

"Info-flow ranks for a modality, seeds DERIVED from S_ent (not /tmp seed files)."
function info_flow(m, modality::AbstractString)
    s_rule, s_ent = open_store(m)
    seeds = query_seeds(s_ent, modality)
    tin = compute_tin(s_rule)
    (seeds, flow_ranks(s_rule, seeds, tin))
end

"Regression: zipper-frontier flow == independent naive oracle, from the persisted store."
function validate(m, modality::AbstractString)
    s_rule, s_ent = open_store(m)
    seeds = query_seeds(s_ent, modality)
    println("$modality: $(length(seeds)) seeds (from S_ent)")
    tin = compute_tin(s_rule)
    fr  = flow_ranks(s_rule, seeds, tin)
    out, tin2 = build_adjacency(s_rule)
    orc = oracle_ranks(out, tin2, seeds)
    hist(d) = sort(collect(begin h=Dict{Int,Int}(); for r in values(d); h[r]=get(h,r,0)+1; end; h end))
    mism = sum(get(fr, k, -999) != v for (k, v) in orc; init=0) +
           sum(get(orc, k, -999) != v for (k, v) in fr; init=0)
    println("  flow   reached=$(length(fr))  hist=$(hist(fr))")
    println("  oracle reached=$(length(orc)) hist=$(hist(orc))")
    println("  rank-mismatches (flow vs oracle): $mism  ", mism == 0 ? "[OK]" : "[FAIL]")
    mism == 0
end

# ── Fig-6 d/e: all-modality analysis (ported from info_flow_all_modalities.jl) ─
const MODALITIES = ["thermosensory", "hygrosensory", "gustatory",
                    "olfactory", "AN", "mechanosensory", "visual"]

"""
    all_modalities(m; modalities, max_rounds) -> Dict

Run info-flow for every afferent modality on one shared connectome (loaded +
`tin` computed once), seeds DERIVED from S_ent. Prints the Fig-6e per-modality
rank histograms and the Fig-6d cross-modality Jaccard overlap matrix. Returns
modality => (neuron => rank).
"""
function all_modalities(m = ConnectomeManifest.manifest();
                        modalities = MODALITIES, max_rounds::Int = 15)
    s_rule, s_ent = open_store(m)
    tin = compute_tin(s_rule)
    results = Dict{String, Dict{String,Int}}()
    for mod in modalities
        seeds = query_seeds(s_ent, mod)
        results[mod] = flow_ranks(s_rule, seeds, tin; max_rounds = max_rounds)
        println("  $mod: seeds=$(length(seeds)) reached=$(length(results[mod]))")
    end

    println("\n=== Fig-6e: rank histograms (rank → count per modality) ===")
    print(rpad("rank", 6)); for mod in modalities; print(rpad(mod, 15)); end; println()
    maxr = maximum((maximum(values(r); init = 0) for r in values(results)); init = 0)
    for k in 0:maxr
        print(rpad(k, 6))
        for mod in modalities; print(rpad(count(==(k), values(results[mod])), 15)); end
        println()
    end

    println("\n=== Fig-6d: cross-modality Jaccard overlap (|Ri∩Rj|/|Ri∪Rj|) ===")
    print(rpad("", 15)); for mod in modalities; print(rpad(mod, 12)); end; println()
    for mi in modalities
        print(rpad(mi, 15)); Ri = Set(keys(results[mi]))
        for mj in modalities
            Rj = Set(keys(results[mj])); u = length(union(Ri, Rj))
            print(rpad(u == 0 ? 0.0 : round(length(intersect(Ri, Rj)) / u, digits = 3), 12))
        end
        println()
    end
    results
end
