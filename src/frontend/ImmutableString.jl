# PROVENANCE: upstream MORK `server` branch @ 2d6730b (2026-05-08) — this file's upstream source
# DOES NOT EXIST on `main`. Verified 2026-07-30: `git cat-file -e main:frontend/src/immutable_string.rs` fails,
# `server:frontend/src/immutable_string.rs` succeeds.
#
# ⚠️ The port-inventory ratchet (test/test_port_inventory.jl) is anchored to MAIN @ 5464713, because
# the release binary the 277-probe differential grades us against is built from main. So for this
# file: its symbols are NOT counted as covered, and an upstream symbol from this subsystem that we
# never ported will NOT show up as a gap. Neither is drift — diff it against `server`, not `main`.
#
# Context: 5 of 6 files in this directory are server-sourced (1365 of 2154 lines, 63%). Their headers
# used to read "port of `mork/frontend/src/...`" with no branch, which is why the inventory reported
# frontend coverage ABOVE 100% — most of our code was not in main's denominator at all.
"""
ImmutableString — 1:1 port of `mork/frontend/src/immutable_string.rs`.

Provides ImmutableString (Allocated vs Literal variants) and ListMap
(insertion-ordered map backed by Vec of pairs).
"""

# =====================================================================
# ListMap — mirrors ListMap<K,V> in immutable_string.rs
# =====================================================================

"""
    ListMap{K,V}

Insertion-ordered map backed by a Vector of (K,V) pairs.
Equality is set-based (order-independent).
Mirrors `ListMap<K, V>` in immutable_string.rs.
"""
mutable struct ListMap{K, V}
    list::Vector{Tuple{K, V}}
end

ListMap{K, V}() where {K, V} = ListMap{K, V}(Tuple{K, V}[])
ListMap(pairs::AbstractVector{Tuple{K, V}}) where {K, V} =
    ListMap{K, V}(Vector{Tuple{K, V}}(pairs))

function lm_get(m::ListMap{K, V}, key::K)::Union{V, Nothing} where {K, V}
    for (k, v) in m.list
        k == key && return v
    end
    nothing
end

function lm_get_mut(m::ListMap{K, V}, key::K)::Union{Ref{V}, Nothing} where {K, V}
    for i in eachindex(m.list)
        m.list[i][1] == key && return Ref(m.list[i])
    end
    nothing
end

function lm_insert!(m::ListMap{K, V}, key::K, val::V) where {K, V}
    push!(m.list, (key, val))
end

function lm_entry_or_insert!(m::ListMap{K, V}, key::K, default::V)::V where {K, V}
    v = lm_get(m, key)
    v !== nothing && return v
    lm_insert!(m, key, default)
    default
end

lm_clear!(m::ListMap) = empty!(m.list)
lm_iter(m::ListMap) = m.list

function Base.:(==)(a::ListMap{K, V}, b::ListMap{K, V}) where {K, V}
    # Set equality: each entry in b must exist in a with same value, and vice versa
    for (k, v) in b.list
        lm_get(a, k) == v || return false
    end
    for (k, v) in a.list
        lm_get(b, k) == v || return false
    end
    true
end

function Base.convert(::Type{ListMap{K, V}}, pairs::Vector{Tuple{K, V}}) where {K, V}
    m = ListMap{K, V}()
    for (k, v) in pairs
        ;
        lm_insert!(m, k, v);
    end
    m
end

# =====================================================================
# ImmutableString — mirrors ImmutableString in immutable_string.rs
# =====================================================================

"""
    ImmutableString

A string that is either heap-allocated (Allocated) or a static literal.
In Julia all strings are immutable, so this is just a thin wrapper
that preserves the API surface from the Rust port.
Mirrors `ImmutableString` in immutable_string.rs.
"""
struct ImmutableString
    value::String
end

ImmutableString(s::AbstractString) = ImmutableString(String(s))

imm_as_str(s::ImmutableString)::String = s.value

Base.:(==)(a::ImmutableString, b::ImmutableString) = a.value == b.value
Base.hash(s::ImmutableString, h::UInt) = hash(s.value, h)
Base.show(io::IO, s::ImmutableString) = print(io, s.value)

export ListMap, lm_get, lm_get_mut, lm_insert!, lm_entry_or_insert!
export lm_clear!, lm_iter
export ImmutableString, imm_as_str
