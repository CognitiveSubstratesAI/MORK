# load_map.jl — S_map accessor over the FAFB skeleton shards, keyed by neuron
# root_id so S_ent / S_rule / S_map all co-resolve on the SAME id.
#
# The skeletons were already imported (import_fafb_skeletons.jl) into 28 parked
# .act shards; this wires them into the unified store WITHOUT re-importing:
#   - query a neuron's morphology by root_id across the shards (cold-mmap);
#   - the S_evid provenance link is `root_id → <root_id>.swc` (already implicit
#     in every skel-br atom — no extra CID field, no 30 GB re-import).
#
# Skeleton atom (arity 14):
#   (skel-br <root_id> <bid> <st> <sx> <sy> <sz> <et> <ex> <ey> <ez> <len> <rad> <n>)

using MORK
using MORK: ExprArity, ExprSymbol, item_byte, byte_item
using PathMap: read_zipper_at_path, zipper_to_next_val!, zipper_path, act_open_mmap

const SKEL_HEAD = codeunits("skel-br")

"Byte prefix selecting all branches of one neuron: (skel-br <root_id> …)."
function skel_root_prefix(root_id::AbstractString)::Vector{UInt8}
    rb = codeunits(root_id); n = length(rb)
    buf = UInt8[item_byte(ExprArity(UInt8(14))), item_byte(ExprSymbol(UInt8(7)))]
    append!(buf, SKEL_HEAD)
    push!(buf, item_byte(ExprSymbol(UInt8(n))))
    append!(buf, rb)
    buf
end

"Parse the trailing symbol args of a skel-br atom (everything after the matched prefix)."
@inline function _parse_skel_args(rel::Vector{UInt8})
    out = String[]
    pos = 1
    while pos <= length(rel)
        t = byte_item(rel[pos]); t isa ExprSymbol || break
        len = Int(t.size); pos + len > length(rel) && break
        push!(out, String(@view rel[pos+1:pos+len]))
        pos += 1 + len
    end
    isempty(out) ? nothing : out
end

"""
    open_skeletons(m) -> Vector

Cold-mmap all S_map shards (`m.skel_dir/shard_*.act`). ~0 RAM per shard.
"""
function open_skeletons(m)
    files = sort(filter(f -> endswith(f, ".act"), readdir(m.skel_dir; join = true)))
    isempty(files) && error("no skeleton shards under $(m.skel_dir)")
    [act_open_mmap(f) for f in files]
end

"""
    query_skeleton(shard_trees, root_id) -> Vector{Vector{String}}

All branches of one neuron, scanned across the shards. Each branch is its 13
arg-strings (bid, st, sx, sy, sz, et, ex, ey, ez, len, rad, n) — the args after
the matched `(skel-br <root_id>` prefix.
"""
function query_skeleton(shard_trees, root_id::AbstractString)
    prefix = skel_root_prefix(root_id)
    branches = Vector{Vector{String}}()
    for tree in shard_trees
        rz = read_zipper_at_path(tree, prefix)
        while zipper_to_next_val!(rz)
            fs = _parse_skel_args(collect(zipper_path(rz)))
            fs === nothing || push!(branches, fs)
        end
    end
    branches
end

# ── S_evid provenance link (root_id → raw SWC) ────────────────────────────────
evid_swc_path(m, root_id::AbstractString) = joinpath(m.skel_swc_dir, "$(root_id).swc")
has_evid(m, root_id::AbstractString) = isfile(evid_swc_path(m, root_id))

"""
    neuron_morphology(m, root_id) -> NamedTuple

S_map summary for a neuron: branch count, total cable length (Σ branch len, nm),
and the S_evid source path + whether it exists. `shards` may be passed to reuse
already-opened trees.
"""
function neuron_morphology(m, root_id::AbstractString; shards = open_skeletons(m))
    br = query_skeleton(shards, root_id)
    # arg order after root_id: 1=bid 2=st 3=sx 4=sy 5=sz 6=et 7=ex 8=ey 9=ez 10=len 11=rad 12=n
    total_len = sum((length(b) >= 10 ? something(tryparse(Int, b[10]), 0) : 0) for b in br; init = 0)
    (; root_id,
       n_branches = length(br),
       total_cable_nm = total_len,
       evid = evid_swc_path(m, root_id),
       evid_exists = has_evid(m, root_id))
end
