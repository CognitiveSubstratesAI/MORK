# morkl.jl — port of experiments/morkl_interpreter/ (server branch)
# Tests the MorkL register-based VM for relational trie algebra.
using MORK, PathMap, Test

is_pm(x) = x isa PathMap.PathMap

@testset "MorkL CfIter — 256-bit bitmask iterator" begin
    # bits 0,1,3 set in first word
    mask = (UInt64(0b1011), UInt64(0), UInt64(0), UInt64(0))
    it = CfIter(mask)
    bits = UInt8[]
    for _ in 1:10

        b = cfiter_next!(it)
        b === nothing && break
        push!(bits, b)
    end
    @test bits == UInt8[0, 1, 3]

    # bits in second word: bit 64
    mask2 = (UInt64(0), UInt64(1), UInt64(0), UInt64(0))
    it2 = CfIter(mask2)
    b2 = cfiter_next!(it2)
    @test b2 == UInt8(64)
end

@testset "MorkL VM — SINGLETON" begin
    cs = UInt8[UInt8('a')]
    instrs = [Instruction(OP_CONSTANT, PathStoreRef(0, 1), 0),
        Instruction(OP_SINGLETON, PathStoreRef(), 0, 0),
        Instruction(OP_EXIT)]
    interp = Interpreter()
    interp_add_routine!(interp, b"r1", RoutineImpl(cs, 0, 0, instrs))
    r = run_routine(interp, b"r1")
    @test is_pm(r)
    @test val_count(r) == 1
end

@testset "MorkL VM — UNION of two singletons" begin
    cs = UInt8[UInt8('a'), UInt8('b')]
    instrs = [Instruction(OP_CONSTANT, PathStoreRef(0, 1), 0),   # path[0]="a"
        Instruction(OP_SINGLETON, PathStoreRef(), 0, 0),     # space[1]={a}
        Instruction(OP_CONSTANT, PathStoreRef(1, 1), 0),   # path[2]="b"
        Instruction(OP_SINGLETON, PathStoreRef(), 2, 0),     # space[3]={b}
        Instruction(OP_UNION, PathStoreRef(), 1, 3),     # space[4]={a,b}
        Instruction(OP_EXIT)]
    interp = Interpreter()
    interp_add_routine!(interp, b"r2", RoutineImpl(cs, 0, 0, instrs))
    r = run_routine(interp, b"r2")
    @test is_pm(r)
    @test val_count(r) == 2
end

@testset "MorkL VM — memo cache reuse" begin
    # Run the same routine twice — second call should hit memo
    cs = UInt8[UInt8('x')]
    instrs = [Instruction(OP_CONSTANT, PathStoreRef(0, 1), 0),
        Instruction(OP_SINGLETON, PathStoreRef(), 0, 0),
        Instruction(OP_EXIT)]
    interp = Interpreter()
    interp_add_routine!(interp, b"memo_r", RoutineImpl(cs, 0, 0, instrs))
    r1 = run_routine(interp, b"memo_r")
    r2 = run_routine(interp, b"memo_r")   # should hit memo
    @test is_pm(r1) && is_pm(r2)
    @test val_count(r1) == val_count(r2) == 1
end
