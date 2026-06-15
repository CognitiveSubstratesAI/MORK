# manifest.jl — single source of truth for connectome substrate paths.
#
# WHY: the connectome scripts each hardcoded absolute paths into the
# to-be-deleted ~/PRIMUS tree (e.g. import_fafb_skeletons.jl `SKEL_DIR`,
# extract_fafb_subset.sh `DATA`, info_flow_all_modalities.jl `Pkg.activate`),
# which silently broke when docs/ moved to ~/code/CognitiveSubstratesAI on
# 2026-06-11 (loader now finds 0 files). And persisted artifacts went to /tmp
# (wiped on reboot). This module is the no-tech-debt fix: every path derives
# from a configurable data_root + store (ENV-overridable), defaulting to the
# post-migration CognitiveSubstratesAI locations — never /tmp, never ~/PRIMUS
# baked into a script.
#
# Override any path via ENV: CONNECTOME_DATA_ROOT / CONNECTOME_STORE /
# CONNECTOME_SKEL_DIR / MORK_PROJECT.

module ConnectomeManifest

export manifest, ensure_store, describe

const DEFAULT_DATA_ROOT = expanduser("~/code/CognitiveSubstratesAI/docs/research/fruit fly/FAFB v783")
const DEFAULT_STORE     = expanduser("~/code/CognitiveSubstratesAI/data/connectome/fafb_v783")
# Skeleton shards are 4.6 GB and stay put until explicitly relocated (a separate
# decision from fixing path debt); referenced here, not moved.
const DEFAULT_SKEL_DIR  = expanduser("~/PRIMUS/data/fafb_skeletons")
const DEFAULT_MORK      = expanduser("~/code/CognitiveSubstratesAI/MORK")

"""
    manifest(; kwargs...) -> NamedTuple

Resolve all connectome paths. Source data (read-only) + persisted store (`.act`
snapshots) + the MORK project to activate. Nothing here touches /tmp.
"""
function manifest(; data_root = get(ENV, "CONNECTOME_DATA_ROOT", DEFAULT_DATA_ROOT),
                    store     = get(ENV, "CONNECTOME_STORE",     DEFAULT_STORE),
                    skel_dir  = get(ENV, "CONNECTOME_SKEL_DIR",  DEFAULT_SKEL_DIR),
                    mork      = get(ENV, "MORK_PROJECT",         DEFAULT_MORK))
    (; data_root, store, skel_dir, mork,
       # read-only source (gzipped CSV exports — Dorkenwald/Schlegel 2024, cite on publish)
       classification_csv = joinpath(data_root, "classification.csv.gz"),
       connections_csv    = joinpath(data_root, "connections_princeton.csv.gz"),
       # S_evid: raw immutable SWC skeletons (the source the S_map shards derive from;
       # the link is `root_id → <root_id>.swc`, already implicit in every skel-br atom)
       skel_swc_dir       = joinpath(data_root, "sk_lod1_783_healed"),
       # persisted derived Spaces (one .act per Space; canonical per-Space tries)
       s_ent_act          = joinpath(store, "S_ent.act"),    # (neuron …) identity/ontology
       s_rule_act         = joinpath(store, "S_rule.act"))   # (syn pre post cnt) wiring
end

"Create the store dir if missing; return the manifest."
function ensure_store(m = manifest())
    isdir(m.store) || mkpath(m.store)
    m
end

"Print a resolved-paths report and flag any missing source file."
function describe(m = manifest())
    println("=== connectome manifest ===")
    for (k, v) in pairs(m)
        tag = ""
        if endswith(string(k), "_csv")
            tag = isfile(v) ? "  [ok]" : "  [MISSING]"
        elseif endswith(string(k), "_act")
            tag = isfile(v) ? "  [built]" : "  [not built]"
        elseif k in (:data_root, :store, :skel_dir, :mork)
            tag = isdir(v) ? "  [ok]" : "  [MISSING]"
        end
        println("  ", rpad(string(k), 20), v, tag)
    end
    m
end

end # module
