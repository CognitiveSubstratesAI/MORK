#!/usr/bin/env bash
# extract_banc_subset.sh — BANC v626 (Brain And Nerve Cord, female) wrapper.
#
# Composes the generic FlyWire connection-aggregation step (in
# extract_flywire_subset.sh) with BANC-specific functional-class extraction
# from neurons.csv_2.gz. BANC is part of the female adult fly's reconstruction
# alongside FAFB v783 (brain) — together they cover the same female specimen.
#
# THE WORK SPLITS as follows (this is the model for adding any new dataset):
#   1. extract_flywire_subset.sh BANC  — generic connections aggregation
#                                        (shared across FAFB/BANC/MAC/MAOL/MCNS)
#   2. THIS script's neuron-class extraction — BANC-specific because its
#      neurons.csv_2.gz uses a 21-column capitalized schema distinct from
#      FAFB's classification.csv.gz (8 columns, snake_case). Male datasets
#      will need their own wrapper scripts at this layer when their neuron-
#      annotation schemas are confirmed.
#
# INPUT  (gitignored — see docs/specs/flywire_connectome_spec.md §11):
#   docs/research/fruit fly/BANC v626/connections_princeton.csv.gz  (3.78M rows)
#   docs/research/fruit fly/BANC v626/neurons.csv_2.gz              (115K rows)
# OUTPUT (written to $OUT, default /tmp):
#   banc_pairs.tsv               — 2,676,592 unique aggregated edges (via generic)
#   banc_motor_neurons.txt       — motor neurons (BANC-specific)
#   banc_descending_neurons.txt  — brain→VNC bridges (BANC-specific)
#   banc_ascending_neurons.txt   — VNC→brain bridges (BANC-specific)
#
# USAGE:  ./extract_banc_subset.sh
set -euo pipefail

DATA="${DATA:-$HOME/PRIMUS/docs/research/fruit fly/BANC v626}"
OUT="${OUT:-/tmp}"
NEUR="$DATA/neurons.csv_2.gz"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

[ -f "$NEUR" ] || { echo "missing $NEUR" >&2; exit 1; }

# Step 1 — generic connection aggregation (delegated to extract_flywire_subset.sh).
DATA="$DATA" OUT="$OUT" "$SCRIPT_DIR/extract_flywire_subset.sh" BANC "$DATA"

# Step 2 — BANC-specific functional-class extraction from neurons.csv_2.gz.
# Schema (21 columns, capitalized; from header inspection):
#   1: Root ID
#   2: Top in/out region
#   3: Community labels
#   4: Predicted NT type
#  11: Super Class
#  12: Class
#  13: Sub Class
#  14: Hemilineage
#  15: Nerve
#  16: Soma side
#  17: Primary Cell Type
echo "[BANC functional classes from $NEUR] ..." >&2

# Motor neurons — `Super Class` or `Class` contains "motor"
zcat "$NEUR" | tail -n +2 | \
    awk -F, 'tolower($11) ~ /motor/ || tolower($12) ~ /motor/ {print $1}' \
    | sort -u > "$OUT/banc_motor_neurons.txt"
echo "      motor neurons:      $(wc -l < "$OUT/banc_motor_neurons.txt")" >&2

# Descending neurons — brain→VNC bridge; class or sub_class contains "descending"
zcat "$NEUR" | tail -n +2 | \
    awk -F, 'tolower($12) ~ /descending/ || tolower($13) ~ /descending/ {print $1}' \
    | sort -u > "$OUT/banc_descending_neurons.txt"
echo "      descending neurons: $(wc -l < "$OUT/banc_descending_neurons.txt")" >&2

# Ascending neurons — VNC→brain bridge; class or sub_class contains "ascending"
zcat "$NEUR" | tail -n +2 | \
    awk -F, 'tolower($12) ~ /ascending/ || tolower($13) ~ /ascending/ {print $1}' \
    | sort -u > "$OUT/banc_ascending_neurons.txt"
echo "      ascending neurons:  $(wc -l < "$OUT/banc_ascending_neurons.txt")" >&2

echo "" >&2
echo "DONE. BANC edges + functional neuron classes ready in $OUT/" >&2
echo "" >&2
echo "Next: combined-load FAFB + BANC into one PathMap btm. Bytes are identical" >&2
echo "encoding; shared root_ids unify automatically. Example:" >&2
echo "  bulk_load_syn!(s, \"$OUT/fafb_pairs.tsv\")     # FAFB first" >&2
echo "  bulk_load_syn!(s, \"$OUT/banc_pairs.tsv\")     # BANC into same trie" >&2
echo "  act_save(act_from_zipper(s.btm, ...), \"/tmp/fly.act\")  # one .act for both" >&2
