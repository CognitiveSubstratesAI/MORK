# Leapfrog.jl — worst-case-optimal unification leapfrog over variable-width MORK terms.
#
# Adopted from upstream `kernel/src/leapfrog.rs` (MORK PR #146, 06cdcf3), which opens with its own
# account of why it exists:
#
#     "MORK answers a conjunctive query with the ProductZipper, a relation-at-a-time join that
#      MATERIALIZES THE INTERMEDIATE PRODUCT before pruning it. This module seeks directly instead,
#      variable-at-a-time, on the PathMap byte-trie: a join variable's value is a variable-width
#      subterm, found by descending the trie with `child_mask` + `descend_to_byte`, its boundary
#      tracked by a parse stack, and a stored variable in the data is a wildcard that unifies.
#      NO DOMAIN IS MATERIALIZED."
#
# ─── WHY WE ARE ADOPTING IT, MEASURED 2026-08-20 ─────────────────────────────────────────────────
# Our `_connected_join_emit!` (TrieJoin.jl P5) DOES accept the shapes at issue — the four narrower
# classifiers reject a 6-factor clique but `_classify_connected` takes it — so this is NOT a missing
# fast path. It is the WRONG KIND of join: relation-at-a-time, materializing `nxt` at every factor.
# On upstream's own `clique4` generator (`(edge $x0 $x1)(edge $x0 $x2)(edge $x0 $x3)(edge $x1 $x2)
# (edge $x1 $x3)(edge $x2 $x3)`), timed here on this box:
#
#     size          Rust ProductZipper   Rust leapfrog   OURS (net of shim)
#     40 x 300              100 ms            28 ms           132 ms
#     200 x 3600           5376 ms           175 ms        19 080 ms
#     scaling                 54x             6.3x             145x
#
# Results are byte-identical (2161 cliques all three) — this is purely speed, and OUR EXPONENT IS
# THE WORST OF THE THREE. A clique is the canonical CYCLIC conjunctive query, and no binary-join
# plan is worst-case-optimal on one; that is a theorem, not a tuning gap. Profiling confirms both
# halves: 2.062 GiB allocated, 61.5% GC time, top frame `dict.jl:110 copy` — the `copy(bnd)` of a
# `Dict{Int,Vector{UInt8}}` once per intermediate tuple per factor (448 B, vs 64 B for a flat
# slab). Upstream reached the same second diagnosis independently and fixed it the same way
# (`52f5fb7` "Bindings is a flat sorted vec, not a BTreeMap" -> `0a41fb9` "a direct-indexed slab").
#
# ─── HOW THIS IS BEING BUILT ─────────────────────────────────────────────────────────────────────
# Bottom-up in validated layers, as upstream did ("Built bottom-up, each layer validated before the
# next: the byte-scan and the subterm parser here, then the zipper subterm cursor, then the
# unification leapfrog, gated against the ProductZipper").
#
#   LAYER 1 ✅ the pure byte-scan and resumable subterm parser (119/119, incl. 82 assertions that
#             the incremental state equals the from-scratch replay byte for byte)
#   LAYER 2 ✅ the zipper subterm cursor — enumeration and leapfrog `seek` over the live trie
#   LAYER 3a ✅ the GROUND leapfrog join (upstream's own scaffolding step, recovered from
#              `69393c7^` where it lived as `GroundJoin::leapfrog`)
#   LAYER 3b 🟡 the UNIFICATION layer — PREDICATES DONE (is_wildcard_term · is_symbol_head ·
#              column_matches_by_equality, with the byte ordering they rest on pinned exhaustively
#              over all 256 bytes). The JOIN INTEGRATION is blocked on one thing, below.
#
#              🔴 3b's INTEGRATION AND THE PORT'S ONLY REAL GAP ARE THE SAME OBJECT — `Bindings`.
#              Three findings from 2026-08-20 converge on it:
#                · the port-inventory ratchet's only genuine missing pair is `expr/lib.rs`
#                  `Bindings` + `SkippedSubterm` (the other 9 new types are leapfrog, nightly
#                  sinks, and linalg)
#                · the profile's top frame is `copy(Dict{Int,Vector{UInt8}})` at 448 B per
#                  intermediate tuple per factor, against 64 B for a flat slab
#                · the leapfrog binds PER CANDIDATE and unwinds on backtrack, so it needs
#                  INCREMENTAL bind-with-undo. Ours (`_expr_unify_inplace!`, ExprAlg.jl:420) takes
#                  a `Dict{ExprVar,ExprEnv}` and `empty!`s it — all-or-nothing, no trail, no marks.
#                  Rebinding from scratch per candidate would reintroduce exactly the copy cost
#                  this whole adoption exists to remove.
#              ⇒ upstream's own sequence is the order to follow: `52f5fb7` (flat sorted vec, not a
#              BTreeMap) -> `0a41fb9` (direct-indexed slab stacked on the trail) -> `cfa8abf`
#              (bind candidates incrementally with an undo trail). Do `Bindings` FIRST; 3b's
#              integration then has something to bind into, and the P5 path gets faster whether or
#              not leapfrog ever dispatches.
#   LAYER 3c ⏳ (was 3b integration) the wildcard branches in the descent, on top of Bindings
#
#             🔴 READ THIS BEFORE WRITING LAYER 3 — the soundness constraint, in upstream's words
#             (`fill_lead_candidates`, leapfrog.rs:1758-1766). It is the one thing here that a
#             plausible implementation gets wrong SILENTLY, by dropping answers:
#
#                 "this join UNIFIES, so a stored value may match a candidate without EQUALLING it,
#                  and an exact intersection would silently drop answers. A candidate is prunable
#                  only where UNIFIABILITY IS EQUALITY. Symbol-headed candidates are ground, and a
#                  restrictor's column holds no stored variable, so at that column only the same
#                  symbol unifies with them (a stored compound cannot unify with a symbol at all).
#                  Symbol bytes sort ABOVE every compound and variable byte, so those candidates
#                  form a SUFFIX of the enumeration: everything before it — stored wildcards, and
#                  compounds that a stored schematic compound like `(f $x)` unifies with without
#                  equalling — is pushed UNFILTERED, and the seek never skips over any of it."
#
#             ⇒ the leapfrog seek may prune ONLY within the symbol-headed suffix. A textbook WCO
#             join intersects exactly, which is correct for a RELATIONAL join and WRONG here: MORK
#             stores variables, and a stored `$w` is a wildcard that unifies with anything. Getting
#             this wrong produces a join that is fast, passes casual tests, and quietly loses every
#             answer that needed a wildcard. [[feedback_oracle_must_observe_the_defect_class]]
#
#             SCOPE, stated honestly: upstream's `UnifyJoin` is ~1500 lines with a 25-field state,
#             flattened pre-order `Step` walks, compound-child descent, factor re-indexing, a
#             binding trail with unwind marks, and buffer pools. It is several focused sessions,
#             not one. The layers below it are complete and independently validated so that work
#             starts from a verified floor.
#   LAYER 4 ⏳ dispatch, gated against the existing P5 path
#
# ⚠️ STILL NO CONSUMER, DELIBERATELY. `_space_query_multi_inner!` is untouched; the live engine takes
# `_connected_join_emit!` exactly as before. Nothing here can affect a query result until layer 4
# wires it, and it will be wired behind a flag so the two are A/B-comparable rather than swapped.
# [[feedback_parses_is_not_fires]]
#
# ⚠️ ADOPTED, NOT TRANSLITERATED. Upstream threads `&mut u32` out-params through
# `subterm_parse_step`; we return an isbits `NTuple{2,UInt32}` instead, which is allocation-free in
# Julia and lets the caller keep the state in locals the compiler can keep in registers. Same
# arithmetic, same invariants, Julia's calling convention.
# [[feedback_native_julia_not_transliteration]]
module Leapfrog

using ..MORK: byte_item, ExprArity, ExprSymbol, ExprVarRef, ExprNewVar
# ⚠️ `PathMap` NAMES BOTH A MODULE AND A TYPE. Importing the bare name binds the TYPE, so
# `PathMap.PathMap{…}` then resolves a field on a UnionAll and fails to load. Import the type
# plainly and take everything else by name.
using PathMap: ByteMask, test_bit, next_bit, PathMap, UnitVal, ReadZipperCore, GlobalAlloc,
               read_zipper_at_path,
               zipper_path, zipper_child_mask, zipper_ascend!, zipper_ascend_byte!,
               zipper_descend_to_byte!, zipper_descend_first_byte!, zipper_descend_to!,
               zipper_descend_first_k_path!, zipper_descend_until_max_bytes!,
               zipper_to_next_sibling_byte!, zipper_is_val

export subterm_parse_step, least_ge, is_complete, PARSE_START,
       SubtermCursor, cursor_first!, cursor_next!, cursor_key, cursor_seek!,
       cursor_descend_floor!, cursor_ascend_floor!, cursor_has_value, cursor_var_counts,
       GroundFactor, ground_leapfrog,
       is_wildcard_term, is_symbol_head, column_matches_by_equality

"""
    PARSE_START

The resumable parse's initial state: one complete subterm owed, no raw payload bytes owed.
A key spells exactly one complete subterm iff the fold of [`subterm_parse_step`] over it, starting
here, reaches `(0, 0)`.
"""
const PARSE_START = (UInt32(1), UInt32(0))

"""
    subterm_parse_step(b, subterms, payload) -> (subterms, payload)

One byte of the resumable subterm parse. `subterms` complete terms and `payload` raw symbol bytes
are still owed after consuming `b`.

Ports upstream `mork_expr::subterm_parse_step` (`expr/src/lib.rs:1932`) exactly:

    if payload > 0        -> payload -= 1                  # inside a symbol's raw bytes
    else                  -> subterms -= 1; then by tag:
         Arity(a)         -> subterms += a
         SymbolSize(s)    -> payload  += s
         VarRef | NewVar  -> (nothing; a variable IS a complete subterm)

⚠️ RETURNS ITS STATE RATHER THAN MUTATING OUT-PARAMS. Upstream takes `&mut u32` twice; the Julia
equivalent of that is a `Ref` per counter, which heap-allocates and defeats the point. An
`NTuple{2,UInt32}` is isbits, so this is allocation-free and the caller's locals stay in registers.

🔑 WHY THIS FUNCTION IS THE WHOLE FOUNDATION. The trie is bytes; a join variable's value is a
variable-width SUBTERM. Knowing where a subterm ends while walking byte-by-byte is what lets the
cursor stop at a term boundary without materializing anything — and doing it INCREMENTALLY is what
makes it O(1) per descent instead of an O(L) replay (see [`is_complete`]).
"""
@inline function subterm_parse_step(b::UInt8, subterms::UInt32, payload::UInt32)
    if payload > 0
        return (subterms, payload - UInt32(1))
    end
    s = subterms - UInt32(1)
    t = byte_item(b)
    if t isa ExprArity
        return (s + UInt32(t.arity), payload)
    elseif t isa ExprSymbol
        return (s, payload + UInt32(t.size))
    else                                    # ExprVarRef | ExprNewVar — a variable is complete
        return (s, payload)
    end
end

"""
    is_complete(bytes) -> Bool

Whether `bytes` spell exactly one complete subterm, by replaying the parse from scratch.

⚠️ O(L), AND THAT IS WHY IT IS NOT THE HOT PATH. Upstream keeps this as the reference its
incremental cursor state is cross-checked against under `debug_assertions`, having measured that
replaying it per descent step made completing an L-byte subterm O(L^2) — which "dominated the join
on MORK's real (hundreds-of-bytes) symbolic terms". We keep it for the same two reasons: as the
oracle the incremental state is tested against, and for callers outside the cursor.
"""
function is_complete(bytes::AbstractVector{UInt8})::Bool
    (s, p) = PARSE_START
    for b in bytes
        (s, p) = subterm_parse_step(b, s, p)
    end
    s == 0 && p == 0
end

"""
    least_ge(mask, k) -> Union{UInt8, Nothing}

The least byte present in `mask` that is `>= k`, or `nothing` when every set bit is below `k`.
This is the per-byte leapfrog seek over a trie node's children.

⚠️ `k` NEEDS ITS OWN TEST. `next_bit` is STRICTLY above its argument (PathMap `Utils.jl:484`, and
upstream's `BitMask::next_bit` likewise), so seeking to a byte that is already present would
otherwise skip it and the join would silently drop every answer at that key. Upstream's comment
flags exactly this; the test below is not redundant.
"""
@inline least_ge(mask::ByteMask, k::UInt8)::Union{UInt8, Nothing} =
    test_bit(mask, k) ? k : next_bit(mask, k)

# ═════════════════════════════════════════════════════════════════════════════════════════════════
# LAYER 2 — the zipper subterm cursor.
#
# Ports upstream `SubtermCursor` (leapfrog.rs:87-521). Its own summary:
#
#     "A cursor over the complete variable-width subterms branching from a PathMap zipper's focus,
#      in ascending lexicographic order, with a leapfrog `seek`. This is the ZIPPER-NATIVE
#      REPLACEMENT FOR A MATERIALIZED PER-VARIABLE DOMAIN: it seeks on the live byte-trie instead
#      of scanning a `Vec`."
#
# 🔑 THE ZIPPER'S OWN PATH IS THE KEY. The cursor keeps no copy of the current subterm — it is
# `zipper_path(z)[floor+1:end]`, and `floor` is ONE INTEGER replacing what upstream previously
# maintained as a byte-for-byte mirror. That is the difference between this and our
# `_connected_join_emit!`, which copies a `Vector` and a `Dict` per intermediate tuple.
#
# ⚠️ EVERY PRIMITIVE THIS NEEDS WAS ALREADY IN OUR PathMap, under our own names. Checked
# 2026-08-20 by capability, after a name search said `descend_first_k_path` was ABSENT — it is
# `zipper_descend_first_k_path!` (Zipper.jl:1081, whose docstring literally says "Mirrors
# `descend_first_k_path`"). Third false absence from a name search that day.
# ═════════════════════════════════════════════════════════════════════════════════════════════════

"""
    BRANCH_CANDIDATE

Marks a parse record whose byte MAY have a sibling in the trie — a position no bulk move covered.

⚠️ IT LIVES IN THE PAYLOAD FIELD'S SPARE BIT, and that is sound only because a symbol payload is at
most 63 bytes (`ExprSymbol` size is 6 bits), so `0x80` can never collide with a real owed-payload
count. Upstream packs it the same way. The flag is what lets `backtrack_then_leftmost!` ascend
STRAIGHT to the deepest branching position instead of probing the zipper at every depth — below
such a position every node has a single child by construction, so a sibling probe there could only
fail.
"""
const BRANCH_CANDIDATE = 0x80

"""
    Column

One column of the enumeration: where its key starts, plus the incremental parse of that key.

`floor` is the absolute length of `zipper_path(z)` at this column's start; the subterm under
enumeration is the path beyond it. `owed_subterms`/`owed_payload` are the running fold of
[`subterm_parse_step`] over that key from [`PARSE_START`], so the boundary test is O(1) rather than
an O(len) replay per descent step — which upstream measured as making an L-byte subterm O(L^2) and
"dominated the join on MORK's real (hundreds-of-bytes) symbolic terms".

⚠️ `parse_stack` IS IRREDUCIBLE, and upstream spends a paragraph on why. Popping byte `b` with
payload `P` owed cannot distinguish "`b` is `SymbolSize(P)`" from "`b` is a payload byte and `P+1`
was owed" — both are legal for the same bytes — so the reverse parse is NOT derivable from content.
The record stores the state that stood BEFORE each byte.
"""
mutable struct Column
    floor::Int
    owed_subterms::UInt32
    owed_payload::UInt32
    parse_stack::Vector{Tuple{UInt32, UInt8}}   # isbits element ⇒ a dense flat buffer
    key_newvars::UInt8
    key_vars::UInt8
end

Column(floor::Int) = Column(floor, UInt32(1), UInt32(0), Tuple{UInt32, UInt8}[], 0x00, 0x00)

"Whether the key is empty — nothing parsed since the floor. The state a column is parked in."
@inline col_at_floor(c::Column) =
    isempty(c.parse_stack) && c.owed_subterms == 1 && c.owed_payload == 0

"Back to an empty key at `floor`, KEEPING the parse stack's allocation."
function col_reset!(c::Column, floor::Int)
    c.floor = floor
    c.owed_subterms = UInt32(1)
    c.owed_payload = UInt32(0)
    c.key_newvars = 0x00
    c.key_vars = 0x00
    empty!(c.parse_stack)                       # `empty!` retains capacity — upstream's `.clear()`
    nothing
end

"""
    SubtermCursor

A non-empty stack of [`Column`]s over ONE HELD zipper. `col` is the column being enumerated and
`floor_stack` those already consumed below it. The walk never ascends above the current floor, so
the zipper is left at the floor between re-seeks and at the subterm boundary while positioned.

⚠️ `at_end` IS A FIELD, NOT `key(...) === nothing`. Upstream's reason is Rust's borrow checker; ours
is simpler and still real — the join's candidate loop tests exhaustion while `seek!` mutates OTHER
cursors, and a predicate that had to build a key view to answer would allocate in the inner loop.
"""
mutable struct SubtermCursor{V, A}
    z::ReadZipperCore{V, A}
    col::Column
    at_end::Bool
    floor_stack::Vector{Column}
end

"Build a cursor at the zipper's current focus. NOT positioned until `cursor_first!`/`cursor_seek!`."
SubtermCursor(z::ReadZipperCore{V, A}) where {V, A} =
    SubtermCursor{V, A}(z, Column(length(zipper_path(z))), true, Column[])

@inline cursor_key_len(c::SubtermCursor) = length(zipper_path(c.z)) - c.col.floor

"`(NewVar count, total variable count)` of the current key — EXACT, and free."
@inline cursor_var_counts(c::SubtermCursor) = (c.col.key_newvars, c.col.key_vars)

"Whether the focus carries a stored value: the factor's fact is present at this full binding."
@inline cursor_has_value(c::SubtermCursor) = zipper_is_val(c.z)

"""
    cursor_key(c) -> Union{Nothing, SubArray{UInt8}}

The current subterm bytes, or `nothing` when exhausted. A VIEW of the zipper's own path — never a
copy, which is the entire point of the design.
"""
@inline cursor_key(c::SubtermCursor) =
    c.at_end ? nothing : view(zipper_path(c.z), (c.col.floor + 1):length(zipper_path(c.z)))

"Whether the key spells exactly one complete subterm, read off the incremental state — O(1)."
@inline cursor_key_complete(c::SubtermCursor) =
    c.col.owed_subterms == 0 && c.col.owed_payload == 0

"""
    cursor_check_invariants(c) -> Bool

The cross-check upstream runs under `debug_assertions`: the incremental parse state must equal the
from-scratch replay, and the record stack must stay in lockstep with the key.

⚠️ EXPOSED AS A FUNCTION RATHER THAN AN `@assert`. A `debug_assert!` compiles out; a test that calls
this cannot. The property tests drive it directly, so the invariant is checked by something that
runs in CI rather than by something that is disabled exactly when it would matter.
"""
function cursor_check_invariants(c::SubtermCursor)::Bool
    length(c.col.parse_stack) == cursor_key_len(c) || return false
    k = view(zipper_path(c.z), (c.col.floor + 1):length(zipper_path(c.z)))
    cursor_key_complete(c) == is_complete(k)
end

# ── the per-byte parse advance / retreat ─────────────────────────────────────────────────────────

"""
    advance_parse_at!(c, b, branch)

Account for one byte the zipper just descended. `branch` records whether a sibling MAY exist here;
a bulk move only crosses single-child positions, so its bytes are marked `false` and the ascending
backtrack skips them without asking the zipper.

🔑 THE VARIABLE COUNTS ARE EXACT BECAUSE THE PARSE ANSWERS "IS THIS A TAG?" BEFORE CONSUMING THE
BYTE. A byte is a tag exactly when no symbol payload is owed — so the test must come first, and a
symbol's payload can never be miscounted as a variable.
"""
@inline function advance_parse_at!(c::SubtermCursor, b::UInt8, branch::Bool)
    flag = branch ? BRANCH_CANDIDATE : 0x00
    push!(c.col.parse_stack, (c.col.owed_subterms, UInt8(c.col.owed_payload) | flag))
    if c.col.owed_payload == 0
        t = byte_item(b)
        if t isa ExprNewVar
            c.col.key_newvars += 0x01; c.col.key_vars += 0x01
        elseif t isa ExprVarRef
            c.col.key_vars += 0x01
        end
    end
    (c.col.owed_subterms, c.col.owed_payload) =
        subterm_parse_step(b, c.col.owed_subterms, c.col.owed_payload)
    nothing
end

@inline advance_parse!(c::SubtermCursor, b::UInt8) = advance_parse_at!(c, b, true)

"Account for the key's last byte `b` leaving, restoring the parse state that preceded it."
@inline function retreat_parse!(c::SubtermCursor, b::UInt8)
    (pre_subterms, pre_payload_flagged) = pop!(c.col.parse_stack)
    pre_payload = pre_payload_flagged & ~BRANCH_CANDIDATE
    c.col.owed_subterms = pre_subterms
    if pre_payload == 0                      # the RESTORED state classifies `b`
        t = byte_item(b)
        if t isa ExprNewVar
            c.col.key_newvars -= 0x01; c.col.key_vars -= 0x01
        elseif t isa ExprVarRef
            c.col.key_vars -= 0x01
        end
    end
    c.col.owed_payload = UInt32(pre_payload)
    nothing
end

# ── floor movement ───────────────────────────────────────────────────────────────────────────────

"Ascend back to the floor (column start), clearing the key."
function cursor_reset_to_floor!(c::SubtermCursor)
    n = cursor_key_len(c)
    n > 0 && zipper_ascend!(c.z, n)
    col_reset!(c.col, c.col.floor)
    c.at_end = false
    nothing
end

"""
    cursor_descend_floor!(c)

Lock the current complete subterm as a consumed column value: the floor descends INTO it so
subsequent enumeration is of the NEXT column. The zipper stays put — only the bookkeeping moves.

🔑 THIS IS WHY ONE CURSOR WALKS A FACTOR'S SUCCESSIVE COLUMNS WITH THE ZIPPER HELD, descended and
ascended in place, never re-opened from the trie root — which upstream names as "the join's
dominant cost". Pairs with [`cursor_ascend_floor!`].
"""
function cursor_descend_floor!(c::SubtermCursor)
    push!(c.floor_stack, c.col)
    c.col = Column(length(zipper_path(c.z)))
    c.at_end = false
    nothing
end

"""
    cursor_ascend_floor!(c)

Undo the most recent [`cursor_descend_floor!`]: the floor rises back to the enclosing column, which
is repositioned at the value it held (still on the zipper's path), ready to advance via
[`cursor_next!`].

🔴 IT RESETS THE CURRENT COLUMN TO ITS FLOOR FIRST, AND UPSTREAM DOES NOT. Upstream states this as a
CALLER PRECONDITION — "requires the zipper to be back at this column's floor plus that value, which
holds because a fully-exhausted deeper column leaves its cursor at its own floor" — and in its own
join that holds, because every exit path runs `reset_parts` before unwinding.

⚠️ MEASURED 2026-08-20: relying on the caller is how this broke. The ground join's CATCH-UP consumes
extra columns that are NOT part of the enumeration, and unwinding them popped a column while the
deeper bytes were still on the zipper's path. The enclosing column's key then read DOUBLE its length
(`|stack|=2` against `key_len=4`), and the next `cursor_next!` popped an empty parse stack —
surfacing as `ArgumentError: array must be non-empty` in `retreat_parse!`, THREE FRAMES from its
cause. Two speculative fixes failed before instrumenting the cursor state per step found it.

Enforcing it here rather than documenting it is the Julia-idiomatic choice and removes a precondition
that a correct-looking caller can silently violate. The reset is a no-op when the caller already
satisfied it, so nothing is paid on upstream's own path.
[[feedback_guarantee_not_convention]]
"""
function cursor_ascend_floor!(c::SubtermCursor)
    isempty(c.floor_stack) && error("cursor_ascend_floor! without a matching cursor_descend_floor!")
    cursor_reset_to_floor!(c)          # bring the zipper back to THIS column's floor
    c.col = pop!(c.floor_stack)
    c.at_end = false
    nothing
end

"Descend by raw `bytes` — NOT necessarily a complete subterm — lowering the floor past them."
function cursor_descend_raw!(c::SubtermCursor, bytes::AbstractVector{UInt8})
    # The raw fragment is NOT part of the key (the floor moves past it), so the parse state is
    # untouched: an empty key still owes exactly one subterm, now measured from the deeper floor.
    zipper_descend_to!(c.z, bytes)
    c.col.floor += length(bytes)
    c.at_end = false
    nothing
end

"Undo the most recent `cursor_descend_raw!` of `n` bytes."
function cursor_ascend_raw!(c::SubtermCursor, n::Int)
    zipper_ascend!(c.z, n)
    c.col.floor -= n
    c.at_end = false
    nothing
end

# ── the enumeration ──────────────────────────────────────────────────────────────────────────────

"""
    complete_leftmost!(c) -> Bool

Descend the least child at each step until the key forms a complete subterm. `false` when a node
runs out of children before completion.

⚠️ THREE MOVES, IN THIS ORDER, AND THE ORDER IS THE OPTIMIZATION:
 1. A symbol's PAYLOAD is a run whose length the parse already knows and inside which no decision is
    taken — take all of it in ONE `zipper_descend_first_k_path!`. Per-byte descent would pay a node
    lookup, a regularize and a key memcmp for every byte. The records the run owes are the
    arithmetic sequence the parse would have produced, and payload bytes are NOT tags, so no
    variable count moves.
 2. The trie is PATH-COMPRESSED, so a span with no branching IS one node key — take the whole span
    with `zipper_descend_until_max_bytes!` and run the allocation-free byte parse over what it
    produced, ascending back if it ran past the subterm boundary.
 3. Only then, the leftmost child one byte at a time.
"""
function complete_leftmost!(c::SubtermCursor)::Bool
    while !cursor_key_complete(c)
        owed = Int(c.col.owed_payload)
        if owed > 1
            if !zipper_descend_first_k_path!(c.z, owed)
                c.at_end = true
                return false
            end
            for i in 0:(owed - 1)
                push!(c.col.parse_stack, (c.col.owed_subterms, UInt8(owed - i) | BRANCH_CANDIDATE))
            end
            c.col.owed_payload = UInt32(0)
            continue
        end
        before = length(zipper_path(c.z))
        if zipper_descend_until_max_bytes!(c.z, 64)
            path = zipper_path(c.z)
            e = length(path)
            i = before
            while i < e
                advance_parse_at!(c, path[i + 1], false)
                i += 1
                (c.col.owed_subterms == 0 && c.col.owed_payload == 0) && break
            end
            i < e && zipper_ascend!(c.z, e - i)
            continue
        end
        if !zipper_descend_first_byte!(c.z)
            c.at_end = true
            return false
        end
        p = zipper_path(c.z)
        advance_parse!(c, p[end])
    end
    true
end

"""
    backtrack_then_leftmost!(c) -> Bool

From the current complete subterm, move to the least subterm STRICTLY greater: ascend until a level
offers a larger sibling, take the least such, then complete leftmost. `false` = exhausted.

🔑 THE BRANCH_CANDIDATE SCAN IS WHAT MAKES THIS CHEAP. Ascend straight to the deepest position a
bulk move did not cover; everything below it has a single child by construction, so the sibling
probe this would otherwise make at every depth could only fail. The scan walks records the retreat
has to walk anyway, so it costs no zipper call and no extra state.
"""
function backtrack_then_leftmost!(c::SubtermCursor)::Bool
    while true
        n = length(c.col.parse_stack)
        while n > 0 && (c.col.parse_stack[n][2] & BRANCH_CANDIDATE) == 0
            n -= 1
        end
        if n == 0
            c.at_end = true
            return false
        end
        cur = length(zipper_path(c.z))
        target = c.col.floor + n
        if cur > target
            path = zipper_path(c.z)
            for i in cur:-1:(target + 1)
                retreat_parse!(c, path[i])
            end
            zipper_ascend!(c.z, cur - target)
        end
        # ⚠️ READ THE DEPARTING BYTE BEFORE THE ZIPPER MOVES. With the path as the only
        # representation of the key, it lives nowhere else.
        old = zipper_path(c.z)[end]
        if zipper_to_next_sibling_byte!(c.z)
            b = zipper_path(c.z)[end]
            retreat_parse!(c, old)
            advance_parse!(c, b)
            return complete_leftmost!(c)
        end
        retreat_parse!(c, old)
        zipper_ascend_byte!(c.z)
    end
end

"Position at the least subterm."
function cursor_first!(c::SubtermCursor)
    cursor_reset_to_floor!(c)
    complete_leftmost!(c)
    nothing
end

"Advance to the next subterm."
function cursor_next!(c::SubtermCursor)
    c.at_end && return nothing
    backtrack_then_leftmost!(c)
    nothing
end

"""
    cursor_seek!(c, target)

Position at the least subterm `>= target`. `target` must itself be a complete subterm — the
leapfrog only ever seeks to another factor's bound subterm value.

🔑 WHY A COMPLETED DESCENT MATCHES EXACTLY: the encoding is PREFIX-FREE and `target` is complete, so
no complete subterm can be a proper prefix of another. Any divergence is handled by taking the least
larger child (then completing leftmost) or, when no larger child exists at that level, backtracking
to an ancestor that offers one.
"""
function cursor_seek!(c::SubtermCursor, target::AbstractVector{UInt8})
    cursor_reset_to_floor!(c)
    ti = 1
    while true
        if cursor_key_complete(c)
            c.at_end = false
            return nothing
        end
        mask = zipper_child_mask(c.z)
        if ti <= length(target)
            t = target[ti]
            if test_bit(mask, t)
                zipper_descend_to_byte!(c.z, t)
                advance_parse!(c, t)
                ti += 1
                continue
            end
            b = next_bit(mask, t)
            if b === nothing
                backtrack_then_leftmost!(c)
            else
                zipper_descend_to_byte!(c.z, b)
                advance_parse!(c, b)
                complete_leftmost!(c)
            end
            return nothing
        else
            complete_leftmost!(c)
            return nothing
        end
    end
end

# ═════════════════════════════════════════════════════════════════════════════════════════════════
# LAYER 3a — the GROUND leapfrog join.
#
# Ports upstream `GroundJoin::leapfrog` — which is UPSTREAM'S OWN SCAFFOLDING STEP, not something we
# invented to make the port easier. It was added in `03dcdad` ("Add a worst-case-optimal
# leapfrog-unification join") as `kernel/src/zipper_join.rs` and deleted in `69393c7` ("Reduce the
# join to a compile-time feature and delete what it doesn't need") once the general unification join
# subsumed it. The general version's own docstring still points at it: "This is the true leapfrog
# intersection, modelled on [`GroundJoin::leapfrog`]". Recovered from `69393c7^`.
#
# 🔑 WHY THIS IS THE RIGHT SLICE TO DO FIRST. It is GROUND: every factor column is a plain variable
# and the data holds no stored variables, so INTERSECTION IS EQUALITY and the wildcard soundness
# constraint recorded in this file's header DOES NOT YET APPLY. That constraint is the one thing a
# plausible WCO implementation gets wrong silently; separating it from the seek machinery means the
# seek can be validated on its own, against an oracle, before anything subtle rests on it.
#
# THE ALGORITHM, in upstream's words: "seek each cursor to the running maximum subterm; when they
# all agree, that value is in the intersection, so descend every cursor into it, recurse, ascend
# back, and step the first cursor forward. Every exit resets the participating cursors to their
# column floors so the parent can ascend past its own column cleanly."
#
# ⚠️ NO INTERMEDIATE IS MATERIALIZED — that is the entire difference from `_connected_join_emit!`.
# There is no `nxt` array, no per-tuple `copy(Dict)`, no per-tuple `copy(Vector)`. The only
# allocation in the loop is `max_buf`, reused, because `cursor_seek!` needs the target to outlive
# the borrow of the cursor it was read from.
# ═════════════════════════════════════════════════════════════════════════════════════════════════

"""
    GroundFactor

One relation participating in a ground join: the byte prefix its facts live under, and which query
variable occupies each successive column.

`cols[j] == v` means column `j` of this factor is query variable `v`. A variable may occur in
several factors and several times within one — that repetition IS the join.
"""
struct GroundFactor
    prefix::Vector{UInt8}
    cols::Vector{Int}
end

"""
    ground_leapfrog(btm, factors, nvars, emit) -> Int

Worst-case-optimal ground conjunctive join. Calls `emit(binding)` once per satisfying assignment,
where `binding[v]` is the bytes bound to variable `v`. Returns the number of assignments emitted.

Variables are scheduled `1:nvars` in order. At each level the participating factors are those whose
CURRENT column is that variable, and their cursors leapfrog to a common value.

⚠️ `emit` MUST NOT RETAIN `binding` — it is the join's live scratch and is mutated on return. Copy
what you need. This mirrors upstream's contract, where the callback takes a borrow.
"""
function ground_leapfrog(btm::PathMap{UnitVal}, factors::Vector{GroundFactor},
                         nvars::Int, emit::Function)::Int
    nf = length(factors)
    nf == 0 && return 0

    # One HELD cursor per factor, opened once at its relation prefix. Upstream: "Every consumed
    # column value is descended in place and ascended on unwind, so no probe pays an O(path)
    # re-descent from the trie root." Re-opening per probe is the cost this design exists to avoid.
    cursors = SubtermCursor{UnitVal, GlobalAlloc}[]
    for f in factors
        z = read_zipper_at_path(btm, f.prefix)
        push!(cursors, SubtermCursor(z))
    end

    next_col = ones(Int, nf)                     # 1-based: which column each factor is at
    binding  = [UInt8[] for _ in 1:nvars]
    max_buf  = UInt8[]
    parts    = Int[]
    emitted  = Ref(0)

    reset_parts!(ps) = (for f in ps; cursor_reset_to_floor!(cursors[f]); end)

    function recurse(i::Int)
        if i > nvars
            # Every column consumed and every cursor sits on a stored fact ⇒ an answer.
            for f in 1:nf
                cursor_has_value(cursors[f]) || return
            end
            emitted[] += 1
            emit(binding)
            return
        end

        # The factors whose CURRENT column is variable i. Rebuilt per level rather than cached:
        # cheap, and a cache here would have to be unwound on every backtrack.
        empty!(parts)
        for f in 1:nf
            c = next_col[f]
            c <= length(factors[f].cols) && factors[f].cols[c] == i && push!(parts, f)
        end
        isempty(parts) && return

        for f in parts
            cursor_first!(cursors[f])
            if cursors[f].at_end
                reset_parts!(parts)
                return
            end
        end

        myparts = copy(parts)                    # `parts` is reused by deeper levels
        while true
            # Running maximum by VIEW comparison — no key is copied to find it.
            max_f = myparts[1]
            for f in myparts
                if cursor_key(cursors[f]) > cursor_key(cursors[max_f])
                    max_f = f
                end
            end
            # Copied ONCE, because `cursor_seek!` mutates the cursor the view reads from.
            empty!(max_buf); append!(max_buf, cursor_key(cursors[max_f]))

            all_match = true
            for f in myparts
                if cursor_key(cursors[f]) != max_buf
                    cursor_seek!(cursors[f], max_buf)
                    if cursors[f].at_end
                        reset_parts!(myparts)
                        return
                    end
                    cursor_key(cursors[f]) != max_buf && (all_match = false)
                end
            end

            if all_match
                val = copy(max_buf)              # the recursion re-uses max_buf below this frame
                for f in myparts
                    cursor_descend_floor!(cursors[f])
                    next_col[f] += 1
                end
                binding[i] = val

                # ── CATCH-UP (upstream `UnifyJoin::catch_up`) ────────────────────────────────────
                # 🔴 WITHOUT THIS, A REPEATED VARIABLE SILENTLY RETURNS NOTHING. The level loop
                # schedules each variable ONCE, so a factor whose NEXT column is a variable that is
                # already bound would never be advanced past it — it would sit mid-fact forever and
                # `cursor_has_value` at the leaf would be false for every assignment.
                # `(edge $x $x)` returned 0 where the diagonal has 2, and the ORACLE FOUND IT: the
                # chain join, the clique4 shape, the empty case and the single-factor case all
                # passed without it. A repeated variable is the cheapest possible join and it was
                # the one shape the happy paths could not see.
                # Seeking to the binding is exactly right here: the column must EQUAL the bound
                # value, and in the ground case unifiability IS equality.
                caught = Int[]                   # (factor, columns advanced) — for the unwind
                ok = true
                for f in 1:nf
                    adv = 0
                    while next_col[f] <= length(factors[f].cols)
                        v = factors[f].cols[next_col[f]]
                        isempty(binding[v]) && break        # still free ⇒ it gets scheduled later
                        cursor_seek!(cursors[f], binding[v])
                        if cursors[f].at_end || cursor_key(cursors[f]) != binding[v]
                            # ⚠️ RESET BEFORE BAILING. `cursor_ascend_floor!` REQUIRES the zipper to
                            # be back at the column's floor — upstream states it as a precondition
                            # ("a fully-exhausted deeper column leaves its cursor at its own
                            # floor"). A failed seek leaves the cursor positioned mid-key or
                            # at_end, so the unwind below would pop a column whose parse stack no
                            # longer matches the zipper's path, and the NEXT `cursor_next!` pops an
                            # empty stack. That surfaced as `ArgumentError: array must be
                            # non-empty` in `retreat_parse!` — a desync reported three frames away
                            # from its cause.
                            cursor_reset_to_floor!(cursors[f])
                            ok = false; break
                        end
                        cursor_descend_floor!(cursors[f])
                        next_col[f] += 1
                        adv += 1
                    end
                    push!(caught, adv)
                    ok || break
                end

                ok && recurse(i + 1)

                # Unwind the catch-up in reverse, so each cursor's floor stack pops in order.
                for f in length(caught):-1:1
                    for _ in 1:caught[f]
                        next_col[f] -= 1
                        cursor_ascend_floor!(cursors[f])
                    end
                end

                binding[i] = UInt8[]
                for f in myparts
                    next_col[f] -= 1
                    cursor_ascend_floor!(cursors[f])
                end
            end

            # Step the FIRST participant forward. Upstream steps `parts[0]`; any single participant
            # works because the next round re-seeks the others to the new running maximum.
            cursor_next!(cursors[myparts[1]])
            if cursors[myparts[1]].at_end
                reset_parts!(myparts)
                return
            end
        end
    end

    recurse(1)
    emitted[]
end

# ═════════════════════════════════════════════════════════════════════════════════════════════════
# LAYER 3b — the UNIFICATION predicates: schematic data, where stored variables act as wildcards.
#
# Ports upstream's "unification layer" (`69393c7^:kernel/src/zipper_join.rs:973-1006`). These three
# predicates are what separate a RELATIONAL worst-case-optimal join from one that is sound over
# MORK's encoding, and the file header's soundness constraint is stated in their terms.
#
# 🔴 THE ORDERING FACT THE WHOLE PRUNING RESTS ON, verified in OUR `byte_item` (Expr.jl:103) and
# pinned by `leapfrog_layer3b.jl` so a re-encoding cannot silently make the join unsound:
#
#       Arity(a)       0b00aaaaaa   0x00..0x3F
#       (reserved)                  0x40..0x7F   ⚠️ OUR byte_item THROWS here; upstream returns a
#                                                non-match. Only reachable from a malformed trie.
#       VarRef(i)      0b10iiiiii   0x80..0xBF
#       NewVar         0b11000000   0xC0
#       SymbolSize(s)  0b11ssssss   0xC1..0xFF   (s > 0)
#
# ⇒ EVERY SYMBOL BYTE SORTS ABOVE EVERY COMPOUND AND VARIABLE BYTE, so a cursor's ascending
# enumeration of a column ends in a CONTIGUOUS RUN of ground symbols. That run is the only part an
# exact-match intersection may prune, because over ground terms unifiability IS byte equality.
# Everything before it — stored wildcards, and compounds that a schematic `(f $x)` unifies with
# without equalling — must be pushed UNFILTERED.
# ═════════════════════════════════════════════════════════════════════════════════════════════════

"""
    is_wildcard_term(k) -> Bool

Whether a stored complete subterm is a bare variable — a one-byte `NewVar` or `VarRef`. Such a fact
column unifies with ANY value, which is why it can never restrict an intersection.
"""
@inline function is_wildcard_term(k::AbstractVector{UInt8})::Bool
    length(k) == 1 || return false
    t = byte_item(k[1])
    t isa ExprNewVar || t isa ExprVarRef
end

"""
    is_symbol_head(k) -> Bool

Whether a stored complete subterm is symbol-headed, hence GROUND and a leaf of the encoding.

🔑 THIS IS THE PRUNABILITY TEST. Symbol-headed candidates are ground, and where the restrictor's
column holds no stored variable only the same symbol unifies with them — a stored compound cannot
unify with a symbol at all. Combined with the ordering above, the symbol-headed candidates form a
SUFFIX of the enumeration, so pruning inside it skips nothing outside it.
"""
@inline is_symbol_head(k::AbstractVector{UInt8})::Bool = byte_item(k[1]) isa ExprSymbol

"""
    column_matches_by_equality(mask) -> Bool

Whether a column whose trie children are `mask` can match a value ONLY by equality — i.e. it holds
no stored variable at this position.

A stored variable is a complete SINGLE-BYTE subterm, so its presence is exactly a variable tag among
the column's children: any set bit in `[VarRef(0), NewVar]` = `[0x80, 0xC0]`. A column that offers
one unifies with anything and must never restrict an intersection.

⚠️ PURE BYTE ARITHMETIC, NO `byte_item` CALL — deliberately. Our `byte_item` THROWS on a reserved
byte (0x40..0x7F) where upstream's returns a non-match; testing the mask numerically keeps this
total, and a reserved byte answers "not equality-only", which is the conservative side either way.
"""
@inline function column_matches_by_equality(mask::ByteMask)::Bool
    b = least_ge(mask, 0x80)              # item_byte(VarRef(0))
    b === nothing && return true
    b > 0xC0                              # item_byte(NewVar); anything above is a symbol
end

end # module Leapfrog
