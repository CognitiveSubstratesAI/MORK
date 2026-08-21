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
                                    effect::Function)::Union{Int, Nothing}
    parsed = Leapfrog.parse_body_factors(pat_expr)
    parsed === nothing && return nothing
    (factors, nvars) = parsed
    # A body with no conjunct at all (`(,)`). The stock path treats it as a single vacuous match;
    # rather than reproduce that here from a reading of its code, hand it back as unroutable — the
    # engine then answers it, by definition correctly. [[feedback_empty_result_may_be_the_wrong_store]]
    isempty(factors) && return nothing
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
    Leapfrog.unify_leapfrog(btm, factors, nvars, function (bindings, st)
        loc = Leapfrog.fact_bytes(st, 1)
        for f in 2:nfac
            append!(loc, Leapfrog.fact_bytes(st, f))
        end
        effect(bindings, loc)
    end)
end
