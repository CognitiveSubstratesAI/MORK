#!/usr/bin/env bash
# extract_fafb_subset.sh — build a tractable real-data subset of the FAFB v783
# connectome for the InfoFlow.metta model (Stage 2 of the connectome validation).
#
# WHY a subset: Core's `core_match` is an O(N) full trie-walk (no structural
# index on bound argument positions — see CoreSpace.jl), so the backward-scan
# info-flow model costs O(candidates x total_atoms) per step.  The full FAFB
# graph (3.73M unique edges) is the Stage-3 perf stress test, not Stage 2.
# Here we cut a biologically-coherent, step-bounded subcircuit small enough to
# run the *unchanged* Stage-1 model in the warm interpreter, and we compute a
# deterministic reference oracle (native awk) to validate the MeTTa run against.
#
# INPUT  (gitignored real data, Codex export — see docs/specs/flywire_connectome_spec.md §11):
#   docs/research/fruit fly/FAFB v783/connections_princeton.csv.gz  (5.34M rows)
#   docs/research/fruit fly/FAFB v783/classification.csv.gz         (139,256 rows)
# OUTPUT (small, reproducible; written to $OUT, default /tmp):
#   fafb_pairs.tsv              — connectome aggregated to unique (pre,post,Σsyn)
#   seed_<MOD>.txt              — afferent root_ids of the seed modality
#   oracle_<MOD>.tsv            — deterministic (node,rank) reference oracle
#   fafb_<MOD>_k<K>_edges.metta — (syn pre post cnt) atoms, in-edges of rank<=K
#   fafb_<MOD>_k<K>_seed.metta  — (reached <id> 0) seed atoms
#
# MODEL (deterministic core of Nature-2024 Fig-6a, spec §7): a neuron is reached
# at step k+1 iff the SYNAPSE-weighted ratio of its inputs from the already-
# reached set is >= 0.3.  Seed = afferent modality.  Rank = step first reached.
#
# USAGE:  ./extract_fafb_subset.sh [MODALITY] [K]
#   MODALITY  one of: thermosensory hygrosensory gustatory olfactory
#             mechanosensory visual AN   (default: thermosensory)
#   K         step cap for the extracted subgraph (default: 1)
set -euo pipefail

MOD="${1:-thermosensory}"
K="${2:-1}"
DATA="${DATA:-$HOME/code/CognitiveSubstratesAI/docs/research/fruit fly/FAFB v783}"
OUT="${OUT:-/tmp}"
CONN="$DATA/connections_princeton.csv.gz"
CLASS="$DATA/classification.csv.gz"

[ -f "$CONN" ]  || { echo "missing $CONN"  >&2; exit 1; }
[ -f "$CLASS" ] || { echo "missing $CLASS" >&2; exit 1; }

# 1. Aggregate per-neuropil edges -> unique (pre,post,Σsyn).  ~40s, ~3.7M rows.
if [ ! -s "$OUT/fafb_pairs.tsv" ]; then
  echo "[1/4] aggregating connectome -> $OUT/fafb_pairs.tsv ..." >&2
  zcat "$CONN" | tail -n +2 | \
    awk -F, '{c[$1 SUBSEP $2]+=$4}
             END{for(k in c){split(k,a,SUBSEP); print a[1]"\t"a[2]"\t"c[k]}}' \
    > "$OUT/fafb_pairs.tsv"
fi
echo "      unique edges: $(wc -l < "$OUT/fafb_pairs.tsv")" >&2

# 2. Seed set = afferent neurons of this modality (classification col2=flow, col4=class).
echo "[2/4] seed set ($MOD) ..." >&2
zcat "$CLASS" | tail -n +2 | \
  awk -F, -v m="$MOD" '$2=="afferent" && $4==m {print $1}' > "$OUT/seed_$MOD.txt"
echo "      seed neurons: $(wc -l < "$OUT/seed_$MOD.txt")" >&2

# 3. Deterministic oracle over the FULL real graph (native; the ground truth).
echo "[3/4] running deterministic oracle (ratio>=0.3) ..." >&2
awk -v SEEDFILE="$OUT/seed_$MOD.txt" -v OUTFILE="$OUT/oracle_$MOD.tsv" -v MAXK="$K" '
  BEGIN { while ((getline l < SEEDFILE) > 0) seed[l]=1 }
  { pre=$1; post=$2; cnt=$3; total_in[post]+=cnt; out[pre]=out[pre] post ":" cnt " ";
    if (pre in seed) reached_in[post]+=cnt }
  END {
    for (s in seed) rank[s]=0; k=1
    while (1) {
      delete fr; nf=0
      for (p in reached_in) if (!(p in rank) && reached_in[p]/total_in[p] >= 0.3) { rank[p]=k; fr[p]=1; nf++ }
      if (nf==0) break
      printf("      step %d: %d newly reached\n", k, nf) > "/dev/stderr"
      for (f in fr) if (f in out) { n=split(out[f],es," "); for(i=1;i<=n;i++){ if(es[i]=="")continue; split(es[i],pc,":"); reached_in[pc[1]]+=pc[2] } }
      k++; if (k>MAXK) break
    }
    for (p in rank) print p"\t"rank[p] > OUTFILE
  }' "$OUT/fafb_pairs.tsv"

# 4. Extract the step-bounded subgraph as MeTTa atoms.
#    Subgraph = ALL in-edges of every node with rank in 1..K (so total-in
#    denominators are exact; pre-neurons outside the reached set are kept as
#    edge sources but never become `reached`).
echo "[4/4] extracting K=$K subgraph atoms ..." >&2
awk -F'\t' -v K="$K" 'NR==FNR{ if($2>=1 && $2<=K) keep[$1]=1; next }
                      ($2 in keep){ print "(syn "$1" "$2" "$3")" }' \
  "$OUT/oracle_$MOD.tsv" "$OUT/fafb_pairs.tsv" > "$OUT/fafb_${MOD}_k${K}_edges.metta"
awk '{print "(reached "$1" 0)"}' "$OUT/seed_$MOD.txt" > "$OUT/fafb_${MOD}_k${K}_seed.metta"

echo "" >&2
echo "DONE. edges=$(wc -l < "$OUT/fafb_${MOD}_k${K}_edges.metta")  seed=$(wc -l < "$OUT/fafb_${MOD}_k${K}_seed.metta")" >&2
echo "oracle ranks 1..$K:" >&2
awk -F'\t' '$2>=1{c[$2]++} END{for(r in c) print "  rank "r": "c[r]}' "$OUT/oracle_$MOD.tsv" | sort >&2
echo "" >&2
echo "Run the model (warm MettaJam server on \$CORE_REPL_PORT, default 7702):" >&2
echo "  cat <(sed -n '26,68p' InfoFlow.metta) \\" >&2
echo "      $OUT/fafb_${MOD}_k${K}_edges.metta $OUT/fafb_${MOD}_k${K}_seed.metta \\" >&2
echo "      <(echo '!(flow-step 1)') > /tmp/run.metta" >&2
echo "  curl -s -X POST http://127.0.0.1:7702/metta_stateless \\" >&2
echo "       -H 'Content-Type: text/plain' --data-binary @/tmp/run.metta" >&2
echo "Then diff the resulting (reached \$n \$rank) set against oracle_$MOD.tsv." >&2
