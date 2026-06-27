# TrieJoin — ADR-056 Lever A, phase P1: empty-tail conjunctive join via trie-algebra.
#
# Computes a conjunction of UNARY relations sharing ONE variable —
#   (, (r1 $v) (r2 $v) ...)  —  as the structural meet (`pmeet`) of the relations'
# argument-value subtries, instead of the naive ProductZipper (which enumerates the
# N^k cross product and unify-filters). Proven equivalent to the exec route and
# ~680× faster at N=400 on a 2-relation join (ADR-056 step-0 / P1 bench).
#
# This is the SUBSTRATE primitive only. It is NOT yet wired into
# `_space_query_multi_inner!` — that is phase P1b (the shared-variable classifier that
# derives head-prefixes from a pattern + the effect/`combined` synthesis), gated
# separately. See docs/architecture/ADR-056_zam_cardinality_join_planning.md.

# Resolve a PathMap `pmeet` result to a concrete PathMap.
#   • AlgResElement  → its `.value` (a genuinely-new meet: overlap, or disjoint→empty)
#   • AlgResIdentity → the meet equals one input; for a meet (intersection) that input
#                      is always the SUBSET, i.e. the smaller-by-`val_count`
#   • AlgResNone     → empty meet
_trie_meet(a::PathMap{UnitVal}, b::PathMap{UnitVal})::PathMap{UnitVal} = begin
    r = pmeet(a, b)
    r isa AlgResElement  && return r.value
    r isa AlgResIdentity && return (val_count(a) <= val_count(b) ? a : b)
    PathMap{UnitVal}()
end

"""
    trie_argset(btm, head_prefix) -> PathMap{UnitVal}

The set of argument-value byte-encodings stored under `head_prefix` — the relation-head
prefix (e.g. the `[Arity2][Sym r]` bytes of `(r \$v)`) — materialized as a fresh PathMap
whose keys are the encoded argument values.
"""
function trie_argset(btm::PathMap{UnitVal}, head_prefix::AbstractVector{UInt8})::PathMap{UnitVal}
    m = PathMap{UnitVal}()
    rz = read_zipper_at_path(btm, collect(head_prefix))
    while zipper_to_next_val!(rz)
        set_val_at!(m, collect(zipper_path(rz)), UNIT_VAL)
    end
    m
end

"""
    trie_join_unary(btm, head_prefixes) -> PathMap{UnitVal}

Empty-tail conjunctive join: the intersection of the argument-value sets of the given
unary relations (each identified by its head-prefix). The result keys are the argument
encodings shared by ALL relations — i.e. the bindings of the join variable. Equivalent
to `(, (r1 \$v) (r2 \$v) ...)` but computed by trie meet rather than ProductZipper.
"""
function trie_join_unary(btm::PathMap{UnitVal},
        head_prefixes::Vector{<:AbstractVector{UInt8}})::PathMap{UnitVal}
    isempty(head_prefixes) && return PathMap{UnitVal}()
    acc = trie_argset(btm, head_prefixes[1])
    for i in 2:length(head_prefixes)
        val_count(acc) == 0 && break          # already empty — meet stays empty
        acc = _trie_meet(acc, trie_argset(btm, head_prefixes[i]))
    end
    acc
end
