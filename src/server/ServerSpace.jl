"""
ServerSpace — port of `mork/server/src/server_space.rs` + `status_map.rs`.

Wraps the kernel Space with path-level read/write permission tracking
for concurrent HTTP access.  Mirrors StatusMap + ServerSpace in server branch.

Julia translation notes:
  - Rust `Arc<RwLock<...>>` → Julia `ReentrantLock` + shared mutable struct
  - Rust `ZipperTracker` (pathmap zipper_tracking) → simplified refcount here
  - Rust `tokio::sync::mpsc` streams → Channel{StatusRecord} per path
  - Rust `Drop for ReadPermission` (releases tracker) → explicit release functions
"""

using JSON3

# =====================================================================
# StatusRecord — mirrors status_map.rs StatusRecord enum
# =====================================================================

"""
    StatusRecord

Status associated with a path. Mirrors `StatusRecord` in status_map.rs.
Used by the status command and permission system.
"""
@enum StatusKind begin
    PATH_CLEAR
    PATH_READ_ONLY
    PATH_READ_ONLY_TEMPORARY
    PATH_FORBIDDEN
    PATH_FORBIDDEN_TEMPORARY
    SERVER_SHUTDOWN
    STATUS_COUNT_RESULT
    STATUS_FETCH_ERROR
    STATUS_PARSE_ERROR
    STATUS_EXEC_ERROR
end

mutable struct StatusRecord
    kind    ::StatusKind
    message ::String
    count   ::Union{Int, Nothing}
end

StatusRecord()                          = StatusRecord(PATH_CLEAR, "", nothing)
StatusRecord(k::StatusKind)             = StatusRecord(k, "", nothing)
StatusRecord(k::StatusKind, m::String)  = StatusRecord(k, m, nothing)

function status_blocks_writer(s::StatusRecord) :: Bool
    s.kind in (PATH_READ_ONLY, PATH_READ_ONLY_TEMPORARY, PATH_FORBIDDEN, PATH_FORBIDDEN_TEMPORARY)
end

function status_blocks_reader(s::StatusRecord) :: Bool
    s.kind in (PATH_READ_ONLY, PATH_READ_ONLY_TEMPORARY, PATH_FORBIDDEN, PATH_FORBIDDEN_TEMPORARY)
end

# Mirrors upstream #[serde(rename_all = "camelCase")] on StatusRecord variants
const _STATUS_KIND_JSON = Dict(
    PATH_CLEAR               => "pathClear",
    PATH_READ_ONLY           => "pathReadOnly",
    PATH_READ_ONLY_TEMPORARY => "pathReadOnlyTemporary",
    PATH_FORBIDDEN           => "pathForbidden",
    PATH_FORBIDDEN_TEMPORARY => "pathForbiddenTemporary",
    SERVER_SHUTDOWN          => "serverShutdown",
    STATUS_COUNT_RESULT      => "countResult",
    STATUS_FETCH_ERROR       => "fetchError",
    STATUS_PARSE_ERROR       => "parseError",
    STATUS_EXEC_ERROR        => "execError",
)

function status_to_json(s::StatusRecord) :: String
    d = Dict{String,Any}("status" => get(_STATUS_KIND_JSON, s.kind, string(s.kind)),
                          "message" => s.message)
    s.count !== nothing && (d["count"] = s.count)
    JSON3.write(d)
end

# =====================================================================
# Permission types — mirrors ReadPermission / WritePermission
# =====================================================================

mutable struct ReadPermission
    path       ::Vector{UInt8}
    status_map ::Any   # StatusMap (forward ref)
    released   ::Bool
end

mutable struct WritePermission
    path       ::Vector{UInt8}
    status_map ::Any   # StatusMap (forward ref)
    released   ::Bool
end

rp_path(p::ReadPermission)  = p.path
wp_path(p::WritePermission) = p.path

# =====================================================================
# StatusMap — mirrors StatusMap in status_map.rs
# Tracks per-path user statuses and concurrent access locks.
# =====================================================================

mutable struct StatusMap
    user_status ::Dict{Vector{UInt8}, StatusRecord}
    readers     ::Dict{Vector{UInt8}, Int}    # refcounts
    writers     ::Set{Vector{UInt8}}
    streams     ::Dict{Vector{UInt8}, Vector{Channel{StatusRecord}}}
    lock        ::ReentrantLock
    shutdown    ::Ref{Bool}
end

StatusMap() = StatusMap(Dict(), Dict(), Set(), Dict(), ReentrantLock(), Ref(false))

function sm_get_user_status(sm::StatusMap, path::Vector{UInt8}) :: StatusRecord
    lock(sm.lock) do
        get(sm.user_status, path, StatusRecord())
    end
end

function sm_get_status(sm::StatusMap, path::Vector{UInt8}) :: StatusRecord
    lock(sm.lock) do
        # Check active reader/writer locks first (PathReadOnlyTemporary / PathForbiddenTemporary)
        if path in sm.writers
            return StatusRecord(PATH_FORBIDDEN_TEMPORARY)
        end
        if get(sm.readers, path, 0) > 0
            return StatusRecord(PATH_READ_ONLY_TEMPORARY)
        end
        get(sm.user_status, path, StatusRecord())
    end
end

# ─────────────────────────────────────────────────────────────────────────────
# Stream notification — snapshot-under-lock + notify-outside-lock.
#
# Port of upstream MORK 205dd91 (server-branch, "Fixing deadlock caused by
# lock being held too long").
#
# Upstream Rust (server/src/status_map.rs::try_set_user_status, lines 313-321)
# scopes the write-lock-guard in a `{ ... }` block so it's dropped before
# `send_new_status(path)` is called.  That fix is necessary because Rust's
# RwLock is not reentrant — holding user_status's lock while send_new_status
# tries to acquire it deadlocks.
#
# In Julia we use ONE ReentrantLock for the whole StatusMap (user_status +
# readers + writers + streams), so the specific reentrant-deadlock isn't
# possible.  But two other issues remain:
#   1. Julia's `put!(ch, val)` is BLOCKING (Rust's `try_send` is not).  A
#      slow reader or full channel blocks the notification thread; if the
#      lock is held during put!, every other task waiting on sm.lock starves.
#   2. Even without starvation, holding sm.lock through N channel sends
#      serializes all StatusMap operations on those sends — same lock-held-
#      too-long shape, just less catastrophic.
#
# Fix: mutate state under lock, snapshot (streams ⊕ composed status) under
# the same lock, release the lock, then run put! per channel OUTSIDE the
# lock.  Garbage-collect dead channels via a brief lock re-acquire.
# ─────────────────────────────────────────────────────────────────────────────

# CALLED UNDER LOCK.  Returns (chs_copy, status) or nothing if no streams.
function _sm_snapshot_streams(sm::StatusMap, path::Vector{UInt8})
    chs = get(sm.streams, path, nothing)
    (chs === nothing || isempty(chs)) && return nothing
    # Compose status inline (no re-entry into the lock — composing is cheap).
    # Mirrors sm_get_status: PATH_FORBIDDEN_TEMPORARY if writer held,
    # PATH_READ_ONLY_TEMPORARY if reader(s) held, else stored user_status.
    st = if path in sm.writers
        StatusRecord(PATH_FORBIDDEN_TEMPORARY)
    elseif get(sm.readers, path, 0) > 0
        StatusRecord(PATH_READ_ONLY_TEMPORARY)
    else
        get(sm.user_status, path, StatusRecord())
    end
    (copy(chs), st)
end

# CALLED OUTSIDE LOCK.  put! per channel; collect dead; one brief lock
# re-acquire to GC them.  Safe for put! to block — sm.lock is free for
# other tasks while we wait on the channel.
function _sm_notify_streams_outside_lock!(sm::StatusMap, path::Vector{UInt8}, snapshot)
    snapshot === nothing && return
    chs_copy, status = snapshot
    dead = Set{Channel{StatusRecord}}()
    for ch in chs_copy
        try
            put!(ch, status)
        catch
            push!(dead, ch)
        end
    end
    isempty(dead) && return
    lock(sm.lock) do
        live = get(sm.streams, path, nothing)
        if live !== nothing
            filter!(ch -> !(ch in dead), live)
            isempty(live) && delete!(sm.streams, path)
        end
    end
end

function sm_try_set_user_status!(sm::StatusMap, path::Vector{UInt8}, status::StatusRecord) :: Bool
    ok_and_snap = lock(sm.lock) do
        existing = get(sm.user_status, path, StatusRecord())
        # Cannot overwrite blocking statuses
        if status_blocks_writer(existing) || status_blocks_reader(existing)
            return (false, nothing)
        end
        sm.user_status[path] = status
        (true, _sm_snapshot_streams(sm, path))
    end
    ok, snap = ok_and_snap
    ok && _sm_notify_streams_outside_lock!(sm, path, snap)
    ok
end

function sm_clear_user_status!(sm::StatusMap, path::Vector{UInt8})
    lock(sm.lock) do
        delete!(sm.user_status, path)
    end
end

function sm_get_read_permission(sm::StatusMap, path::Vector{UInt8}) :: Union{ReadPermission, Nothing}
    perm_and_snap = lock(sm.lock) do
        user_st = get(sm.user_status, path, StatusRecord())
        status_blocks_reader(user_st) && return (nothing, nothing)
        path in sm.writers              && return (nothing, nothing)
        sm.readers[path] = get(sm.readers, path, 0) + 1
        (ReadPermission(path, sm, false), _sm_snapshot_streams(sm, path))
    end
    perm, snap = perm_and_snap
    perm !== nothing && _sm_notify_streams_outside_lock!(sm, path, snap)
    perm
end

function sm_release_read!(sm::StatusMap, perm::ReadPermission)
    perm.released && return
    perm.released = true
    snap = lock(sm.lock) do
        n = get(sm.readers, perm.path, 0)
        n > 1 ? (sm.readers[perm.path] = n - 1) : delete!(sm.readers, perm.path)
        _sm_snapshot_streams(sm, perm.path)
    end
    _sm_notify_streams_outside_lock!(sm, perm.path, snap)
end

function sm_get_write_permission(sm::StatusMap, path::Vector{UInt8}) :: Union{WritePermission, Nothing}
    perm_and_snap = lock(sm.lock) do
        user_st = get(sm.user_status, path, StatusRecord())
        status_blocks_writer(user_st)                          && return (nothing, nothing)
        (haskey(sm.readers, path) || path in sm.writers)       && return (nothing, nothing)
        delete!(sm.user_status, path)   # clear user status on write acquisition
        push!(sm.writers, path)
        (WritePermission(path, sm, false), _sm_snapshot_streams(sm, path))
    end
    perm, snap = perm_and_snap
    perm !== nothing && _sm_notify_streams_outside_lock!(sm, path, snap)
    perm
end

function sm_release_write!(sm::StatusMap, perm::WritePermission)
    perm.released && return
    perm.released = true
    snap = lock(sm.lock) do
        delete!(sm.writers, perm.path)
        _sm_snapshot_streams(sm, perm.path)
    end
    _sm_notify_streams_outside_lock!(sm, perm.path, snap)
end

# Add a status stream channel for a path
function sm_add_stream!(sm::StatusMap, path::Vector{UInt8}, ch::Channel{StatusRecord})
    lock(sm.lock) do
        push!(get!(sm.streams, path, Channel{StatusRecord}[]), ch)
    end
end

# Legacy single-call entry point — kept for external callers (tests etc.).
# Internally now routes through snapshot-under-lock + notify-outside-lock so
# callers get the corrected semantics whether they enter via this function
# or one of the mutator paths.
function _sm_notify_streams!(sm::StatusMap, path::Vector{UInt8})
    snap = lock(sm.lock) do
        _sm_snapshot_streams(sm, path)
    end
    _sm_notify_streams_outside_lock!(sm, path, snap)
end

function sm_shutdown!(sm::StatusMap)
    sm.shutdown[] = true
    lock(sm.lock) do
        for (path, chs) in sm.streams
            for ch in chs
                try; put!(ch, StatusRecord(SERVER_SHUTDOWN)); catch; end
                close(ch)
            end
        end
        empty!(sm.streams)
    end
end

# =====================================================================
# ServerSpace — wraps Space with permission management
# Mirrors ServerSpace in server_space.rs
# =====================================================================

const SETTLE_TIME_S = 0.005   # 5ms settle time from upstream

mutable struct ServerSpace
    space          ::Space
    status_map     ::StatusMap
    resource_store ::ResourceStore
    _next_cmd_id   ::Ref{UInt64}   # monotonic command-ID counter
end

function ServerSpace(resource_dir::AbstractString=".")
    mkpath(resource_dir)
    ServerSpace(new_space(), StatusMap(), ResourceStore(resource_dir), Ref(UInt64(0)))
end

# Thread-safe command-ID allocation
function _ss_next_cmd_id!(ss::ServerSpace) :: UInt64
    id = ss._next_cmd_id[]
    ss._next_cmd_id[] = id + one(UInt64)
    id
end

function ss_get_status(ss::ServerSpace, path::Vector{UInt8}) :: StatusRecord
    sm_get_status(ss.status_map, path)
end

function ss_set_status!(ss::ServerSpace, path::Vector{UInt8}, status::StatusRecord) :: Bool
    sm_try_set_user_status!(ss.status_map, path, status)
end

# Acquire reader — retry once after settle time if conflicted
function ss_new_reader(ss::ServerSpace, path::Vector{UInt8}) :: Union{ReadPermission, Nothing}
    p = sm_get_read_permission(ss.status_map, path)
    if p === nothing
        sleep(SETTLE_TIME_S)
        p = sm_get_read_permission(ss.status_map, path)
    end
    p
end

# Acquire writer — retry once after settle time if conflicted
function ss_new_writer(ss::ServerSpace, path::Vector{UInt8}) :: Union{WritePermission, Nothing}
    p = sm_get_write_permission(ss.status_map, path)
    if p === nothing
        sleep(SETTLE_TIME_S)
        p = sm_get_write_permission(ss.status_map, path)
    end
    p
end

ss_release_reader!(ss::ServerSpace, perm::ReadPermission)  = sm_release_read!(ss.status_map, perm)
ss_release_writer!(ss::ServerSpace, perm::WritePermission) = sm_release_write!(ss.status_map, perm)

"""
    ss_new_multiple(ss, f)

Atomically acquire multiple permissions within `f`. While `f` runs no other
thread can acquire permissions — concurrent `ss_new_reader`/`ss_new_writer`
calls block on `sm.lock`. Mirrors `Space::new_multiple` in space_temporary.rs.
"""
function ss_new_multiple(ss::ServerSpace, f::Function)
    lock(ss.status_map.lock) do
        f(ss)
    end
end

"""
    ss_new_writer_retry(ss, path, attempts=5) → Union{WritePermission, Nothing}

Retry writer acquisition up to `attempts` times with 500µs between tries.
Mirrors `Space::new_writer_retry` in space_temporary.rs.
"""
function ss_new_writer_retry(ss::ServerSpace, path::Vector{UInt8}, attempts::Int=5) :: Union{WritePermission, Nothing}
    for _ in 1:max(1, attempts)
        p = sm_get_write_permission(ss.status_map, path)
        p !== nothing && return p
        sleep(500e-6)
    end
    nothing
end

export ServerSpace, StatusMap, StatusRecord, StatusKind, ReadPermission, WritePermission
export PATH_CLEAR, PATH_READ_ONLY, PATH_READ_ONLY_TEMPORARY
export PATH_FORBIDDEN, PATH_FORBIDDEN_TEMPORARY, SERVER_SHUTDOWN
export STATUS_COUNT_RESULT, STATUS_FETCH_ERROR, STATUS_PARSE_ERROR, STATUS_EXEC_ERROR
export status_to_json, status_blocks_writer, status_blocks_reader
export sm_get_status, sm_try_set_user_status!, sm_clear_user_status!
export sm_get_read_permission, sm_release_read!
export sm_get_write_permission, sm_release_write!
export sm_add_stream!, sm_shutdown!
export ss_get_status, ss_set_status!, ss_new_reader, ss_new_writer
export ss_release_reader!, ss_release_writer!
export ss_new_multiple, ss_new_writer_retry
export _ss_next_cmd_id!
