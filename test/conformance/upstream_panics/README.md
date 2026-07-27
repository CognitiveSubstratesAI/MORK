# Probes that CRASH the upstream binary

49 MM2 programs from the 2026-07-26 differential sweep for which `mork run <probe>.mm2` **aborts** —
`todo!()`, `unreachable!()`, a panic, or a timeout — so upstream produces **no output to compare
against**. They are deliberately kept OUT of the conformance corpus proper: with no oracle there is
nothing to assert, and scoring them as failures would make the gate permanently red for no reason.

They are vendored anyway because they are **evidence about upstream's limits**, and that evidence is
expensive to recreate — it took a full sweep with a built binary to find them.

## Why they matter

1. **They mark where "match upstream" has no meaning.** If a future session finds our engine diverging
   on one of these shapes, the answer is *not* "make it match" — there is nothing to match. Upstream
   crashes. Any behaviour we choose is a design decision to be recorded, not a port defect. Without
   this list that call gets re-litigated from scratch every time.

2. **They are candidates for upstream bug reports.** Several are ordinary-looking programs — a
   non-numeric value handed to `sum`, an unknown function name, a compound `<source>` slot reaching a
   `todo!()` in `PureSink` (sinks.rs:1136/1145).

3. **They are a tripwire for upstream updates.** When the vendored binary is rebuilt, re-running these
   is the cheapest way to learn that upstream has implemented or fixed something — a probe that starts
   producing output is a `todo!()` that got filled in, and likely a port gap that just opened for us.

## Re-running them

```bash
for f in MORK/test/conformance/upstream_panics/*.mm2; do
  ( cd "$(mktemp -d)" && timeout 25 <path-to>/mork run "$f" ) || echo "STILL PANICS: $(basename "$f")"
done
```

Any probe that now succeeds should be promoted: pin its output as a `.expected`, move it into
`conformance/{sinks,space}/`, and add it to `EXPECTED_PASS.txt` if we match.

## Provenance

Filenames keep their sweep group prefix (`g1`..`g8` = Count+Hash, And+Sum, FloatReduction, Pure,
HeadTail, Add/Remove/Compat, U+AU, ACT+dispatch for the sinks sweep; `s1`..`s8` = coref-join,
query_multi, query_multi_raw, prefix-subsumption, transform_/_i, transform_o/_io, driver, space-io for
the space sweep).
