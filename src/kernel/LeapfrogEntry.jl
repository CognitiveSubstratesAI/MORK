# The engine-facing entry to the leapfrog join.
#
# Ports upstream `query_multi_leapfrog` (`kernel/src/leapfrog.rs:1319`): stream every assignment the
# join accepts through the STOCK `query_multi` callback contract, so a caller cannot tell which
# engine answered except by speed.
#
# 🔑 THE BINDINGS ARE HANDED OVER AS-IS, NOT REBUILT. The join already carries the ProductZipper's
# namespace convention — query variables in `QUERY_NS` (0), factor `f`'s data in `1 + f` — and
# `apply` observes a binding only by DEREFERENCE, so map shape (which end of a var-var equation
# survived, whether a chain was path-compressed) is invisible downstream. Re-unifying each tuple to
# produce a "clean" map would cost the join's whole advantage and change nothing observable.
#
# ⚠️ `nothing` MEANS "NOT ROUTABLE", NOT "NO ANSWERS" — the two are opposites and conflating them
# silently drops every answer for an unroutable body. The caller must fall back to the ProductZipper
# on `nothing`, and only a returned `Int` is an answer count.
#
# 🔴 NOT YET ON THE DEFAULT QUERY PATH, DELIBERATELY. `space_query_multi` does NOT call this. Upstream
# gates the choice, and our own P5 measurement says a wrong gate makes queries SLOWER rather than
# merely different — so adopting it is an A/B against the ProductZipper on real shapes, with the
# dispatch rule earning its place, not a swap. [[feedback_parity_vs_opt_in]]

"""
    space_query_multi_leapfrog(btm, pat_expr, effect) -> Union{Int, Nothing}

Answer the conjunctive query `pat_expr` with the leapfrog unification join, calling
`effect(bindings, loc) -> Bool` per match exactly as [`space_query_multi`] does, and returning the
match count.

Returns `nothing` — and calls `effect` zero times — when the body is not a well-formed conjunction
the join can represent. That is a ROUTING answer, not an empty result: the caller must retry through
[`space_query_multi`], which answers every body.

`loc` is factor 1's stored fact, matching the stock path's contract.
"""
function space_query_multi_leapfrog(btm::PathMap{UnitVal}, pat_expr::MORK.Expr,
    effect::Function; route_by_shape::Bool=false)::Union{Int, Nothing}
    parsed = Leapfrog.parse_body_factors(pat_expr)
    # ⚠️ `nothing` HERE MEANS THE BODY IS NOT A CONJUNCTION AT ALL — a bare symbol, a bare variable,
    # or an encoding the parse rejects (a `VarRef` naming a variable the body never introduced, more
    # than 63 variables). It is NOT "no matches"; conflating the two would silently drop every answer.
    #
    # 🔴 MEASURED 2026-08-21: over the 285-probe conformance corpus this NEVER FIRES — ROUTED 408,
    # DECLINED 0. The four declines it once showed were all `(,)`, a case skipped on purpose and now
    # handled below. So the caller's fallback is dead code, and the stock path REJECTS these same
    # bodies anyway (`space_query_multi`: "pat_expr must be an Arity node"). Handing them back
    # quietly would only move a producer bug somewhere it cannot be seen — upstream's argument, and
    # after the measurement, ours: "a violation is a bug in the producer and should surface as one,
    # NOT AS A SILENT DETOUR TO A DIFFERENT ENGINE."
    if parsed === nothing
        LEAPFROG_LAST_DECLINE[] = :not_conjunction
        return nothing
    end
    (factors, nvars) = parsed
    # ── `(,)` — THE EMPTY CONJUNCTION. Nothing constrains anything, so it matches EXACTLY ONCE
    # with empty bindings. Upstream handles it inline and says why: it "mirrors `Space::query_multi`'s
    # `n_factors == 1` arm byte for byte, including that it calls `effect` once, ignores the answer,
    # and returns 1". Ours does the same (`Space.jl:633`).
    #
    # 🔴 THIS WAS DECLINED ON PURPOSE UNTIL 2026-08-21, and the measurement is what corrected it.
    # `LEAPFROG_DECLINED` over the 285-probe conformance corpus read ROUTED 404 / DECLINED 4 — and
    # capturing the BODIES showed all four were `(,)`. Not a frontend emitting something exotic:
    # a case I skipped rather than read the stock arm. The count alone said "the fallback is
    # load-bearing"; the bodies said "you declined four copies of the same trivial shape."
    # ⇒ MEASURE, THEN NAME. A non-zero counter is not a finding until you know what is in it.
    if isempty(factors)
        effect(Bindings(), pat_expr.buf)
        return 1
    end

    # ── SHAPE ROUTING: a body with a DISCONNECTED conjunct goes to the stock engine ─────────────
    # NOT a capability limit — the join answers these correctly. It is measurably SLOWER on them.
    # MEASURED 2026-08-24 (`workflows/leapfrog_predictor.jl`, 3 reps, cases sized to run for
    # seconds): shared-variable 5 of 5 win at 1.10-1.15x; cross product 0 of 4 win at 0.46-0.54x.
    # Non-overlapping bands. See `factors_connected` for the two bounds this rule stays inside.
    #
    # ⚠️ DISTINCT FROM THE PARSE DECLINE ABOVE, and the distinction is load-bearing: that one is a
    # PRODUCER BUG the caller warns about, measured at ZERO over the conformance corpus. This one is
    # an expected routing decision. Sharing a counter would destroy the zero-rate signal that made
    # the `(,)` bug findable.
    # ⚠️ OPT-IN, AND THE DEFAULT MATTERS. This function ANSWERS every body it can parse — that is
    # its contract, and the differentials, the wiring tests and the conformance corpus all call it
    # directly and depend on it. Making the shape test unconditional CHANGED THAT CONTRACT and broke
    # 120 assertions: `_w_leapfrog(s, b) == _w_engine(s, b)` became `nothing == 9`, because a
    # declining engine and a wrong engine look identical to a caller that expects an answer.
    # ⇒ ROUTING POLICY BELONGS TO THE DISPATCHER, not to the engine. `Space.jl` passes
    #   `route_by_shape=true`; everything that asks this function a direct question still gets one.
    if route_by_shape && !Leapfrog.factors_connected(factors)
        LEAPFROG_LAST_DECLINE[] = :disconnected
        LEAPFROG_DECLINED_SHAPE[] += 1
        return nothing
    end
    # 🔴 `loc` IS THE CONCATENATION OF EVERY MATCHED FACT, NOT FACTOR 1's. Upstream's own comment
    # says "loc is factor 0's stored fact, as stock passes" — TRUE OF UPSTREAM'S STOCK PATH, FALSE
    # OF OURS. `space_query_multi` hands the callback `combined` (Space.jl:813), all matched facts
    # end to end. Matching UPSTREAM's contract here instead of OURS would make this a drop-in
    # replacement for a different engine than the one it replaces.
    #
    # ⚠️ MEASURED, because reading either engine's prose would have got it wrong:
    #     stock    [edge a b][edge b c]   (20 bytes, two atoms)
    #     leapfrog [edge a b]             (10 bytes)  ← before this
    # A truncated `loc` changes no ANSWER COUNT, so the 603-shape differential, the 330-body wiring
    # suite and the 274/274 conformance corpus were all blind to it. `leapfrog_loc.jl` compares the
    # BYTES. [[feedback_verify_code_body_not_comments]]
    nfac = length(factors)
    Leapfrog.unify_leapfrog(
        btm, factors, nvars, function (bindings, st)
            # \U0001f534 PORTS `unsafe { crate::space::unifications += 1 }` (leapfrog.rs:1352) — upstream
            # bumps it HERE, inside `on_match`, once per match and BEFORE `effect`. We had never
            # ported it, and the omission is what made this lane look free.
            #
            # MEASURED 2026-08-23, counter_machine_5.mm2 — and it explains a result that read as a
            # mystery all day:
            #     upstream binary : unifications 403, transitions 0
            #     ours, stock     : unifications 402, transitions 920,549
            #     ours, leapfrog  : unifications   0, transitions       0   ← BOTH zero, and wrong
            # `transitions` is only ever bumped inside `_coreferential_transition!`, which the join
            # does not enter — so 0 there is CORRECT on both sides. But upstream's 403 unifications
            # against our 0 was pure instrument gap, not a behavioural difference. Two engines that
            # agree on every answer looked incomparable because one of them was not counting.
            # ⇒ upstream's `unifications 403 / transitions 0` is the signature of ITS OWN LEAPFROG
            #   LANE, not of some unexplained third path.
            #
            # ⚠️ The `isempty(factors)` arm above must NOT bump this, and does not. Upstream states
            # the reason at leapfrog.rs:1336 — `(,)` mirrors `query_multi`'s `n_factors == 1` arm
            # "byte for byte, including that it does NOT bump the `unifications` counter, so the
            # printed statistics stay identical". Bumping there would make the join disagree with
            # the stock path on a body that does no matching at all.
            #
            # Julia note: `ENGINE_COUNTERS` is a `const` mutable struct with concrete `Int` fields,
            # so this is a type-stable field store — the idiomatic stand-in for upstream's
            # `static mut`, without `unsafe` and without the boxed global a `Ref` would introduce.
            # Deliberately unsynchronised, exactly as upstream is: a lock in the innermost match
            # loop would change the thing being measured.
            ENGINE_COUNTERS.unifications += 1
            loc = Leapfrog.fact_bytes(st, 1)
            for f in 2:nfac
                append!(loc, Leapfrog.fact_bytes(st, f))
            end
            effect(bindings, loc)
        end
    )
end
