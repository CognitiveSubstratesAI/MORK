# Adaptations — where upstream is RIGHT and we deliberately built it differently

`UPSTREAM_BUGS.md` records the cases where **upstream is wrong** and we decline to reproduce it.
This file is the other category, and it had no home until 2026-08-03: places where upstream is
correct, we understood it, and we chose a **different mechanism** anyway.

**Why this file exists.** Every entry below was already written down — inside the file it affects,
often inside an unrelated function's comment. That is not findable. On 2026-08-03 a single one of
them (entry 1) was rediscovered the hard way three times in one session: it was called "unfinished
port work", then a working guard was suspected of being wrong because of it, then an argument was
built on a trait that does not exist. The information existed each time. It was not where anyone
would look.

**The rule this file encodes:** *"we ported exactly from upstream"* is FALSE, and believing it is
what makes these recur. The port is faithful in RESULT for the things below, and deliberately
different in MECHANISM. A divergence you cannot find is indistinguishable from a defect.

Each entry states: what upstream does (with the upstream file:line, re-read 2026-08-03), what we do,
why, and **what it costs** — because the cost is the part that surfaces later as a mystery.

---

## 1. Sinks write ABSOLUTE PATHS; upstream writes through a ROOTED WriteZipper

**Upstream.** Every BTM sink requests a write zipper rooted at its own `request()` prefix, then
writes RELATIVE to that root, stripping both the keyword header and the root off the matched path:

```rust
// sinks.rs:167 (AddSink::sink), and the same shape at :145 :349 :390 :517 :559 :638 :735 :845 :987 :1101
let mpath = &path[3 + wz.root_prefix_path().len()..];
wz.move_to_path(mpath);
```

**Ours.** `sink_apply!` receives the ABSOLUTE matched path and writes absolutely — `path[skip+1:end]`.
There is no rooted zipper, and `Sinks.jl:59` records the choice: *"PRIMUS's intentional direct-`s.btm`
adaptation of upstream's writer-zipper sink interface."*

**Why it is sound.** The two are EQUIVALENT for the storing sinks, and the arithmetic is the proof.
The matched path is `header ++ root ++ tail`, so:

```
upstream absolute  =  root ++ path[skip+rootlen..]  =  root ++ tail
ours     absolute  =  path[skip..]                  =  root ++ tail
```

Identical. This is why every AddSink/RemoveSink/HeadSink probe matches byte-for-byte.

**What it costs — and this is the part that keeps resurfacing.** The equivalence holds for `sink()`.
It does NOT hold for the reduction sinks' `finalize`, where upstream grafts the collected input AT
the root and traverses from the EMPTY path, so branches 1/2 emit `root ++ root ++ tail`. We reproduce
that OUTPUT via a guarded prepend (`_redsink_finalize!`, and separately in `CountSink`/`PureSink`)
rather than by rooting the zipper. The guard — prepend only when the root is a PROPER PREFIX of the
output — is not cosmetic: removing it regresses 15 probes, MEASURED, producing `(ok) 1 (ok)` and
`(six) 6 (six)` where the binary emits neither.

Three probes remain divergent as a DIRECT CONSEQUENCE of this adaptation and are not backlog:

* `sinks/g1_count_fixed_depth` and `sinks/g2_sum_lit_removecheck` — upstream's write PATH is longer
  than ours in a way that is invisible in a dump but visible to an exact-path removal. Both probe
  names say so.
* `sinks/g4_ignored` — upstream's three `if`s are not mutually exclusive, so its `1` arrives from
  the trie path rather than the template.

⚠️ **Do not "fix" these by widening the prepend.** Always-prepend was tested on 2026-08-03 and broke
15 probes; CountSink-only always-prepend broke 2 more. Both refuted by measurement, not argument.

---

## 2. `PrefixBtm` — byte-prefix multi-space regions, which upstream does not have

**Upstream** scopes exec by THREAD ID. There is no byte-prefix region model.

**Ours** wraps the destination as `PrefixBtm(inner, prefix)` and overloads the five PathMap ops the
sinks touch, so sinks keep writing relative paths and the wrapper redirects them into the region
(`Sinks.jl:54-97`). Internal accumulators (`s.head`, `s.unique`) are raw `PathMap`s and untouched.

**Cost.** No upstream counterpart exists, so no conformance probe can validate it — it is covered
only by our own tests. Anything comparing "our sink layer" to "upstream's sink layer" must exclude
this; it is an addition, not a port.

---

## 3. `ez_next!` / `ez_gnext!` — a split traversal where upstream has one

**Upstream** has a single traversal, `next() = gnext(0)` (`expr/src/lib.rs:1321-1325`), where `gnext`
takes a trace offset.

**Ours** exposes both under separate names because the offset argument is load-bearing in some call
sites and absent in others; `Expr.jl:380` records that `ez_next!` is ours.

**Cost.** Low, but a "function inventory" sweep comparing names will report a phantom extra
function. It is one upstream function surfaced as two.

---

## 4. ADR-056 chain-projection pushdown — ENTIRELY OURS

**Upstream has no counterpart.** `_try_chain_projection!` is our optimization: a strict chain (k≥3)
whose templates project to the chain endpoints is computed by composition instead of enumerating
paths.

**Cost, and it was realised.** An addition above upstream has no upstream oracle, and on 2026-08-03
this one was found to fire on arity-N factors and emit NOTHING — `_chain_compose` splits stored
paths with `_split2` (exactly two sub-expressions), so a 3-ary link never matches and the composition
returns empty. Two probes (`s5_chain4_ground`, `s5_chain4_proj`) were silently wrong. Now restricted
to binary factors (`TrieJoin.jl`).

**The general lesson:** the general path it bypasses was correct the whole time. An optimization with
no upstream counterpart needs its own oracle, or it is a silent-wrong-answer generator.

---

## 5. `MorkL` — ours

No upstream counterpart. Same caveat as entry 4: no conformance probe can see it.

---

## 6. `remove_val_at!` call sites do NOT pass `prune` — ATTEMPTED, REVERTED, cause UNKNOWN

Upstream's PathMap removal at a call site is `.remove(path)`, which is the alias
`remove_val_at(path, TRUE)` (`trie_map.rs:379-381`) — it always prunes. Four of our MORK call sites
omit the flag and take the `prune=false` default:

    Space.jl:217   <-> upstream space.rs:850   (space_add_all_sexpr! add/remove branch)
    Space.jl:2220  <-> upstream space.rs:1704  (driver popping the exec it is about to run)
    Space.jl:2497                              (transform result path — upstream counterpart unmapped)
    Space.jl:2745                              (prefix variant of :2220 — unmapped)

`Sinks.jl` HeadSink WAS fixed (`remove_val_at!(s.head, s.top, true)`) and closed 2 probes.
`RemoveSink` is a MECHANISM difference, not a missing flag: upstream does ONE trie-level
`wz.subtract_into(&self.remove.read_zipper(), true)` (sinks.rs:366) where ours loops per path.

### ⚠️ DO NOT simply add `prune=true` and commit — it was tried on 2026-08-03 and REVERTED

Adding it to the first two sites made the 285-probe conformance corpus **6-10x slower**:

    gate normally        ~110-230s
    with the two sites   1260s and 1855s (both killed before finishing), at load 1.30 on 2 cores

and the cause was NOT identified. What WAS measured, and rules out the obvious explanations:

* prune is CHEAP in isolation — 1.6x over 4000 `remove_val_at!` calls at n=4000, and *faster* than
  no-prune at n=100/1000.
* prune WORKS and matches upstream's construction — after `remove_val_at!(m, b"p/q/r", true)`,
  `path_exists_at(m, b"p/q")` is false; with prune=false it stays true; upstream's own
  root-zipper-then-descend form gives the same answer as ours.
* the DRIVER is not the victim — 80 execs / 80 steps / 6480 atoms in **0.664s** with both sites
  pruning.
* individual probes are FAST WARM — `g8_act_accum` 0.0s, `g1_hash_ctl_eg_fixpoint` 0.2s,
  `g2_sum_dup` 0.0s, taking the minimum of 3 runs.

So it is not the prune primitive, not the driver, and not steady-state probe execution. The cost
appears only in the full corpus. **Next attempt should PROFILE (`@profile` / `@time` inside the
corpus runner), not bisect** — three bisect rounds at 20+ minutes each produced no localisation.

### ⚠️ And check the machine FIRST

Two environment traps cost more time than the change itself on 2026-08-03:

* **VS Code's Julia LSP was indexing `~/PRIMUS`** (the dead 8.2 GB legacy root) at 85% CPU for
  55 minutes. This box has **2 cores**, so that alone doubles every timing. Check `/proc/loadavg`
  and `ps -eo pcpu,pid,cmd --sort=-pcpu` BEFORE attributing a slowdown to code.
* **Cold JIT reads as a slowdown.** A probe-by-probe sweep timing each probe's FIRST run reported
  18s/63s/10s for probes that are 0.0-0.2s warm. Always warm before timing — the same trap already
  recorded for `meet_k_path` ("10 min for 800 cases" was JIT; 61ms warm).

**Zero conformance probes currently depend on these four sites**, which is why reverting was the
right call rather than pushing through.

---

## MAINTENANCE — the sink layer has THREE independent write paths, and that is why fixes recur

**Measured from `git log -- src/kernel/Sinks.jl` on 2026-08-03: 47 commits since 2026-04-23.** The
single most repeated failure is not a bug — it is a SHAPE: *fix one sink, rediscover the same defect
in the others weeks later, fix them one at a time.*

```
three-branch dispatch      07-26  48b7e8e  And/Sum
                           07-26  c620e4e  Count/Float/Pure   ("one defect, four call sites")
                           07-27  5b2053c  HashSink            ← still a third commit, next day

root-doubling              08-03  8d5437a  _redsink_finalize!
                           08-03  e4cad55  CountSink           ("apply the same guarded ...")
                           08-03  56e8b25  PureSink            ← same rule, three commits, one day

HeadSink capping           06-14  4f57120  "fix HeadSink never-capping"  (reworked the boundary)
                           08-02  efe5787  "HeadSink kept N-1"           ← STILL not capping, 7 weeks later
```

The HeadSink pair is the sharpest: June reworked the eviction-boundary logic and August found the
real cause was a missing `prune` flag on the removal. Right area, wrong mechanism, seven weeks apart.

**The structural reason** — and it is why "be more careful" will not fix it — is that there is no
single sink write path:

| path | sinks | where |
|---|---|---|
| `_redsink_finalize!` | And · Sum · Hash · FloatReduction | shared finalize |
| `sink_finalize!(::CountSink)` | Count | its own — reduces at CONTEXT level |
| `sink_apply!(::PureSink)` | Pure | writes PER MATCH, not in finalize |
| `sink_apply!(::HeadSink)` | Head/Tail | its own eviction loop |
| `sink_apply!(::USink)` | U | running unification |

A fix to "the reduction sinks" genuinely does not reach the other four, and nothing makes their
absence visible.

⚠️ **THE CHECK, before committing any sink behaviour change:** grep the OTHER paths in the table for
the same shape. Mechanically — if you changed a branch dispatch, a write position, or a guard, ask
which of the five other sites has the same construct. That single step would have collapsed the
root-doubling work into one commit and caught HashSink in July.

---

## Not in this file

Cases where **upstream is wrong** live in `UPSTREAM_BUGS.md`, not here — `mod_i*` aborting on a zero
divisor, `encode_hex` corrupting at 32 bytes and aborting at 33, the quote cursor rewind, `unbind`'s
255 sentinel, `load_jsonl`'s untagged index, #135, the HashSink digest width, and the
`_redsink_parse_entry` / `remove` prune defects. Those are deviations FROM a defect; these are
adaptations AWAY FROM a correct design.

`PathMap/test/differential/ADAPTATIONS.md` carries the PathMap-side entries.
