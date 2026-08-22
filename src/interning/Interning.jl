"""
Interning — port of `mork/interning/src/lib.rs` + `handle.rs` + `symbol_backing.rs`.

Bucket-map symbol table for intern/lookup of byte-string symbols.

Algorithm Overview
==================
  - `MAX_WRITER_THREADS` (128) append-only slab chains, one per permission bucket.
  - Each permission bucket owns a slab `Vector{UInt8}` that symbols are appended to.
  - `to_symbol[hash % MAX_WRITER_THREADS]` : PathMap{MorkSymbol} → maps raw bytes to a Symbol handle.
  - `to_bytes[permission_idx]`             : PathMap{ThinBytes}  → maps Symbol (BE bytes) to slab offset.
  - A micro Pearson hash on the first 8 bytes of input selects the `to_symbol` bucket.
  - `permission_idx` (byte 2 of Symbol) selects the write-permission bucket for exclusive writes.

Julia translation notes
========================
  - Rust `AtomicU64` + CAS → `Threads.Atomic{UInt64}` + `Threads.atomic_cas!`
  - Rust `RwLock<PathMap>` → `ReentrantLock` + `PathMap`
  - Rust `thread_local!` → `task_local_storage(:mork_thread_idx)` / `(:mork_live_permits)`
  - Rust `ThinBytes(*const u8)` (raw pointer) → `ThinBytes(perm_idx, offset, len)` (GC-safe indices)
  - Rust `Slab` (heap-allocated linked list) → `SlabChain` (`Vector{UInt8}`) — GC manages memory
"""

# =====================================================================
# Constants  (mirrors lib.rs constants)
# =====================================================================

const SYM_LEN = 8
const MAX_WRITER_THREADS = 128   # i8::MAX + 1
const MAX_WRITER_THREAD_INDEX = 127
const SYMBOL_THREAD_PERMIT_BYTE_POS = 3     # 1-based; byte index 2 in 0-based Rust
const PEARSON_BOUND = 8

# =====================================================================
# MorkSymbol — 8-byte intern handle
# =====================================================================

"""
    MorkSymbol

Fixed-size 8-byte handle identifying an interned symbol.
Mirrors `type Symbol = [u8;8]` in mork_interning.

Layout (1-based Julia indexing):
  bytes[1..2]  : unused (reserved)
  bytes[3]     : permission_idx (which write bucket owns this symbol)
  bytes[4..8]  : unique symbol id within that bucket (big-endian counter)
"""
struct MorkSymbol
    bytes::NTuple{8, UInt8}
end

MorkSymbol() = MorkSymbol(ntuple(_ -> UInt8(0), 8))
Base.:(==)(a::MorkSymbol, b::MorkSymbol) = a.bytes == b.bytes
Base.hash(s::MorkSymbol, h::UInt) = hash(s.bytes, h)

"""Return the permission_idx stored in byte 3 (1-based)."""
sym_perm_idx(s::MorkSymbol) = s.bytes[3]

"""Encode Symbol as big-endian bytes for use as PathMap key."""
sym_as_be_bytes(s::MorkSymbol) = collect(UInt8, s.bytes)

# =====================================================================
# ThinBytes — GC-safe reference into a slab chain
# =====================================================================

"""
    ThinBytes

Points to an interned symbol's bytes within a permission bucket's slab.
Mirrors `ThinBytes(*const u8)` in mork_interning — uses (perm_idx, offset, len)
instead of a raw pointer so the GC can manage the backing Vector.
"""
struct ThinBytes
    perm_idx::UInt8
    offset::UInt32   # byte offset within the bucket's slab Vector
    len::UInt32   # byte length of the symbol
end

# =====================================================================
# SlabChain — append-only byte buffer (replaces Rust Slab linked list)
# =====================================================================

"""
    SlabChain

Single append-only `Vector{UInt8}` per permission bucket.
Replaces Rust's `Slab` linked-list allocator — Julia GC handles growth.
"""
mutable struct SlabChain
    data::Vector{UInt8}
    write_pos::Int
end

SlabChain() = SlabChain(Vector{UInt8}(undef, 4096), 0)

function _slab_append!(sc::SlabChain, bytes::AbstractVector{UInt8})::ThinBytes
    sc  # returned below after we fill in perm_idx caller-side
    n = length(bytes)
    needed = sc.write_pos + n
    if needed > length(sc.data)
        resize!(sc.data, max(needed * 2, length(sc.data) * 2))
    end
    copyto!(sc.data, sc.write_pos + 1, bytes, 1, n)
    offset = sc.write_pos
    sc.write_pos += n
    ThinBytes(0x00, UInt32(offset), UInt32(n))   # perm_idx filled by caller
end

function _slab_read(sc::SlabChain, tb::ThinBytes)::SubArray{UInt8}
    start = Int(tb.offset) + 1
    stop = start + Int(tb.len) - 1
    view(sc.data, start:stop)
end

# =====================================================================
# ThreadPermission — per-bucket ownership state
# =====================================================================

"""
    ThreadPermission

Tracks which Julia task holds write-permission on this bucket and the
monotonic symbol counter.  Mirrors `ThreadPermission` in mork_interning.

Fields:
  `thread_id`   : 0 = unowned; nonzero = owning task object_id+1
  `next_symbol` : atomic counter; top byte = permission_idx, rest = count
  `slab`        : the slab chain for symbol bytes
"""
mutable struct ThreadPermission
    thread_id::Threads.Atomic{UInt64}
    next_symbol::Threads.Atomic{UInt64}
    slab::SlabChain
end

function ThreadPermission(index::Int)
    @assert 0 <= index <= MAX_WRITER_THREAD_INDEX
    # Mirrors Rust: byte 2 (0-based) = permission_idx stored in bits 40..47
    init_val = if index == 0
        UInt64(1)
    else
        UInt64(index) << (64 - 24)
    end
    ThreadPermission(
        Threads.Atomic{UInt64}(0),
        Threads.Atomic{UInt64}(init_val),
        SlabChain()
    )
end

# =====================================================================
# Pearson hash (mirrors bounded_pearson_hash in lib.rs exactly)
# =====================================================================

const PEARSON_TABLE = UInt8[
    65, 243, 145, 88, 141, 27, 18, 96, 233, 173, 239, 229, 48, 29, 67, 214,
    39, 230, 19, 237, 128, 49, 95, 220, 216, 198, 249, 79, 204, 171, 200, 184,
    0, 111, 219, 163, 140, 59, 114, 33, 207, 41, 210, 70, 104, 137, 14, 118,
    71, 80, 209, 35, 234, 13, 232, 149, 99, 159, 153, 165, 241, 47, 38, 218,
    57, 227, 131, 68, 247, 197, 187, 105, 253, 77, 156, 16, 24, 94, 255, 181,
    54, 120, 160, 182, 244, 62, 194, 8, 113, 20, 22, 138, 17, 135, 202, 61,
    58, 185, 240, 51, 169, 179, 196, 154, 167, 55, 3, 235, 4, 238, 12, 142,
    150, 157, 108, 133, 226, 109, 172, 34, 86, 103, 106, 127, 130, 42, 168, 148,
    245, 100, 143, 123, 155, 206, 60, 72, 11, 10, 180, 64, 215, 177, 92, 189,
    90, 186, 225, 115, 228, 208, 176, 82, 102, 190, 119, 222, 139, 166, 211, 136,
    89, 231, 74, 69, 56, 162, 53, 2, 87, 164, 76, 125, 205, 195, 73, 5,
    107, 6, 30, 203, 213, 188, 110, 248, 144, 101, 151, 126, 15, 91, 242, 183,
    44, 146, 25, 78, 223, 254, 236, 112, 50, 31, 224, 250, 84, 221, 46, 43,
    98, 7, 147, 199, 85, 116, 66, 28, 252, 1, 93, 192, 158, 212, 124, 81,
    175, 63, 201, 36, 217, 251, 83, 26, 52, 37, 97, 152, 134, 45, 21, 178,
    174, 193, 161, 129, 170, 75, 132, 9, 122, 32, 23, 246, 191, 117, 121, 40
]

"""
    bounded_pearson_hash(bytes) → UInt8

Micro Pearson hash over first min(PEARSON_BOUND, length(bytes)) bytes.
Mirrors `bounded_pearson_hash::<PEARSON_BOUND>` in mork_interning.
"""
function bounded_pearson_hash(bytes::AbstractVector{UInt8})::UInt8
    h = UInt8(0)
    n = min(PEARSON_BOUND, length(bytes))
    for i in 1:n
        h = PEARSON_TABLE[Int(h ⊻ bytes[i]) + 1]
    end
    h
end

# =====================================================================
# SharedMapping
# =====================================================================

"""
    SharedMapping

128-bucket symbol interning table.  Mirrors `SharedMapping` in mork_interning.

Two families of lookup PathMaps:
  `to_symbol[bucket]` : raw bytes → MorkSymbol handle
  `to_bytes[bucket]`  : MorkSymbol BE-bytes → ThinBytes (slab location)

`permissions[bucket]` owns the slab and exclusive-write atomic for each bucket.
"""
mutable struct SharedMapping
    count::Threads.Atomic{UInt64}
    permissions::Vector{ThreadPermission}
    to_symbol::Vector{Tuple{ReentrantLock, PathMap{MorkSymbol}}}
    to_bytes::Vector{Tuple{ReentrantLock, PathMap{ThinBytes}}}
end

function SharedMapping()
    perms = [ThreadPermission(i-1) for i in 1:MAX_WRITER_THREADS]
    tsym = [(ReentrantLock(), PathMap{MorkSymbol}()) for _ in 1:MAX_WRITER_THREADS]
    tbytes = [(ReentrantLock(), PathMap{ThinBytes}()) for _ in 1:MAX_WRITER_THREADS]
    SharedMapping(Threads.Atomic{UInt64}(1), perms, tsym, tbytes)
end

# =====================================================================
# SharedMappingHandle — reference-counted wrapper
# =====================================================================

"""
    SharedMappingHandle

Reference-counted handle to a `SharedMapping`.
Mirrors `SharedMappingHandle(NonNull<SharedMapping>)`.
"""
mutable struct SharedMappingHandle
    inner::SharedMapping
    SharedMappingHandle() = new(SharedMapping())
end

Base.getproperty(h::SharedMappingHandle, s::Symbol) =
    s === :inner ? getfield(h, :inner) : getproperty(getfield(h, :inner), s)

# =====================================================================
# Read-only lookups on SharedMapping
# =====================================================================

"""
    get_sym(m, bytes) → Union{Nothing, MorkSymbol}

Look up whether `bytes` is already interned.  Thread-safe read.
Mirrors `SharedMapping::get_sym`.
"""
function get_sym(m::SharedMapping, bytes::AbstractVector{UInt8})::Union{Nothing, MorkSymbol}
    bucket = Int(bounded_pearson_hash(bytes)) % MAX_WRITER_THREADS + 1
    lk, pm = m.to_symbol[bucket]
    lock(lk) do
        get_val_at(pm, bytes)
    end
end

get_sym(h::SharedMappingHandle, bytes::AbstractVector{UInt8}) = get_sym(h.inner, bytes)
get_sym(m::SharedMapping, s::AbstractString) = get_sym(m, Vector{UInt8}(s))
get_sym(h::SharedMappingHandle, s::AbstractString) = get_sym(h.inner, Vector{UInt8}(s))

"""
    get_bytes(m, sym) → Union{Nothing, SubArray{UInt8}}

Retrieve the raw bytes for a previously-interned symbol.
Mirrors `SharedMapping::get_bytes`.
"""
function get_bytes(m::SharedMapping, sym::MorkSymbol)::Union{Nothing, SubArray{UInt8}}
    pidx = Int(sym_perm_idx(sym))
    # NB: parens required — `A || B && return` parses as `A || (B && return)` in
    # Julia (&& binds tighter), so a pidx<1 symbol (e.g. all-zero/De-Bruijn) fell
    # through to `to_bytes[pidx]` → BoundsError instead of returning nothing.
    (pidx < 1 || pidx > MAX_WRITER_THREADS) && return nothing
    lk, pm = m.to_bytes[pidx]
    tb = lock(lk) do
        get_val_at(pm, sym_as_be_bytes(sym))
    end
    tb === nothing && return nothing
    _slab_read(m.permissions[pidx].slab, tb)
end

get_bytes(h::SharedMappingHandle, sym::MorkSymbol) = get_bytes(h.inner, sym)

# =====================================================================
# WritePermit — exclusive write access to one bucket
# =====================================================================

"""
    WritePermit

Scoped write-permit for a specific permission bucket.
Mirrors `WritePermit<'a>` in handle.rs.

Obtain via `try_acquire_permission(handle)`.
Release by calling `release_permission!(permit)` or letting it go out of scope
(call `release_permission!` explicitly — Julia has no RAII destructors).
"""
mutable struct WritePermit
    handle::SharedMappingHandle
    index::Int    # 1-based bucket index
    active::Bool
end

"""
    try_acquire_permission(h) → Union{Nothing, WritePermit}

Attempt to acquire an exclusive write permit on any free bucket.
Returns `nothing` if all 128 buckets are currently held by other tasks.
Mirrors `SharedMappingHandle::try_aquire_permission`.
"""
function try_acquire_permission(h::SharedMappingHandle)::Union{Nothing, WritePermit}
    # Check task-local: if this task already holds a permit, return same slot
    tls_key = :mork_thread_idx
    existing = get(task_local_storage(), tls_key, nothing)
    if existing !== nothing
        idx = existing::Int
        live_key = :mork_live_permits
        task_local_storage(live_key, get(task_local_storage(), live_key, 0) + 1)
        return WritePermit(h, idx, true)
    end

    # Try each bucket with CAS on thread_id
    task_uid = UInt64(objectid(current_task())) + 1
    for i in 1:MAX_WRITER_THREADS
        perm = h.inner.permissions[i]
        old = Threads.atomic_cas!(perm.thread_id, UInt64(0), task_uid)
        if old == UInt64(0)
            task_local_storage(:mork_thread_idx, i)
            task_local_storage(:mork_live_permits, 1)
            return WritePermit(h, i, true)
        end
    end
    nothing
end

"""
    release_permission!(permit)

Release the write permit back to the pool.
Mirrors the `Drop` impl on `WritePermit` in handle.rs.
"""
function release_permission!(wp::WritePermit)
    wp.active || return nothing
    live_key = :mork_live_permits
    idx_key = :mork_thread_idx
    live = get(task_local_storage(), live_key, 1) - 1
    task_local_storage(live_key, live)
    if live == 0
        perm = wp.handle.inner.permissions[wp.index]
        Threads.atomic_xchg!(perm.thread_id, UInt64(0))
        delete!(task_local_storage(), idx_key)
    end
    wp.active = false
end

"""
    with_write_permit(f, h::SharedMappingHandle)

Acquire a write permit, run `f(permit)`, and ALWAYS release it — even if `f` throws.
This is the exception-safe (RAII-equivalent) form, mirroring Rust's `WritePermit`
`Drop`. Prefer it over the raw `try_acquire_permission`/`release_permission!` pair,
which permanently LEAKS the bucket on exception (the thread_id CAS stays claimed, so
no task can ever reacquire it, and the task-local slot index is never cleared).
Returns `f`'s result, or `nothing` if no permit was available.
"""
function with_write_permit(f, h::SharedMappingHandle)
    wp = try_acquire_permission(h)
    wp === nothing && return nothing
    try
        return f(wp)
    finally
        release_permission!(wp)
    end
end

# =====================================================================
# get_sym_or_insert! — main write path
# =====================================================================

"""
    get_sym_or_insert!(wp, bytes) → MorkSymbol

Intern `bytes`, returning an existing Symbol or creating a new one.
Mirrors `WritePermit::get_sym_or_insert` in handle.rs.
"""
function get_sym_or_insert!(wp::WritePermit, bytes::AbstractVector{UInt8})::MorkSymbol
    wp.active || error("WritePermit is no longer active")
    m = wp.handle.inner

    # Fast path: already interned
    existing = get_sym(m, bytes)
    existing !== nothing && return existing

    index = wp.index    # 1-based permission bucket
    hash_bucket = Int(bounded_pearson_hash(bytes)) % MAX_WRITER_THREADS + 1
    sym_lk, sym_pm = m.to_symbol[hash_bucket]
    perm = m.permissions[index]

    # ALL side-effects (id allocation, slab append, to_bytes write, to_symbol write)
    # happen INSIDE the to_symbol lock, AFTER the double-check — so a race-loser
    # (existing2 found) returns immediately with NO side-effects, leaving no orphan
    # to_bytes entry / wasted id / dead slab bytes (audit I-2; this leaked 192 orphans
    # under a 4-thread / 8-task / 300-word stress before the fix).
    # Upstream eagerly slab-writes then reverts on loss (handle.rs:41-111); doing it
    # lazily inside the lock is the simpler Julia equivalent — no revert needed.
    # Lock order is always to_symbol → to_bytes (get_sym/get_bytes each take one only),
    # so no deadlock; perm.slab is exclusive to this permit, safe to append in-scope.
    lock(sym_lk) do
        existing2 = get_val_at(sym_pm, bytes)
        existing2 !== nothing && return existing2

        raw_id = Threads.atomic_add!(perm.next_symbol, UInt64(1))
        # Symbol stored big-endian: bytes[1..2]=0, bytes[3]=perm_idx, bytes[4..8]=counter.
        new_sym_bytes = ntuple(8) do i
            if i <= 2

                UInt8(0)
            elseif i == 3

                UInt8(index)
            else

                UInt8((raw_id >> ((8-i)*8)) & 0xFF)
            end
        end
        new_sym = MorkSymbol(new_sym_bytes)

        tb_raw = _slab_append!(perm.slab, bytes)
        tb = ThinBytes(UInt8(index), tb_raw.offset, tb_raw.len)
        bytes_lk, bytes_pm = m.to_bytes[index]
        lock(bytes_lk) do
            set_val_at!(bytes_pm, sym_as_be_bytes(new_sym), tb)
        end

        set_val_at!(sym_pm, bytes, new_sym)
        new_sym
    end
end

get_sym_or_insert!(wp::WritePermit, s::AbstractString) =
    get_sym_or_insert!(wp, Vector{UInt8}(s))

# =====================================================================
# Exports
# =====================================================================

export SYM_LEN, MAX_WRITER_THREADS, PEARSON_BOUND
export MorkSymbol, sym_perm_idx, sym_as_be_bytes
export ThinBytes, SlabChain
export ThreadPermission
export bounded_pearson_hash
export SharedMapping, SharedMappingHandle
export WritePermit, try_acquire_permission, release_permission!, with_write_permit
export get_sym, get_bytes, get_sym_or_insert!
