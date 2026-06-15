# Fly connectome (FAFB v783)

A complete, real-world MORK example: a unified, persisted, manifest-driven
representation of the **FAFB v783** adult *Drosophila* (fruit-fly) connectome on
the MORK substrate, and the **Fig-6 information-flow** model (Dorkenwald, Schlegel
et al., *Nature* 2024) run over it. Lives in `examples/connectome/`.

It is a real heterogeneous graph organized into world-model **Spaces** — a
concrete instance of the world-modeling architecture ("World Modeling in Hyperon
for PRIMUS", Goertzel 2025) — all co-resolving on one key, the neuron `root_id`,
with the raw data kept immutable as evidence. It exercises the MORK substrate
end-to-end: prefix-scoped multi-Space `.act` snapshots, cold-mmap reads, and the
zipper-frontier traversal from the [Zipper Queries](../guide/zipper_queries.md) guide.

## The Spaces

| Space | Atom | Source | Role |
|---|---|---|---|
| **`S_ent`** | `(neuron <id> <flow> <super_class> <class> <sub_class> <side>)` | `classification.csv.gz` (139,256 neurons) | identity / ontology. For afferent neurons `class` is the sensory modality — info-flow **seeds are derived by querying this Space**, not hand-listed. |
| **`S_rule`** | `(syn <pre> <post> <Σsyn_count>)` | `connections_princeton.csv.gz` (5.34 M rows → **3,732,460** unique edges) | the wiring. |
| **`S_map`** | `(skel-br <id> <bid> <st> <sx> <sy> <sz> <et> <ex> <ey> <ez> <len> <rad> <n>)` | 139,273 SWC skeletons → 28 branch-decomposed `.act` shards | spatial morphology (branch endpoints, cable length, radius). |
| **`S_evid`** | the raw 31 GB SWC files | `sk_lod1_783_healed/<id>.swc` | immutable evidence. Provenance is `root_id → <id>.swc` — already implicit in every `skel-br` atom (no CID field, no re-import). |

Every Space keys on the same `root_id`, so one id resolves its class (`S_ent`),
morphology (`S_map`), synapses (`S_rule`), and source file (`S_evid`).

## Design — MORK-canonical, no technical debt

- **One `.act` per Space** (canonical per-Space tries), cold-mmap'd on use
  (`act_open_mmap`, ~0 RAM) — built once, instant thereafter. No `/tmp` staging,
  no re-ingest per run.
- **Manifest-driven paths** (`manifest.jl`) — single source of truth,
  ENV-overridable (`CONNECTOME_DATA_ROOT` / `CONNECTOME_STORE` /
  `CONNECTOME_SKEL_DIR` / `MORK_PROJECT`); no hardcoded absolute paths.
- **Reads via the documented zipper algebra** (`read_zipper_at_path` +
  prefix-narrowed walks over the `.act` snapshot — the sanctioned high-speed read
  path for relational reachability).
- **Derive, don't pre-bake**: seeds come from an `S_ent` match, not a text file.

## Files (`examples/connectome/`)

| File | What |
|---|---|
| `manifest.jl` | resolved paths (data root, store, shards, MORK project) |
| `load_ent.jl` | `classification.csv.gz → S_ent.act`; `query_seeds(modality)` |
| `load_rule.jl` | `connections.csv.gz → S_rule.act` (Julia-side aggregation, no `awk`/TSV) |
| `load_map.jl` | `S_map` accessor over the skeleton shards; `query_skeleton`, `neuron_morphology`, `evid_swc_path` |
| `info_flow.jl` | the Fig-6 flow over the persisted store: `info_flow`, `validate`, `all_modalities` |

Companion artifacts: `InfoFlow.metta` / `InfoFlowMS.metta` / `InfoFlowFast.metta`
(pure-MeTTa exec-calculus models — a different, interpreter-based approach),
`import_fafb_skeletons.jl` (the `S_map` importer),
`extract_{fafb,banc,flywire}_subset.sh` (subset/oracle generators; BANC + FlyWire
are future cross-species runs), `STAGE2_RESULTS.md`.

## Usage

Run inside the MORK project's warm REPL (the substrate uses raw MORK/PathMap):

```julia
include("examples/connectome/info_flow.jl")
using .ConnectomeManifest
m = ConnectomeManifest.manifest()

# Build the store (idempotent; first S_rule build ~4 min, then instant cold-mmap):
ConnectomeManifest.ensure_store()
open_store(m)                       # builds/opens S_rule.act + S_ent.act

# Single-modality info-flow (seeds derived from S_ent):
seeds, ranks = info_flow(m, "thermosensory")

# Regression: zipper-frontier flow == independent in-Julia oracle, from the store:
validate(m, "thermosensory")        # → 0 rank-mismatches

# Fig-6 d/e across all 7 afferent modalities on one shared connectome:
all_modalities(m)                   # per-modality rank histograms + Jaccard overlap

# Cross-Space resolution by neuron id:
include("examples/connectome/load_map.jl")
neuron_morphology(m, "720575940611720362")   # branches, cable length, S_evid path
```

## Validation

- **Build**: `S_rule.act` reproduces the 5.34 M → **3,732,460** unique-edge aggregation.
- **Flow vs oracle**: thermosensory reaches 367 neurons with **rank-1 = 46**, and
  the zipper-frontier flow matches an independent naive-rescan oracle
  **node-for-node (0 mismatches)** — both re-derived from the persisted store.
- **Fig-6 d/e**: all 7 modalities run on one shared connectome; the cross-modality
  Jaccard matrix shows the expected biology (e.g. AN↔mechanosensory ≈ 0.41,
  thermo↔gustatory = 0.0).
- **Cross-Space join**: all 29/29 thermosensory seeds resolve in `S_ent`, `S_map`
  (e.g. 214 branches / 601,722 nm), `S_rule`, and `S_evid` on the same `root_id`.

## Data & citation

Real FlyWire/Codex FAFB v783 exports (CC-BY-NC). Cite **Dorkenwald, Schlegel et
al., *Nature* 2024** ("Neuronal wiring diagram of an adult brain") for any
published result. Raw data is gitignored; not redistributed here.
