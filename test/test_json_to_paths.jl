# test_json_to_paths.jl — Space::json_to_paths / jsonl_to_paths (ported 2026-07-31).
#
# These are the `*_to_paths` entry points: parse JSON and stream every resulting path straight into a
# zlib `.paths` stream WITHOUT ever building a trie. The equivalence that matters is therefore not a
# count but a SET: whatever `space_load_json!` would have inserted must be exactly what comes back
# out of the serialized stream. Counts alone would pass while the paths themselves were wrong.
using MORK, Test, PathMap

const M = MORK

"Every path in a PathMap, as a sorted set of byte vectors."
function _paths(m)
    z = PathMap.read_zipper(m)
    out = Vector{UInt8}[]
    while PathMap.zipper_to_next_val!(z)
        push!(out, collect(PathMap.zipper_path(z)))
    end
    sort!(out)
end

"Deserialize a `.paths` stream into a fresh PathMap."
function _from_paths(bytes)
    m = PathMap.PathMap{PathMap.UnitVal}()
    PathMap.deserialize_paths(m, IOBuffer(bytes), M.UNIT_VAL)
    m
end

@testset "json_to_paths / jsonl_to_paths" begin
    @testset "json_to_paths — same PATH SET as load_json!" begin
        for doc in ("{\"a\": 1, \"b\": [2, 3]}",
            "{\"x\": {\"y\": {\"z\": \"deep\"}}}",
            "[1, 2, 3]",
            "{\"t\": true, \"f\": false, \"n\": null}",
            "{\"e\": [], \"o\": {}}",
            "\"bare string\"")
            io = IOBuffer()
            n = M.space_json_to_paths(M.new_space(), doc, io)
            streamed = _paths(_from_paths(take!(io)))

            ref = M.new_space()
            M.space_load_json!(ref, doc)
            @test streamed == _paths(ref.btm)
            @test n == length(streamed)
        end
    end

    @testset "jsonl_to_paths — and an UPSTREAM INCONSISTENCY it exposes" begin
        # 🔴 upstream's two JSONL writers disagree on the line index, and only one is well-formed:
        #
        #   load_jsonl     (space.rs:628)  wz.descend_to(lines.to_be_bytes())      8 bytes, NO tag
        #   jsonl_to_paths (space.rs:596)  push(SymbolSize(8)); extend(to_be_bytes) 8 bytes, TAGGED
        #
        # Settled by execution, not by reading. The untagged path
        # `[3] (5)JSONL 00*8 [2] (1)a (1)1` parses as an expression only 9 BYTES long, rendering
        # `(JSONL () ())` — the first two zero index bytes are consumed as two Arity(0) empties,
        # which satisfies the Arity(3), and the remaining 6 index bytes AND THE ENTIRE DOCUMENT sit
        # outside the expression span. It survives as a trie KEY (still unique per line) but does not
        # read back. `jsonl_to_paths` writes a `.paths` stream meant to be deserialized, and tags it.
        #
        # Both of ours mirror their own upstream function, so this pins the DIFFERENCE rather than
        # papering over it: "fixing" space_load_jsonl! would break parity with the binary.
        src = "{\"a\": 1}\n{\"b\": 2}\n{\"c\": 3}\n"
        io = IOBuffer()
        (lines, count) = M.space_jsonl_to_paths(M.new_space(), src, io)
        streamed = _paths(_from_paths(take!(io)))

        ref = M.new_space()
        M.space_load_jsonl!(ref, src)
        reference = _paths(ref.btm)

        @test lines == 3
        @test count == length(streamed)
        @test length(streamed) == length(reference)

        # they differ ONLY by the SymbolSize(8) tag at offset 8
        for (a, b) in zip(streamed, reference)
            @test a[1:7] == b[1:7]                       # [3] (5)JSONL
            @test a[8] == M.item_byte(M.ExprSymbol(0x08))
            @test a[9:end] == b[8:end]                   # index bytes + document, identical
        end

        # ours is the well-formed one: the span covers the WHOLE path
        @test length(collect(M.expr_span(M.Expr(streamed[1]), 1))) == length(streamed[1])
        # upstream's load_jsonl shape stops early, leaving the document outside the expression
        @test length(collect(M.expr_span(M.Expr(reference[1]), 1))) < length(reference[1])
    end

    @testset "empty input" begin
        io = IOBuffer()
        @test M.space_jsonl_to_paths(M.new_space(), "", io) == (0, 0)
    end
end
