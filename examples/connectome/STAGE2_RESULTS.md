# Connectome info-flow — Stage 2 (real FAFB v783 data)

Stage 2 swaps the synthetic Stage-1 graph for the **real adult-fly connectome**
(FlyWire FAFB v783, Dorkenwald et al. *Nature* 2024) and confirms the *unchanged*
[InfoFlow.metta](InfoFlow.metta) model reproduces a native reference oracle
**exactly** on real data — single-step and multi-step.

## What ran

1. **Aggregate** the edge list (`connections_princeton.csv.gz`, 5,342,447
   per-neuropil rows) into **3,732,460 unique `(pre, post, Σsyn)` pairs** (~41 s,
   pure `awk`). This is the weighted directed connectome the model consumes.
2. **Reference oracle** — the deterministic Fig-6a rule (`reached at step k+1
   iff Σsyn(reached→p) / Σsyn(*→p) ≥ 0.3`) computed natively over the *full* real
   graph from a sensory seed (`extract_fafb_subset.sh`). This is the ground truth
   the MeTTa run must match.
3. **Tractable subcircuit** — extract the step-bounded subgraph (all in-edges of
   every node reached through step K, so denominators are exact) as
   `(syn pre post cnt)` atoms, seed the afferent modality as `(reached <id> 0)`,
   and run the **same** `flow-step` on the warm MettaJam server.

## Result — thermosensory modality (29 afferent seeds)

| Run | Subgraph edges | MeTTa output | Oracle | Diff | Wall time |
|-----|---:|---|---|---|---:|
| **K=1** (one step) | 1,226 | rank-1 = **46** | 46 | **0** | ~52–81 s |
| **K=2** (iterate to fixed point) | 2,974 | rank-1 = **46**, rank-2 = **45** | 46 / 45 | **0 / 0** | ~380 s |

The MeTTa `reached`/`rank` sets are **identical to the oracle, node-for-node**
(`comm` diff = ∅ in both directions). The multi-step run confirms the
iterate-to-fixed-point logic on real data: rank-2 membership correctly depends
on the rank-1 set marked in the prior step, and `flow-step` halts when no new
neuron crosses the 0.3 threshold.

Oracle layer sizes on the full real graph (thermosensory): step 1 = 46,
2 = 45, 3 = 81, 4 = 109, 5 = 45. (Deterministic ≥0.3 reaches fewer per step than
the paper's stochastic-ramp averaging — expected; the oracle, not the paper's
147/498/… counts, is the pass criterion for *this* deterministic model.)

## A real substrate bug, found and fixed

The first K=1 run returned **45**, not 46 — one node (`…612305506`) with a
*single* in-edge from a seed neuron had `reached-in = 0` despite `total-in = 7`
and `reached? pre = True`. Root cause was in the evaluator, not the model:

- The interpreter represents both expressions and nondeterministic result
  streams as raw Julia `Vector`. `_eval_match` returned a **single** result
  *unwrapped* (`results[1]`); when that lone result was itself a tuple
  `($r $c)`, `_eval_collapse` mistook it for the results-list and iterated its
  two fields instead of treating it as one pair → `foldl-atom` summed garbage.
- Stage-1 synthetic nodes all had ≥2 in-edges, so `collapse` always saw a real
  multi-element list — the bug was invisible until a real single-in-edge neuron.

Fix ([Eval.jl](../../src/eval/Eval.jl)): added `_eval_match_all` (gathers the
full results vector, no single-result unwrap); `collapse` over `match`/`superpose`
now uses it, so a lone expression-valued result stays a 1-element stream.
Regression test added (`runtests.jl` testset 19); **119/119 pass**.

## Tractability boundary (→ Stage 3) — corrected 2026-05-28

`core_match` is an **O(N) full trie-walk** with a shape pre-filter, so this
interpreter-level model costs **O(candidates × total_atoms) per step**:
~1.2 k edges ran in ~80 s, ~3 k edges in ~380 s. **However**: this is a property
of the INTERPRETER abstraction, not a substrate gap. The actual long-term scaling
path is NOT to scale the interpreter further — it is to drop to **direct zipper
algebra on PathMap**, mirroring upstream MORK's own recursive-query benchmark
(`benchmarks/aunt-kg`, Datalog-style transitive closure on an 11k-atom kinship
graph). aunt-kg's measured per-query times: "all parents" 20 µs, "all mothers"
877 µs, "all aunts" 4 ms — *microseconds*, using `PathMap` zipper primitives
(`read_zipper_at_path` / `descend_to` / `to_next_val!` / `graft` / `restrict` /
`meet` / `subtract`). Those primitives are all present in the Julia PathMap port
(70/70 pass). For connectome at scale: iterate the frontier with a read zipper,
`descend_to((syn r))` per reached r (prefix-narrowed subtrie lookup, µs-scale),
walk the small subtrie to enumerate r's out-edges, accumulate per-post `rin`,
threshold-check. O(E) total. **The interpreter model in this document remains the
small-scale oracle reference; the scalable path is the zipper-algebra
implementation in Julia, not a further MORK-internals change.**

## Multi-space (App + Common) — the substrate-validation payoff

The reason this workload exists: validate the **multi-space substrate**, not just
the model. [InfoFlowMS.metta](InfoFlowMS.metta) is the App+Common variant
(Whitepaper §9) — the connectome lives **once** in a shared `&common` space, and
each modality's traversal state (`reached`/`rank`) lives in its **own** space,
threaded as the `$ss` argument. The helpers read the connectome from `&common`
and read/write state from `$ss`, so modalities run over one shared wiring without
cross-contaminating.

Real-data run — **thermosensory + hygrosensory**, K=1, over a single shared
`&common` connectome (union of both subgraphs, 2,802 edges, loaded once):

| Modality | State space | MeTTa rank-1 | Oracle | Diff |
|---|---|---:|---:|---|
| thermosensory | `&therm` | **46** | 46 | **0** |
| hygrosensory  | `&hygro` | **52** | 52 | **0** |

(~79 s for both.) Each modality reproduces its *standalone* oracle **exactly even
while sharing the connectome** — which is the strongest isolation proof available:
any state bleed from the other modality would have added extra rank-1 nodes
(there were none). The two reach **largely distinct** neuron sets — only **3 of
46/52 overlap** — the per-modality divergence (Fig 6d/e) that the isolated state
spaces make directly comparable.

Mechanism notes: `bind! &name (new-space)` currently gives each named space its
**own MORK trie** (canonical isolation, as hyperon-experimental/CeTTa/PeTTa do);
cross-space reads resolve via `_resolve_space`. The byte-prefix-regions-in-one-
trie optimization (the dormant `rebind_to_shared_prefix` "polarity flip" in
`_eval_bind!`) is the substrate-novel follow-up — it would store all regions in
one shared trie and is validated at the MORK/PathMap level already (70/70,
1650/1650), but is **not** required for the App+Common semantics shown here.

## Zipper-algebra at full FAFB scale (2026-05-28)

After the tractability-boundary correction above (small-scale interpreter is the
oracle, scale comes from direct zipper algebra), the connectome flow was
re-implemented in [info_flow_zipper.jl](info_flow_zipper.jl) using PathMap zipper
primitives directly — the same pattern upstream MORK uses for its own recursive
queries (`benchmarks/aunt-kg`).

Per-round shape: a frontier of newly-reached `r`s; for each `r`,
`read_zipper_at_path(btm, (syn r))` (prefix-narrowed subtrie, µs); walk that
subtrie to enumerate `r → post, cnt`; accumulate per-post `rin`; threshold
`rin/tin ≥ 0.3`; emit newly-`reached`. O(E) total work; per-round = ms.

Measured on the **full 3.73M-edge FAFB v783** (load via direct `set_val_at!`):

| Modality | Seeds | Reached | Rounds | Total flow | rank-mismatches |
|---|---:|---:|---:|---:|---:|
| thermosensory | 29 | 367 | 8 (fixed point) | **0.09 s** | **0** |
| gustatory | 408 | 4,540 | 30 (cap; small-world cascade still growing) | **9.75 s** | **0** |

Compare on the K=1 *subset* alone (9,487 edges):

| Approach | gustatory K=1 |
|---|---|
| Interpreter `InfoFlowFast` (prefix-narrowed `core_match`) | 99 s |
| Interpreter `InfoFlowPush` (forward-push) | broke (`union-atom`, stack overflow) |
| Exec-calculus + `fsum` | stuck at 15+ min, killed |
| **Zipper algebra** | **45 ms** (this driver) on the same subset; **~10 s on the full 3.73M-edge graph** |

Validation: `rank-mismatches = 0` against the awk oracle within the oracle's
coverage (oracle is K-bounded; the zipper flow runs to fixed point, so it
returns the same ranks plus extra later-rank nodes).

The interpreter `InfoFlow.metta` / `InfoFlowFast.metta` / `InfoFlowMS.metta`
remain as small-scale **oracle reference** + multi-space demonstration; the
scalable production path is `info_flow_zipper.jl`.

## All-7-modalities on mmap'd `.act` — load once, query forever (2026-05-28)

[info_flow_all_modalities.jl](info_flow_all_modalities.jl) closes the loop:
load the FAFB connectome once, snapshot to a 41.7 MB `.act` file, then
**every subsequent run cold-mmap-opens in 0.25 ms with zero RAM trie**, runs
all 7 afferent modalities to fixed point on the full real graph, and emits the
Fig-6 d/e analog (per-modality rank distributions + cross-modality Jaccard).

Substrate enabler: **one-line adapter in Julia PathMap**
([`read_zipper_at_path(::ArenaCompactTree, path)`](../../../PathMap/src/pathmap/ArenaCompact.jl)
dispatches to `act_read_zipper_at_path`, PathMap commit `98ae99c`). Everything
else — the `zipper_*` API polymorphism on `ACTZipper` (Zipper.jl-style methods
in ArenaCompact.jl lines 835-854), `.act` save/load, `act_open_mmap` true
lazy mmap (PathMap `0805cff`) — was already in place. The same driver code
runs against either an in-RAM PathMap or a mmap'd ACT trie, transparently.

Measured (3.73M-edge FAFB v783, one workstation):

| Phase | Time | Notes |
|---|---|---|
| First-run text-load | 125.7 s | one-time cost; 3.73M `(syn pre post cnt)` atoms |
| Snapshot to `.act` | 35.5 s | 41.7 MB on disk — **113× smaller than the 4.7 GB in-RAM trie** |
| Drop in-RAM PathMap + cold mmap-open | **0.25 ms** | RSS drops 4.7 GB → 515 MB (just the Julia runtime, no trie) |
| `tin` (Σsyn per post, on mmap'd ACT) | 7.1 s | 130,183 distinct posts |
| **All 7 modality flows** (max_rounds=15) | **~14 s** | thermosensory 0.03s / hygrosensory 0.02s / gustatory 0.33s / olfactory 1.45s / mechanosensory 1.33s / AN 3.16s / **visual 7.44s** |

After the first run, every iteration of this analysis is **~21 s total** (mmap
+ tin + all flows). The 4.7 GB in-RAM trie is gone; the data lives on disk as
a 42 MB file and queries page in only the touched subtries.

**Cross-modality Jaccard overlap of reach sets** (Fig 6 d analog):

| | therm | hygro | gust | olf | AN | mech | vis |
|---|---|---|---|---|---|---|---|
| thermosensory | 1.000 | 0.098 | 0.000 | 0.015 | 0.004 | 0.003 | 0.001 |
| hygrosensory | 0.098 | 1.000 | 0.002 | 0.009 | 0.001 | 0.001 | 0.000 |
| gustatory | 0.000 | 0.002 | 1.000 | 0.066 | 0.078 | **0.169** | 0.011 |
| olfactory | 0.015 | 0.009 | 0.066 | 1.000 | **0.276** | 0.137 | 0.093 |
| AN | 0.004 | 0.001 | 0.078 | 0.276 | 1.000 | **0.414** | 0.293 |
| mechanosensory | 0.003 | 0.001 | 0.169 | 0.137 | 0.414 | 1.000 | 0.117 |
| visual | 0.001 | 0.000 | 0.011 | 0.093 | 0.293 | 0.117 | 1.000 |

AN ↔ mechanosensory share the largest pair-wise reach (0.414); visual,
thermo, and hygro are the most-isolated modalities. Each modality reaches a
distinct subset that the deterministic 0.3-threshold flow makes comparable
across afferent classes — matching the small-world-but-modality-specific
finding of Lappalainen et al. 2024 Fig 6.

The full `(modality, neuron, rank)` triple set (211,988 rows) is written to
`/tmp/all_modalities_ranks.tsv` for downstream UMAP / clustering analyses
(Fig 6 c — UMAP of per-neuron rank vectors — is a post-processing step
outside this substrate-side driver).

## Reproduce

```bash
# (gitignored real data must be present under docs/research/fruit fly/FAFB v783/)
cd packages/Core/examples/connectome
./extract_fafb_subset.sh thermosensory 1          # → /tmp/fafb_thermosensory_k1_*.{metta,tsv}
cat <(sed -n '26,68p' InfoFlow.metta) \
    /tmp/fafb_thermosensory_k1_edges.metta /tmp/fafb_thermosensory_k1_seed.metta \
    <(echo '!(flow-step 1)') <(echo '!(collapse (match &self (reached $n 1) $n))') > /tmp/run.metta
curl -s -X POST http://127.0.0.1:7702/metta_stateless \
     -H 'Content-Type: text/plain' --data-binary @/tmp/run.metta
# diff the (reached $n $rank) set against /tmp/oracle_thermosensory.tsv → expect ∅
```

Citation for any published result: Dorkenwald, Matsliah, Sterling, Schlegel et al.
& The FlyWire Consortium, *Nature* **634**, 124–138 (2024), DOI
10.1038/s41586-024-07558-y. See `docs/specs/flywire_connectome_spec.md`.
