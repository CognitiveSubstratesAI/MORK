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
# ═════════════════════════════════════════════════════════════════════════════════════════════════
# THE ALGORITHM, END TO END — read 2026-08-20 from `kernel/src/leapfrog.rs` (the CURRENT version,
# not the `zipper_join.rs` ancestor layers 3a/3d follow). This is the assembly plan.
#
#   recurse(i)                     = catch_up(i, 0)
#
#   catch_up(i, f)                 advance every factor past steps ALREADY DETERMINED
#     f == nfactors             -> recurse_after_catch_up(i)
#     step is Var(vp), pos >= i -> catch_up(i, f+1)      # scheduled now or later: leave it
#     otherwise                 -> consume_step(f) then catch_up(i, f)   # same factor again
#
#   recurse_after_catch_up(i)
#     i == nvars                -> every factor must sit on a stored value -> EMIT
#     v = var_order[i]
#     parts = factors whose CURRENT step is Var(v)       # dynamic, recomputed per level
#     parts empty               -> recurse(i+1)
#     v already bound           -> consume_var_parts(parts, v, i)        # seek all to it
#     else                      -> rank_parts · partition_restrictors · consume_lead
#
# 🔑 WHY IT AVOIDS THE 1 182x BLOWUP `_JOIN_TRACE` MEASURED. There is no tuple set. The entire
# state is the CURSORS' POSITIONS plus the bindings, and a candidate value for `v` is explored only
# if EVERY participating factor offers it — so a value that would die three factors later is never
# bound at all. Our `_connected_join_emit!` builds 2 555 436 partial tuples for 2 161 answers
# because factors 4-6's constraints have not been consulted when factors 1-3 are combined.
#
# 🔴 TWO PIECES I HAD NOT UNDERSTOOD BEFORE READING IT PROPERLY, both in the level's work:
#
#  1. `rank_parts` — THE LEAD IS CHOSEN PER LEVEL, BY SMALLEST DOMAIN, VIA ROUND ROBIN. Every
#     participating cursor is stepped ONE value per round; counting stops at the end of the round in
#     which some cursor runs out, and that cursor is the EXACT argmin. Upstream says why a per-factor
#     count-to-N cannot do this: "it scored every domain over the cap equal and left the choice to
#     syntactic factor order, so a 100k-value factor beat a 100-value one and the join enumerated
#     100k candidates to keep 100."
#     ⇒ AND THE COST IS SELF-FINANCING, which is the elegant part: the scan costs
#     `parts.len() * (min_domain + 1)` steps, while the node then enumerates `min_domain` candidates
#     against `parts.len()-1` factors — at least `min_domain * (parts.len()-1)` steps. So ranking is
#     never more than a constant factor of the enumeration it is choosing, and it NEVER scales with
#     the space size: nothing reads more than the SMALLEST participating domain.
#
#  2. `partition_restrictors` — WHICH FACTORS MAY PRUNE. A column holding a stored wildcard matches
#     ANYTHING and must never restrict an intersection; only equality-only columns can. That is
#     `mask_has_wildcard`, which is our `column_matches_by_equality` (layer 3b) NEGATED — upstream
#     flipped the name between versions, same expression. It also short-circuits: if the LEAD's
#     column offers no symbol-headed value at all, nothing is prunable, so answer 0 off ONE mask read
#     rather than scanning every other factor's.
#
# ⇒ WHAT LAYERS 1-3d ALREADY SUPPLY: the cursor (domains without materialising), `ground_probe!` +
# `stored_wildcard_bytes` (3c), `column_matches_by_equality` (3b), `match_candidate!` +
# `with_bound_bytes!` (3d), and the mutual seek (3a's `ground_leapfrog`).
# ⇒ WHAT ASSEMBLY STILL NEEDS: the `Step` flattening (a variable at ANY depth becomes its own
# schedulable position), `catch_up`, `rank_parts`, `partition_restrictors`, and the per-level
# dispatch above.
# ═════════════════════════════════════════════════════════════════════════════════════════════════
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

using ..MORK: byte_item, ExprArity, ExprSymbol, ExprVarRef, ExprNewVar,
    ExprEnv, Bindings, expr_unify, UnificationFailure, _expr_newvars,
    item_byte, ee_args!, ee_var_opt, ExprVar, maybe_byte_item, UNIT_VAL,
    expr_unify_into!, expr_unify_unwind!
using ..MORK: Expr as MORKExpr
# ⚠️ `PathMap` NAMES BOTH A MODULE AND A TYPE. Importing the bare name binds the TYPE, so
# `PathMaps.PathMap{…}` then resolves a field on a UnionAll and fails to load. Import the type
# plainly and take everything else by name.
using PathMaps: ByteMask, test_bit, next_bit, PathMap, UnitVal, ReadZipperCore, GlobalAlloc,
    read_zipper_at_path, set_val_at!, zipper_to_next_val!,
    zipper_path, zipper_child_mask, zipper_ascend!, zipper_ascend_byte!,
    zipper_descend_to_byte!, zipper_descend_first_byte!, zipper_descend_to!,
    zipper_descend_first_k_path!, zipper_descend_until_max_bytes!,
    zipper_to_next_sibling_byte!, zipper_is_val,
    iter        # ⇐ ByteMask's set-bit iterator; `import PathMaps` collides with the TYPE

export subterm_parse_step, least_ge, is_complete, PARSE_START,
    SubtermCursor, cursor_first!, cursor_next!, cursor_key, cursor_seek!,
    cursor_descend_floor!, cursor_ascend_floor!, cursor_has_value, cursor_var_counts,
    GroundFactor, ground_leapfrog,
    is_wildcard_term, is_symbol_head, column_matches_by_equality,
    cursor_floor_child_mask, ground_probe!, stored_wildcard_bytes,
    factor_namespace, var_env, query_var_env, data_env_for, unified_bindings,
    with_bound_bytes!, match_candidate!, candidate_intro_delta, QUERY_NS,
    Step, STEP_VAR, STEP_SYM, STEP_COMPOUND, push_steps!, factor_steps,
    UnifyColumn, unify_var_col, unify_term_col, UnifyFactor, unify_leapfrog,
    scan_subterm, parse_body_factors, fact_bytes, _LF_TRACE, _LF_CANDIDATES,
    rank_parts!, partition_restrictors!, fill_lead_candidates!,
    descend_restrictors!,
    RIItem, ri_span_len, ri_split_columns, ri_columns_to_items, ri_emit_reordered,
    is_inverted, ri_col_min_var_pos,
    reindex_regions, fold_region_into_reindex!, build_reindex, ri_invert_order

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

"Query variables live in namespace 0; factor `f`'s data lives in `1 + f`. Upstream `QUERY_NS`."
const QUERY_NS = UInt8(0)

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
            c.col.key_newvars += 0x01
            c.col.key_vars += 0x01
        elseif t isa ExprVarRef
            c.col.key_vars += 0x01
        end
    end
    (c.col.owed_subterms, c.col.owed_payload) = subterm_parse_step(
        b, c.col.owed_subterms, c.col.owed_payload
    )
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
            c.col.key_newvars -= 0x01
            c.col.key_vars -= 0x01
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
    isempty(c.floor_stack) &&
        error("cursor_ascend_floor! without a matching cursor_descend_floor!")
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
                push!(
                    c.col.parse_stack,
                    (c.col.owed_subterms, UInt8(owed - i) | BRANCH_CANDIDATE)
                )
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
    binding = [UInt8[] for _ in 1:nvars]
    max_buf = UInt8[]
    parts = Int[]
    emitted = Ref(0)

    reset_parts!(ps) = (
        for f in ps
            cursor_reset_to_floor!(cursors[f])
        end
    )

    function recurse(i::Int)
        if i > nvars
            # Every column consumed and every cursor sits on a stored fact ⇒ an answer.
            for f in 1:nf
                cursor_has_value(cursors[f]) || return nothing
            end
            emitted[] += 1
            emit(binding)
            return nothing
        end

        # The factors whose CURRENT column is variable i. Rebuilt per level rather than cached:
        # cheap, and a cache here would have to be unwound on every backtrack.
        empty!(parts)
        for f in 1:nf
            c = next_col[f]
            c <= length(factors[f].cols) && factors[f].cols[c] == i && push!(parts, f)
        end
        isempty(parts) && return nothing

        for f in parts
            cursor_first!(cursors[f])
            if cursors[f].at_end
                reset_parts!(parts)
                return nothing
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
            empty!(max_buf)
            append!(max_buf, cursor_key(cursors[max_f]))

            all_match = true
            for f in myparts
                if cursor_key(cursors[f]) != max_buf
                    cursor_seek!(cursors[f], max_buf)
                    if cursors[f].at_end
                        reset_parts!(myparts)
                        return nothing
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
                            ok = false
                            break
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

            # Step the FIRST participant forward. `GroundJoin::leapfrog` steps `parts[0]`, and any
            # single participant is CORRECT because the next round re-seeks the others to the new
            # running maximum.
            #
            # 🔴 BUT WHICH ONE LEADS IS NOT ARBITRARY IN THE REAL JOIN, and I did not know that when
            # I wrote this. `UnifyJoin` calls `rank_parts` FIRST, so `parts[0]` is the SMALLEST
            # DOMAIN — and upstream reserves the name for exactly that
            # (`zipper_join.rs:2414`): "The leapfrog principle: lead with the smallest domain so the
            # leading factor enumerates few candidates and the rest seek. This is what makes a
            # selective factor, say `(e a $y)` with a few edges, drive the join instead of the whole
            # relation."
            # `GroundJoin` is upstream's SCAFFOLDING and skips ranking; this port is faithful to it,
            # so nothing here is wrong — but assembling the full join from THIS shape would ship a
            # leapfrog without the principle it is named after. `rank_parts` (round-robin argmin, see
            # the assembly plan in the header) is required, not an optimisation.
            # ⚠️ Found only because the user asked for a deep dive of the whole algorithm. I had
            # applied "read upstream first" PER PIECE and not to the orchestration, which is how a
            # faithful port of the wrong layer looks correct all the way down.
            # [[feedback_always_read_upstream_source_first]]
            cursor_next!(cursors[myparts[1]])
            if cursors[myparts[1]].at_end
                reset_parts!(myparts)
                return nothing
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

# ═════════════════════════════════════════════════════════════════════════════════════════════════
# LAYER 3c — the WILDCARD-AWARE ground probe.
#
# Ports upstream `ground_probe` (`69393c7^:kernel/src/zipper_join.rs:2667`). Small, and the insight
# is the whole layer, in upstream's words:
#
#     "The stored wildcards at this position are exactly the WILDCARD TAG BYTES set in that mask: a
#      wildcard is a COMPLETE SINGLE-BYTE SUBTERM, so its presence as a child byte at the column
#      start IS its presence as a stored subterm."
#
# 🔑 WHY THAT MATTERS: a ground query column matches either the IDENTICAL bytes or ANY stored
# wildcard — a fact `(rel $w)` unifies with `(rel anything)`. Finding those wildcards would
# otherwise need a scan; instead one child-mask read at the floor yields all of them, because a
# stored variable occupies exactly one byte and therefore appears as a child byte.
#
# ⚠️ THIS IS THE HALF THAT MAKES THE JOIN A UNIFICATION JOIN RATHER THAN A RELATIONAL ONE, and it is
# where the file header's soundness constraint becomes operative: the leapfrog may prune only in the
# symbol-headed suffix, because everywhere else a stored value can MATCH a candidate without
# EQUALLING it. `column_matches_by_equality` (layer 3b) is the guard; this is what it guards.
# ═════════════════════════════════════════════════════════════════════════════════════════════════

"""
    cursor_floor_child_mask(c) -> ByteMask

The trie children at the column start. Requires the cursor to be AT its floor — the caller's
obligation, and `ground_probe` satisfies it by reading the mask before it seeks.
"""
@inline cursor_floor_child_mask(c::SubtermCursor)::ByteMask = zipper_child_mask(c.z)

"""
    ground_probe!(c, ground) -> (exact::Bool, mask::ByteMask)

Probe a factor's current GROUND column: does the trie hold this exact subterm, and what are the
column's children?

Ports upstream verbatim in shape — mask read at the floor, ONE exact seek, restore:

    let mask = cur.floor_child_mask();   cur.seek(ground);
    let exact = cur.key() == Some(ground);   cur.reset_to_floor();

⚠️ THE ORDER IS LOAD-BEARING. The mask must be read BEFORE the seek, because seeking moves the
zipper off the floor and `cursor_floor_child_mask` would then report the children of wherever it
landed. Reading it after would be a silently different question with a plausible-looking answer.

⚠️ AND IT RESTORES THE CURSOR. A probe that left the cursor positioned would corrupt the enclosing
enumeration — the same class of defect as `cursor_ascend_floor!`'s precondition, which cost two
speculative fixes before instrumentation found it.
"""
function ground_probe!(c::SubtermCursor, ground::AbstractVector{UInt8})
    mask = cursor_floor_child_mask(c)          # BEFORE the seek — see above
    cursor_seek!(c, ground)
    k = cursor_key(c)
    exact =
        k !== nothing && length(k) == length(ground) &&
        all(k[i] == ground[i] for i in eachindex(ground))
    cursor_reset_to_floor!(c)
    (exact, mask)
end

"""
    stored_wildcard_bytes(mask) -> Vector{UInt8}

The stored wildcards present at a column, read off its child mask: every variable tag byte set in
it. `VarRef(0..63)` is `0x80..0xBF` and `NewVar` is `0xC0`, so the wildcard range is exactly
`0x80..0xC0` — the same range `column_matches_by_equality` tests, which is why the two cannot
disagree about what counts as a wildcard.

Ascending byte order, which is the order upstream's former seek-and-scan produced; the join's visit
order depends on it.
"""
function stored_wildcard_bytes(mask::ByteMask)::Vector{UInt8}
    # ⚠️ ITERATE THE SET BITS AND FILTER WITH THE PREDICATE, exactly as upstream does:
    #     for w in mask.iter() { if is_wildcard_term(&[w]) { … } }
    # 🔴 A FIRST VERSION SCANNED THE HARDCODED RANGE 0x80..0xC0 with `least_ge`. Same answer TODAY —
    # layer 3b pins that range exhaustively — but it encodes the tag layout in a SECOND place.
    # Upstream asks the PREDICATE, so a re-encoding moves one definition and every caller follows;
    # the range form would keep returning confident wrong answers. Cross-checking against upstream
    # on 2026-08-20 is what caught it, and it is the same "assert the contract, not the
    # representation" error in a new costume. [[feedback_assert_the_contract_not_the_representation]]
    # Not slower either: `ByteMaskIter` visits only bits that are SET, where the range scan probed
    # 65 positions whether or not anything was there.
    out = UInt8[]
    for w in iter(mask)
        is_wildcard_term(UInt8[w]) && push!(out, w)
    end
    out
end

# ═════════════════════════════════════════════════════════════════════════════════════════════════
# LAYER 3d — the DESCENT: bind a candidate, unify, recurse, restore.
#
# Ports upstream `match_candidate` / `with_bound_term` / `with_bound_path_bytes` /
# `unified_bindings` / `data_env_for` (`69393c7^:kernel/src/zipper_join.rs:2709-3044`).
#
# 🔑 `unified_bindings` DOES NOT EXTEND INCREMENTALLY — it rebuilds the WHOLE equation set (every
# existing binding re-stated as an equation, plus the new pair) and re-runs `unify` from scratch:
#
#     for (&var, &env) in &self.bindings { pairs.push((self.var_env(var), env)); }
#     pairs.push((lhs, rhs));
#     unify(&mut pairs).ok()
#
# That is O(|bindings|) work and one full unification PER CANDIDATE, and it is exactly why upstream
# later replaced it with an undo trail (`cfa8abf` "Bind candidates incrementally with an undo
# trail"). We followed THIS version first, deliberately: it is upstream's own sequence, it is simple
# enough to validate, and the trail is a separate optimization with its own correctness argument.
#
# 🔑 THE TRAIL IS NOW LIVE (2026-08-21). `match_candidate!` solves the ONE new equation against a
# LIVE `Bindings` and unwinds by removal; `unified_bindings` IS NO LONGER CALLED BY THE JOIN. It is
# retained as the port record of `69393c7^` AND as the trail's differential ORACLE — the two must
# agree on every deref, and `leapfrog_layer3d.jl` asserts exactly that. Do not delete it without
# replacing the oracle: it is the only from-scratch MGU the incremental path can be checked against.
#
# ⚠️ WE NEED NO `bound[f]` MIRROR. This older upstream keeps `bound[f]` as a byte-for-byte copy of
# the cursor's path and `debug_assert`s they agree ("held cursor drifted from prefix+bound"). The
# LATER design dropped it — "the zipper's own path IS the key" — and our layer 2 already follows
# that, so the invariant is structural here rather than asserted. One less thing to drift.
# ═════════════════════════════════════════════════════════════════════════════════════════════════

"A factor's variable namespace. Upstream: `1 + f as u8` — namespace 0 is reserved for query vars."
@inline factor_namespace(f::Int)::UInt8 = UInt8(1 + f)

"The one-byte NewVar term, as upstream's `NEW_VAR_EXPR_BYTES`."
const NEWVAR_BYTES = UInt8[0xC0]

"""
    var_env(key) -> ExprEnv

An `ExprEnv` standing for the variable `key = (n, v)` — a NewVar term carrying that namespace and
index. Used to re-state an existing binding as a unification equation.
"""
@inline var_env(key::Tuple{UInt8, UInt8})::ExprEnv =
    ExprEnv(key[1], key[2], UInt32(0), MORKExpr(NEWVAR_BYTES))

"The query-variable env for global variable `v` — namespace `QUERY_NS` (0)."
@inline query_var_env(v::Int)::ExprEnv =
    ExprEnv(QUERY_NS, UInt8(v), UInt32(0), MORKExpr(NEWVAR_BYTES))

"""
    data_env_for(f, intro, bytes) -> ExprEnv

An `ExprEnv` over a factor's STORED bytes, in that factor's namespace, offset by the NewVars already
introduced for it. Upstream threads this through an arena; in Julia the bytes are owned by the
`Expr`, so the arena is the GC.
"""
@inline data_env_for(f::Int, intro::UInt8, bytes::AbstractVector{UInt8})::ExprEnv =
    ExprEnv(factor_namespace(f), intro, UInt32(0), MORKExpr(Vector{UInt8}(bytes)))

"""
    unified_bindings(bindings, lhs, rhs) -> Union{Bindings, Nothing}

Unify `lhs` against `rhs` UNDER the existing bindings, returning the new binding set or `nothing`
when they do not unify.

⚠️ EVERY EXISTING BINDING IS RE-STATED AS AN EQUATION, not carried. That is upstream's shape and it
is what makes the result a genuine MGU over the whole system rather than a local extension — a new
pair can force an existing binding to refine, and an incremental `setindex!` would miss that.

🔑 NOT ON THE LIVE PATH SINCE 2026-08-21 — the join uses the undo trail (`match_candidate!`). This
is kept for two reasons, and the second is the load-bearing one:
  1. the port record of `69393c7^`, upstream's own earlier sequence;
  2. THE TRAIL'S DIFFERENTIAL ORACLE. The incremental path is only correct if it agrees with a
     from-scratch MGU on every dereference, and this is the from-scratch MGU. `leapfrog_layer3d.jl`
     asserts that agreement directly. Deleting this as dead code would delete the oracle — the
     failure mode being that an incremental binder can look right on answers while diverging on
     bindings that no test observes. [[feedback_green_suite_hides_unwired_correct_code]]
"""
function unified_bindings(
    bindings::Bindings, lhs::ExprEnv, rhs::ExprEnv
)::Union{Bindings, Nothing}
    pairs = Vector{Tuple{ExprEnv, ExprEnv}}()
    sizehint!(pairs, length(bindings) + 1)
    for (var, env) in bindings
        push!(pairs, (var_env(var), env))
    end
    push!(pairs, (lhs, rhs))
    r = expr_unify(pairs)
    r isa UnificationFailure ? nothing : r
end

"""
    with_bound_bytes!(c, bytes, cont)

Descend the cursor past `bytes`, run `cont()`, ascend back. The held cursor's floor moves with the
binding, so no probe below re-opens from the trie root — which upstream names as the join's dominant
cost.

⚠️ RESTORE IS UNCONDITIONAL. `cont` may throw or stop the search; the ascend must still happen or
every enclosing column is left descended. Upstream relies on straight-line control flow; Julia has
exceptions, so this is a `try/finally`.
"""
# \U0001f534 `cont::F where {F}`, NOT `cont::Function`. Annotating a parameter `::Function` is one of the
# documented cases where Julia DELIBERATELY DOES NOT SPECIALIZE — it compiles ONE method for all
# callers, so every call through `cont` is a dynamic dispatch and the closure can neither be inlined
# nor elided. A bare or type-parameterised argument specializes per call site.
#
# THIS IS NOT A PORT INFIDELITY — upstream `leapfrog.rs` uses the same continuation-passing shape.
# Rust monomorphises each closure at its call site with zero indirection, and a non-escaping closure
# is stack data. Julia will do the equivalent, but only if asked; `::Function` is where we did not ask.
#
# \U0001f534 BUT THIS CHANGE DID NOT REDUCE THE COST, AND THAT IS THE POINT OF THIS PARAGRAPH.
# MEASURED by differential profile against the stock lane on the same query (so the shared
# answer-construction cost cancels and only the per-unit difference survives):
#
#     cont::Function   stock 160,075  leapfrog 1,345,670   ratio 8.4x
#     cont::F          stock 207,597  leapfrog 1,907,224   ratio 9.19x
#
# Absolute counts are not comparable across runs (sampling duration differs); the RATIO is, and it
# did not collapse. ⇒ THE PER-UNIT COST IS NOT DISPATCH. Specialization makes the CALL direct; it
# does not stop the closure being CONSTRUCTED. `uj_consume_sym` still yields THREE profile entries at
# one line (`uj_consume_sym` + `##0` + `##2`, ~109k samples each) because
#     with_bound_bytes!(c, bytes, () -> uj_at_step(st, f, s+1, () -> cont(bindings)))
# builds TWO NESTED CLOSURES PER STEP, each capturing five variables. That allocation is the cost.
#
# The annotation is kept because `::F where {F}` is the correct Julia idiom and costs nothing — NOT
# because it was measured to help. It was measured NOT to.
# ⇒ The real fix is structural: turn this CPS into an explicit state machine so no closure is built
#   per step. That is a large change and is NOT attempted here.
#
# ⚠️ Upstream pays none of this: `leapfrog.rs` uses the same CPS shape, but Rust monomorphises each
# closure at its call site and a non-escaping closure is STACK data. Same algorithm, and the
# abstraction is free there and is not here. This is a LANGUAGE-COST divergence, not a port defect —
# which is why matching upstream's structure line for line reproduces its answers and not its speed.
function with_bound_bytes!(c::SubtermCursor, bytes::AbstractVector{UInt8}, cont::F) where {F}
    cursor_descend_raw!(c, bytes)
    try
        cont()
    finally
        cursor_ascend_raw!(c, length(bytes))
    end
    nothing
end

"""
    match_candidate!(c, bindings, f, pattern, bytes, cont) -> Union{Bindings, Nothing}

Try one stored candidate: unify `pattern` against it under `bindings`, and if it unifies, descend
and run `cont(newbindings)`. Returns the bindings that were in force for the continuation, or
`nothing` when the candidate did not unify.

⚠️ THE CALLER'S `bindings` ARE NOT MUTATED. Upstream saves and restores around the call
(`let saved = self.bindings.clone(); … self.bindings = saved;`); we return the new set instead and
leave the caller's untouched, which is the same discipline without the aliasing question.

`intro_delta` is the candidate's OWN NewVar count — a stored wildcard introduces one variable, a
ground term none — and it advances the factor's namespace so a later candidate in the same factor
cannot collide with variables this one introduced.
"""
function match_candidate!(c::SubtermCursor, bindings::Bindings, f::Int, intro::UInt8,
    pattern::ExprEnv, bytes::AbstractVector{UInt8}, cont::F;   # `::F`, not `::Function` — see with_bound_bytes!
    trail::Vector{ExprVar}=ExprVar[],
    stack::Vector{Tuple{ExprEnv, ExprEnv}}=Tuple{ExprEnv, ExprEnv}[]) where {F}
    data = data_env_for(f, intro, bytes)
    # 🔑 THE UNDO TRAIL (upstream `cfa8abf`). Solve the ONE new equation against the LIVE map and
    # unwind by removal, instead of cloning the map and re-solving every prior equation per
    # candidate. The derefs consult the live map, so an earlier binding constrains exactly as if its
    # equation were re-asserted — that is the whole trade.
    #
    # ⚠️ `cont` NOW RECEIVES THE SAME OBJECT, MUTATED, not a fresh map. The signature is unchanged
    # and that is the hazard: a caller that RETAINED the binding set across candidates used to be
    # safe and no longer is. Nothing in the join does — every use is inside the continuation, below
    # the unwind.
    #
    # ⚠️ UNWIND ON BOTH PATHS. A failed solve may insert before it contradicts, so the map is left
    # DIRTY on failure; `test/integration/expr_unify_trail.jl` pins exactly that case.
    mark = length(trail)
    empty!(stack)
    push!(stack, (pattern, data))
    r = expr_unify_into!(bindings, stack, trail)
    if r isa UnificationFailure
        # 🔴 WHY A MUTANT DELETING THE UNWIND BELOW SURVIVES — and the answer is STRUCTURAL, not a
        # coverage gap. Measured over the whole corpus (2026-08-21), then attributed per case:
        #     2 programs reach this branch at all — `s6_cycle_join`, `s6_cycle_selfocc`, once each.
        #     BOTH ARE OCCURS VIOLATIONS. An occurs check fires BEFORE inserting, so it cannot be
        #     dirty. 0 dirty is not luck.
        # ⚠️ AND THE OTHER CANDIDATE MECHANISM NEVER ARRIVES. A repeated-variable contradiction
        # (`(d \$x \$x)` meeting `(d aa ab)`) WOULD insert then fail — and that shape is ABUNDANT:
        # 591 distinct repeated-variable terms across 269 corpus files. It produces ZERO failures
        # here, because the join resolves the coreference on the TRIE DESCENT (`descend_to_check`)
        # and the binder is handed an already-consistent equation.
        # ⇒ SO THE DIRTY CASE NEEDS A CONTRADICTION FOUND *AFTER* A PARTIAL INSERT, which neither
        #   mechanism that actually produces failures here can generate. `leapfrog_layer3d.jl`
        #   constructs it by calling `match_candidate!` DIRECTLY with a pattern the join would not
        #   hand it: a legitimate unit test of THIS FUNCTION'S contract, but NOT evidence of a
        #   reachable join-level state. Do not upgrade it to one.
        # ⚠️ TWO EARLIER READINGS STOOD HERE AND BOTH WERE WRONG — recorded, not deleted, because
        # each was written as a finding: (a) "unreachable, candidate enumeration pre-filters by byte
        # prefix", a mechanism story told from ONE zero on mm1 — the branch runs; (b) "a
        # repeated-variable candidate inserts first, and the test constructs exactly that" — it does
        # not arrive here at all, per the coreference note above.
        # ⇒ KEEP THE UNWIND AND THE COUNTERS ANYWAY. Absent-here is a property of the corpus and of
        #   the current column scheduling, neither of which is a guarantee.
        UNIFY_FAILURES[] += 1
        if length(trail) > mark
            UNIFY_FAILURES_DIRTY[] += 1
            # 🔑 SURFACE THE FIRST ONE. Measured absent on every corpus program, so its APPEARANCE is
            # news: a workload shape that no test but the hand-written one covers has arrived, and
            # the unwind below is now load-bearing rather than merely correct. Warn once — waiting
            # for someone to run `engine_work.jl` makes a live signal into a static claim.
            UNIFY_FAILURES_DIRTY[] == 1 &&
                @warn "leapfrog: a candidate INSERTED then contradicted — \
                the failure-path unwind is now doing real work. Absent from the whole corpus as of \
                2026-08-21; see tools/mutation_trail.sh (mutant M2)."
        end
        expr_unify_unwind!(bindings, trail, mark)
        return nothing
    end
    try
        with_bound_bytes!(c, bytes, () -> cont(bindings))
    finally
        expr_unify_unwind!(bindings, trail, mark)
    end
    bindings
end

"""
    UNIFY_FAILURES / UNIFY_FAILURES_DIRTY

How often a candidate reached [`match_candidate!`] and FAILED to unify, and how many of those had
already inserted a binding before contradicting (so the failure-path unwind had work to do).

MEASURED 2026-08-21 over the corpus, then ATTRIBUTED PER CASE — which changed the conclusion twice:
  - the branch is reached by exactly **2 programs** (`s6_cycle_join`, `s6_cycle_selfocc`), once each,
    and **both are OCCURS violations**. An occurs check fires BEFORE inserting, so it CANNOT be
    dirty. `0 dirty` is structural, not luck.
  - the sweep first said "4", which was those 2 counted twice by the tool's own warm-up pass.
  - the repeated-variable shape that WOULD insert-then-fail is abundant (591 distinct terms in 269
    files) and produces ZERO failures: the join settles coreference on the trie descent, so the
    binder receives an already-consistent equation.

⚠️ VOLUME IS NOT THE DENOMINATOR HERE, SHAPE IS. "64 538 candidates" sounds like coverage and is not
— 61 913 of them are one program, and running one program's shapes 61 913 times does not sample new
ones. The question "has the dirty case been exercised" is answered by body shape, not candidate
count.

⚠️ DO NOT PROMOTE THIS TO "the branch is dead" OR TO A MECHANISM. An earlier note claimed prefix
filtering made it unreachable, extrapolated from ONE zero on mm1; the corpus figure refutes the
"unreachable" half. The dirty case needs a candidate that unifies structurally and THEN contradicts
on a repeated variable (`(pair \$x \$x)` vs `(pair a b)`) — hand-constructed in
`leapfrog_layer3d.jl`, absent from every corpus program. Re-read these counters on any new workload
before concluding anything.
"""
const UNIFY_FAILURES = Ref{Int}(0)
const UNIFY_FAILURES_DIRTY = Ref{Int}(0)

"The NewVars a candidate introduces — upstream `expr_from_bytes(bytes).newvars()`."
@inline candidate_intro_delta(bytes::AbstractVector{UInt8})::UInt8 =
    UInt8(_expr_newvars(Vector{UInt8}(bytes), 1, length(bytes)))

# ═════════════════════════════════════════════════════════════════════════════════════════════════
# LAYER 4 — THE ASSEMBLY. The layer whose absence made the other three decoration.
#
# Ports upstream `UnifyJoin` (`kernel/src/leapfrog.rs:1411-2478`): `Step`/`push_steps`/
# `factor_steps`, `catch_up`, `recurse_after_catch_up`, `consume_step`/`consume_col`/`consume_sym`/
# `consume_compound`, `match_expr_at_current`/`match_compound_at_current`/`match_compound_children`,
# and `consume_var_parts`.
#
# 🔴 WHY THIS EXISTS AND WHY IT IS LATE. Layers 3b/3c/3d were written, tested (77 assertions, all
# green) and then CALLED BY NOTHING for as long as they existed — they appeared in `export` lines
# and their own definitions and nowhere else. The only end-to-end path was `ground_leapfrog`, and a
# twelve-line probe against the live engine showed what that meant:
#
#     space:  (edge $a b) | (edge a b) | (edge b c)
#     ours: 2 answers        engine: 5 answers
#
# Component tests cannot report that. `test/integration/leapfrog_end_to_end.jl` pins it as
# `@test_broken`; THIS FILE is what turns that green. The lesson is in the ordering, not the code:
# the end-to-end oracle comparison was available from the first commit and should have been the
# FIRST test written, not the one that arrived after three unreachable layers.
# [[feedback_parses_is_not_fires]] · [[feedback_green_suite_hides_unwired_correct_code]]
#
# ─── WHAT MAKES THIS A UNIFICATION JOIN AND NOT `ground_leapfrog` WITH EXTRA STEPS ───────────────
#
# `ground_leapfrog` requires every participating factor's column to EQUAL the running maximum. That
# is correct when data is ground, and WRONG the moment a fact contains a variable: `(edge $w b)`
# unifies with `(edge a b)` without equalling it, so an equality intersection drops it. Every
# structure below exists to let a position match in more ways than one:
#
#   · a stored WILDCARD at a position matches whatever the query has there (`consume_sym`,
#     `consume_compound`, `match_*_at_current` all branch on the column's wildcard bytes)
#   · a query COMPOUND may be matched by a stored wildcard capturing the WHOLE subterm, so its
#     structure must NOT be absorbed into a seek prefix — the trap upstream names explicitly
#   · matching is `expr_unify`, not `==`, so accepting a candidate can refine EARLIER bindings
#
# ─── STEPS: WHY THE COLUMN LIST IS FLATTENED ─────────────────────────────────────────────────────
#
# A factor is not a list of variables; it is a term, and a join variable can sit at any depth.
# `factor_steps` flattens each column into a PRE-ORDER step list so that every position — a
# variable, a ground symbol, a compound node — is a schedulable slot with an index. Upstream's note
# on why this replaced a top-level-columns-only design is the warning worth keeping:
#
#     "Before flattening this asked only about top-level argument columns, so under a namespace
#      wrapper no factor ever qualified, the multiway intersection never engaged, and the structural
#      descent degenerated into the ProductZipper's nested loop with the join's machinery on top."
#
# A join that silently stops being a join is exactly the failure this port keeps re-learning.
#
# ─── WHAT IS DELIBERATELY NOT HERE YET, AND WHY THAT IS NOT A SILENT GAP ─────────────────────────
#
# Upstream splits the level into a BOUND path (`consume_var_parts`) and a FREE path
# (`rank_parts` → `partition_restrictors` → `consume_lead` → `fill_lead_candidates`). We run
# `consume_var_parts` for BOTH, which is correctness-complete — the first participating factor
# enumerates its column and binds the variable, and every later one then sees it bound and seeks —
# but it is NOT yet worst-case-optimal:
#
#   · `rank_parts` (round-robin argmin) picks the SMALLEST domain to lead. Without it, syntactic
#     factor order decides, and a 100k-value factor can lead over a 100-value one.
#   · `fill_lead_candidates` is the true multiway intersection: it leaps the lead to a restrictor's
#     larger value instead of walking the values in between.
#
# ⚠️ THOSE ARE PERFORMANCE, NOT ANSWERS — the answer set is identical either way, and the
# differential test asserts exactly that. They are the next commit, not a hidden shortcut. The
# soundness constraint they must respect is already built and tested one layer down: pruning is
# legal ONLY in the symbol-headed suffix (`is_symbol_head` + `column_matches_by_equality`), because
# everywhere else a stored value can MATCH a candidate without EQUALLING it.
# ═════════════════════════════════════════════════════════════════════════════════════════════════

# Opt-in counter of CANDIDATES ENUMERATED — the number `rank_parts` exists to reduce.
#
# 🔑 WHY A COUNT AND NOT A TIMING. "The join got faster" is a claim about wall clock, which varies
# with GC and the box; "the join enumerated 3000 candidates where 3 would do" is the MECHANISM, and
# it is deterministic. A ranking change must move THIS number or it did nothing — a timing that
# improved while this stayed flat would mean the win came from somewhere else.
# [[feedback_run_the_check_before_making_the_claim]] · [[feedback_no_perf_attribution_without_profiling]]
#
# Off by default; one branch per enumerated column when off.
#   MORK.Leapfrog._LF_TRACE[] = true; MORK.Leapfrog._LF_CANDIDATES[] = 0
const _LF_TRACE = Ref(false)
const _LF_CANDIDATES = Ref(0)

const STEP_VAR = 0x00
const STEP_SYM = 0x01
const STEP_COMPOUND = 0x02

"""
    Step

One position in a factor's flattened term: a schedulable join variable, a ground symbol leaf, or a
compound node whose children are the following steps.

⚠️ ONE CONCRETE STRUCT WITH A TAG, not a `Union` of three types and not an abstract field. `steps`
is walked in the join's innermost loop; a `Vector{Step}` of a concrete isbits-adjacent struct stays
a dense buffer, where a union-typed vector would box every element and put a dynamic dispatch in
the hot path. [[feedback_no_any_typed_containers]]
"""
struct Step
    kind::UInt8
    v::Int          # STEP_VAR: the query variable this position IS (0-based, upstream's numbering)
    env::ExprEnv    # STEP_SYM / STEP_COMPOUND: where the position sits in the query term
    stop::Int       # STEP_COMPOUND: the step index just past this subtree — where a wildcard leaps to
end

"The env slot for a `STEP_VAR`, which carries no position. Built once; never read."
const STEP_NO_ENV = ExprEnv(QUERY_NS, UInt8(0), UInt32(0), MORKExpr(NEWVAR_BYTES))

"""
    push_steps!(base, offset, intro, out) -> (offset, intro)

Flatten the encoded subterm at `base[offset+1…]` into `out` in pre-order, returning the offset and
introduced-variable count just past it.

`offset` is 0-BASED, mirroring upstream's pointer arithmetic; every read adds 1 for Julia. Keeping
upstream's numbering here rather than translating it makes the correspondence checkable line by
line, and the `+ 1` appears exactly at the buffer reads. [[feedback_verify_the_correspondence_not_just_the_code]]
"""
function push_steps!(base::MORKExpr, offset::Int, intro::UInt8, out::Vector{Step})
    b = base.buf[offset + 1]
    env = ExprEnv(QUERY_NS, intro, UInt32(offset), base)
    t = byte_item(b)
    if t isa ExprNewVar
        # A fresh variable: its index IS the count introduced so far, and the count advances.
        push!(out, Step(STEP_VAR, Int(intro), STEP_NO_ENV, 0))
        return (offset + 1, intro + 0x01)
    elseif t isa ExprVarRef
        push!(out, Step(STEP_VAR, Int(t.idx), STEP_NO_ENV, 0))
        return (offset + 1, intro)
    elseif t isa ExprSymbol
        push!(out, Step(STEP_SYM, 0, env, 0))
        return (offset + 1 + Int(t.size), intro)
    else
        arity = Int((t::ExprArity).arity)
        at = length(out) + 1
        push!(out, Step(STEP_COMPOUND, 0, env, 0))     # `stop` patched once the children are known
        off = offset + 1
        for _ in 1:arity
            (off, intro) = push_steps!(base, off, intro, out)
        end
        # 🔴 1-BASED `stop`. Upstream stores `end = out.len()`, an EXCLUSIVE 0-based index; the same
        # position in a 1-based vector is `length(out) + 1`. Off by one here and a wildcard that
        # captures a whole subterm resumes INSIDE it — re-consuming the last child against data that
        # has already moved past it. [[reference_mork_port_state_and_rule64]]
        out[at] = Step(STEP_COMPOUND, 0, env, length(out) + 1)
        return (off, intro)
    end
end

"""
    UnifyColumn

One column of a unify-join factor: either a plain query variable, or a term (which may nest, and
whose ground structure must stay a column so it can unify with a stored variable at its position).
"""
struct UnifyColumn
    is_var::Bool
    v::Int
    term::MORKExpr
    intro::UInt8
end

"A column that is exactly query variable `v`."
unify_var_col(v::Int) = UnifyColumn(true, v, MORKExpr(UInt8[]), 0x00)

"A column holding a term, with the count of variables introduced before it."
unify_term_col(t::MORKExpr, intro::Integer=0) = UnifyColumn(false, 0, t, UInt8(intro))

"""
    UnifyFactor

One relation in a unify join: the trie prefix its facts live under, and its columns in syntactic
order.

⚠️ `prefix` IS TRIE-PATH BYTES, NOT AN EXPRESSION — upstream keeps it a slice for exactly that
reason. Baking a ground relation head into the prefix is legal but costs the ability to match a
stored WILDCARD head, so the body parser emits the arity byte alone and leaves the head as column 0.
"""
struct UnifyFactor
    prefix::Vector{UInt8}
    cols::Vector{UnifyColumn}
end

"The factor's columns flattened into one ordered step list."
function factor_steps(f::UnifyFactor)::Vector{Step}
    out = Step[]
    sizehint!(out, length(f.cols))
    for col in f.cols
        if col.is_var
            push!(out, Step(STEP_VAR, col.v, STEP_NO_ENV, 0))
        else
            push_steps!(col.term, 0, col.intro, out)
        end
    end
    out
end

"""
    UnifyJoinState

The join's live state. `bindings` are NOT here: they are threaded through the recursion.

🔑 SINCE THE TRAIL (2026-08-21) THE THREADED OBJECT IS ONE LIVE MAP, MUTATED AND UNWOUND — not a
fresh value per candidate. The `trail` field below is its undo log. The signature did not change,
which is the hazard: a caller that RETAINED a binding set across candidates was safe before and is
not now. Every use in the join is inside the continuation, below the unwind.

⚠️ THIS NO LONGER DEVIATES FROM UPSTREAM. It did until 2026-08-21: rebuilding the map per candidate
made save/restore UNREPRESENTABLE rather than merely asserted, which was worth its O(|b|) cost while
the assembly itself was unproven — adopting the trail and the assembly at once would have left a
failure ambiguous between them. With the assembly validated, the trail landed and we now do what
upstream does: mutate one map, unwind by trail. What upstream asserts with `debug_assert`s that the
unwind restored the map, we assert in `test/integration/expr_unify_trail.jl` — INCLUDING the failure
path, where a contradiction may insert before it fails and leave the map dirty.
"""
mutable struct UnifyJoinState{V, A, F}
    cursors::Vector{SubtermCursor{V, A}}
    steps::Vector{Vector{Step}}
    next_step::Vector{Int}        # 1-based index into steps[f]
    data_intro::Vector{UInt8}     # variables factor f's data has introduced so far
    var_order::Vector{Int}        # level -> query variable (0-based ids)
    var_pos::Vector{Int}          # query variable -> level
    nvars::Int
    nf::Int
    emit::F
    stopped::Bool
    emitted::Int
    # ── RE-INDEXING (layer 6) ────────────────────────────────────────────────────────────────────
    # `reindex_order[f]` is EMPTY for a factor read from the live map, and otherwise the permutation
    # `new_order[j] = original column at re-indexed position j`. `prefixes[f]` is the factor's own
    # trie prefix, which a re-indexed cursor no longer carries (its private map holds column bytes
    # only) but which `fact_bytes` must put back to reconstruct the stored fact.
    reindex_order::Vector{Vector{Int}}
    prefixes::Vector{Vector{UInt8}}
    # The undo trail: ONE per join, marked and unwound per candidate.
    trail::Vector{ExprVar}
    # 🔑 THE EQUATION STACK IS POOLED, NOT ALLOCATED PER CANDIDATE — upstream's `unify_stack`, which
    # it `clear()`s and `mem::take`s across candidates. Allocating a fresh one-element vector here
    # costs one allocation per candidate, and `match_candidate!` runs 61 913 times on a single
    # `mm1_forward_full_proof` step. Found by DIFFING cfa8abf's `UnifyJoin` fields against ours, not
    # by reading our own code.
    unify_stack::Vector{Tuple{ExprEnv, ExprEnv}}
end

"Query variable ids are 0-BASED (upstream's numbering); array slots are 1-based. One helper, so the
conversion cannot drift — the `BoundsError at index [0]` in `TrieJoin` came from having it inline."
@inline _vslot(v::Int) = v + 1

"NewVars a one-byte stored wildcard introduces: a `NewVar` brings one, a `VarRef` reuses an old one."
@inline uj_wildcard_newvars(w::UInt8)::UInt8 = byte_item(w) isa ExprNewVar ? 0x01 : 0x00

"""
    uj_deref(bindings, env) -> ExprEnv

Follow variable bindings to the term they resolve to, or to the free variable at the end.

The loop is BOUNDED by the number of bindings: each hop consumes a distinct bound variable, so a
chain cannot be longer. Upstream's is unbounded and relies on `unify`'s occurs check; the bound
costs nothing and turns a corrupted map into a wrong answer rather than a hang.
"""
function uj_deref(bindings::Bindings, env::ExprEnv)::ExprEnv
    cur = env
    for _ in 0:length(bindings)
        var = ee_var_opt(cur)
        var === nothing && return cur
        nxt = get(bindings, var, nothing)
        nxt === nothing && return cur
        cur = nxt
    end
    cur
end

"Run `cont` with factor `f`'s data namespace advanced by a candidate's own NewVars, then restore.
Without the advance, two candidates in one factor introduce COLLIDING variable ids."
function uj_match_candidate(st::UnifyJoinState, bindings::Bindings, f::Int,
    pattern::ExprEnv,
    bytes::AbstractVector{UInt8}, newvars::UInt8, cont)
    st.stopped && return nothing
    intro = st.data_intro[f]
    st.data_intro[f] = intro + newvars
    try
        match_candidate!(st.cursors[f], bindings, f, intro, pattern, bytes, cont;
            trail=st.trail, stack=st.unify_stack)
    finally
        st.data_intro[f] = intro
    end
    nothing
end

"Run `cont` with `next_step[f]` set to `to`, then restore it. Every step consumer needs this and
each one that open-coded it was a place the index could be left advanced on an exception."
@inline function uj_at_step(st::UnifyJoinState, f::Int, to::Int, cont)
    s = st.next_step[f]
    st.next_step[f] = to
    try
        cont()
    finally
        st.next_step[f] = s
    end
    nothing
end

"""
    uj_match_expr_at_current(st, bindings, f, pattern, cont)

Match `pattern` against factor `f`'s current cursor position, calling `cont(newbindings)` once per
way the stored data can match — WITHOUT advancing `next_step`, which is the caller's business.
"""
function uj_match_expr_at_current(st::UnifyJoinState, bindings::Bindings, f::Int,
    pattern::ExprEnv, cont)
    st.stopped && return nothing
    c = st.cursors[f]
    resolved = uj_deref(bindings, pattern)

    if ee_var_opt(resolved) !== nothing
        # A STILL-FREE variable: every stored value at this column is a candidate. Materialised
        # before the loop because `match_candidate!` descends the very cursor being enumerated —
        # iterating and mutating at once is how the cursor desyncs from its parse stack.
        cands = Vector{Tuple{Vector{UInt8}, UInt8}}()
        cursor_first!(c)
        while !c.at_end
            k = cursor_key(c)
            k === nothing && break
            (nv, _) = cursor_var_counts(c)          # EXACT counts off the parse — never a rescan
            push!(cands, (Vector{UInt8}(k), nv))
            cursor_next!(c)
        end
        cursor_reset_to_floor!(c)
        _LF_TRACE[] && (_LF_CANDIDATES[] += length(cands))
        for (bytes, nv) in cands
            st.stopped && break
            # ⚠️ Upstream has a GROUND FAST BIND here (a free variable against a ground candidate
            # is one insert, no re-unify). We run the general path for both: same answers, and one
            # path to be wrong in. It is a named optimisation to add against this test, not a
            # behaviour we are missing.
            uj_match_candidate(st, bindings, f, pattern, bytes, nv, cont)
        end
        return nothing
    end

    t = byte_item(resolved.base.buf[Int(resolved.offset) + 1])
    if t isa ExprArity
        uj_match_compound_at_current(st, bindings, f, pattern, resolved, cont)
    else
        # A SYMBOL. Byte equality is unifiability on ground terms, so an exact probe hit binds
        # directly; and a stored wildcard here unifies with the symbol too.
        off = Int(resolved.offset)
        bytes = view(resolved.base.buf, (off + 1):(off + 1 + Int((t::ExprSymbol).size)))
        (exact, mask) = ground_probe!(c, bytes)
        exact && with_bound_bytes!(c, bytes, () -> cont(bindings))
        for w in stored_wildcard_bytes(mask)
            st.stopped && break
            uj_match_candidate(
                st, bindings, f, pattern, UInt8[w], uj_wildcard_newvars(w), cont
            )
        end
    end
    nothing
end

"""
    uj_match_compound_at_current(st, bindings, f, pattern, resolved, cont)

🔴 THE TRAP UPSTREAM SAYS THIS MODULE KEEPS RE-LEARNING: the query's ground structure must NOT be
absorbed into a seek prefix. A stored variable at this very position is a wildcard capturing the
WHOLE subterm — `(data \$w)` must match a query `(data (e a b))` — so the child mask is read HERE and
every wildcard byte becomes its own branch. Only then is the arity byte descended, leaving the
children to their own steps so a variable inside them stays schedulable.
"""
function uj_match_compound_at_current(st::UnifyJoinState, bindings::Bindings, f::Int,
    pattern::ExprEnv, resolved::ExprEnv, cont)
    c = st.cursors[f]
    # ONE mask read serves both branches: each `match_candidate!` restores the cursor, so the
    # position — and therefore the mask — is the same before and after the wildcard loop.
    mask = cursor_floor_child_mask(c)
    for w in stored_wildcard_bytes(mask)
        st.stopped && break
        uj_match_candidate(st, bindings, f, pattern, UInt8[w], uj_wildcard_newvars(w), cont)
    end
    t = byte_item(resolved.base.buf[Int(resolved.offset) + 1])
    t isa ExprArity || return nothing
    ab = item_byte(ExprArity((t::ExprArity).arity))
    if test_bit(mask, ab)
        children = ExprEnv[]
        ee_args!(resolved, children)
        with_bound_bytes!(c, UInt8[ab],
            () -> uj_match_compound_children(st, bindings, f, children, 1, cont))
    end
    nothing
end

"Match each child of a compound in turn against successive cursor positions."
function uj_match_compound_children(st::UnifyJoinState, bindings::Bindings, f::Int,
    children::Vector{ExprEnv}, idx::Int, cont)
    if idx > length(children)
        cont(bindings)
        return nothing
    end
    uj_match_expr_at_current(st, bindings, f, children[idx],
        nb -> uj_match_compound_children(st, nb, f, children, idx + 1, cont))
    nothing
end

"Consume factor `f`'s current position against `env`, advancing `next_step[f]` past exactly it."
function uj_consume_env(st::UnifyJoinState, bindings::Bindings, f::Int, env::ExprEnv, cont)
    s = st.next_step[f]
    uj_match_expr_at_current(
        st, bindings, f, env, nb -> uj_at_step(st, f, s + 1, () -> cont(nb))
    )
end

"Consume factor `f`'s current position as query variable `v`."
uj_consume_col(st::UnifyJoinState, bindings::Bindings, f::Int, v::Int, cont) =
    uj_consume_env(st, bindings, f, query_var_env(v), cont)

"""
    uj_consume_sym(st, bindings, f, s, env, cont)

A ground symbol position: the exact stored bytes match, and so does any stored wildcard at the
column. Both are branches, not alternatives — a space can hold both `(rel a)` and `(rel \$w)`.
"""
function uj_consume_sym(st::UnifyJoinState, bindings::Bindings, f::Int, s::Int,
    env::ExprEnv, cont)
    c = st.cursors[f]
    buf = env.base.buf
    off = Int(env.offset)
    t = byte_item(buf[off + 1])
    bytes = view(buf, (off + 1):(off + 1 + Int((t::ExprSymbol).size)))
    (exact, mask) = ground_probe!(c, bytes)
    if exact
        with_bound_bytes!(c, bytes, () -> uj_at_step(st, f, s + 1, () -> cont(bindings)))
    end
    for w in stored_wildcard_bytes(mask)
        st.stopped && break
        uj_match_candidate(st, bindings, f, env, UInt8[w], uj_wildcard_newvars(w),
            nb -> uj_at_step(st, f, s + 1, () -> cont(nb)))
    end
    nothing
end

"""
    uj_consume_compound(st, bindings, f, s, env, stop, cont)

A compound position. A stored wildcard captures the WHOLE subterm and therefore leaps `next_step`
to `stop`; the arity byte descends one level and leaves the children to the following steps.
"""
function uj_consume_compound(st::UnifyJoinState, bindings::Bindings, f::Int, s::Int,
    env::ExprEnv, stop::Int, cont)
    c = st.cursors[f]
    t = byte_item(env.base.buf[Int(env.offset) + 1])
    mask = cursor_floor_child_mask(c)
    for w in stored_wildcard_bytes(mask)
        st.stopped && break
        uj_match_candidate(st, bindings, f, env, UInt8[w], uj_wildcard_newvars(w),
            nb -> uj_at_step(st, f, stop, () -> cont(nb)))
    end
    ab = item_byte(ExprArity((t::ExprArity).arity))
    if test_bit(mask, ab)
        with_bound_bytes!(
            c, UInt8[ab], () -> uj_at_step(st, f, s + 1, () -> cont(bindings))
        )
    end
    nothing
end

"Consume whatever kind of position factor `f` currently sits on."
function uj_consume_step(st::UnifyJoinState, bindings::Bindings, f::Int, cont)
    s = st.next_step[f]
    step = st.steps[f][s]
    if step.kind == STEP_VAR
        uj_consume_col(st, bindings, f, step.v, cont)
    elseif step.kind == STEP_SYM
        uj_consume_sym(st, bindings, f, s, step.env, cont)
    else
        uj_consume_compound(st, bindings, f, s, step.env, step.stop, cont)
    end
end

"""
    uj_catch_up(st, bindings, i, f)

Before each scheduled variable, walk every factor forward over the positions whose value is already
determined — the query's own ground structure at any depth, and variables an earlier level bound.
A factor stops at the first position holding a variable this level has not reached, which is what
leaves that variable available to the intersection.

🔴 WITHOUT THIS A REPEATED VARIABLE SILENTLY RETURNS NOTHING — the same defect `ground_leapfrog`'s
inline catch-up exists for, where `(edge \$x \$x)` returned 0 on a diagonal of 2.

⚠️ AND EVERY DETERMINED POSITION CAN STILL BRANCH, which is the part an equality-based catch-up gets
wrong: a stored variable there is a wildcard capturing whatever the query has, so the step consumers
take those branches rather than seeking to one value.
"""
function uj_catch_up(st::UnifyJoinState, bindings::Bindings, i::Int, f::Int)
    st.stopped && return nothing
    if f > st.nf
        uj_recurse_after_catch_up(st, bindings, i)
        return nothing
    end
    s = st.next_step[f]
    if s > length(st.steps[f])
        uj_catch_up(st, bindings, i, f + 1)
        return nothing
    end
    step = st.steps[f][s]
    if step.kind == STEP_VAR && st.var_pos[_vslot(step.v)] >= i
        uj_catch_up(st, bindings, i, f + 1)      # scheduled here or later: leave it to the intersection
        return nothing
    end
    uj_consume_step(st, bindings, f, nb -> uj_catch_up(st, nb, i, f))
end

"""
    uj_consume_var_parts(st, bindings, parts, pi, v, i)

Consume variable `v`'s column in each participating factor in turn.

🔑 THIS IS THE LEAPFROG, in its correctness-complete form: `parts[1]` enumerates its column and
binds `v`, and every later participant then sees `v` BOUND — `uj_match_expr_at_current` derefs it
and seeks rather than enumerating. What is missing is only WHICH factor leads (`rank_parts`) and the
mutual-seek leap (`fill_lead_candidates`); see this section's header. The answers are the same.
"""
function uj_consume_var_parts(st::UnifyJoinState, bindings::Bindings, parts::Vector{Int},
    pi::Int, v::Int, i::Int)
    st.stopped && return nothing
    if pi > length(parts)
        uj_catch_up(st, bindings, i + 1, 1)
        return nothing
    end
    f = parts[pi]
    uj_consume_col(
        st, bindings, f, v, nb -> uj_consume_var_parts(st, nb, parts, pi + 1, v, i)
    )
end

"""
    rank_parts!(st, parts)

Order the participating factors by domain size, SMALLEST FIRST, so `parts[1]` leads.

🔑 THE COUNT IS A ROUND ROBIN, and that is the whole design. Every participating cursor is stepped
ONE value per round, and counting stops at the end of the round in which some cursor runs out. That
cursor's count is its EXACT domain size, so a tiny domain wins the lead even against a domain of
millions. Upstream replaced a per-factor count-to-32 with this because the cap scored every domain
above it equal and left the choice to syntactic order — "a 100k-value factor beat a 100-value one
and the join enumerated 100k candidates to keep 100."

⚠️ THE SCAN IS SELF-FINANCING, not a heuristic budget. It costs `length(parts) * (min_domain + 1)`
cursor steps, and the level then enumerates the lead's `min_domain` candidates against every other
participant — at least `min_domain * (length(parts) - 1)` steps. So the estimate stays within a
constant factor of the enumeration it is choosing, and it NEVER scales with the space: nothing here
reads more than the SMALLEST participating domain plus one step per larger one. That is why a full
`val_count` (O(subtree), growing with the whole relation) is still refused.

MEASURED on `test/integration/leapfrog_ranking.jl`'s skewed shape: 303 candidates enumerated for 3
answers BEFORE this, 6 after — because `sel` (3 values) leads instead of `big` (300).
"""
function rank_parts!(st::UnifyJoinState, parts::Vector{Int})
    length(parts) < 2 && return nothing
    # ⚠️ A LOCAL, NOT A MODULE CONST — deliberately. Revise reloads method bodies but strands new
    # const bindings under 1.12's world-partitioned globals, and this file is iterated against a
    # warm server. [[reference_revise_binding_bugs_and_world_partitioning]]
    hard_rounds = 512

    n = length(parts)
    counts = zeros(Int, n)
    done = falses(n)
    for f in parts
        cursor_first!(st.cursors[f])
    end

    round = 0
    while true
        round += 1
        alive = false
        exhausted = false
        for j in 1:n
            done[j] && continue
            c = st.cursors[parts[j]]
            if c.at_end
                done[j] = true
                exhausted = true            # …and we stop at the END of this round, not instantly
                continue
            end
            counts[j] += 1
            cursor_next!(c)
            alive = true
        end
        # `hard_rounds` only stops a level whose EVERY domain is huge from an unbounded pre-scan;
        # such a level is about to enumerate at least that many candidates anyway.
        (!alive || exhausted || round >= hard_rounds) && break
    end

    for f in parts
        cursor_reset_to_floor!(st.cursors[f])
    end

    # 🔴 STABLE, EXPLICITLY. An exhausted cursor carries its exact domain size and one still alive
    # carries the round count — strictly larger — so exact counts always sort first. Equal counts
    # must keep syntactic factor order, or the join's visit order would depend on a sort's
    # internals and a passing differential could reorder tomorrow for no visible reason.
    permute!(parts, sortperm(counts; alg=MergeSort))
    nothing
end

"""
    partition_restrictors!(st, parts) -> nr

Stable-partition `parts[2:end]` so the factors whose current column matches ONLY BY EQUALITY come
first, and return how many there are. Those are the ones [`fill_lead_candidates!`] may intersect the
lead against; a factor holding a stored variable at this column unifies with anything and stays in
the ordinary cascade.

⚠️ THE EARLY-OUT IS NOT A MICRO-OPTIMISATION. Only symbol-headed lead values are prunable, so a lead
column offering none — a column of compounds, say — has nothing to intersect: answer 0 off ONE mask
read instead of scanning every other factor's.
"""
function partition_restrictors!(st::UnifyJoinState, parts::Vector{Int})
    length(parts) < 2 && return 0
    # `item_byte(ExprSymbol(1))` is the first symbol byte; nothing at or above it means the lead
    # offers no ground symbol at all.
    least_ge(cursor_floor_child_mask(st.cursors[parts[1]]), item_byte(ExprSymbol(0x01))) ===
    nothing &&
        return 0

    nr = 0
    for j in 2:length(parts)
        if column_matches_by_equality(cursor_floor_child_mask(st.cursors[parts[j]]))
            nr += 1
            # Rotate the entry down to the end of the restrictor group, keeping BOTH groups'
            # relative order — the same stability argument as `rank_parts!`'s sort.
            v = parts[j]
            for k in j:-1:(nr + 2)
                parts[k] = parts[k - 1]
            end
            parts[nr + 1] = v
        end
    end
    nr
end

"""
    fill_lead_candidates!(st, f, restrictors) -> (candidates, confirmed_from)

The lead's candidate values for a still-free join variable, and the 1-based index of the first one
the mutual seek confirmed present in EVERY restrictor.

🔑 THIS IS THE TRUE LEAPFROG INTERSECTION, and it is the piece `rank_parts!` cannot substitute for.
Ranking picks the smallest domain to lead; when EVERY domain is large and the intersection is tiny,
there is no small domain to pick. Here, each restrictor is sought to the candidate, and when one
answers with a LARGER value the lead LEAPS straight there instead of walking — and unifying,
binding, unwinding — every value in between.
MEASURED on `test/integration/leapfrog_ranking.jl`'s both-large shape: 1000 candidates for 3
answers before this, and the ranked-only path could not improve it.

🔴 SOUNDNESS, WHICH IS THE WHOLE SUBTLETY. This join UNIFIES, so a stored value may MATCH a candidate
without EQUALLING it, and an exact intersection would silently drop answers. A candidate is prunable
ONLY where unifiability IS equality: [`is_symbol_head`] candidates are ground, and a restrictor's
column holds no stored variable ([`column_matches_by_equality`], checked by
[`partition_restrictors!`]), so at that column only the same symbol unifies with them — a stored
compound cannot unify with a symbol at all.

⚠️ AND SYMBOL BYTES SORT ABOVE EVERY COMPOUND AND VARIABLE BYTE, so those candidates form a SUFFIX of
the enumeration. Everything before it — stored wildcards, and compounds a schematic `(f \$x)` unifies
with without equalling — is pushed UNFILTERED, and the seek never skips over any of it. The surviving
candidates are a subsequence of the unfiltered ones IN THE SAME ORDER, so the join's visit order is
unchanged. That is why `confirmed_from` is returned rather than the buffer simply being filtered.
"""
function fill_lead_candidates!(st::UnifyJoinState, f::Int, restrictors::AbstractVector{Int})
    c = st.cursors[f]
    cands = Vector{Tuple{Vector{UInt8}, UInt8}}()

    # ── the UNPRUNABLE PREFIX: everything up to the first symbol-headed value, pushed as-is ──────
    cursor_first!(c)
    while !c.at_end
        k = cursor_key(c)
        (k === nothing || is_symbol_head(k)) && break
        (nv, _) = cursor_var_counts(c)
        push!(cands, (Vector{UInt8}(k), nv))
        cursor_next!(c)
    end
    confirmed_from = length(cands) + 1

    if isempty(restrictors)
        while !c.at_end
            k = cursor_key(c)
            k === nothing && break
            (nv, _) = cursor_var_counts(c)
            push!(cands, (Vector{UInt8}(k), nv))
            cursor_next!(c)
        end
        cursor_reset_to_floor!(c)
        # ⚠️ COUNT ON THIS PATH TOO. This early return is taken whenever the level has ONE
        # participant (no restrictors to intersect against) — and it skipped the counter, so an
        # inverted-factor shape read 0 candidates while enumerating 300. TWO return paths, two
        # increments: an instrument that observes only the branch you were thinking about is how a
        # ratchet goes quietly blind.
        _LF_TRACE[] && (_LF_CANDIDATES[] += length(cands))
        return (cands, confirmed_from)
    end

    # ── the MUTUAL SEEK over the symbol-headed suffix ────────────────────────────────────────────
    lead_max = UInt8[]
    while !c.at_end
        k = cursor_key(c)
        k === nothing && break
        empty!(lead_max)
        append!(lead_max, k)

        leapt = false
        bail = false
        for r in restrictors
            cr = st.cursors[r]
            cursor_seek!(cr, lead_max)
            if cr.at_end
                # Nothing stored at or above the candidate. Every remaining candidate is a ground
                # symbol at least as large, so none can match this factor — stop, do not continue.
                bail = true
                break
            end
            rk = cursor_key(cr)
            if rk === nothing || rk != lead_max
                # The restrictor's least value at or above the candidate is LARGER, so every lead
                # value in between is a ground symbol absent from this factor. Leap there. The
                # target is a symbol, so the lead lands on a symbol too and skips nothing outside
                # the prunable suffix.
                empty!(lead_max)
                rk !== nothing && append!(lead_max, rk)
                cursor_seek!(c, lead_max)
                leapt = true
                break
            end
        end
        bail && break
        leapt && continue

        # Confirmed in every restrictor. The candidate IS the lead cursor's current key, so its
        # variable counts are too — no rescan.
        (nv, _) = cursor_var_counts(c)
        push!(cands, (copy(lead_max), nv))
        cursor_next!(c)
    end

    cursor_reset_to_floor!(c)
    for r in restrictors
        cursor_reset_to_floor!(st.cursors[r])
    end
    # 🔴 COUNT HERE TOO, OR THE INSTRUMENT GOES BLIND EXACTLY WHERE THE WORK MOVED. `_LF_CANDIDATES`
    # was incremented only in `uj_match_expr_at_current`'s free-variable branch. When `consume_lead`
    # took over the lead enumeration, that branch stopped seeing it — the counter read ZERO on a
    # 300-edge join, and `leapfrog_ranking.jl`'s `cand <= 60` passed by measuring NOTHING.
    # A ratchet whose instrument stops observing the path it guards is worse than no ratchet: it is
    # a green light wired to nothing. [[feedback_oracle_must_observe_the_defect_class]]
    _LF_TRACE[] && (_LF_CANDIDATES[] += length(cands))
    (cands, confirmed_from)
end

"""
    descend_restrictors!(st, restrictors, j, value, cont)

Consume the confirmed column of each restrictor in turn, then continue.

The mutual seek already established that `value` — a ground symbol — is stored at this column and
that the column holds no stored variable. So [`uj_consume_col`] would seek to exactly this value,
bind it with no intro of its own, and find no wildcard alternative: that is what happens here,
WITHOUT the mask read and the ascend-then-re-descend the general path pays.

⚠️ EVERY EXIT LEAVES THE CURSOR BACK AT ITS COLUMN FLOOR, which the ancestors' unwind requires — the
same precondition whose violation cost two speculative fixes on `cursor_ascend_floor!`.
"""
function descend_restrictors!(st::UnifyJoinState, restrictors::AbstractVector{Int}, j::Int,
    value::AbstractVector{UInt8}, cont)
    if j > length(restrictors)
        cont()
        return nothing
    end
    r = restrictors[j]
    cr = st.cursors[r]
    cursor_seek!(cr, value)
    k = cursor_key(cr)
    if cr.at_end || k === nothing || k != value
        # Unreachable given the mutual seek's agreement; treated as "no match", which is what the
        # general path would conclude from the same probe.
        cursor_reset_to_floor!(cr)
        return nothing
    end
    cursor_descend_floor!(cr)
    st.next_step[r] += 1
    try
        descend_restrictors!(st, restrictors, j + 1, value, cont)
    finally
        st.next_step[r] -= 1
        cursor_ascend_floor!(cr)
        cursor_reset_to_floor!(cr)
    end
    nothing
end

"""
    uj_consume_lead(st, bindings, parts, nr, v, i)

The lead level for a still-free join variable: `parts[1]` offers its column's values and the
remaining participants match against each accepted value.

`parts[2:1+nr]` are the equality-matching restrictors, which the mutual seek has ALREADY intersected
the lead against over the ground-symbol candidates. For those candidates their columns are consumed
right here — the only possible match is that exact value, already located — and the cascade handles
only the rest. Every other candidate goes through the full cascade over all of `parts[2:end]`, so
stored wildcards and schematic compounds keep the unchanged path.
"""
function uj_consume_lead(st::UnifyJoinState, bindings::Bindings, parts::Vector{Int},
    nr::Int, v::Int, i::Int)
    st.stopped && return nothing
    f = parts[1]
    pattern = query_var_env(v)
    restr_all = view(parts, 2:(1 + nr))
    (cands, confirmed_from) = fill_lead_candidates!(st, f, restr_all)

    for (ci, (bytes, nv)) in enumerate(cands)
        st.stopped && break
        # A candidate BEFORE `confirmed_from` was pushed unfiltered, so it has NOT been intersected
        # and must take the full cascade. Getting this backwards would skip restrictor checks for
        # exactly the wildcard/compound candidates that need them.
        (restrictors, rest) = if ci >= confirmed_from
            (restr_all, view(parts, (2 + nr):length(parts)))
        else
            (view(parts, 1:0), view(parts, 2:length(parts)))
        end
        rest_v = collect(rest)
        s0 = st.next_step[f]
        uj_match_candidate(
            st,
            bindings,
            f,
            pattern,
            bytes,
            nv,
            function (nb)
                uj_at_step(
                    st,
                    f,
                    s0 + 1,
                    () ->
                        descend_restrictors!(st, restrictors, 1, bytes,
                            () -> uj_consume_var_parts(st, nb, rest_v, 1, v, i))
                )
            end
        )
    end
    nothing
end

"Schedule the next variable: intersect the factors sitting on it, or emit if none are left."
function uj_recurse_after_catch_up(st::UnifyJoinState, bindings::Bindings, i::Int)
    st.stopped && return nothing
    if i > st.nvars
        # Every position consumed. A factor not sitting on a stored value means this assignment
        # spells a fact the space does not hold.
        for f in 1:st.nf
            cursor_has_value(st.cursors[f]) || return nothing
        end
        st.emitted += 1
        st.emit(bindings, st) === false && (st.stopped = true)
        return nothing
    end
    v = st.var_order[i]
    parts = Int[]
    for f in 1:st.nf
        s = st.next_step[f]
        s <= length(st.steps[f]) || continue
        step = st.steps[f][s]
        step.kind == STEP_VAR && step.v == v && push!(parts, f)
    end
    if isempty(parts)
        uj_catch_up(st, bindings, i + 1, 1)      # nothing mentions it at this level
        return nothing
    end
    # Rank ONLY when the variable is still free. If an earlier level already bound it, every
    # participant seeks to that one value and there is no lead to choose — upstream branches the
    # same way, and ranking there would pay the round-robin scan for nothing.
    # 🔑 FREE vs BOUND, and upstream branches the same way. If an earlier level already bound the
    # variable, every participant simply seeks to that one value — there is no lead to choose and
    # nothing to intersect, so ranking and the mutual seek would both be paid for nothing.
    if ee_var_opt(uj_deref(bindings, query_var_env(v))) !== nothing
        rank_parts!(st, parts)                       # smallest domain leads
        nr = partition_restrictors!(st, parts)       # …and which of the rest can prune it
        uj_consume_lead(st, bindings, parts, nr, v, i)
    else
        uj_consume_var_parts(st, bindings, parts, 1, v, i)
    end
end

"""
    fact_bytes(st, f) -> Vector{UInt8}

Factor `f`'s STORED FACT at the current answer — upstream's `original_fact_bytes`, which the
engine-facing entry passes to the stock callback as `loc`.

🔑 NO RECONSTRUCTION IS NEEDED, and that is a property of the held-cursor design rather than a
shortcut: the cursor was opened AT the factor's prefix and every consumed column was descended in
place, so the zipper's own path IS `prefix ++ every column consumed` — the complete stored fact.
Upstream needs a real reconstruction only for a RE-INDEXED factor, whose columns were permuted into
a private map; we do not re-index, so this stays a copy.
"""
function fact_bytes(st::UnifyJoinState, f::Int)::Vector{UInt8}
    # 🔴 `zipper_path` IS RELATIVE TO THE ZIPPER'S ROOT, NOT ABSOLUTE. The cursor was opened AT the
    # factor's prefix, so its path is the COLUMN BYTES ONLY and the prefix must be prepended.
    #
    # ⚠️ THIS SHIPPED WRONG IN 8d02787 AND NO TEST COULD SEE IT. `loc` came back as
    # `[0xc4 'edge' …]` where the stored atom is `[0x03 0xc4 'edge' …]` — the arity byte missing.
    # Every leapfrog test compares ANSWER COUNTS, and a truncated `loc` changes no count; the
    # conformance corpus passed 274/274 on this engine with the defect present. Found only by
    # accident, while debugging the re-index region walk, which failed loudly on the SAME wrong
    # assumption (`reserved byte: 0x6e` — a symbol payload read as a tag).
    # `test/integration/leapfrog_loc.jl` is the test that would have caught it: it compares the loc
    # BYTES against the stock engine, not the counts. [[feedback_assert_the_contract_not_the_representation]]
    path = Vector{UInt8}(zipper_path(st.cursors[f].z))
    ord = st.reindex_order[f]
    isempty(ord) && return vcat(st.prefixes[f], path)   # live map: prefix ++ consumed columns
    # 🔴 RE-INDEXED: the path is the PERMUTED key. `loc` must be the ORIGINAL stored fact, so undo
    # the permutation and put the prefix back. Returning the permuted bytes would hand the caller a
    # well-formed atom that is NOT in the space — a wrong answer with no error.
    cols = ri_split_columns(path, length(ord))
    items = ri_columns_to_items(path, cols)
    vcat(st.prefixes[f], ri_emit_reordered(items, ri_invert_order(ord)))
end

"""
    unify_leapfrog(btm, factors, nvars, emit) -> Int

Worst-case-optimal-shaped UNIFICATION conjunctive join. Calls `emit(bindings, st)` once per
satisfying assignment and returns the number emitted; `emit` may return `false` to stop the search.

`st` is the live join state, passed so the callback can recover a factor's stored fact via
[`fact_bytes`] — the `loc` the engine's own callback contract expects. Upstream reads it off `self`
for the same reason; a callback that only ever counts can ignore it.

Unlike [`ground_leapfrog`], a stored variable in a fact acts as a wildcard, so this agrees with the
engine's full unification (`space_query_multi`) on schematic data — which is the property
`test/integration/leapfrog_end_to_end.jl` asserts against the engine as oracle rather than against
hand-computed counts.

⚠️ `bindings` IS LIVE SCRATCH ONLY IN THE SENSE THAT THE CURSORS BENEATH IT MOVE. The map itself is
a fresh value per candidate (see [`UnifyJoinState`]), but the `ExprEnv`s inside it VIEW candidate
byte buffers owned by the enumerating frame — read what you need before returning.
"""
function unify_leapfrog(btm::PathMap{UnitVal}, factors::Vector{UnifyFactor},
    nvars::Int, emit::Function)::Int
    nf = length(factors)
    nf == 0 && return 0

    # var_pos FIRST — `is_inverted` needs the schedule to decide anything.
    var_order = collect(0:(nvars - 1))
    var_pos = zeros(Int, max(nvars, 1))
    for (lvl, v) in enumerate(var_order)
        var_pos[_vslot(v)] = lvl
    end

    # ── RE-INDEX THE INVERTED FACTORS (layer 6) ──────────────────────────────────────────────────
    # A factor whose columns mention variables OUT OF SCHEDULE ORDER cannot be SOUGHT — at the
    # relevant level it is not even a participant, so its whole column gets enumerated once per
    # binding. MEASURED: 90 600 candidates where an ordered factor takes 900 (100.7x).
    # ⚠️ `reindex_maps` is a LOCAL and must stay one: the cursors hold zippers INTO these maps, and
    # the whole join runs synchronously inside this call, so the binding keeps them alive. Upstream
    # builds them outside its join state for the same reason (a zipper into a map owned by the state
    # would be a self-reference); here it is lifetime, not borrowck, but the shape is identical.
    reindex_maps = PathMap{UnitVal}[]
    cursors = SubtermCursor{UnitVal, GlobalAlloc}[]
    eff_cols = Vector{UnifyColumn}[]
    reindex_order = Vector{Int}[]
    prefixes = Vector{UInt8}[]
    for f in factors
        push!(prefixes, copy(f.prefix))
        if length(f.cols) > 1 && is_inverted(f, var_pos)
            (rmap, new_cols, new_order) = build_reindex(btm, f, var_pos)
            push!(reindex_maps, rmap)
            push!(cursors, SubtermCursor(read_zipper_at_path(rmap, UInt8[])))
            push!(eff_cols, new_cols)
            push!(reindex_order, new_order)
        else
            push!(cursors, SubtermCursor(read_zipper_at_path(btm, f.prefix)))
            push!(eff_cols, f.cols)
            push!(reindex_order, Int[])
        end
    end

    steps = Vector{Step}[factor_steps(UnifyFactor(UInt8[], c)) for c in eff_cols]
    st = UnifyJoinState(cursors, steps, ones(Int, nf), zeros(UInt8, nf),
        var_order, var_pos, nvars, nf, emit, false, 0,
        reindex_order, prefixes, ExprVar[], Tuple{ExprEnv, ExprEnv}[])
    uj_catch_up(st, Bindings(), 1, 1)
    st.emitted
end

# ═════════════════════════════════════════════════════════════════════════════════════════════════
# LAYER 5 — THE PARSE. A query BODY becomes factors, so the engine can reach the join at all.
#
# Ports upstream `scan_subterm` + `parse_body_factors` (`kernel/src/leapfrog.rs:1183-1298`).
#
# ⚠️ THIS IS WHERE A WRONG ANSWER HIDES, NOT IN THE JOIN. The join is differentialled over 603
# generated shapes — but every one of those HAND-BUILT its factors, so it cannot see a parse that
# numbers a variable wrong or picks the wrong prefix. Such a parse produces a perfectly well-formed
# join OF THE WRONG QUESTION, and every downstream assertion still passes. `leapfrog_wiring.jl`
# therefore compares against the engine given the SAME BODY TEXT, never against hand-built factors.
#
# 🔴 THE DEFECT THAT SHAPE INVITES: a PER-CONJUNCT variable counter. Then `$y` in the second
# conjunct is a different variable from `$y` in the first, the join stops joining, and the answer is
# a cross product — still well-formed, still "green" against any structural check. Variable ids are
# BODY-GLOBAL, which is what `intro` threading through every conjunct is for, and
# `leapfrog_wiring.jl` asserts the shared id explicitly rather than trusting the count.
#
# ─── A THIRD DELIBERATE OMISSION: RE-INDEXING ────────────────────────────────────────────────────
#
# `scan_subterm` returns a VARIABLE MASK that this parse discards. Upstream stores it per column and
# feeds `is_inverted` (`leapfrog.rs:727`), which asks whether a factor mentions variables OUT OF
# SCHEDULE ORDER — `(, (edge $x $y) (edge $z $x))`, where factor 2 has `$z` (id 2) before `$x`
# (id 0). Such a factor cannot seek on `$x` at its first column, so upstream permutes its columns
# into a PRIVATE re-indexed map and seeks that instead.
#
# ⚠️ ITS ABSENCE COSTS SPEED, NOT ANSWERS: `catch_up` still walks an inverted factor forward
# correctly, it just enumerates where it could have sought. That shape is COMMON, so this belongs
# on the same list as `rank_parts` and `fill_lead_candidates` — the three things standing between
# "correct" and "worst-case-optimal" — and the mask is discarded rather than stored precisely so
# nobody reads a stored-but-unused field as evidence the feature is half-present.
# ═════════════════════════════════════════════════════════════════════════════════════════════════

"""
    scan_subterm(buf, at, intro) -> Union{Nothing, Tuple{Int, UInt64, UInt8}}

Walk the one complete subterm at `buf[at+1…]`, returning its byte length, the mask of query
variables it mentions, and `intro` advanced past its own `NewVar`s — which is what gives each
variable its BODY-GLOBAL id.

`nothing` on a truncated term, a `VarRef` naming a variable not yet introduced, or a variable id at
or above 64. Upstream returns `None` for all three and the caller treats it as "not routable"; none
is an error, because a body the join cannot represent is a body the ProductZipper still answers.

⚠️ `maybe_byte_item`, NOT `byte_item` — ours THROWS on a reserved byte (0x40–0x7F) where upstream's
returns a tag. A malformed body must make this UNROUTABLE, not blow up a query.
"""
function scan_subterm(buf::AbstractVector{UInt8}, at::Int, intro::UInt8)
    i = at
    pending = 1
    vars = UInt64(0)
    while pending != 0
        i < length(buf) || return nothing            # truncated
        b = buf[i + 1]
        i += 1
        pending -= 1
        t = maybe_byte_item(b)
        if t isa ExprArity
            pending += Int(t.arity)
        elseif t isa ExprSymbol
            i += Int(t.size)
        elseif t isa ExprNewVar
            intro >= 0x40 && return nothing          # the parser's 63-variable cap
            vars |= UInt64(1) << intro
            intro += 0x01
        elseif t isa ExprVarRef
            t.idx >= intro && return nothing         # names a variable never introduced
            vars |= UInt64(1) << t.idx
        else
            return nothing                           # a reserved byte: not routable
        end
    end
    i <= length(buf) || return nothing               # a symbol payload ran off the end
    (i - at, vars, intro)
end

"""
    parse_body_factors(body) -> Union{Nothing, Tuple{Vector{UnifyFactor}, Int}}

Turn a query body into join factors and the body's variable count, or `nothing` when the body is not
a well-formed conjunction — in which case the caller sends it down the ProductZipper path.

Two ways a conjunct spreads over seekable columns, both upstream's:

  · a COMPOUND `(rel arg…)` seeks under its ARITY BYTE ALONE, with every top-level argument a
    column and the relation head as column 0. 🔑 The head stays a COLUMN rather than being baked
    into the prefix so a query head and a STORED WILDCARD head can unify either way round; baking
    it in would be faster and would silently drop `(\$anything a b)` facts.
  · anything else — a bare symbol, a bare variable, `()` — has no arguments to spread, so it
    becomes a WHOLE-ATOM factor: EMPTY prefix, so the cursor opens at the trie root where complete
    facts live, and one column holding the conjunct.
"""
function parse_body_factors(body::MORKExpr)
    buf = body.buf
    isempty(buf) && return nothing
    t0 = maybe_byte_item(buf[1])
    t0 isa ExprArity || return nothing
    nconj = Int(t0.arity)
    nconj == 0 && return nothing

    intro = 0x00
    pos = 1                                          # 0-based offset, just past the arity byte
    factors = UnifyFactor[]
    sizehint!(factors, max(nconj - 1, 0))

    for ci in 0:(nconj - 1)
        conj_start = pos
        if ci == 0
            # The `,` head itself carries no factor — but it is still SCANNED, because a head that
            # introduced variables would shift every id after it.
            sc = scan_subterm(buf, pos, intro)
            sc === nothing && return nothing
            (len, _, intro) = sc
            pos += len
            continue
        end

        pos < length(buf) || return nothing
        tb = maybe_byte_item(buf[pos + 1])
        local prefix::Vector{UInt8}
        local ncols::Int
        if tb isa ExprArity && tb.arity != 0
            prefix = buf[(conj_start + 1):(conj_start + 1)]     # the arity byte ALONE
            pos += 1
            ncols = Int(tb.arity)
        else
            prefix = UInt8[]                                    # whole-atom factor, cursor at root
            ncols = 1
        end

        cols = UnifyColumn[]
        sizehint!(cols, ncols)
        for _ in 1:ncols
            col_intro = intro
            col_start = pos
            sc = scan_subterm(buf, pos, intro)
            sc === nothing && return nothing
            (len, _, intro) = sc
            tc = maybe_byte_item(buf[col_start + 1])
            if len == 1 && tc isa ExprNewVar
                push!(cols, unify_var_col(Int(col_intro)))
            elseif len == 1 && tc isa ExprVarRef
                push!(cols, unify_var_col(Int(tc.idx)))
            else
                # ⚠️ THE COLUMN'S OWN `intro` IS `col_intro`, NOT THE RUNNING ONE. `push_steps!`
                # numbers a `NewVar` by the count it is handed, so passing the post-scan value would
                # give every variable in this column an id one too high — a join on the wrong
                # variables, silently.
                push!(
                    cols,
                    unify_term_col(MORKExpr(buf[(col_start + 1):(col_start + len)]),
                        col_intro)
                )
            end
            pos += len
        end
        push!(factors, UnifyFactor(prefix, cols))
    end
    (factors, Int(intro))
end

# ═════════════════════════════════════════════════════════════════════════════════════════════════
# LAYER 6 — RE-INDEXING AN INVERTED FACTOR. The last documented omission.
#
# Ports upstream `is_inverted` / `split_columns` / `columns_to_items` / `emit_reordered` /
# `reindex_regions` / `fold_region_into_reindex` / `build_reindex`
# (`kernel/src/leapfrog.rs:727-928`).
#
# 🔴 WHAT AN INVERTED FACTOR COSTS, MEASURED BEFORE PORTING (2026-08-21, 300-edge chain):
#
#     (, (edge $x $y) (edge $x $z))   ORDERED    900 candidates, 300 answers
#     (, (edge $x $y) (edge $z $x))   INVERTED  90 600 candidates, 299 answers   ← 100.7x
#
# `$z` is id 2 and `$x` is id 0, so at `$x`'s level factor 2 is NOT EVEN A PARTICIPANT — its current
# step is `$z`. It cannot be sought, so its whole column is enumerated once per `$x`. 90 600 ≈
# 300 × 302. Answers are correct either way; this is purely work, which is why it was safe to leave
# until the other two mechanisms landed — and why the measurement had to come first.
#
# THE FIX, and it is the standard worst-case-optimal answer to a cycle: copy the factor's facts into
# a private PathMap with the columns PERMUTED into schedule order, so the join can SEEK it like any
# compatible factor. Only the inverted factor pays the materialisation.
#
# ⚠️ TWO SUBTLETIES, EITHER OF WHICH SILENTLY CORRUPTS ANSWERS RATHER THAN ERRORING:
#
#  1. RENUMBERING. A stored fact is canonically numbered IN COLUMN ORDER, so moving columns changes
#     which occurrence is the binder. `(e $u $u)` must stay COREFERENT after the permutation: the
#     first reference in the NEW order becomes `NewVar` and later ones `VarRef` of its new index.
#     Emitting the original bytes in a new order would make the second `$u` a dangling back-ref.
#
#  2. SCOPING SOUNDNESS. A parsed factor's prefix is the ARITY BYTE ALONE (the head stays column 0
#     so a stored wildcard head still unifies), so "the factor's region" would otherwise be every
#     same-arity fact in the space. Scoping to `prefix + head` is sound ONLY for a ground SYMBOL
#     head: at that trie position a ground symbol unifies with the identical bytes or a stored
#     wildcard, so the union of `prefix+head` and `prefix+w` for each wildcard byte `w` holds every
#     fact the factor can match. 🔴 A ground COMPOUND head is DELIBERATELY NOT SCOPED — a stored
#     compound head may carry variables (`(g $x)` unifies with `(g a)`) and lives outside
#     `prefix + head bytes`. Getting that wrong drops facts, and the join reports fewer answers with
#     no error at all.
# ═════════════════════════════════════════════════════════════════════════════════════════════════

"""
    RIItem

One position in a re-emitted subterm: a literal byte, or a variable identified by its ORIGINAL id
so the re-index can renumber it canonically in the new column order.

⚠️ A CONCRETE TAGGED STRUCT, not a `Union{UInt8,Int}` — a union-typed vector boxes every element,
and this is walked once per stored fact. [[feedback_no_any_typed_containers]]
"""
struct RIItem
    is_var::Bool
    byte::UInt8
    var::Int
end

"Byte length of the one complete subterm starting at `bytes[from]` — the resumable parse run to (0,0)."
function ri_span_len(bytes::AbstractVector{UInt8}, from::Int)::Int
    (s, pay) = PARSE_START
    i = from
    n = length(bytes)
    while i <= n
        (s, pay) = subterm_parse_step(bytes[i], s, pay)
        i += 1
        (s == UInt32(0) && pay == UInt32(0)) && return i - from
    end
    error("ri_span_len: truncated subterm at offset $from")
end

"""
    ri_split_columns(bytes, ncols) -> Vector{UnitRange{Int}}

Split a fact's COLUMN BYTES (everything after the relation prefix) into its `ncols` subterm ranges.
Ranges rather than copies: the caller only walks them.
"""
function ri_split_columns(bytes::AbstractVector{UInt8}, ncols::Int)
    cols = Vector{UnitRange{Int}}(undef, ncols)
    i = 1
    for c in 1:ncols
        len = ri_span_len(bytes, i)
        cols[c] = i:(i + len - 1)
        i += len
    end
    cols
end

"""
    ri_columns_to_items(bytes, cols) -> Vector{Vector{RIItem}}

Decode each column into items, tagging every variable with its ORIGINAL id: a `NewVar` takes the
next id in encounter order ACROSS THE WHOLE FACT, and `VarRef(i)` refers to id `i`. That fact-global
counter is what lets the re-index renumber a coreferent schematic fact correctly after its columns
move — a per-column counter would make `(e \$u \$u)` two distinct variables.
"""
function ri_columns_to_items(bytes::AbstractVector{UInt8}, cols::Vector{UnitRange{Int}})
    next_orig = 0
    out = Vector{Vector{RIItem}}(undef, length(cols))
    for (ci, rng) in enumerate(cols)
        items = RIItem[]
        i = first(rng)
        while i <= last(rng)
            b = bytes[i]
            t = maybe_byte_item(b)
            if t isa ExprArity
                push!(items, RIItem(false, b, 0))
                i += 1
            elseif t isa ExprVarRef
                push!(items, RIItem(true, 0x00, Int(t.idx)))
                i += 1
            elseif t isa ExprNewVar
                push!(items, RIItem(true, 0x00, next_orig))
                next_orig += 1
                i += 1
            elseif t isa ExprSymbol
                push!(items, RIItem(false, b, 0))            # the size tag…
                for k in 1:Int(t.size)                        # …then its payload, verbatim
                    push!(items, RIItem(false, bytes[i + k], 0))
                end
                i += 1 + Int(t.size)
            else
                error("ri_columns_to_items: reserved byte 0x$(string(b; base=16)) at $i")
            end
        end
        out[ci] = items
    end
    out
end

"""
    ri_emit_reordered(items_by_col, new_order) -> Vector{UInt8}

Re-emit the columns in `new_order`, RENUMBERING variables so the first reference to each original id
(in the new order) is a `NewVar` and later references are a `VarRef` of its NEW index. Produces a
canonical, self-consistent encoding for the re-indexed key.

🔴 THIS IS THE STEP THAT KEEPS `(e \$u \$u)` COREFERENT. A stored fact is numbered canonically in
COLUMN order; permuting columns changes which occurrence is the binder. Emitting the original bytes
in a new order would leave the second `\$u` a `VarRef` to an id that no longer precedes it.
"""
function ri_emit_reordered(items_by_col::Vector{Vector{RIItem}}, new_order::Vector{Int})
    out = UInt8[]
    renum = Dict{Int, Int}()
    for c in new_order
        for it in items_by_col[c]
            if !it.is_var
                push!(out, it.byte)
            else
                nid = get(renum, it.var, -1)
                if nid >= 0
                    push!(out, item_byte(ExprVarRef(UInt8(nid))))
                else
                    renum[it.var] = length(renum)
                    push!(out, item_byte(ExprNewVar()))
                end
            end
        end
    end
    out
end

"""
    is_inverted(factor, var_pos) -> Bool

Whether `factor`'s columns mention variables OUT OF SCHEDULE ORDER — the condition under which the
join cannot seek the factor and must enumerate it instead.

Ground columns are skipped: they constrain nothing about ordering.
"""
function is_inverted(f::UnifyFactor, var_pos::Vector{Int})::Bool
    prev = -1
    for col in f.cols
        pos = ri_col_min_var_pos(col, var_pos)
        pos == typemax(Int) && continue
        prev >= 0 && prev > pos && return true
        prev = pos
    end
    false
end

"The earliest SCHEDULE POSITION any variable in this column occupies; `typemax(Int)` if ground."
function ri_col_min_var_pos(col::UnifyColumn, var_pos::Vector{Int})::Int
    col.is_var && return var_pos[_vslot(col.v)]
    best = typemax(Int)
    buf = col.term.buf
    intro = col.intro
    i = 1
    while i <= length(buf)
        t = maybe_byte_item(buf[i])
        if t isa ExprNewVar
            best = min(best, var_pos[_vslot(Int(intro))])
            intro += 0x01
            i += 1
        elseif t isa ExprVarRef
            best = min(best, var_pos[_vslot(Int(t.idx))])
            i += 1
        elseif t isa ExprSymbol
            i += 1 + Int(t.size)
        elseif t isa ExprArity
            i += 1
        else
            break
        end
    end
    best
end

"""
    reindex_regions(btm, factor) -> Union{Nothing, Vector{Vector{UInt8}}}

The regions of the source map a factor's re-index must walk, or `nothing` when no sound scoping
exists and the whole same-arity prefix has to be read.

A parsed factor's `prefix` is the ARITY BYTE ALONE — the relation head is kept as column 0 on
purpose, so a stored WILDCARD head still unifies under a ground query head — so "the factor's
region" is otherwise EVERY same-arity fact in the space, unrelated relations included.

🔑 SCOPING IS SOUND EXACTLY WHEN THE HEAD COLUMN IS A GROUND SYMBOL. At that trie position a ground
symbol query column unifies only with the identical symbol bytes or with a stored wildcard, so the
union of `prefix ++ head` and `prefix ++ w` for every wildcard byte `w` present there holds every
fact the factor can ever match, and nothing outside it is reachable. Re-emitting preserves each
column's shape, so no excluded fact can re-enter through the permuted key either.

🔴 A GROUND COMPOUND HEAD IS DELIBERATELY NOT SCOPED. A stored compound head may carry variables
inside it — `(g \$x)` unifies with `(g a)` — and would live OUTSIDE `prefix ++ head bytes`. Scoping
it would drop facts, and the join would report fewer answers with no error at all.
"""
function reindex_regions(btm::PathMap{UnitVal}, factor::UnifyFactor)
    isempty(factor.cols) && return nothing
    head = factor.cols[1]
    head.is_var && return nothing
    hb = head.term.buf
    isempty(hb) && return nothing
    t = maybe_byte_item(hb[1])
    t isa ExprSymbol || return nothing          # compound / variable head: NOT scopable

    head_bytes = hb[1:(1 + Int(t.size))]        # the symbol IS tag + payload
    regions = Vector{UInt8}[vcat(factor.prefix, head_bytes)]
    mask = zipper_child_mask(read_zipper_at_path(btm, factor.prefix))
    for w in stored_wildcard_bytes(mask)
        push!(regions, vcat(factor.prefix, UInt8[w]))
    end
    regions
end

"""
    fold_region_into_reindex!(btm, region, plen, ncols, new_order, reindex)

Fold every fact under `region` into `reindex`, permuted by `new_order`. `plen` is the factor's
prefix length, so the column bytes start at `plen` of the absolute path regardless of how deep
`region` reaches.

⚠️ A FACT STORED EXACTLY AT THE REGION ROOT NEEDS FOLDING EXPLICITLY — `zipper_to_next_val!` starts
strictly BELOW the root. Only a single-column factor can reach that, and a single-column factor is
never inverted, but the walk stays total either way rather than relying on that argument.
"""
function fold_region_into_reindex!(btm::PathMap{UnitVal}, region::Vector{UInt8}, plen::Int,
    ncols::Int, new_order::Vector{Int},
    reindex::PathMap{UnitVal})
    _ins(colbytes) = begin
        cols = ri_split_columns(colbytes, ncols)
        items = ri_columns_to_items(colbytes, cols)
        set_val_at!(reindex, ri_emit_reordered(items, new_order), UNIT_VAL)
    end
    # ⚠️ `zipper_path` IS RELATIVE to `region`, so the column bytes are
    # `region-beyond-the-prefix` ++ `the zipper's own path`. Slicing the zipper path by `plen`
    # instead — which assumed an absolute path — cut into the middle of a symbol and threw
    # `reserved byte: 0x6e` (an ASCII payload byte read as a tag). Upstream reads `origin_path()`
    # here for exactly this reason.
    head = length(region) > plen ? region[(plen + 1):end] : UInt8[]
    rz = read_zipper_at_path(btm, region)
    zipper_is_val(rz) && !isempty(head) && _ins(head)
    while zipper_to_next_val!(rz)
        _ins(vcat(head, Vector{UInt8}(zipper_path(rz))))
    end
    nothing
end

"""
    build_reindex(btm, factor, var_pos) -> (map, new_cols, new_order)

Re-index an inverted factor: copy its facts into a FRESH PathMap with the columns permuted into
schedule-position order (variables renumbered to stay canonical). Returns that map, the permuted
column list — now non-decreasing, so the join seeks it like any compatible factor — and the
permutation itself, so a leaf can reconstruct the stored fact's ORIGINAL bytes.

This is the one partial materialisation the inverted case needs, and ONLY the inverted factor pays
it. Re-keying into another attribute order is the standard worst-case-optimal answer to a cycle.

Ground columns sort FIRST (they constrain nothing about ordering and seek trivially); the rest sort
by the earliest schedule position any of their variables occupies, ties broken by original position
so the permutation is deterministic.
"""
function build_reindex(btm::PathMap{UnitVal}, factor::UnifyFactor, var_pos::Vector{Int})
    ncols = length(factor.cols)
    keyed = [
        (
            if ri_col_min_var_pos(factor.cols[c], var_pos) == typemax(Int)
                (0, 0, c)
            else
                (ri_col_min_var_pos(factor.cols[c], var_pos), 1, c)
            end, c) for c in 1:ncols
    ]
    sort!(keyed; by=first)
    new_order = Int[c for (_, c) in keyed]
    new_cols = UnifyColumn[factor.cols[c] for c in new_order]

    reindex = PathMap{UnitVal}()
    plen = length(factor.prefix)
    regions = reindex_regions(btm, factor)
    regions === nothing && (regions = Vector{UInt8}[copy(factor.prefix)])
    for region in regions
        fold_region_into_reindex!(btm, region, plen, ncols, new_order, reindex)
    end
    (reindex, new_cols, new_order)
end

"""
    ri_invert_order(new_order) -> Vector{Int}

The permutation that undoes `new_order`: `inv[new_order[j]] = j`. Used to reconstruct a re-indexed
factor's ORIGINAL stored bytes from its permuted key, which is what `loc` must be.
"""
function ri_invert_order(new_order::Vector{Int})
    inv = zeros(Int, length(new_order))
    for (j, c) in enumerate(new_order)
        inv[c] = j
    end
    inv
end

end # module Leapfrog
