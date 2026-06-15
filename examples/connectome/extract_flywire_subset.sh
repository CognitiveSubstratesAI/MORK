#!/usr/bin/env bash
# extract_flywire_subset.sh — generic FlyWire/Codex connectome extraction.
#
# Aggregates per-neuropil edges from a FlyWire/Codex dataset's
# connections_princeton.csv.gz into a unique (pre, post, Σsyn) TSV.
# Works for any organism that publishes in the FlyWire/Codex schema:
#   FAFB v783, BANC v626, MAC, MAOL, MCNS, etc.
#
# This is the COMMON step across all FlyWire-published connectomes. Per-organism
# downstream stages (modality classification, deterministic oracles, K-bounded
# subgraph extraction) live in dataset-specific wrapper scripts that call this
# script and then add their own logic.
#
# WHY a generic script: FAFB and BANC are reconstructions of the SAME female
# fly (one being); MAC, MAOL, MCNS are reconstructions of a MALE fly (different
# being). Each new FlyWire/Codex dataset reuses the same connections_princeton
# schema, so the aggregation logic is shared. Per-organism wrappers diverge
# only at the annotation/seed/oracle layer where neuron classification schemas
# differ between datasets.
#
# ARCHITECTURE NOTE: female datasets (FAFB+BANC+skeletons) live in atomspace
# `&fly-female`; male datasets (MAC+MAOL+MCNS) in `&fly-male`. The combined
# load is one bulk_load_syn! per organism per pairs.tsv. Shared species-level
# taxonomy lives in `&common`. See docs/specs/flywire_connectome_spec.md.
#
# INPUT  (gitignored per docs/specs/flywire_connectome_spec.md §11):
#   <DATA_PATH>/connections_princeton.csv.gz  — schema: pre_root_id,post_root_id,neuropil,syn_count,nt_type
#
# OUTPUT (written to $OUT, default /tmp):
#   <organism_lower>_pairs.tsv  — aggregated (pre, post, Σsyn) edges, TSV
#
# USAGE:
#   ./extract_flywire_subset.sh <ORGANISM> [DATA_PATH]
#
# EXAMPLES:
#   ./extract_flywire_subset.sh FAFB "$HOME/PRIMUS/docs/research/fruit fly/FAFB v783"
#   ./extract_flywire_subset.sh BANC "$HOME/PRIMUS/docs/research/fruit fly/BANC v626"
#   ./extract_flywire_subset.sh MAC  "$HOME/PRIMUS/docs/research/fruit fly/MAC"
#
# If DATA_PATH is omitted, falls back to:
#   $HOME/PRIMUS/docs/research/fruit fly/<ORGANISM>/
set -euo pipefail

if [ $# -lt 1 ]; then
    echo "usage: $0 <ORGANISM> [DATA_PATH]" >&2
    echo "  <ORGANISM>   short tag, e.g. FAFB / BANC / MAC / MAOL / MCNS" >&2
    echo "  [DATA_PATH]  defaults to \$HOME/PRIMUS/docs/research/fruit fly/<ORGANISM>/" >&2
    exit 1
fi

ORGANISM="$1"
ORGANISM_LC=$(echo "$ORGANISM" | tr '[:upper:]' '[:lower:]')
DATA="${2:-$HOME/PRIMUS/docs/research/fruit fly/$ORGANISM}"
OUT="${OUT:-/tmp}"
CONN="$DATA/connections_princeton.csv.gz"
PAIRS="$OUT/${ORGANISM_LC}_pairs.tsv"

[ -d "$DATA" ] || { echo "missing data directory: $DATA" >&2; exit 1; }
[ -f "$CONN" ] || { echo "missing $CONN (expected FlyWire/Codex schema)" >&2; exit 1; }

# Aggregate per-neuropil edges → unique (pre, post, Σsyn).
# All FlyWire/Codex connections_princeton.csv.gz files share this schema:
#   pre_root_id, post_root_id, neuropil, syn_count, nt_type
# So this awk is identical across organisms — that's the shared core.
if [ ! -s "$PAIRS" ]; then
    echo "[aggregating $ORGANISM connectome] $CONN -> $PAIRS ..." >&2
    zcat "$CONN" | tail -n +2 | \
        awk -F, '{c[$1 SUBSEP $2]+=$4}
                 END{for(k in c){split(k,a,SUBSEP); print a[1]"\t"a[2]"\t"c[k]}}' \
        > "$PAIRS"
fi

EDGES=$(wc -l < "$PAIRS")
echo "      $ORGANISM unique edges: $EDGES" >&2
echo "      $PAIRS ready for bulk_load_syn!" >&2
