# Upstream MORK bug report — `tail` sink keeps the wrong set (HeadTailSink shared fill branch)

**Target:** `trueagi-io/MORK`, `kernel/src/sinks.rs` — `HeadTailSink<const head: bool>`
**Introduced by:** commit `d409be2` ("Add connectome dimensionality example") — newest commit touching `sinks.rs`, so the bug is current.
**Severity:** correctness — `tail N` returns a set that is **not** the N largest, for `N ≥ 2` whenever the sink does not see paths in ascending order (i.e. essentially always, e.g. any multi-source join). `head` is unaffected; `tail 1` is unaffected.

## Symptom

`tail N` is supposed to keep the N lexicographically-largest paths. It instead keeps an incorrect set — retaining some of the *smallest* paths and dropping some that belong in the top-N.

Verbatim-logic reproduction (the `HeadTailSink::sink` fill+capacity code copied unchanged, with `extrema: PathMap<()>` modeled by a `BTreeSet<Vec<u8>>`; `descend_last_path`→`next_back`, `to_next_val`→`next`):

```
head 2  input order ["e","a","b"]       kept {a,b}     truth {a,b}     OK
tail 2  input order ["e","a","b"]       kept {a,e}     truth {b,e}     BUG
head 3  input order ["e","a","c","b","d"] kept {a,b,c}  truth {a,b,c}   OK
tail 3  input order ["e","a","c","b","d"] kept {a,c,e}  truth {c,d,e}   BUG
```

`head` (the control) is correct; only `tail` is wrong — which localizes the cause.

## Root cause

`HeadTailSink` uses `extremum` as the eviction boundary, and the capacity branch is correctly `head`-aware:

```rust
if self.count == self.max {
    if (if head { &self.extremum[..] <= mpath } else { &self.extremum[..] >= mpath }) { /* ignore */ }
    else { /* insert mpath, remove extremum, recompute: head→descend_last (max), tail→to_next_val (min) */ }
}
```

For this to be correct the boundary must be **max(kept) for head** and **min(kept) for tail**. But the *fill* branch (`count < max`) is **shared with no head/tail split** and only ever moves `extremum` up toward the max:

```rust
} else { // count < max  — SHARED
    if &self.extremum[..] <= mpath {
        if self.extrema.insert(mpath, ()).is_none() { self.extremum.clear(); self.extremum.extend_from_slice(mpath); self.count += 1; }
    } else {
        if self.extrema.insert(mpath, ()).is_none() { self.count += 1; }
    }
}
```

So when `count` first reaches `max`, **tail's `extremum` is the max of the kept set, not the min.** The very first capacity decision for tail then:
- `extremum >= mpath` with `extremum = max` → ignores almost every `mpath` (anything `≤ max`), failing to admit elements larger than the true min; and
- in the replace branch it removes `extremum` (the **max**) instead of the min — evicting the wrong element.

After the first replace, `to_next_val` resets `extremum` to the min (correct thereafter), but the element wrongly kept/dropped at the transition persists in the result. Ascending input streams happen to mask it; non-ascending ones (multi-source joins) expose it.

`tail 1` is unaffected (with `max = 1` the single kept element is both min and max), so the connectome example's `(tail 1 (top-farness …))` and its dimensionality result are **not** affected.

## Fix

Make the fill branch track the correct boundary per `head`/`tail` (max for head, min for tail) — e.g.:

```rust
} else { // count < max
    if self.extrema.insert(mpath, ()).is_none() {
        self.count += 1;
        let update = self.extremum.is_empty()
            || if head { mpath > &self.extremum[..] } else { mpath < &self.extremum[..] };
        if update { self.extremum.clear(); self.extremum.extend_from_slice(mpath); }
    }
}
```

(Equivalently: after each fill insert, recompute `extremum = if head { extrema.last } else { extrema.first }`.)

## Also: the `sink_tail()` test characterizes the bug

`kernel/src/main.rs::sink_tail()` asserts
`"(3 x Q)\n(1 y Q)\n(3 y Q)\n(1 x R)\n(3 x R)\n(2 y R)\n(3 y R)\n"`,
which is **not** the 7 lexicographically-largest `cux` paths (it includes `Q`-prefixed paths while dropping the larger `(cux R x 2)` / `(cux R y 1)`). It's a characterization of the current (buggy) output, not a correctness check; it should be updated to the true top-7 once the fill branch is fixed. (`sink_head()`'s assertion *is* the true 7-smallest — consistent with head being correct.)

## Cross-check (independent confirmation)

The Julia reimplementation (`CognitiveSubstratesAI/MORK`, `HeadSink`/`TailSink`) is a faithful 1:1 port of this logic. A discriminating test (`tail 2` of ascending `a..e`, plus the trip cases above) **failed** until the fill branch was split per head/tail exactly as above, then passed — and `head` was unchanged. See `project_mork_tailsink_port`. (Standalone reproduction: `docs/headtail_repro.rs` — `rustc -O docs/headtail_repro.rs && ./headtail_repro`, runs on stable.)
