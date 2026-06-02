# MorkL — port of experiments/morkl_interpreter/ (server branch)
#
# A register-based VM for relational trie algebra over PathMap spaces.
# NOT a MeTTa interpreter — computes relational queries (Union, Intersection,
# Subtraction, Restriction, Wrap, Unwrap, DropHead, ...) over BytesTrieMap.
#
# Example: the Aunt query in comments of lib.rs computes aunt relationships
# from family/people spaces using trie lattice operations.
#
# Status: VM execution fully ported and tested (CfIter, Interpreter, run_routine,
# all trie algebra ops). Text parser intentionally absent — upstream Rust also has
# todo!() for parse_routine_with_args_paths; routines are built programmatically.

# =====================================================================
# CfIter — port of cf_iter.rs
# Iterates set bits in a 256-bit mask (stored as [u64; 4]).
# =====================================================================

"""
    CfIter

Iterates bytes set in a 256-bit child mask (4 × UInt64 words).
Mirrors `CfIter` in cf_iter.rs.
"""
mutable struct CfIter
    i    ::UInt8
    w    ::UInt64
    mask ::NTuple{4, UInt64}
end

function CfIter(mask::NTuple{4,UInt64})
    CfIter(UInt8(0), mask[1], mask)
end

function cfiter_next!(it::CfIter) :: Union{UInt8, Nothing}
    while true
        if it.w != 0
            wi   = UInt8(trailing_zeros(it.w))
            it.w = xor(it.w, UInt64(1) << wi)
            idx  = it.i * UInt8(64) + wi
            return UInt8(idx)
        elseif it.i < 3
            it.i += UInt8(1)
            it.w  = it.mask[it.i + 1]  # 1-based in Julia
        else
            return nothing
        end
    end
end

# =====================================================================
# Op — port of Op enum in lib.rs
# =====================================================================

@enum Op begin
    OP_EMPTY
    OP_CALL
    OP_SINGLETON
    OP_UNION
    OP_INTERSECTION
    OP_SUBTRACTION
    OP_RESTRICTION
    OP_WRAP
    OP_UNWRAP
    OP_DROP_HEAD
    OP_EXTRACT_PATH_REF
    OP_EXTRACT_SPACE_MENTION
    OP_CONSTANT
    OP_CONCAT
    OP_ITER_SUBROUTINE
    OP_EXIT
end

# =====================================================================
# PathStoreReference — offset+len into a path buffer
# =====================================================================

struct PathStoreRef
    offset ::Int
    len    ::Int
end

PathStoreRef() = PathStoreRef(0, 0)
psr_range(r::PathStoreRef) = r.offset+1 : r.offset+r.len

# =====================================================================
# Instruction — one VM instruction
# =====================================================================

struct Instruction
    op              ::Op
    const_arg       ::PathStoreRef
    input_registers ::NTuple{4, UInt16}
end

Instruction(op::Op) = Instruction(op, PathStoreRef(), (UInt16(0),UInt16(0),UInt16(0),UInt16(0)))
Instruction(op::Op, c::PathStoreRef, r1::Int, r2::Int=0, r3::Int=0, r4::Int=0) =
    Instruction(op, c, (UInt16(r1), UInt16(r2), UInt16(r3), UInt16(r4)))

# =====================================================================
# RoutineImpl — compiled routine (const_paths + instructions)
# =====================================================================

struct RoutineImpl
    const_paths_store      ::Vector{UInt8}
    formal_parameter_count ::Int
    max_subroutine_depth   ::Int
    instructions           ::Vector{Instruction}
end

# =====================================================================
# Subroutine — one level of IterSubRoutine context
# =====================================================================

mutable struct Subroutine
    zipper_space             ::PathMap{UnitVal}
    read_zipper              ::ReadZipperCore
    iter                     ::CfIter
    subroutine_start_counter ::UInt16
    previous_program_counter ::UInt16
    prefix_first_byte        ::UInt8
end

function Base.copy(sr::Subroutine)
    new_rz = read_zipper_at_path(sr.zipper_space, collect(zipper_path(sr.read_zipper)))
    Subroutine(deepcopy(sr.zipper_space), new_rz, deepcopy(sr.iter),
               sr.subroutine_start_counter, sr.previous_program_counter, sr.prefix_first_byte)
end

# =====================================================================
# ParsedRoutine — parsed call with name index + arg indices
# =====================================================================

struct ParsedRoutine
    routine_name_index ::PathStoreRef
    arg_indices        ::Vector{PathStoreRef}
end

# =====================================================================
# RoutineActivationRecord — live execution state
# =====================================================================

mutable struct RoutineActivationRecord
    arg_offsets      ::ParsedRoutine
    routine_code     ::RoutineImpl
    program_counter  ::Int
    subroutine_stack ::Vector{Subroutine}
    space_reg        ::Vector{PathMap{UnitVal}}
    path_reg         ::Vector{PathStoreRef}
    path_buffer      ::Vector{UInt8}
end

# =====================================================================
# CallStack — call chain for continuation passing
# =====================================================================

mutable struct CallStack
    data    ::Vector{UInt8}
    offsets ::Vector{Int}
end

# =====================================================================
# Interpreter — main VM structure
# =====================================================================

"""
    Interpreter

Register-based VM for relational trie algebra.
Mirrors `Interpreter` in morkl_interpreter/src/lib.rs.
"""
mutable struct Interpreter
    memo                  ::PathMap{UnitVal}
    routines              ::Dict{Vector{UInt8}, RoutineImpl}
    routine_continuations ::Dict{Vector{UInt8}, RoutineActivationRecord}
end

Interpreter() = Interpreter(PathMap{UnitVal}(), Dict(), Dict())

"""Register a named routine."""
function interp_add_routine!(interp::Interpreter, name::AbstractVector{UInt8}, routine::RoutineImpl)
    interp.routines[collect(name)] = routine
end

# =====================================================================
# Helpers
# =====================================================================

_is_length_byte(b::UInt8) :: Bool = (b & 0b11000000) == 0

# OP_DROP_HEAD — strip the first length-byte-prefixed layer from every path.
# Ports Op::DropHead (experiments/morkl_interpreter/src/lib.rs:385): for each
# length-byte child b>0 at the root, descend to [b], drop_head(b) the subtrie
# below it, ascend; then drop_head(1) at the root. drop_head(n) == join_k_path_into(n).
# (The previous inline impl was an IDENTITY NO-OP — the "skip b bytes" was a comment
# in an empty if-body, so it returned a copy of the input unmodified. Audit M-1.)
function _morkl_drop_head(space::PathMap{UnitVal}) :: PathMap{UnitVal}
    out  = deepcopy(space)
    wz   = write_zipper(out)
    mask = wz_child_mask(wz)
    for b in iter(mask)
        (!_is_length_byte(b) || b == 0) && continue
        wz_descend_to!(wz, UInt8[b])
        wz_join_k_path_into!(wz, Int(b))   # drop_head(b)
        wz_ascend!(wz, 1)
    end
    wz_join_k_path_into!(wz, 1)            # drop_head(1) at the root
    out
end

function _descend_leading!(rz::ReadZipperCore, prefix_first_byte::UInt8)
    zipper_reset!(rz)
    zipper_descend_to!(rz, UInt8[prefix_first_byte])
    if _is_length_byte(prefix_first_byte) && prefix_first_byte > 0
        zipper_descend_to!(rz, zeros(UInt8, Int(prefix_first_byte)))
    end
end

# Binary space op helper
function _alg_to_pathmap(r, default::PathMap{UnitVal}) :: PathMap{UnitVal}
    r isa AlgResElement ? r.value : default
end

function _binary_space_op!(space_reg::Vector{PathMap{UnitVal}}, pc::Int,
                            arg0::Int, arg1::Int, op::Symbol)
    a = deepcopy(space_reg[arg0+1])
    b = space_reg[arg1+1]
    result = if op == :union;        pjoin(a, b)
             elseif op == :intersection; pmeet(a, b)
             elseif op == :subtraction;  psubtract(a, b)
             else                        prestrict(a, b)
             end
    space_reg[pc+1] = _alg_to_pathmap(result, PathMap{UnitVal}())
end

# =====================================================================
# ParsedRoutine stub (upstream has todo!())
# =====================================================================

"""
    parse_routine_with_args_paths(path) → ParsedRoutine

Parse a routine call path into name + argument indices.
NOTE: upstream has `todo!()` here — this is a stub.
"""
function parse_routine_with_args_paths(path::Vector{UInt8}) :: ParsedRoutine
    # Stub: treat entire path as the routine name, no args
    ParsedRoutine(PathStoreRef(0, length(path)), PathStoreRef[])
end

function path_from_offset(store::Vector{UInt8}, r::PathStoreRef) :: Vector{UInt8}
    store[psr_range(r)]
end

# =====================================================================
# run_routine — main VM execution loop
# Mirrors Interpreter::run_routine in lib.rs.
# =====================================================================

"""
    interp_has_memo(interp, path) → Bool

Check if a path is memoized in the interpreter's memo space.
"""
function interp_has_memo(interp::Interpreter, path::AbstractVector{UInt8}) :: Bool
    get_val_at(interp.memo, collect(path)) !== nothing
end

"""
    interp_get_memo(interp, path) → PathMap

Get the memoized result for a path (returns the full sub-trie).
"""
function interp_get_memo(interp::Interpreter, path::AbstractVector{UInt8}) :: PathMap{UnitVal}
    m = PathMap{UnitVal}()
    rz = read_zipper_at_path(interp.memo, collect(path))
    while zipper_to_next_val!(rz)
        set_val_at!(m, collect(zipper_path(rz)), UNIT_VAL)
    end
    m
end

"""
    interp_set_memo!(interp, path, result)

Store a result in the memo PathMap.
"""
function interp_set_memo!(interp::Interpreter, path::AbstractVector{UInt8},
                           result::PathMap{UnitVal})
    p = collect(path)
    rz = read_zipper(result)
    while zipper_to_next_val!(rz)
        set_val_at!(interp.memo, vcat(p, collect(zipper_path(rz))), UNIT_VAL)
    end
    isempty(p) || val_count(result) == 0 || set_val_at!(interp.memo, p, UNIT_VAL)
end

"""
    run_routine(interp, routine_with_arguments, fuel) → Union{PathMap, Symbol}

Execute a named routine. Returns the result PathMap or :not_found/:malformed.
Mirrors `Interpreter::run_routine`.
"""
function run_routine(interp::Interpreter, routine_with_arguments::AbstractVector{UInt8},
                     fuel::UInt64=typemax(UInt64)) :: Union{PathMap{UnitVal}, Symbol}

    SLICE_SIZE = 2
    call_stack = CallStack(collect(routine_with_arguments), Int[0, length(routine_with_arguments)])

    while true   # 'routine loop

        # ── 'find_memo block: check memo cache for current top-of-stack ─
        # Mirrors 'find_memo: { ... } in upstream
        popped_value = begin
            len   = length(call_stack.offsets)
            start = call_stack.offsets[len - SLICE_SIZE + 1]
            stop  = call_stack.offsets[len - SLICE_SIZE + 2]
            routine_path = call_stack.data[start+1 : stop]

            if interp_has_memo(interp, routine_path)
                m = interp_get_memo(interp, routine_path)
                if length(call_stack.offsets) == SLICE_SIZE
                    return m   # done — top-level result is memoized
                end
                # Pop call stack entry and return the memoized value upward
                resize!(call_stack.data, stop)
                pop!(call_stack.offsets)
                m
            else
                nothing
            end
        end

        # ── Restore or create activation record ───────────────────────
        len   = length(call_stack.offsets)
        start = call_stack.offsets[len - SLICE_SIZE + 1]
        stop  = call_stack.offsets[len - SLICE_SIZE + 2]
        cur_path = call_stack.data[start+1 : stop]

        record = if haskey(interp.routine_continuations, Vector{UInt8}(cur_path))
            pop!(interp.routine_continuations, Vector{UInt8}(cur_path))
        else
            arg_offsets = parse_routine_with_args_paths(cur_path)
            routine_name = path_from_offset(cur_path, arg_offsets.routine_name_index)

            if !haskey(interp.routines, Vector{UInt8}(routine_name))
                return :not_found
            end
            rc = interp.routines[Vector{UInt8}(routine_name)]
            n  = length(rc.instructions)
            RoutineActivationRecord(
                arg_offsets, rc, 0,
                Subroutine[],
                [PathMap{UnitVal}() for _ in 1:n],
                [PathStoreRef()     for _ in 1:n],
                UInt8[]
            )
        end

        if popped_value !== nothing
            record.space_reg[record.program_counter + 1] = popped_value
            record.program_counter += 1
        end

        rc          = record.routine_code
        pc_ref      = Ref(record.program_counter)
        sub_stack   = record.subroutine_stack
        space_reg   = record.space_reg
        path_reg    = record.path_reg
        path_buffer = record.path_buffer

        # ── Inner subroutine loop ─────────────────────────────────────
        while true   # 'subroutine loop
            if pc_ref[] >= length(rc.instructions)
                break
            end

            instr = rc.instructions[pc_ref[] + 1]  # 1-based
            op    = instr.op
            ca    = instr.const_arg
            regs  = instr.input_registers
            r0    = Int(regs[1])
            r1    = Int(regs[2])

            const_path() = ca.len > 0 ? rc.const_paths_store[psr_range(ca)] : UInt8[]

            if op == OP_EMPTY
                # no-op

            elseif op == OP_CALL
                path = path_buffer[psr_range(path_reg[r0+1])]
                if interp_has_memo(interp, path)
                    space_reg[pc_ref[]+1] = interp_get_memo(interp, path)
                else
                    # Push call onto call_stack, save continuation, continue 'routine
                    interp.routine_continuations[cur_path] = record
                    append!(call_stack.data, path)
                    push!(call_stack.offsets, length(call_stack.data))
                    break   # exit subroutine loop → continue 'routine
                end

            elseif op == OP_SINGLETON
                prefix = path_buffer[psr_range(path_reg[r0+1])]
                m = PathMap{UnitVal}()
                set_val_at!(m, prefix, UNIT_VAL)
                space_reg[pc_ref[]+1] = m

            elseif op == OP_UNION
                _binary_space_op!(space_reg, pc_ref[], r0, r1, :union)
            elseif op == OP_INTERSECTION
                _binary_space_op!(space_reg, pc_ref[], r0, r1, :intersection)
            elseif op == OP_SUBTRACTION
                _binary_space_op!(space_reg, pc_ref[], r0, r1, :subtraction)
            elseif op == OP_RESTRICTION
                _binary_space_op!(space_reg, pc_ref[], r0, r1, :restriction)

            elseif op == OP_WRAP
                prefix = path_buffer[psr_range(path_reg[r1+1])]
                out = PathMap{UnitVal}()
                src = space_reg[r0+1]
                rz  = read_zipper(src)
                wz  = write_zipper_at_path(out, prefix)
                while zipper_to_next_val!(rz)
                    p = collect(zipper_path(rz))
                    set_val_at!(out, vcat(prefix, p), UNIT_VAL)
                end
                space_reg[pc_ref[]+1] = out

            elseif op == OP_UNWRAP
                prefix = path_buffer[psr_range(path_reg[r1+1])]
                src = space_reg[r0+1]
                rz  = read_zipper_at_path(src, prefix)
                m   = PathMap{UnitVal}()
                while zipper_to_next_val!(rz)
                    set_val_at!(m, collect(zipper_path(rz)), UNIT_VAL)
                end
                if val_count(m) == 0
                    return :malformed
                end
                space_reg[pc_ref[]+1] = m

            elseif op == OP_DROP_HEAD
                space_reg[pc_ref[]+1] = _morkl_drop_head(space_reg[r0+1])

            elseif op == OP_EXTRACT_PATH_REF
                path = if !isempty(sub_stack)
                    collect(zipper_path(sub_stack[end].read_zipper))
                else
                    const_path()
                end
                old_len = length(path_buffer)
                append!(path_buffer, path)
                path_reg[pc_ref[]+1] = PathStoreRef(old_len, length(path))

            elseif op == OP_EXTRACT_SPACE_MENTION
                out = if !isempty(sub_stack)
                    deepcopy(sub_stack[end].zipper_space)
                else
                    cp = const_path()
                    m  = PathMap{UnitVal}()
                    # Copy paths from memo at this prefix
                    rz = read_zipper_at_path(interp.memo, cp)
                    while zipper_to_next_val!(rz)
                        set_val_at!(m, collect(zipper_path(rz)), UNIT_VAL)
                    end
                    m
                end
                if val_count(out) == 0
                    return :value_not_memoed
                end
                space_reg[pc_ref[]+1] = out

            elseif op == OP_CONSTANT
                old_len = length(path_buffer)
                cp = const_path()
                append!(path_buffer, cp)
                path_reg[pc_ref[]+1] = PathStoreRef(old_len, length(cp))

            elseif op == OP_CONCAT
                pr0 = path_reg[r0+1]
                pr1 = path_reg[r1+1]
                old_len = length(path_buffer)
                append!(path_buffer, path_buffer[psr_range(pr0)])
                append!(path_buffer, path_buffer[psr_range(pr1)])
                path_reg[pc_ref[]+1] = PathStoreRef(old_len, pr0.len + pr1.len)

            elseif op == OP_ITER_SUBROUTINE
                subr_start  = UInt16(r0)
                src_space   = space_reg[r1+1]
                zspace      = deepcopy(src_space)
                rz          = read_zipper(zspace)
                mask_tuple  = zipper_child_mask(rz)
                mask_arr    = (mask_tuple.bits[1], mask_tuple.bits[2], mask_tuple.bits[3], mask_tuple.bits[4])
                it          = CfIter(mask_arr)
                first_byte  = cfiter_next!(it)

                if first_byte === nothing
                    space_reg[pc_ref[]+1] = PathMap{UnitVal}()
                else
                    _descend_leading!(rz, first_byte)
                    push!(sub_stack, Subroutine(zspace, rz, it, subr_start,
                                                 UInt16(pc_ref[]), first_byte))
                    pc_ref[] = Int(subr_start)
                    continue  # skip pc increment
                end

            elseif op == OP_EXIT
                if isempty(sub_stack)
                    ret = space_reg[pc_ref[]]   # last written register (0-based pc index)
                    interp_set_memo!(interp, cur_path, ret)
                    return ret
                else
                    sr = pop!(sub_stack)
                    # Union result into parent
                    result = space_reg[pc_ref[]]
                    space_reg[Int(sr.previous_program_counter)+1] =
                        _alg_to_pathmap(pjoin(space_reg[Int(sr.previous_program_counter)+1], result), result)

                    # Advance iterator
                    if _is_length_byte(sr.prefix_first_byte) && sr.prefix_first_byte > 0 &&
                       zipper_to_next_val!(sr.read_zipper)
                        push!(sub_stack, Subroutine(sr.zipper_space, sr.read_zipper, sr.iter,
                                                     sr.subroutine_start_counter,
                                                     sr.previous_program_counter, sr.prefix_first_byte))
                        pc_ref[] = Int(sr.subroutine_start_counter)
                    else
                        next_b = cfiter_next!(sr.iter)
                        if next_b !== nothing
                            _descend_leading!(sr.read_zipper, next_b)
                            push!(sub_stack, Subroutine(sr.zipper_space, sr.read_zipper, sr.iter,
                                                         sr.subroutine_start_counter,
                                                         sr.previous_program_counter, next_b))
                            pc_ref[] = Int(sr.subroutine_start_counter)
                        else
                            pc_ref[] = Int(sr.previous_program_counter)
                        end
                    end
                    continue  # skip increment
                end
            end

            pc_ref[] += 1
        end  # 'subroutine

        # Save continuation if we broke out early (Call instruction)
        if pc_ref[] < length(rc.instructions)
            record.program_counter = pc_ref[]
            interp.routine_continuations[cur_path] = record
        else
            # Routine completed naturally
            n = length(rc.instructions)
            return n > 0 ? space_reg[n] : PathMap{UnitVal}()
        end
    end  # 'routine
end


# =====================================================================
# Exports
# =====================================================================

export CfIter, cfiter_next!
export Op, OP_EMPTY, OP_CALL, OP_SINGLETON
export OP_UNION, OP_INTERSECTION, OP_SUBTRACTION, OP_RESTRICTION
export OP_WRAP, OP_UNWRAP, OP_DROP_HEAD
export OP_EXTRACT_PATH_REF, OP_EXTRACT_SPACE_MENTION
export OP_CONSTANT, OP_CONCAT, OP_ITER_SUBROUTINE, OP_EXIT
export PathStoreRef, Instruction, RoutineImpl
export Interpreter, run_routine, interp_add_routine!
