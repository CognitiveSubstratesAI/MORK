"""
Commands — 1:1 port of `mork/server/src/commands.rs`.

Each command mirrors the upstream Rust CommandDefinition impl exactly:
  - ACK-and-async pattern (count, import, metta_thread) → return ACK immediately,
    spawn background task, write result to status_map
  - Synchronous pattern (clear, copy, status, stop) → return result directly
  - Worker pattern (explore, export, upload, transform) → run blocking work
    on a thread, return result

Julia translation:
  - Rust `tokio::task::spawn_blocking` → `Threads.@spawn`
  - Rust `WorkResult::Immediate(bytes)` → `(:ok, bytes)`
  - Rust `StatusRecord::CountResult(n)` → `StatusRecord(STATUS_COUNT_RESULT, string(n), n)`
  - Rust `derive_prefix_from_expr_slice` → ported as `_derive_prefix` (line ~74)
  - Rust `pattern_template_from_sexpr_pair` → `_parse_pattern_template`
"""

using HTTP
using JSON3

# =====================================================================
# DataFormat — mirrors DataFormat enum in commands.rs
# =====================================================================

@enum DataFormat begin
    FMT_METTA
    FMT_CSV
    FMT_JSON
    FMT_JSONL
    FMT_RAW
    FMT_PATHS
end

function dataformat_from_str(s::AbstractString) :: Union{DataFormat, Nothing}
    d = Dict("metta"=>FMT_METTA, "csv"=>FMT_CSV, "json"=>FMT_JSON,
             "jsonl"=>FMT_JSONL, "raw"=>FMT_RAW, "paths"=>FMT_PATHS)
    get(d, lowercase(s), nothing)
end

# =====================================================================
# WorkResult — mirrors WorkResult enum in commands.rs
# =====================================================================

# (:ok, bytes)  — WorkResult::Immediate
# (:error, http_status_code::Int, message::String)
# (:stream, channel::Channel) — WorkResult::Streamed (SSE)

const WorkResult = Tuple   # (:ok, bytes) | (:error, code, msg) | (:stream, ch)

work_ok(s::AbstractString)     = (:ok, Vector{UInt8}(s))
work_ok(b::Vector{UInt8})      = (:ok, b)
work_error(code::Int, msg::String) = (:error, code, msg)
work_stream(ch::Channel)       = (:stream, ch)

# =====================================================================
# Helpers
# =====================================================================

# Mirrors pattern_template_from_sexpr_pair in commands.rs
# Parses "(transform (, pat) (, tpl))" or bare "pat_sexpr tpl_sexpr"
function _parse_pattern_template(ss::ServerSpace, pat_str::String, tpl_str::String)
    pat = sexpr_to_expr(pat_str)
    tpl = sexpr_to_expr(tpl_str)
    (pat, tpl)
end

# _derive_prefix: constant prefix of expr up to first NewVar/VarRef.
# "a" → full; "(isa)" → full; "(isa \$x \$y)" → [Arity3, "isa"]; "\$x" → []
# Mirrors derive_prefix_from_expr_slice + till_constant_to_full (upstream 83d1276).
function _derive_prefix(expr::MORK.Expr) :: Vector{UInt8}
    buf = expr.buf
    n   = length(buf)
    # BFS walk via an explicit stack of (offset, remaining_children) pairs.
    # We include bytes only while they are constant (Symbol or Arity header).
    # As soon as we see a NewVar or VarRef, we stop.
    i = 1
    stack = Int[]   # remaining child counts at each depth
    while i <= n
        b   = buf[i]
        tag = byte_item(b)
        if tag isa ExprNewVar || tag isa ExprVarRef
            break   # variable encountered — stop here
        elseif tag isa ExprSymbol
            i += 1 + Int(tag.size)   # include symbol bytes
        elseif tag isa ExprArity
            i += 1   # include the arity header byte, push children
        else
            break
        end
    end
    buf[1:i-1]
end

# Parse transform POST body: "(transform (, pat...) (, tpl...))"
# Mirrors pattern_template_args in commands.rs
function _parse_transform_body(ss::ServerSpace, src::String)
    # Parse the outer (transform ...) expression
    outer = sexpr_to_expr(src)
    args  = ExprEnv[]
    ee_args!(ExprEnv(UInt8(0), UInt8(0), UInt32(0), outer), args)
    length(args) >= 3 || error("transform: expected (transform (, pats...) (, tpls...))")

    # args[1] = "transform" symbol, args[2] = pattern list, args[3] = template list
    pat_list = args[2]
    tpl_list = args[3]

    # Extract sub-expressions from comma list (, e1 e2 ...)
    function extract_comma_list(ee::ExprEnv)
        sub_args = ExprEnv[]
        ee_args!(ee, sub_args)
        length(sub_args) >= 2 || error("expected comma list")
        # sub_args[1] = "," functor, rest are the elements
        [MORK.Expr(Vector{UInt8}(expr_span(a.base, Int(a.offset)+1))) for a in sub_args[2:end]]
    end

    patterns  = extract_comma_list(pat_list)
    templates = extract_comma_list(tpl_list)
    (patterns, templates)
end

# =====================================================================
# busywait — mirrors BusywaitCmd in commands.rs
# GET /busywait/<millis>
# Ties up a worker for N ms. Returns "ACK. Waiting" immediately.
# =====================================================================
function cmd_busywait(ss::ServerSpace, args::Vector{String}, props::Dict{String,String}, body::Vector{UInt8})
    length(args) < 1 && return work_error(400, "busywait: expected millis argument")
    millis = tryparse(Int, args[1])
    millis === nothing && return work_error(400, "busywait: expected integer milliseconds")
    Threads.@spawn sleep(millis / 1000)
    work_ok("ACK. Waiting")
end

# =====================================================================
# clear — mirrors ClearCmd in commands.rs
# GET /clear/<expr_sexpr>
# Removes all values at the expression's prefix. Synchronous.
# =====================================================================
function cmd_clear(ss::ServerSpace, args::Vector{String}, props::Dict{String,String}, body::Vector{UInt8})
    isempty(args) && return work_error(400, "clear: expected expr argument")
    expr_str = join(args, "/")
    try
        expr   = sexpr_to_expr(expr_str)
        prefix = _derive_prefix(expr)
        writer = ss_new_writer(ss, prefix)
        writer === nothing && return work_error(503, "clear: path is locked")
        try
            # Collect all paths under prefix, then remove each one.
            # Mirrors upstream wz.remove_branches + wz.remove_val via
            # iteration instead of direct bulk-remove (handles node misalignment).
            rz = read_zipper_at_path(ss.space.btm, prefix)
            paths = Vector{UInt8}[]
            while zipper_to_next_val!(rz)
                push!(paths, copy(rz.prefix_buf))
            end
            for p in paths
                remove_val_at!(ss.space.btm, p)
            end
        finally
            ss_release_writer!(ss, writer)
        end
        work_ok("ACK. Cleared")
    catch e
        work_error(400, "clear: $e")
    end
end

# =====================================================================
# copy — mirrors CopyCmd in commands.rs
# GET /copy/<src_expr>/<dst_expr>
# Grafts src subtrie into dst. Synchronous.
# =====================================================================
function cmd_copy(ss::ServerSpace, args::Vector{String}, props::Dict{String,String}, body::Vector{UInt8})
    length(args) < 2 && return work_error(400, "copy: expected src_expr and dst_expr")
    try
        src_expr   = sexpr_to_expr(args[1])
        dst_expr   = sexpr_to_expr(args[2])
        src_prefix = _derive_prefix(src_expr)
        dst_prefix = _derive_prefix(dst_expr)

        reader = ss_new_reader(ss, src_prefix)
        reader === nothing && return work_error(503, "copy: source path is locked")
        writer = ss_new_writer(ss, dst_prefix)
        if writer === nothing
            ss_release_reader!(ss, reader); return work_error(503, "copy: dest path is locked")
        end
        try
            # Mirrors wz.graft(&rz) — copy every value from src subtrie to dst.
            # Read all relative paths under src_prefix, write each at dst_prefix + rel_path.
            rz = read_zipper_at_path(ss.space.btm, src_prefix)
            while zipper_to_next_val!(rz)
                rel_path = collect(zipper_path(rz))
                set_val_at!(ss.space.btm, vcat(dst_prefix, rel_path), UNIT_VAL)
            end
        finally
            ss_release_reader!(ss, reader)
            ss_release_writer!(ss, writer)
        end
        work_ok("ACK. Copied")
    catch e
        work_error(500, "copy: $e")
    end
end

# =====================================================================
# count — mirrors CountCmd in commands.rs
# GET /count/<expr_sexpr>
# Returns "ACK. Starting Count" immediately; result stored in status_map.
# =====================================================================
function cmd_count(ss::ServerSpace, args::Vector{String}, props::Dict{String,String}, body::Vector{UInt8})
    isempty(args) && return work_error(400, "count: expected expr argument")
    expr_str = join(args, "/")
    try
        expr   = sexpr_to_expr(expr_str)
        prefix = _derive_prefix(expr)
        reader = ss_new_reader(ss, prefix)
        reader === nothing && return work_error(503, "count: path is locked")
        Threads.@spawn begin
            try
                rz = read_zipper_at_path(ss.space.btm, prefix)
                n  = zipper_val_count(rz)
                ss_set_status!(ss, prefix, StatusRecord(STATUS_COUNT_RESULT, string(n), n))
            finally
                ss_release_reader!(ss, reader)
            end
        end
        work_ok("ACK. Starting Count")
    catch e
        work_error(400, "count: $e")
    end
end

# =====================================================================
# explore — mirrors ExploreCmd + do_bfs in commands.rs
# GET /explore/<expr_sexpr>/<focus_token_bytes>
# Returns JSON: [{"token":[bytes],"cnt":N,"expr":"..."}]
# focus_token is opaque bytes for iterative exploration.
# =====================================================================
function cmd_explore(ss::ServerSpace, args::Vector{String}, props::Dict{String,String}, body::Vector{UInt8})
    isempty(args) && return work_error(400, "explore: expected expr argument")
    expr_str = args[1]
    # Empty token = begin exploration from root. Trailing '/' in URL creates
    # empty segment which is filtered out — treat missing token as UInt8[].
    # Non-empty token is opaque bytes from a prior /explore response;
    # use codeunits (not String) to handle non-UTF-8 byte values correctly.
    focus_token = length(args) >= 2 ? Vector{UInt8}(codeunits(args[2])) : UInt8[]

    try
        expr   = sexpr_to_expr(expr_str)
        prefix = _derive_prefix(expr)
        reader = ss_new_reader(ss, prefix)
        reader === nothing && return work_error(503, "explore: path is locked")

        result_pairs = try
            space_token_bfs(ss.space, focus_token, expr)
        finally
            ss_release_reader!(ss, reader)
        end

        # Mirrors do_bfs JSON output: [{"token":[bytes], "cnt":N, "expr":"..."}]
        # cnt is the downstream child count from token_bfs_impl (upstream dbf9d50)
        # — lets the client decide whether further exploration is fruitful.
        io = IOBuffer()
        write(io, "[")
        first = true
        for (new_tok, e, cnt) in result_pairs
            first || write(io, ",\n")
            first = false
            tok_bytes = join(string.(new_tok), ", ")
            expr_str  = expr_serialize(e.buf)
            write(io, "{\"token\": [$tok_bytes], \"cnt\": $cnt, \"expr\": $(JSON3.write(expr_str))}")
        end
        write(io, "]")
        work_ok(take!(io))
    catch e
        work_error(400, "explore: $e")
    end
end

# =====================================================================
# export — mirrors ExportCmd + do_export + dump_as_format in commands.rs
# GET /export/<pattern_sexpr>/<template_sexpr>?format=metta&max_write=N
# Returns serialized atoms matching pattern/template.
# =====================================================================
function cmd_export(ss::ServerSpace, args::Vector{String}, props::Dict{String,String}, body::Vector{UInt8})
    length(args) < 2 && return work_error(400, "export: expected pattern and template")
    pat_str  = args[1]
    tpl_str  = args[2]
    fmt_str  = get(props, "format", "metta")
    fmt      = dataformat_from_str(fmt_str)
    fmt === nothing && return work_error(400, "export: unrecognized format '$fmt_str'")
    max_write = tryparse(Int, get(props, "max_write", "")) |> x -> x === nothing ? typemax(Int) : x

    try
        pat    = sexpr_to_expr(pat_str)
        tpl    = sexpr_to_expr(tpl_str)
        prefix = _derive_prefix(pat)
        reader = ss_new_reader(ss, prefix)
        reader === nothing && return work_error(503, "export: path is locked")

        io = IOBuffer()
        try
            if fmt == FMT_METTA
                space_dump_sexpr(ss.space, pat, tpl, io)
            elseif fmt == FMT_RAW
                rz = read_zipper_at_path(ss.space.btm, prefix)
                n  = 0
                while zipper_to_next_val!(rz) && n < max_write
                    println(io, repr(collect(zipper_path(rz))))
                    n += 1
                end
            elseif fmt == FMT_PATHS
                space_backup_paths(ss.space, io)
            else
                write(io, "Export Error: Unimplemented Export Format")
            end
        finally
            ss_release_reader!(ss, reader)
        end
        work_ok(take!(io))
    catch e
        work_error(500, "export: $e")
    end
end

# =====================================================================
# import — mirrors ImportCmd + do_import in commands.rs
# GET /import/<pattern_sexpr>/<template_sexpr>?uri=<url>&format=metta
# Returns "ACK. Starting Import" immediately; loads data in background.
# =====================================================================
function cmd_import(ss::ServerSpace, args::Vector{String}, props::Dict{String,String}, body::Vector{UInt8})
    length(args) < 2 && return work_error(400, "import: expected pattern and template")
    pat_str = args[1]
    tpl_str = args[2]
    uri     = get(props, "uri", "")
    isempty(uri) && return work_error(400, "import: missing uri property")
    fmt_str = get(props, "format", "metta")
    fmt     = dataformat_from_str(fmt_str)
    fmt === nothing && return work_error(400, "import: unrecognized format '$fmt_str'")

    try
        pat    = sexpr_to_expr(pat_str)
        tpl    = sexpr_to_expr(tpl_str)
        # Lock at template prefix (not root) — mirrors till_constant_to_full in upstream
        tpl_prefix = _derive_prefix(tpl)
        writer = ss_new_writer(ss, tpl_prefix)
        writer === nothing && return work_error(503, "import: space is locked for writing")

        cmd_id      = _ss_next_cmd_id!(ss)
        file_handle = rs_new_resource(ss.resource_store, uri, cmd_id)

        Threads.@spawn begin
            try
                # Fetch URL → write to disk
                resp = try
                    HTTP.get(uri; readtimeout=30)
                catch e
                    ss_set_status!(ss, tpl_prefix, StatusRecord(STATUS_FETCH_ERROR, "fetch failed: $e"))
                    close(file_handle)
                    return
                end
                if resp.status < 200 || resp.status >= 300
                    ss_set_status!(ss, tpl_prefix, StatusRecord(STATUS_FETCH_ERROR, "HTTP $(resp.status)"))
                    close(file_handle)
                    return
                end
                data = resp.body
                write(rh_path(file_handle), data)

                # Detect format from URI extension (mirrors detect_file_type in upstream).
                # If the ?format= property was explicitly set use it; otherwise auto-detect.
                # Unknown extensions (e.g. .md, .txt) → parseError immediately.
                uri_lc = lowercase(uri)
                detect_fmt = if fmt != FMT_METTA
                    fmt   # explicitly set by caller
                elseif endswith(uri_lc, ".metta")
                    FMT_METTA
                elseif endswith(uri_lc, ".csv")
                    FMT_CSV
                elseif endswith(uri_lc, ".json")
                    FMT_JSON
                else
                    # Unknown extension — cannot determine format → parseError
                    ss_set_status!(ss, tpl_prefix,
                        StatusRecord(STATUS_PARSE_ERROR, "unrecognized file format for URI: $uri"))
                    close(file_handle)
                    return
                end

                try
                    if detect_fmt == FMT_METTA
                        space_add_sexpr!(ss.space, data, pat, tpl)
                    elseif detect_fmt == FMT_CSV
                        space_load_csv!(ss.space, data, pat, tpl)
                    elseif detect_fmt == FMT_JSON
                        space_load_json!(ss.space, data)
                    end
                    rh_finalize!(file_handle, UInt64(time_ns()))
                    # On success writer release → status reverts to pathClear automatically
                catch pe
                    ss_set_status!(ss, tpl_prefix,
                        StatusRecord(STATUS_PARSE_ERROR, "parse failed: $pe"))
                    close(file_handle)
                end
            catch e
                @error "import spawn error" exception=(e, catch_backtrace())
                ss_set_status!(ss, tpl_prefix, StatusRecord(STATUS_FETCH_ERROR, "import error: $e"))
                close(file_handle)
            finally
                ss_release_writer!(ss, writer)
            end
        end
        work_ok("ACK. Starting Import")
    catch e
        work_error(400, "import: $e")
    end
end

# =====================================================================
# upload — mirrors UploadCmd + do_parse in commands.rs
# POST /upload/<pattern_sexpr>/<template_sexpr>?format=metta
# Body = raw data to parse. Returns "ACK. Upload Successful".
# =====================================================================
function cmd_upload(ss::ServerSpace, args::Vector{String}, props::Dict{String,String}, body::Vector{UInt8})
    length(args) < 2 && return work_error(400, "upload: expected pattern and template")
    pat_str  = args[1]
    tpl_str  = args[2]
    fmt_str  = get(props, "format", "metta")
    fmt      = dataformat_from_str(fmt_str)
    fmt === nothing && return work_error(400, "upload: unrecognized format '$fmt_str'")

    try
        pat    = sexpr_to_expr(pat_str)
        tpl    = sexpr_to_expr(tpl_str)
        writer = ss_new_writer(ss, UInt8[])
        writer === nothing && return work_error(503, "upload: space is locked for writing")
        try
            if fmt == FMT_METTA
                space_add_sexpr!(ss.space, body, pat, tpl)
            elseif fmt == FMT_CSV
                space_load_csv!(ss.space, body, pat, tpl)
            elseif fmt == FMT_JSON
                space_load_json!(ss.space, body)
            else
                return work_error(501, "upload: unimplemented format '$fmt_str'")
            end
        finally
            ss_release_writer!(ss, writer)
        end
        work_ok("ACK. Upload Successful")
    catch e
        work_error(400, "upload: $e")
    end
end

# =====================================================================
# transform — mirrors TransformCmd + pattern_template_args in commands.rs
# POST /transform
# Body = "(transform (, pat...) (, tpl...))"
# Returns "ACK. TranformMultiMulti dispatched" [sic — matches upstream typo]
# =====================================================================
function cmd_transform(ss::ServerSpace, args::Vector{String}, props::Dict{String,String}, body::Vector{UInt8})
    isempty(body) && return work_error(400, "transform: empty POST body")
    try
        src    = String(body)
        # Parse (transform <pat_conjunction> <tpl_conjunction>)
        # Pass the FULL conjunction expressions to space_transform_multi_multi!,
        # exactly as space_interpret! does — do NOT split the comma list.
        outer  = sexpr_to_expr(src)
        eargs  = ExprEnv[]
        ee_args!(ExprEnv(UInt8(0), UInt8(0), UInt32(0), outer), eargs)
        length(eargs) >= 3 || return work_error(400, "transform: expected (transform (, pats...) (, tpls...))")
        pat_expr = MORK.Expr(Vector{UInt8}(expr_span(eargs[2].base, Int(eargs[2].offset)+1)))
        tpl_expr = MORK.Expr(Vector{UInt8}(expr_span(eargs[3].base, Int(eargs[3].offset)+1)))

        writer = ss_new_writer(ss, UInt8[])
        writer === nothing && return work_error(503, "transform: space is locked")

        Threads.@spawn begin
            try
                space_transform_multi_multi!(ss.space, pat_expr, UInt8(0), tpl_expr, UInt8(0), pat_expr)
            catch e
                @error "transform spawn error" exception=(e, catch_backtrace())
                ss_set_status!(ss, UInt8[], StatusRecord(STATUS_FETCH_ERROR, "transform error: $e"))
            finally
                ss_release_writer!(ss, writer)
            end
        end
        work_ok("ACK. TranformMultiMulti dispatched")
    catch e
        work_error(400, "transform: $e")
    end
end

# =====================================================================
# status — mirrors StatusCmd in commands.rs
# GET /status/<expr_sexpr>
# Returns JSON status for the expression's path. Synchronous.
# =====================================================================
function cmd_status(ss::ServerSpace, args::Vector{String}, props::Dict{String,String}, body::Vector{UInt8})
    expr_str = isempty(args) ? "" : join(args, "/")
    prefix   = isempty(expr_str) ? UInt8[] : try
        _derive_prefix(sexpr_to_expr(expr_str))
    catch
        UInt8[]
    end
    status = ss_get_status(ss, prefix)
    work_ok(status_to_json(status))
end

# =====================================================================
# stop — mirrors StopCmd in commands.rs
# GET /stop  or  GET /stop?wait_for_idle
# Sets stop flag. Returns ACK.
# =====================================================================
function cmd_stop(ss::ServerSpace, args::Vector{String}, props::Dict{String,String}, body::Vector{UInt8})
    wait = haskey(props, "wait_for_idle")
    sm_shutdown!(ss.status_map)
    if wait
        work_ok("ACK. Shutdown will occur when server activity stops")
    else
        work_ok("ACK. Initiating Shutdown.  Connections will not longer be accepted")
    end
end

# =====================================================================
# metta_thread — mirrors MettaThreadCmd in commands.rs
# GET /metta_thread?location=<sexpr>
# Runs metta_calculus at location until exhausted. Returns ACK.
# Result/errors stored in status_map at (exec <location>).
# =====================================================================
function cmd_metta_thread(ss::ServerSpace, args::Vector{String}, props::Dict{String,String}, body::Vector{UInt8})
    location_str = get(props, "location", "")
    isempty(location_str) && return work_error(501,
        "Thread ID substitution is work in progress. Use the `location` property with a constant, e.g. `?location=task_name`.")

    try
        loc_expr = sexpr_to_expr(location_str)
        status_loc_str = "(exec $location_str)"
        # Use MORK expression bytes (not raw ASCII) so cmd_status can look it up.
        # cmd_status derives prefix via _derive_prefix(sexpr_to_expr(expr_str)),
        # so the key must be the constant prefix of the s-expression "(exec <loc>)".
        status_loc = _derive_prefix(sexpr_to_expr(status_loc_str))

        # Acquire write lock on status location — ensures only one thread runs at that location
        writer = ss_new_writer(ss, status_loc)
        writer === nothing && return work_error(409, "Thread is already running at that location.")

        Threads.@spawn begin
            try
                space_metta_calculus_at!(ss.space, location_str, typemax(Int))
            catch e
                ss_set_status!(ss, status_loc, StatusRecord(STATUS_EXEC_ERROR, string(e)))
            finally
                ss_release_writer!(ss, writer)
            end
        end
        work_ok("Thread `$location_str` was dispatched. Errors will be found at the status location: `$status_loc_str`")
    catch e
        work_error(400, "metta_thread: $e")
    end
end

# =====================================================================
# metta_thread_suspend — mirrors MettaThreadSuspendCmd in commands.rs
# GET /metta_thread_suspend/<exec_loc>/<suspend_loc>
# Moves exec expressions from exec_loc to suspend_loc.
# =====================================================================
function cmd_metta_thread_suspend(ss::ServerSpace, args::Vector{String}, props::Dict{String,String}, body::Vector{UInt8})
    length(args) < 2 && return work_error(400, "metta_thread_suspend: expected exec_location and suspend_location")
    exec_loc_str    = args[1]   # thread location to suspend
    suspend_loc_str = args[2]   # where to store suspended execs

    try
        # Validate both are ground (no variables)
        exec_loc_expr    = sexpr_to_expr(exec_loc_str)
        suspend_loc_expr = sexpr_to_expr(suspend_loc_str)

        # Derive prefixes
        # exec_prefix    = constant prefix of "(exec (exec_loc $) $ $)"
        # suspend_prefix = constant prefix of "(suspend_loc $x)"
        exec_prefix_str    = "(exec ($exec_loc_str \$) \$ \$)"
        suspend_prefix_str = "($suspend_loc_str \$x)"
        exec_prefix    = _derive_prefix(sexpr_to_expr(exec_prefix_str))
        suspend_prefix = _derive_prefix(sexpr_to_expr(suspend_prefix_str))

        # Acquire writer at suspend_prefix; clear any prior suspended state
        suspend_writer = ss_new_writer(ss, suspend_prefix)
        suspend_writer === nothing && return work_error(409, "metta_thread_suspend: suspend location is locked")

        try
            # Clear prior suspended atoms at suspend_prefix
            old_paths = Vector{UInt8}[]
            rz0 = read_zipper_at_path(ss.space.btm, suspend_prefix)
            while zipper_to_next_val!(rz0); push!(old_paths, copy(rz0.prefix_buf)); end
            for p in old_paths; remove_val_at!(ss.space.btm, p); end

            # Try to acquire writer on exec_prefix (blocks the running thread)
            exec_writer = ss_new_writer(ss, exec_prefix)
            if exec_writer === nothing
                # Couldn't acquire — thread is actively running; retry with spin
                deadline = time() + 2.0
                while exec_writer === nothing && time() < deadline
                    sleep(0.01)
                    exec_writer = ss_new_writer(ss, exec_prefix)
                end
                exec_writer === nothing && return work_error(409, "metta_thread_suspend: exec location is locked (thread still running)")
            end

            try
                # Check if thread already stopped (no reader means no active thread)
                status_loc = _derive_prefix(sexpr_to_expr("(exec $exec_loc_str)"))

                # Collect all exec atoms at exec_prefix and move to suspend_prefix
                exec_paths = Vector{UInt8}[]
                rz = read_zipper_at_path(ss.space.btm, exec_prefix)
                while zipper_to_next_val!(rz)
                    push!(exec_paths, copy(rz.prefix_buf))
                end

                if isempty(exec_paths)
                    return work_error(410, "metta_thread_suspend: thread already exhausted, no exec atoms to suspend")
                end

                # Rename exec atoms: change thread ID from exec_loc → suspend_loc.
                # (exec (exec_loc p) pats tpls) → (exec (suspend_loc p) pats tpls)
                # This lets metta_thread?location=suspend_loc resume them directly.
                # rel_path = bytes AFTER exec_prefix (priority + patterns + templates bytes)
                suspend_exec_prefix = _derive_prefix(sexpr_to_expr("(exec ($suspend_loc_str \$) \$ \$)"))
                for path in exec_paths
                    remove_val_at!(ss.space.btm, path)
                    rel_path = path[length(exec_prefix)+1:end]
                    new_path = vcat(suspend_exec_prefix, rel_path)
                    set_val_at!(ss.space.btm, new_path, UNIT_VAL)
                end

                work_ok("Ack. Thread $exec_loc_str cleared, now frozen at `($suspend_loc_str (exec ($exec_loc_str \$priorities) \$patterns \$templates))`")
            finally
                ss_release_writer!(ss, exec_writer)
            end
        finally
            ss_release_writer!(ss, suspend_writer)
        end
    catch e
        work_error(400, "metta_thread_suspend: $e")
    end
end

# =====================================================================
# status_stream — mirrors StatusStreamCmd in commands.rs
# GET /status_stream/<expr_sexpr>
# Returns Server-Sent Events (SSE) stream of status changes for a path.
# Sends current status immediately, then streams any changes for up to
# SSE_TIMEOUT_S seconds.  Mirrors StatusStreamCmd::work in commands.rs.
# =====================================================================

const SSE_TIMEOUT_S = 10.0   # max time to collect stream events

function cmd_status_stream(ss::ServerSpace, args::Vector{String}, props::Dict{String,String}, body::Vector{UInt8})
    expr_str = isempty(args) ? "" : join(args, "/")
    prefix   = isempty(expr_str) ? UInt8[] : try
        _derive_prefix(sexpr_to_expr(expr_str))
    catch
        UInt8[]
    end

    # Create a buffered channel for status events — mirrors mpsc::channel(100)
    ch = Channel{StatusRecord}(100)

    # Send current status immediately (mirrors tx.send(status).await)
    current = ss_get_status(ss, prefix)
    put!(ch, current)

    # Register channel in StatusMap streams so we receive future updates
    stream_id = UInt64(objectid(ch))
    sm_add_stream!(ss.status_map, prefix, ch)

    # Return a stream WorkResult — the server will drain the channel
    # and format each StatusRecord as an SSE "data: ..." event.
    # Mirrors WorkResult::Streamed in the upstream.
    work_stream(ch)
end

# =====================================================================
# COMMAND_TABLE — maps URL path → (fn, method)
# Mirrors the dispatch! macro in server/src/main.rs
# =====================================================================

const COMMAND_TABLE = Dict{String, Tuple{Symbol, Function}}(
    "busywait"              => (:GET,  cmd_busywait),
    "clear"                 => (:GET,  cmd_clear),
    "copy"                  => (:GET,  cmd_copy),
    "count"                 => (:GET,  cmd_count),
    "explore"               => (:GET,  cmd_explore),
    "export"                => (:GET,  cmd_export),
    "import"                => (:GET,  cmd_import),
    "status"                => (:GET,  cmd_status),
    "status_stream"         => (:GET,  cmd_status_stream),
    "stop"                  => (:GET,  cmd_stop),
    "metta_thread"          => (:GET,  cmd_metta_thread),
    "metta_thread_suspend"  => (:GET,  cmd_metta_thread_suspend),
    "transform"             => (:POST, cmd_transform),
    "upload"                => (:POST, cmd_upload),
)

export WorkResult, DataFormat, COMMAND_TABLE
export FMT_METTA, FMT_CSV, FMT_JSON, FMT_JSONL, FMT_RAW, FMT_PATHS
export work_ok, work_error, work_stream, dataformat_from_str
export cmd_busywait, cmd_clear, cmd_copy, cmd_count, cmd_explore
export cmd_export, cmd_import, cmd_upload, cmd_transform
export cmd_status, cmd_stop, cmd_metta_thread, cmd_metta_thread_suspend
