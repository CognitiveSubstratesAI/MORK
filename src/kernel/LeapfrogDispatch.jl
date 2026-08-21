# Which engine answers the `,`-source space-to-space transform, and the one space shape on which the
# two engines DISAGREE.
#
# Ports upstream `Space::query_multi_dispatch` (space.rs:1102) and `Space::warn_top_level_variable`
# (space.rs:938).
#
# ─── WHY A RUNTIME FLAG WHERE UPSTREAM HAS A CARGO FEATURE ───────────────────────────────────────
#
# Upstream's dispatch is COMPILE TIME: `#[cfg(feature = "leapfrog")]`, and with the feature on the
# join owns every conjunction body — no shape test, no cost model, no heuristic. That is worth
# stating plainly because it is easy to assume otherwise and build a gate upstream deliberately does
# not have.
#
# A `Ref{Bool}` is the honest Julia analogue and is strictly better HERE, for one reason that is not
# a preference: it lets the differential run the SAME corpus through BOTH engines in ONE process and
# compare. A `cfg` cannot do that — you would need two builds and could never diff them live.
# [[feedback_parity_vs_opt_in]]

"""
    LEAPFROG_DISPATCH

Route the `,`-source space-to-space transform through the worst-case-optimal leapfrog join
([`space_query_multi_leapfrog`]) instead of the ProductZipper.

**Off by default.** Turning it on changes WHICH ENGINE answers, and the two are not
interchangeable on every space — see [`warn_top_level_variable`].

Only that one call site consults this. Interpreted `I` sources, prefix-scoped reads, and the
pattern-directed dumps keep the stock path, as upstream does — the dumps because their ENUMERATION
ORDER is observable and the join's differs.
"""
const LEAPFROG_DISPATCH = Ref(false)

"""
    LEAPFROG_ROUTED / LEAPFROG_DECLINED

How many `,`-source transform bodies the join ANSWERED, and how many it handed back as unroutable.

🔴 THIS COUNTER EXISTS TO SETTLE A DESIGN DISAGREEMENT WITH UPSTREAM, not to report a statistic.
Upstream does NOT fall back. It asserts:

    let (factors, nvars) = parse_body_factors(&pat_expr)
        .expect("a transform body must be a well-formed conjunction");

    "The join owns every body the engine hands it, so parsing is a precondition rather than a
     decline ... A violation is a bug in the producer and should surface as one, NOT AS A SILENT
     DETOUR TO A DIFFERENT ENGINE."

⚠️ AND I BUILT THE DETOUR FROM A STALE DOC COMMENT. The prose above `query_multi_leapfrog` still
says it "returns None ... which the caller sends down the ProductZipper path", while the signature
returns `usize` and the body panics. Reading the comment instead of the body is exactly the failure
[[feedback_verify_code_body_not_comments]] records.

⇒ If `LEAPFROG_DECLINED` is 0 across the corpus, the two designs are observationally identical and
ours is hiding a producer bug that upstream would surface — so the fallback should go. If it is
NON-zero, our frontend emits bodies upstream's does not, and the detour is load-bearing: then say
WHICH bodies, and why, rather than keeping a silent branch. Measure first.
"""
const LEAPFROG_ROUTED = Ref(0)
const LEAPFROG_DECLINED = Ref(0)

"""
    warn_top_level_variable(s) -> Bool

Warn if the space holds a fact that is NOTHING BUT A VARIABLE, and return whether one was found.

🔴 THE ONE SHAPE ON WHICH THE TWO ENGINES DISAGREE. Such a fact sits at the trie root under no arity
prefix, and it unifies with every conjunct of every query. The ProductZipper sees it; the leapfrog
cannot, because the join opens each factor's cursor AT a prefix. Upstream does not fix this either —
it warns, in these words:

    "it unifies with every conjunct of every query, and the leapfrog join cannot see it, so the two
     engines will not agree on this space."

MEASURED in our port 2026-08-21 on `(edge a b) (edge b c) \$loose` with body `(, (edge \$x \$y))`:
ProductZipper 3, leapfrog 2. Pinned in `test/integration/leapfrog_wiring.jl`.

⚠️ NO DIFFERENTIAL CAN REACH THIS SHAPE. Both generators build spaces from `(rel arg arg)` lines, so
a bare-variable atom is structurally impossible in them — the case is covered only because it is
hand-written. A gap a generator cannot produce is unobserved, not absent.
[[feedback_oracle_must_observe_the_defect_class]]

ONE O(1) ROOT PROBE: a stored variable is a complete single-byte subterm, so its presence is exactly
a wildcard tag among the root's children, and those are the contiguous range `VarRef(0)..=NewVar`.
"""
function warn_top_level_variable(s::Space; warn::Bool = true)::Bool
    # ⚠️ UNQUALIFIED, DELIBERATELY. `PathMap` binds the TYPE here, not the module — `Leapfrog.jl`'s
    # import block already warns about this, and qualifying the call fails load with "type UnionAll
    # has no field". I hit that exact error in a throwaway probe an hour before writing this, called
    # it irrelevant to what I was measuring, and then reproduced it in shipped code.
    # [[feedback_verify_code_body_not_comments]]
    mask = zipper_child_mask(read_zipper(s.btm))
    lo = item_byte(ExprVarRef(0x00))               # 0x80
    hi = item_byte(ExprNewVar())                   # 0xC0
    found = false
    b = lo
    while true
        if test_bit(mask, b)
            found = true
            break
        end
        b == hi && break
        b += 0x01
    end
    if found && warn
        @warn "top level variable in the space: it unifies with every conjunct of every query, " *
              "and the leapfrog join cannot see it, so the two engines will not agree on this space."
    end
    found
end
