# load_ent.jl — classification.csv.gz → S_ent: (neuron …) identity/ontology atoms.
#
# Replaces the pre-baked /tmp/seed_<modality>.txt files (extract_fafb_subset.sh
# step 2) with a queryable Space: seeds are DERIVED by matching S_ent, not
# hand-generated text. This is the "derive by query, don't pre-bake" half of the
# no-tech-debt pass, and it unblocks every richer query (region, side, class)
# the world model will want from S_ent.
#
# Atom: (neuron <root_id> <flow> <super_class> <class> <sub_class> <side>)  arity 7
#   CSV cols: root_id,flow,super_class,class,sub_class,hemilineage,side,nerve
#   - `flow` ∈ {afferent,intrinsic,efferent}
#   - for AFFERENT neurons, `class` IS the sensory modality (thermosensory/…) —
#     exactly the info-flow seed key.
#   - empty CSV fields → "na" (fixed arity keeps the atom byte-paths regular).
#
# Encoding is the direct-byte path (mirrors emit_branch! / bulk_load_syn!): for
# 139 k atoms it's a fraction of a second and avoids the s-expr parser.
#
# Reads the .gz via `zcat` (no Julia gzip dep added; Cmd interpolation preserves
# the space in "fruit fly").

using MORK
using MORK: ExprArity, ExprSymbol, item_byte, byte_item
using PathMap: read_zipper_at_path, zipper_to_next_val!, zipper_path, set_val_at!,
               act_from_zipper, act_save, act_open_mmap

const NEURON_HEAD   = codeunits("neuron")
# prefix = (arity 7)(symbol "neuron") — the read-zipper anchor for all neuron atoms
const NEURON_PREFIX = vcat(UInt8[item_byte(ExprArity(UInt8(7))), item_byte(ExprSymbol(UInt8(6)))],
                           codeunits("neuron"))
const N_NEURON_ARGS = 6   # id, flow, super_class, class, sub_class, side

@inline function _push_sym!(buf::Vector{UInt8}, s::AbstractVector{UInt8})
    push!(buf, item_byte(ExprSymbol(UInt8(length(s)))))
    append!(buf, s)
end

_na(x) = isempty(x) ? "na" : x

"""
    load_classification!(s, csv_gz) -> Int

Stream classification.csv.gz into space `s` as (neuron …) atoms. Returns count.
"""
function load_classification!(s::Space, csv_gz::AbstractString)::Int
    isfile(csv_gz) || error("classification csv not found: $csv_gz")
    btm = s.btm
    buf = UInt8[]
    n   = 0
    header_skipped = false
    for line in eachline(`zcat $csv_gz`)
        if !header_skipped
            header_skipped = true
            continue
        end
        isempty(line) && continue
        f = split(line, ',')
        length(f) >= 8 || continue   # root_id..nerve
        root_id = f[1]
        isempty(root_id) && continue
        empty!(buf)
        push!(buf, item_byte(ExprArity(UInt8(7))))
        _push_sym!(buf, NEURON_HEAD)
        _push_sym!(buf, codeunits(String(root_id)))
        _push_sym!(buf, codeunits(_na(String(f[2]))))   # flow
        _push_sym!(buf, codeunits(_na(String(f[3]))))   # super_class
        _push_sym!(buf, codeunits(_na(String(f[4]))))   # class (= modality for afferent)
        _push_sym!(buf, codeunits(_na(String(f[5]))))   # sub_class
        _push_sym!(buf, codeunits(_na(String(f[7]))))   # side  (col6 hemilineage, col8 nerve skipped)
        set_val_at!(btm, buf, MORK.UNIT_VAL)
        n += 1
    end
    n
end

"Parse `k` consecutive symbols from a zipper-path remainder; nothing on malformed."
@inline function _parse_syms(rel::Vector{UInt8}, k::Int)
    out = Vector{String}(undef, k)
    pos = 1
    @inbounds for i in 1:k
        pos > length(rel) && return nothing
        t = byte_item(rel[pos]); t isa ExprSymbol || return nothing
        len = Int(t.size); pos + len > length(rel) && return nothing
        out[i] = String(@view rel[pos+1:pos+len])
        pos += 1 + len
    end
    out
end

"""
    query_seeds(btm, modality) -> Vector{String}

Afferent neuron ids whose `class` == modality — i.e. the info-flow seed set,
derived by scanning S_ent instead of reading /tmp/seed_<modality>.txt.
`btm` is a live space's `.btm` OR a cold-mmap'd `.act` tree (zipper-polymorphic).
"""
function query_seeds(btm, modality::AbstractString)::Vector{String}
    seeds = String[]
    rz = read_zipper_at_path(btm, NEURON_PREFIX)
    while zipper_to_next_val!(rz)
        fs = _parse_syms(collect(zipper_path(rz)), N_NEURON_ARGS)
        fs === nothing && continue
        # fs = [id, flow, super_class, class, sub_class, side]
        (fs[2] == "afferent" && fs[4] == modality) && push!(seeds, fs[1])
    end
    seeds
end

"All distinct (flow, class) modality keys present, with counts — for discovery."
function modality_histogram(btm)
    h = Dict{Tuple{String,String}, Int}()
    rz = read_zipper_at_path(btm, NEURON_PREFIX)
    while zipper_to_next_val!(rz)
        fs = _parse_syms(collect(zipper_path(rz)), N_NEURON_ARGS)
        fs === nothing && continue
        k = (fs[2], fs[4])
        h[k] = get(h, k, 0) + 1
    end
    h
end

"""
    build_s_ent!(m) -> tree

Idempotent build: if `m.s_ent_act` exists, cold-mmap it; else load the CSV,
snapshot to `.act`, and reopen the disk-backed copy. Returns a zipper-usable tree.
"""
function build_s_ent!(m)
    if isfile(m.s_ent_act)
        return act_open_mmap(m.s_ent_act)
    end
    isdir(dirname(m.s_ent_act)) || mkpath(dirname(m.s_ent_act))
    s = new_space()
    n = load_classification!(s, m.classification_csv)
    @info "S_ent: loaded $n neuron atoms"
    tree = act_from_zipper(s.btm, _ -> UInt64(0))
    act_save(tree, m.s_ent_act)
    @info "S_ent: snapshot → $(m.s_ent_act) ($(round(filesize(m.s_ent_act)/1024/1024, digits=1)) MB)"
    act_open_mmap(m.s_ent_act)
end
