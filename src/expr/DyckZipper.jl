# DyckZipper — 1:1 port of experiments/expr/dyck/ (server branch)
#
# Compact bit-packed binary tree representation using Dyck words.
# A u64 encodes the complete tree structure: 1-bits = leaf positions,
# 0-bits = branch/internal positions.  Up to 32 leaves per tree.
#
# Key types:
#   DyckWord              — validated u64 with Dyck path structure
#   SubtreeSlice          — (terminal, head) cursor into a subtree
#   DyckStructureZipperU64 — zipper navigating a DyckWord tree
#
# Ports:
#   dyck_zipper.rs    → DyckStructureZipperU64
#   left_branch_impl.rs → left_branch (u64 variant)
#   lib.rs            → DyckWord + validation

# =====================================================================
# SubtreeSlice — port of SubtreeSlice in dyck_zipper.rs
# =====================================================================

"""
    SubtreeSlice

Cursor into a subtree: `terminal` is one past the last leaf bit,
`head` is the position of the subtree root bit.
Mirrors `SubtreeSlice` in dyck_zipper.rs.
"""
struct SubtreeSlice
    terminal::UInt8
    head::UInt8
end

SubtreeSlice() = SubtreeSlice(UInt8(0), UInt8(0))

_ss_is_leaf(s::SubtreeSlice)::Bool = s.terminal - s.head == 1

# =====================================================================
# left_branch — port of left_branch_impl::u64::left_branch
# =====================================================================

"""
    left_branch(structure::UInt64) → UInt64

Find the bit position of the left branch head within a Dyck structure.
Returns a bitmask with the relevant bit set, or 0 if no left branch.
Mirrors `left_branch_impl::u64::left_branch`.
"""
function left_branch(structure::UInt64)::UInt64
    # single element — no left branch
    structure <= 1 && return UInt64(0)
    # right branch is a leaf (0b10 pattern)
    (structure & 0b10) == 0b10 && return UInt64(0b100)
    # look for all positions of bit pattern `011`
    left_splits = ~structure & (structure << 1) & (structure << 2)
    while true
        trailing = trailing_zeros(left_splits)
        current = UInt64(1) << trailing
        if count_ones(left_splits) == 1
            return current >> 1
        end
        tmp = structure >> trailing
        bits = UInt64(64) - UInt64(leading_zeros(tmp)) + 1
        if bits - UInt64(count_ones(tmp)) * 2 == 0
            return current
        end
        # remove candidate
        left_splits ⊻= current
    end
end

# =====================================================================
# DyckWord — port of DyckWord in lib.rs
# =====================================================================

"""
    DyckWord

A validated u64 encoding a binary tree as a Dyck path.
1-bits = internal/leaf marker, 0-bits = branch.
Mirrors `DyckWord` in lib.rs.
"""
struct DyckWord
    word::UInt64
end

const DYCK_WORD_LEAF = DyckWord(UInt64(1))

"""
    dyck_valid_non_empty(word) → Bool

Validate a u64 as a non-empty Dyck word.
Mirrors `DyckWord::valid_non_empty`.
"""
function dyck_valid_non_empty(word::UInt64)::Bool
    leading = leading_zeros(word)
    leading == 0 && return false
    cursor = UInt64(1) << (UInt64(63) - UInt64(leading))
    sum = Int32(0)
    while true
        sum < 0 && return false
        cursor == 0 && return sum == 1
        sum += (cursor & word) == 0 ? Int32(-1) : Int32(1)
        cursor >>= 1
    end
end

"""
    DyckWord(word) → Union{DyckWord, Nothing}

Construct a DyckWord if the u64 is a valid non-empty Dyck word, else nothing.
Mirrors `DyckWord::new`.
"""
function dyck_word_new(word::UInt64)::Union{DyckWord, Nothing}
    dyck_valid_non_empty(word) ? DyckWord(word) : nothing
end

# =====================================================================
# DyckStructureZipperU64 — port of DyckStructureZipperU64 in dyck_zipper.rs
# =====================================================================

const DYCK_MAX_LEAVES = 32   # u64::BITS / 2

"""
    DyckStructureZipperU64

Zipper over a binary tree encoded as a Dyck word (u64).
Supports up to $(DYCK_MAX_LEAVES) leaves per tree.
Mirrors `DyckStructureZipperU64` in dyck_zipper.rs.
"""
mutable struct DyckStructureZipperU64
    structure::UInt64
    current_depth::UInt8
    stack::NTuple{32, SubtreeSlice}   # DYCK_MAX_LEAVES = 32
end

const _ZERO_STACK = NTuple{32, SubtreeSlice}(ntuple(_ -> SubtreeSlice(), 32))

"""LEAF constant — a single-leaf zipper."""
const DYCK_ZIPPER_LEAF = let
    stk = ntuple(i -> i == 1 ? SubtreeSlice(UInt8(1), UInt8(0)) : SubtreeSlice(), 32)
    DyckStructureZipperU64(UInt64(1), UInt8(0), stk)
end

"""
    DyckStructureZipperU64(structure) → Union{DyckStructureZipperU64, Nothing}

Create a zipper for the given Dyck structure. Returns nothing for the empty tree.
Mirrors `DyckStructureZipperU64::new`.
"""
function DyckStructureZipperU64(structure::UInt64)::Union{DyckStructureZipperU64, Nothing}
    structure == 0 && return nothing
    word = dyck_valid_non_empty(structure) ? structure : structure  # debug-checked in upstream
    terminal = UInt8(64 - leading_zeros(structure))
    stk = ntuple(i -> i == 1 ? SubtreeSlice(terminal, UInt8(0)) : SubtreeSlice(), 32)
    DyckStructureZipperU64(word, UInt8(0), stk)
end

function DyckStructureZipperU64(dw::DyckWord)::DyckStructureZipperU64
    terminal = UInt8(64 - leading_zeros(dw.word))
    stk = ntuple(i -> i == 1 ? SubtreeSlice(terminal, UInt8(0)) : SubtreeSlice(), 32)
    DyckStructureZipperU64(dw.word, UInt8(0), stk)
end

# ── Internal helpers ──────────────────────────────────────────────────

function _dsz_cur(z::DyckStructureZipperU64)::SubtreeSlice
    z.stack[z.current_depth + 1]   # 1-based
end

function _dsz_set_cur!(z::DyckStructureZipperU64, s::SubtreeSlice)
    stk = z.stack
    z.stack = ntuple(i -> i == z.current_depth + 1 ? s : stk[i], 32)
end

function _dsz_set_at!(z::DyckStructureZipperU64, depth::Int, s::SubtreeSlice)
    stk = z.stack
    z.stack = ntuple(i -> i == depth + 1 ? s : stk[i], 32)
end

function _left_subtree_head(s::SubtreeSlice, structure::UInt64)::UInt64
    mask = (UInt64(0b10) << UInt64(s.terminal - 1)) - 1
    slice = (structure & mask) >> s.head
    left_branch(slice) << s.head
end

# ── Navigation ────────────────────────────────────────────────────────

"""
    dsz_descend_left!(z) → Bool

Descend to the left child. Returns false if at a leaf.
Mirrors `decend_left`.
"""
function dsz_descend_left!(z::DyckStructureZipperU64)::Bool
    cur = _dsz_cur(z)
    _ss_is_leaf(cur) && return false
    l_head = _left_subtree_head(cur, z.structure)
    l_head == 0 && return false
    z.current_depth += UInt8(1)
    _dsz_set_cur!(z, SubtreeSlice(cur.terminal, UInt8(trailing_zeros(l_head))))
    true
end

"""
    dsz_descend_right!(z) → Bool

Descend to the right child. Returns false if at a leaf.
Mirrors `decend_right`.
"""
function dsz_descend_right!(z::DyckStructureZipperU64)::Bool
    dsz_descend_left!(z) || return false
    _dsz_left_to_right_unchecked!(z)
    true
end

"""
    dsz_ascend!(z) → Bool

Move up to the parent. Returns false if at root.
Mirrors `accend`.
"""
function dsz_ascend!(z::DyckStructureZipperU64)::Bool
    z.current_depth == 0 && return false
    z.current_depth -= UInt8(1)
    true
end

"""
    dsz_ascend_to_root!(z)

Move to the tree root.
Mirrors `accend_to_root`.
"""
dsz_ascend_to_root!(z::DyckStructureZipperU64) = (z.current_depth=UInt8(0); z)

"""
    dsz_ascend_n!(z, n) → Bool

Ascend n levels. Returns false if n > current_depth.
Mirrors `accend_n`.
"""
function dsz_ascend_n!(z::DyckStructureZipperU64, n::UInt8)::Bool
    z.current_depth < n && return false
    z.current_depth -= n
    true
end

# ── Side-to-side movement ─────────────────────────────────────────────

function _dsz_side_to_side!(z::DyckStructureZipperU64, ::Val{:left_to_right})::Bool
    (z.structure <= 1 || z.current_depth == 0) && return false
    prev = z.stack[z.current_depth]     # parent (1-based: depth-1+1 = depth)
    cur = _dsz_cur(z)
    # avoid double right
    prev.head == cur.head - 1 && return false
    _dsz_set_cur!(z, SubtreeSlice(cur.head, UInt8(prev.head + 1)))
    true
end

function _dsz_side_to_side!(z::DyckStructureZipperU64, ::Val{:right_to_left})::Bool
    (z.structure <= 1 || z.current_depth == 0) && return false
    prev = z.stack[z.current_depth]
    cur = _dsz_cur(z)
    # avoid double left
    prev.terminal == cur.terminal && return false
    _dsz_set_cur!(z, SubtreeSlice(prev.terminal, cur.terminal))
    true
end

function _dsz_left_to_right_unchecked!(z::DyckStructureZipperU64)
    prev = z.stack[z.current_depth]
    cur = _dsz_cur(z)
    _dsz_set_cur!(z, SubtreeSlice(cur.head, UInt8(prev.head + 1)))
end

"""
    dsz_left_to_right!(z) → Bool

Switch from left branch to sibling right branch.
Mirrors `left_to_right`.
"""
dsz_left_to_right!(z::DyckStructureZipperU64) = _dsz_side_to_side!(z, Val(:left_to_right))

"""
    dsz_right_to_left!(z) → Bool

Switch from right branch to sibling left branch.
Mirrors `right_to_left`.
"""
dsz_right_to_left!(z::DyckStructureZipperU64) = _dsz_side_to_side!(z, Val(:right_to_left))

# ── Queries ───────────────────────────────────────────────────────────

"""
    dsz_at_root(z) → Bool

True if the zipper is at the tree root (depth 0).
"""
dsz_at_root(z::DyckStructureZipperU64) = z.current_depth == 0

"""
    dsz_is_leaf(z) → Bool

True if the current focus is a leaf.
Mirrors `current_is_leaf`.
"""
dsz_is_leaf(z::DyckStructureZipperU64) = _ss_is_leaf(_dsz_cur(z))

"""
    dsz_is_left_branch(z) → Bool

True if the current node is a left child (not at root).
Mirrors `current_is_left_branch`.
"""
function dsz_is_left_branch(z::DyckStructureZipperU64)::Bool
    z.current_depth == 0 && return false
    prev = z.stack[z.current_depth]   # parent (depth-1 → 1-based: depth)
    cur = _dsz_cur(z)
    prev.terminal == cur.terminal && prev.head != cur.head - 1
end

"""
    dsz_leaf_store_index(z, tree_offset) → Int

Index into the leaf store for the bit at `tree_offset`.
Mirrors `leaf_store_index_unchecked`.
"""
function dsz_leaf_store_index(z::DyckStructureZipperU64, tree_offset::UInt8)::Int
    mask = ~((UInt64(0b10) << UInt32(tree_offset)) - 1)
    Int(count_ones(z.structure & mask))
end

"""
    dsz_current_leaf_range(z) → UnitRange{Int}

Range of leaf store indices for the current subtree.
Mirrors `current_leaf_store_index_range`.
"""
function dsz_current_leaf_range(z::DyckStructureZipperU64)::UnitRange{Int}
    cur = _dsz_cur(z)
    head_bits = z.structure ⊻ (z.structure & ((UInt64(1) << UInt32(cur.head)) - 1))
    right_raw = UInt8(min(Int(trailing_zeros(head_bits)), Int(cur.terminal) - 1))
    first = dsz_leaf_store_index(z, UInt8(cur.terminal - 1))
    last = dsz_leaf_store_index(z, right_raw)
    first:max(last, first)
end

"""
    dsz_current_first_leaf(z) → Int

Index of the first leaf in the current scope.
Mirrors `current_first_leaf_store_index`.
"""
function dsz_current_first_leaf(z::DyckStructureZipperU64)::Int
    cur = _dsz_cur(z)
    dsz_leaf_store_index(z, UInt8(cur.terminal - 1))
end

"""
    dsz_current_substructure(z) → DyckWord

Extract the Dyck subword for the current subtree.
Mirrors `current_substructure`.
"""
function dsz_current_substructure(z::DyckStructureZipperU64)::DyckWord
    cur = _dsz_cur(z)
    mask = (UInt64(1) << UInt32(cur.terminal)) - 1
    DyckWord((mask & z.structure) >> cur.head)
end

"""
    dsz_depth_first_leaves(z) → Vector{Int}

Depth-first (left-to-right) leaf indices for the current subtree.
Mirrors `current_depth_first_indicies`.
"""
function dsz_depth_first_leaves(z::DyckStructureZipperU64)::Vector{Int}
    collect(dsz_current_leaf_range(z))
end

"""
    dsz_breadth_first_leaves(z) → Vector{Int}

Breadth-first leaf indices for the current subtree.
Mirrors `current_breadth_first_indicies`.
"""
function dsz_breadth_first_leaves(z::DyckStructureZipperU64)::Vector{Int}
    MAX_DEFERED = DYCK_MAX_LEAVES
    tmp = DyckStructureZipperU64(z.structure, UInt8(0), z.stack)
    tmp.current_depth = UInt8(0)

    ring = Vector{SubtreeSlice}(undef, MAX_DEFERED)
    ring[1] = _dsz_cur(z)
    front = 1;
    tail = 2

    result = Int[]
    while front != tail
        tmp.current_depth = UInt8(0)   # mirrors tmp.accend_to_root() in upstream
        tmp.stack = ntuple(i -> i == 1 ? ring[front] : SubtreeSlice(), 32)
        front = mod1(front + 1, MAX_DEFERED)

        if dsz_descend_left!(tmp)
            ring[mod1(tail, MAX_DEFERED)] = _dsz_cur(tmp)
            tail = mod1(tail + 1, MAX_DEFERED)
            _dsz_left_to_right_unchecked!(tmp)
            ring[mod1(tail, MAX_DEFERED)] = _dsz_cur(tmp)
            tail = mod1(tail + 1, MAX_DEFERED)
        else
            push!(result, dsz_leaf_store_index(z, tmp.stack[1].head))
        end
    end
    result
end

# =====================================================================
# Exports
# =====================================================================

export SubtreeSlice, DyckWord, DYCK_WORD_LEAF, dyck_word_new, dyck_valid_non_empty
export DYCK_MAX_LEAVES, DYCK_ZIPPER_LEAF
export DyckStructureZipperU64
export left_branch
export dsz_descend_left!,
    dsz_descend_right!, dsz_ascend!, dsz_ascend_to_root!, dsz_ascend_n!
export dsz_left_to_right!, dsz_right_to_left!
export dsz_at_root, dsz_is_leaf, dsz_is_left_branch
export dsz_leaf_store_index, dsz_current_leaf_range, dsz_current_first_leaf
export dsz_current_substructure, dsz_depth_first_leaves, dsz_breadth_first_leaves
