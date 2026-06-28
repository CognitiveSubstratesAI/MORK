TITLE:
`tail` sink returns the wrong set for N ≥ 2 — HeadTailSink fill branch tracks the max boundary for both head and tail

----- BODY (paste below the title) -----

## Summary

`HeadTailSink<const head: bool>` (`kernel/src/sinks.rs`) is shared between `head` (keep N lexicographically-smallest) and `tail` (keep N largest). The **capacity** branch is `head`-aware, but the **fill** branch (`count < max`) is not — it only ever moves `extremum` up toward the max. That's correct for `head` (boundary = max kept) but wrong for `tail` (boundary should be the min kept). As a result **`tail N` keeps an incorrect set for `N ≥ 2`** whenever paths aren't sunk in ascending order (i.e. essentially always — any multi-source join).

- `head` is **not** affected.
- `tail 1` is **not** affected (the single kept element is both min and max), so the `connectome_*` example's `(tail 1 …)` is fine.
- Current as of `d409be2` (newest commit touching `sinks.rs`).

## Reproduction

The `HeadTailSink::sink` fill+capacity logic copied verbatim, with `extrema: PathMap<()>` modeled by a `BTreeSet<Vec<u8>>` (`descend_last_path`→`next_back`, `to_next_val`→`next`). Runs on stable:

```
head 2  input ["e","a","b"]        kept {a,b}     truth {a,b}     OK   (control)
tail 2  input ["e","a","b"]        kept {a,e}     truth {b,e}     BUG  (kept the smallest, dropped a top-2)
head 3  input ["e","a","c","b","d"] kept {a,b,c}  truth {a,b,c}   OK
tail 3  input ["e","a","c","b","d"] kept {a,c,e}  truth {c,d,e}   BUG  (dropped d, kept a)
```

(Full standalone file available; can attach.)

## Root cause

```rust
// capacity branch — correctly head-aware:
if (if head { &self.extremum[..] <= mpath } else { &self.extremum[..] >= mpath }) { /* ignore */ }
else { /* insert mpath; remove extremum; head→descend_last (max) | tail→to_next_val (min) */ }

// fill branch (count < max) — SHARED, only tracks the max:
} else {
    if &self.extremum[..] <= mpath {
        if self.extrema.insert(mpath, ()).is_none() { self.extremum = mpath; self.count += 1; }
    } else {
        if self.extrema.insert(mpath, ()).is_none() { self.count += 1; }
    }
}
```

When `count` first hits `max`, tail's `extremum` is `max(kept)`, not `min(kept)`. The first capacity decision then ignores almost everything (`extremum >= mpath` is true for any `mpath ≤ max`) and, in the replace path, evicts the **max** instead of the min. `to_next_val` fixes `extremum` after the first replace, but the element wrongly kept/dropped at the transition persists.

## Fix

Make the fill branch track the correct boundary per `head`/`tail`:

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

## Note: the `sink_tail()` test characterizes the bug

`kernel/src/main.rs::sink_tail()` asserts `"(3 x Q)\n(1 y Q)\n(3 y Q)\n(1 x R)\n(3 x R)\n(2 y R)\n(3 y R)\n"`, which isn't the 7 largest `cux` paths (it keeps `Q`-prefixed paths while dropping the larger `(cux R x 2)` / `(cux R y 1)`). It should be updated to the true top-7 once fixed. `sink_head()`'s assertion *is* the true 7-smallest, consistent with head being correct.
