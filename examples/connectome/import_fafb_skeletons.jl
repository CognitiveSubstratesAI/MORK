# import_fafb_skeletons.jl — load FAFB v783 neuron skeleton SWC files into
# MORK, decompose to per-branch atoms (Tier B per
# docs/research/fruit fly/FAFB v783/import notes), snapshot to .act.
#
# 🔴 INPUT DELETED 2026-09-03 — THIS SCRIPT CANNOT RUN AS-IS.
# INPUT:  <FAFB v783>/sk_lod1_783_healed/*.swc  (139,273 files, 31.18 GB, ~745M raw nodes)
#         REMOVED to reclaim 32 GB. The import was never completed: no `data/fafb_v783_skeletons.act`
#         was ever produced, and nothing in any test or gate read the skeletons — verified, every
#         in-tree reference to connectome/fafb is a COMMENT (WorldModel cites this directory as a
#         PATTERN it mirrors, not a path it opens). Re-fetch from the public FlyWire/Codex FAFB v783
#         release if this is revived.
# ⚠️ ALSO LOST: the `import notes` cited below for the Tier-B rationale. The atom shape, target
#         counts and usage in this header survive; the reasoning behind choosing Tier B does not.
# ✅ RETAINED: the CONNECTIVITY tables beside it — connections_*, synapse_*, neurons, labels,
#         coordinates, cell_stats (3.4 GB .csv.gz) + BANC v626 (28 MB). Those are the connectome
#         GRAPH and the more reusable artifact; only skeleton GEOMETRY was removed.
#
# OUTPUT: data/fafb_v783_skeletons.act
#         atom shape: (skel-br <root_id> <branch_id> <st> <sx> <sy> <sz>
#                              <et> <ex> <ey> <ez> <len> <rad> <n>)
#         where coords are integer nanometers (rounded), `st`/`et` are SWC
#         type tags (0=undefined, 1=soma, 5=fork, 6=endpoint), and
#         (root_id, branch_id) is a unique key per branch.
#
# ATOM COUNT TARGET: ~30–50M atoms (vs 745M for per-node).
#
# Usage:
#   julia --project=. examples/connectome/import_fafb_skeletons.jl \
#       [--limit N] [--out PATH]
#
#   --limit N   process only first N files (default: all 139273)
#   --out  P    output .act path (default: data/fafb_v783_skeletons.act)

using MORK
using MORK: ExprArity, ExprSymbol, item_byte
using PathMap
using PathMap: ArenaCompactTree, act_from_zipper, act_save, act_open_mmap, set_val_at!

# Paths come from the manifest (single source of truth; ENV-overridable —
# CONNECTOME_DATA_ROOT / CONNECTOME_SKEL_DIR). No hardcoded local paths.
include(joinpath(@__DIR__, "manifest.jl"))
using .ConnectomeManifest
const _M = ConnectomeManifest.manifest()
const SKEL_DIR = _M.skel_swc_dir            # raw SWC source (S_evid)
const DEFAULT_OUT_DIR = _M.skel_dir         # branch-shard .act output (S_map)
const DEFAULT_SHARD_FILES = 5000            # ≤5 GB peak RSS per shard on this box

# ── SWC parsing ────────────────────────────────────────────────────────────────

"""
One row of an SWC file.
id     — node id (1-indexed in the file)
typ    — SWC label: 0/1/5/6 (undefined/soma/fork/endpoint)
x,y,z  — coords in nanometers (per file header)
r      — radius in nm
parent — parent node id (-1 = root)
"""
struct SWCNode
    id::Int32
    typ::UInt8
    x::Float32
    y::Float32
    z::Float32
    r::Float32
    parent::Int32
end

"""
Parse an SWC file (text). Skips comment lines starting with '#'. Returns the
node vector in file order (whose `id` is implicit at position+1, but we trust
the file's explicit id field per the SWC spec).
"""
function parse_swc(path::AbstractString)::Vector{SWCNode}
    nodes = SWCNode[]
    sizehint!(nodes, 6000)   # mean is 5349
    for line in eachline(path)
        isempty(line) && continue
        first(line) == '#' && continue
        toks = split(line)
        length(toks) >= 7 || continue
        push!(
            nodes,
            SWCNode(
                parse(Int32, toks[1]),
                parse(UInt8, toks[2]),
                parse(Float32, toks[3]),
                parse(Float32, toks[4]),
                parse(Float32, toks[5]),
                parse(Float32, toks[6]),
                parse(Int32, toks[7])
            )
        )
    end
    nodes
end

# ── Branch decomposition ──────────────────────────────────────────────────────

"""
A decomposed branch: contiguous path of degree-2 internal nodes bracketed
by junctions (soma/forks) or endpoints. Carries enough info for the MORK
atom: endpoint types + coords, accumulated path length, mean radius, count.
"""
struct Branch
    st::UInt8    # SWC type of start node
    sx::Float32
    sy::Float32
    sz::Float32
    et::UInt8    # SWC type of end node
    ex::Float32
    ey::Float32
    ez::Float32
    len::Float32   # cumulative euclidean length along the branch
    rad::Float32   # mean radius across the branch
    nnode::Int32     # number of nodes in the branch (≥ 2)
end

"""
Decompose a parsed SWC into Branches.

A "junction node" is the root (parent == -1) OR has child_count != 1 OR is
explicitly tagged as soma (1) / fork (5) / endpoint (6). For each junction
N with at least one child, follow each child path through degree-2 internal
nodes until the next junction is reached, emitting one Branch.

Returns the branches in deterministic traversal order (so the per-neuron
branch_id is reproducible across runs).
"""
function decompose_branches(nodes::Vector{SWCNode})::Vector{Branch}
    n = length(nodes)
    n == 0 && return Branch[]

    # Build index: id → position (SWC ids aren't always sequential after editing).
    idx = Dict{Int32, Int}()
    sizehint!(idx, n)
    for (i, node) in enumerate(nodes)
        idx[node.id] = i
    end

    # Child counts: how many nodes claim each parent.
    child_count = zeros(Int32, n)
    for node in nodes
        node.parent == -1 && continue
        pos = get(idx, node.parent, 0)
        pos == 0 && continue   # parent missing — skip silently (shouldn't happen)
        child_count[pos] += 1
    end

    # A node is a "junction" if it has child_count ≠ 1 OR no parent (root)
    # OR is labeled soma(1) / fork(5) / endpoint(6).
    is_junction = (i::Int) -> begin
        node = nodes[i]
        node.parent == -1 && return true
        cc = child_count[i]
        cc != 1 && return true
        node.typ in (UInt8(1), UInt8(5), UInt8(6)) && return true
        false
    end

    # Adjacency: for each parent position, list of child positions.
    children = [Int[] for _ in 1:n]
    for (i, node) in enumerate(nodes)
        node.parent == -1 && continue
        pp = get(idx, node.parent, 0)
        pp != 0 && push!(children[pp], i)
    end

    branches = Branch[]
    sizehint!(branches, n ÷ 100)   # heuristic — ~1 branch per ~100 nodes

    # For each junction with children, walk each child chain until next junction.
    for start_i in 1:n
        is_junction(start_i) || continue
        for next_i in children[start_i]
            # Walk start_i → next_i → ... until we hit another junction.
            sx = nodes[start_i].x
            sy = nodes[start_i].y
            sz = nodes[start_i].z
            st = nodes[start_i].typ
            cur_i = next_i
            len_total = 0.0f0
            rad_sum = nodes[start_i].r
            count = 1   # start node counts
            prev_x, prev_y, prev_z = sx, sy, sz
            while true
                nx = nodes[cur_i].x
                ny = nodes[cur_i].y
                nz = nodes[cur_i].z
                dx = nx - prev_x
                dy = ny - prev_y
                dz = nz - prev_z
                len_total += sqrt(dx*dx + dy*dy + dz*dz)
                rad_sum += nodes[cur_i].r
                count += 1
                if is_junction(cur_i)
                    push!(
                        branches,
                        Branch(
                            st,
                            sx,
                            sy,
                            sz,
                            nodes[cur_i].typ,
                            nx,
                            ny,
                            nz,
                            len_total,
                            rad_sum / count,
                            Int32(count)
                        )
                    )
                    break
                end
                # Advance to the single child.
                kids = children[cur_i]
                isempty(kids) && break   # shouldn't reach (would be junction)
                prev_x, prev_y, prev_z = nx, ny, nz
                cur_i = kids[1]
            end
        end
    end

    branches
end

# ── Atom emission ─────────────────────────────────────────────────────────────

"""
Convert a Branch into a MORK Expr byte-encoding and insert it directly
into the PathMap btm. Mirrors `bulk_load_syn!` in info_flow_all_modalities.jl
— skipping the s-expr parser is the difference between ~17 ms/atom and
~10 µs/atom (1000× speedup; measured: 100 files in 595 s via s-expr loader
vs estimated ~6 s via direct-byte path).

Atom: (skel-br <root_id> <bid> <st> <sx> <sy> <sz> <et> <ex> <ey> <ez> <len> <rad> <n>)
arity 14 (head + 13 args)
"""
const SKEL_HEAD = codeunits("skel-br")

@inline function _push_sym!(buf::Vector{UInt8}, s::AbstractVector{UInt8})
    push!(buf, item_byte(ExprSymbol(UInt8(length(s)))))
    append!(buf, s)
end

@inline function emit_branch!(
    btm, buf::Vector{UInt8}, root_id::UInt64, bid::Int32, b::Branch
)
    empty!(buf)
    # Arity 14: head + 13 args
    push!(buf, item_byte(ExprArity(UInt8(14))))
    _push_sym!(buf, SKEL_HEAD)
    _push_sym!(buf, codeunits(string(root_id)))
    _push_sym!(buf, codeunits(string(bid)))
    _push_sym!(buf, codeunits(string(b.st)))
    _push_sym!(buf, codeunits(string(round(Int, b.sx))))
    _push_sym!(buf, codeunits(string(round(Int, b.sy))))
    _push_sym!(buf, codeunits(string(round(Int, b.sz))))
    _push_sym!(buf, codeunits(string(b.et)))
    _push_sym!(buf, codeunits(string(round(Int, b.ex))))
    _push_sym!(buf, codeunits(string(round(Int, b.ey))))
    _push_sym!(buf, codeunits(string(round(Int, b.ez))))
    _push_sym!(buf, codeunits(string(round(Int, b.len))))
    _push_sym!(buf, codeunits(string(round(Int, b.rad))))
    _push_sym!(buf, codeunits(string(b.nnode)))
    set_val_at!(btm, buf, MORK.UNIT_VAL)
end

# ── Main driver ───────────────────────────────────────────────────────────────

rss_mb() = parse(Int, split(read("/proc/self/statm", String))[2]) * 4096 ÷ 1024 ÷ 1024

function parse_args(argv::Vector{String})::NamedTuple
    limit = typemax(Int)
    out_dir = DEFAULT_OUT_DIR
    shard_files = DEFAULT_SHARD_FILES
    i = 1
    while i <= length(argv)
        a = argv[i]
        if a == "--limit"
            limit = parse(Int, argv[i + 1])
            i += 2
        elseif a == "--out-dir"
            out_dir = argv[i + 1]
            i += 2
        elseif a == "--shard-files"
            shard_files = parse(Int, argv[i + 1])
            i += 2
        else
            error("unknown arg: $a")
        end
    end
    (; limit, out_dir, shard_files)
end

"""
Snapshot the current space to `path`, verify by cold mmap reopen, and
return the file size in MB. Frees the space afterward (caller is
responsible for allocating a fresh one for the next shard).
"""
function snapshot_shard!(s, path::AbstractString)::Float64
    t_snap = time()
    tree = act_from_zipper(s.btm, _ -> UInt64(0))
    act_save(tree, path)
    sz_mb = round(filesize(path) / 1024 / 1024; digits=1)
    elapsed = round(time() - t_snap; digits=1)
    println("    snapshot → $path ($(sz_mb) MB) in $(elapsed)s")
    # Sanity check: file exists, has nonzero size, and mmap-open succeeds.
    @assert filesize(path) > 0
    _ = act_open_mmap(path)   # raises if file is corrupt
    flush(stdout)
    sz_mb
end

function main(argv::Vector{String}=ARGS)
    args = parse_args(argv)
    println("=== FAFB v783 skeleton importer (Tier B, sharded) ===")
    println("input dir:    $SKEL_DIR")
    println("output dir:   $(args.out_dir)")
    println("shard size:   $(args.shard_files) files per .act")
    println("limit:        $(args.limit == typemax(Int) ? "all (139273)" : args.limit)")
    flush(stdout)

    # Enumerate input files.
    files = readdir(SKEL_DIR; sort=true)
    filter!(f -> endswith(f, ".swc"), files)
    n_files = min(length(files), args.limit)
    n_shards = cld(n_files, args.shard_files)
    println("plan:         $n_files files → $n_shards shards")
    mkpath(args.out_dir)

    n_branches_total = 0
    n_processed_total = 0
    n_failed_total = 0
    sz_total_mb = 0.0
    t_global = time()
    atom_buf = UInt8[]   # reused per atom

    for shard_i in 1:n_shards
        shard_start = (shard_i - 1) * args.shard_files + 1
        shard_end = min(shard_i * args.shard_files, n_files)
        shard_path = joinpath(args.out_dir, "shard_" * lpad(shard_i, 3, '0') * ".act")
        if isfile(shard_path)
            println("\n[shard $shard_i/$n_shards] $(shard_path) already exists, skipping")
            continue
        end
        println("\n[shard $shard_i/$n_shards] files $(shard_start)..$(shard_end)")
        flush(stdout)

        s = new_space()
        btm = s.btm
        n_b_shard = 0
        n_p_shard = 0
        n_f_shard = 0
        t_shard = time()

        for file_i in shard_start:shard_end
            fname = files[file_i]
            root_id = try
                parse(UInt64, fname[1:(end - 4)])
            catch
                n_f_shard += 1
                continue
            end
            path = joinpath(SKEL_DIR, fname)
            nodes = try
                parse_swc(path)
            catch
                n_f_shard += 1
                continue
            end
            isempty(nodes) && (n_f_shard += 1; continue)
            branches = decompose_branches(nodes)
            for (bid, b) in enumerate(branches)
                emit_branch!(btm, atom_buf, root_id, Int32(bid), b)
                n_b_shard += 1
            end
            n_p_shard += 1
            if n_p_shard % 1000 == 0
                e = round(time() - t_shard; digits=1)
                println(
                    "    [$n_p_shard/$(shard_end - shard_start + 1)] branches=$n_b_shard  ",
                    "elapsed=$(e)s  RSS=$(rss_mb()) MB"
                )
                flush(stdout)
            end
        end

        t_load = round(time() - t_shard; digits=1)
        println(
            "    load done: $n_p_shard files, $n_b_shard branches in $(t_load)s, RSS=$(rss_mb()) MB"
        )
        flush(stdout)

        sz_total_mb += snapshot_shard!(s, shard_path)
        n_branches_total += n_b_shard
        n_processed_total += n_p_shard
        n_failed_total += n_f_shard

        # Drop the space and force GC so the next shard starts from a clean
        # RSS baseline.
        s = nothing
        btm = nothing
        GC.gc()
        GC.gc()
        println("    post-GC RSS: $(rss_mb()) MB")
        flush(stdout)
    end

    println("\n=== ALL SHARDS DONE ===")
    println("total files:     $n_processed_total processed, $n_failed_total failed")
    println("total branches:  $n_branches_total atoms across $n_shards shards")
    println("total .act size: $(round(sz_total_mb, digits=1)) MB")
    println("total time:      $(round((time() - t_global) / 60, digits=1)) min")
    flush(stdout)
    return n_branches_total
end

if abspath(PROGRAM_FILE) == @__FILE__
    main(ARGS)
end
