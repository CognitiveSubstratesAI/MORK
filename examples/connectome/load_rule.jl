# load_rule.jl — connections_princeton.csv.gz → S_rule: (syn pre post cnt) atoms.
#
# Aggregates synapse counts per (pre,post) across neuropils — the same reduction
# the old extract_fafb_subset.sh did in awk, but in Julia, with NO /tmp TSV
# intermediate and NO shell dependency. Persists to the manifest's stable
# S_rule.act (NOT /tmp/fafb.act). Idempotent: cold-mmap if already built.
#
# Atom: (syn <pre_root_id> <post_root_id> <Σsyn_count>)  arity 4
#   pre/post are the STRING form of the root_id (matches S_ent neuron ids + the
#   info-flow seeds). Aggregation keys on UInt64 for speed/memory; emitted as
#   string (root_ids round-trip exactly — no leading zeros).
#
# CSV cols: pre_root_id,post_root_id,neuropil,syn_count,nt_type
#   neuropil + nt_type are intentionally dropped here (the validated info-flow
#   uses the (pre,post,Σsyn) form). They stay in the raw CSV (S_evid) for when a
#   region-scoped / neurotransmitter-typed workload actually pulls them.

using MORK
using MORK: ExprArity, ExprSymbol, item_byte
using PathMap: set_val_at!, act_from_zipper, act_save, act_open_mmap

const SYN_HEAD = codeunits("syn")

@inline function _push_sym!(buf::Vector{UInt8}, s::AbstractVector{UInt8})
    push!(buf, item_byte(ExprSymbol(UInt8(length(s)))))
    append!(buf, s)
end

"""
    aggregate_connections(csv_gz) -> Dict{Tuple{UInt64,UInt64},Int}

Stream the raw CSV, summing syn_count per (pre,post) across neuropils. Uses
`findnext`/`SubString` (no per-field allocation) and UInt64 keys.
"""
function aggregate_connections(csv_gz::AbstractString)
    isfile(csv_gz) || error("connections csv not found: $csv_gz")
    agg = Dict{Tuple{UInt64,UInt64}, Int}()
    sizehint!(agg, 4_000_000)
    header = true
    for line in eachline(`zcat $csv_gz`)
        if header; header = false; continue; end
        isempty(line) && continue
        c1 = findfirst(',', line);          c1 === nothing && continue
        c2 = findnext(',', line, c1 + 1);   c2 === nothing && continue
        c3 = findnext(',', line, c2 + 1);   c3 === nothing && continue
        c4 = findnext(',', line, c3 + 1)
        pre  = tryparse(UInt64, SubString(line, 1, c1 - 1));        pre === nothing && continue
        post = tryparse(UInt64, SubString(line, c1 + 1, c2 - 1));   post === nothing && continue
        cntstr = c4 === nothing ? SubString(line, c3 + 1, lastindex(line)) : SubString(line, c3 + 1, c4 - 1)
        cnt  = tryparse(Int, cntstr);                              cnt === nothing && continue
        k = (pre, post)
        agg[k] = get(agg, k, 0) + cnt
    end
    agg
end

"""
    load_synapses!(s, csv_gz) -> Int

Aggregate + emit (syn pre post cnt) atoms into space `s`. Returns #unique edges.
"""
function load_synapses!(s::Space, csv_gz::AbstractString)::Int
    agg = aggregate_connections(csv_gz)
    btm = s.btm
    buf = UInt8[]
    for ((pre, post), cnt) in agg
        empty!(buf)
        push!(buf, item_byte(ExprArity(UInt8(4))))
        _push_sym!(buf, SYN_HEAD)
        _push_sym!(buf, codeunits(string(pre)))
        _push_sym!(buf, codeunits(string(post)))
        _push_sym!(buf, codeunits(string(cnt)))
        set_val_at!(btm, buf, MORK.UNIT_VAL)
    end
    length(agg)
end

"""
    build_s_rule!(m) -> tree

Idempotent build of the persisted synapse Space. Cold-mmap if `m.s_rule_act`
exists, else aggregate the CSV, snapshot to `.act`, reopen disk-backed.
"""
function build_s_rule!(m)
    if isfile(m.s_rule_act)
        return act_open_mmap(m.s_rule_act)
    end
    isdir(dirname(m.s_rule_act)) || mkpath(dirname(m.s_rule_act))
    s = new_space()
    n = load_synapses!(s, m.connections_csv)
    @info "S_rule: loaded $n unique (syn pre post cnt) edges"
    tree = act_from_zipper(s.btm, _ -> UInt64(0))
    act_save(tree, m.s_rule_act)
    @info "S_rule: snapshot → $(m.s_rule_act) ($(round(filesize(m.s_rule_act)/1024/1024, digits=1)) MB)"
    act_open_mmap(m.s_rule_act)
end
