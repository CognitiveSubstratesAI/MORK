"""
Prefix — 1:1 port of `mork/kernel/src/prefix.rs` (server branch).

Byte-slice prefix comparison utilities used by the server space layer.
"""

# =====================================================================
# PrefixComparison — mirrors PrefixComparison enum in prefix.rs
# =====================================================================

@enum PrefixComparison begin
    PREFIX_BOTH_EMPTY
    PREFIX_FIRST_EMPTY
    PREFIX_SECOND_EMPTY
    PREFIX_DISJOINT
    PREFIX_OF         # left is a prefix of right
    PREFIX_PREFIXED_BY # right is a prefix of left
    PREFIX_SHARING    # share a common prefix but neither is prefix of other
    PREFIX_EQUALS
end

# =====================================================================
# prefix_compare — mirrors Prefix::compare in prefix.rs
# Returns (comparison, n) where n = length of common prefix found.
# =====================================================================

function prefix_compare(
    left::Vector{UInt8}, right::Vector{UInt8}
)::Tuple{PrefixComparison, Int}
    ll = length(left)
    rl = length(right)

    ll == 0 && rl == 0 && return (PREFIX_BOTH_EMPTY, 0)
    ll == 0 && return (PREFIX_FIRST_EMPTY, 0)
    rl == 0 && return (PREFIX_SECOND_EMPTY, 0)
    left[1] != right[1] && return (PREFIX_DISJOINT, 0)

    n = 1
    while true
        left_done = n == ll
        right_done = n == rl
        left_done && right_done && return (PREFIX_EQUALS, n)
        left_done && return (PREFIX_OF, n)
        right_done && return (PREFIX_PREFIXED_BY, n)
        left[n + 1] != right[n + 1] && return (PREFIX_SHARING, n)
        n += 1
    end
end

export PrefixComparison
export PREFIX_BOTH_EMPTY, PREFIX_FIRST_EMPTY, PREFIX_SECOND_EMPTY
export PREFIX_DISJOINT, PREFIX_OF, PREFIX_PREFIXED_BY, PREFIX_SHARING, PREFIX_EQUALS
export prefix_compare
