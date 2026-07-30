#!/usr/bin/env bash
# run_probes.sh — drive the upstream release binary over a generated pure-op probe directory.
#
# WHY THIS IS A SCRIPT AND NOT A ONE-LINER. Three things have to be right or the differential lies:
#
#  1. GROUND TRUTH GOES TO A FILE, NEVER STDOUT. `mork run p.mm2 p.raw` preserves the bytes;
#     `mork run p.mm2 > p.raw` does not — upstream's stdout dump replaces invalid UTF-8, so byte
#     0xFE prints as EF BF BD. Most pure ops produce high bytes, so stdout cannot be ground truth.
#  2. AN ABORT MUST BE REPORTED, NOT SKIPPED. A panic inside `extern "C"` is a NON-UNWINDING abort:
#     the process dies and writes NO output file. A comparison harness that pairs `.mm2` with `.raw`
#     then sees a missing file and skips it — coverage loss that reads as success. Every abort is
#     listed here and recorded in `ABORTED.txt` for `cmp_pure.jl` to attribute.
#  3. ONE FILE PER OP is what makes (2) survivable: an abort costs one op, not a whole type family.
#
# Usage:  ./run_probes.sh <probedir> [path-to-mork-binary]
set -uo pipefail

DIR="${1:?usage: run_probes.sh <probedir> [mork-binary]}"
MORK_BIN="${2:-$HOME/JuliaAGI/dev-zone/MORK/target/release/mork}"

[ -x "$MORK_BIN" ] || { echo "no mork binary at $MORK_BIN" >&2; exit 2; }
[ -d "$DIR" ] || { echo "no probe dir at $DIR" >&2; exit 2; }

ABORTED="$DIR/ABORTED.txt"
: > "$ABORTED"
ok=0 aborted=0 empty=0

for f in "$DIR"/op_*.mm2; do
    [ -e "$f" ] || continue
    base="${f%.mm2}"
    op=$(basename "$base"); op="${op#op_}"
    rm -f "$base.raw"
    # `cd` into the binary's workspace: upstream resolves some relative resource paths from there.
    if err=$(cd "$(dirname "$MORK_BIN")/../.." && "$MORK_BIN" run "$f" "$base.raw" 2>&1); then
        if [ -s "$base.raw" ]; then
            ok=$((ok + 1))
        else
            empty=$((empty + 1))
            printf '%s\tEMPTY OUTPUT\n' "$op" >> "$ABORTED"
        fi
    else
        aborted=$((aborted + 1))
        reason=$(printf '%s' "$err" | grep -iE "panicked at|assertion|range end|overflow|abort" \
                 | head -1 | sed 's/^[[:space:]]*//')
        printf '%s\t%s\n' "$op" "${reason:-nonzero exit, no panic line}" >> "$ABORTED"
        rm -f "$base.raw"     # a partial file would be compared as if it were complete
    fi
done

echo "=== upstream probe run ==="
echo "  ops with output : $ok"
echo "  ops EMPTY       : $empty"
echo "  ops ABORTED     : $aborted"
if [ "$aborted" -gt 0 ] || [ "$empty" -gt 0 ]; then
    echo "--- $ABORTED ---"
    cat "$ABORTED"
fi
