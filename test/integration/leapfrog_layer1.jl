# Leapfrog LAYER 1 — the byte-scan and the resumable subterm parser.
#
# Upstream builds this join "bottom-up, each layer validated before the next". This file is that
# validation for layer 1, and it exists BEFORE the cursor or the join is written, so a defect here
# cannot be discovered through three layers of indirection later.
#
# 🔑 THE ORACLE IS OUR OWN EXPRESSION MACHINERY, NOT THE PARSER ITSELF. `is_complete` answers "do
# these bytes spell exactly one subterm?"; `_expr_end_offset` already answers "where does the
# subterm at this offset end?" — independently, by a different traversal, written long before this.
# Testing the parser against hand-written literals would only prove it agrees with my arithmetic.
# Testing it against `_expr_end_offset` proves it agrees with the encoding the ENGINE uses.
# [[feedback_verify_the_oracle_runs]] · [[feedback_oracle_must_observe_the_defect_class]]

using MORK, Test
const _LF = MORK.Leapfrog

_lf_buf(s::AbstractString) = MORK.sexpr_to_expr(s).buf

@testset "leapfrog layer 1 — subterm parse + byte seek" begin

    @testset "subterm_parse_step is allocation-free and isbits" begin
        # The whole reason we return a tuple instead of threading upstream's `&mut u32` out-params.
        # If this ever allocates, the cursor's inner loop has a heap write per BYTE and the join is
        # dead on arrival — which is precisely the defect class we are adopting leapfrog to escape.
        (s, p) = _LF.PARSE_START
        b = UInt8(0xC0)
        _LF.subterm_parse_step(b, s, p)                       # warm
        @test @allocated(_LF.subterm_parse_step(b, s, p)) == 0
        @test isbits(_LF.subterm_parse_step(b, s, p))
        @test _LF.PARSE_START === (UInt32(1), UInt32(0))
    end

    @testset "is_complete agrees with _expr_end_offset on real expressions" begin
        # ⚠️ ANTI-VACUITY FIRST. If these did not parse, every assertion below would hold over empty
        # buffers and the testset would be green for the wrong reason.
        srcs = ["(edge a b)", "a", "(f (g h) i)", "(edge \$x \$y)", "\$x",
            "(, (edge \$x0 \$x1) (edge \$x1 \$x2))", "(deeply (nested (thing (here x))))"]
        @test all(!isempty(_lf_buf(s)) for s in srcs)

        for s in srcs
            buf = _lf_buf(s)
            n = MORK._expr_end_offset(buf, 1) - 1          # end offset is exclusive, 1-based
            @test 1 <= n <= length(buf)
            # THE claim: complete exactly at the boundary the engine's own parser reports.
            @test _LF.is_complete(view(buf, 1:n))
            # …and NOT complete one byte short — the negative twin. A parser that returned `true`
            # unconditionally would pass every assertion above and fail this one.
            n > 1 && @test !_LF.is_complete(view(buf, 1:(n - 1)))
        end
    end

    @testset "incremental state matches the from-scratch replay, byte for byte" begin
        # The cursor will carry (owed_subterms, owed_payload) incrementally and NEVER replay. That
        # is only safe if folding one byte at a time is identical to re-running the whole prefix —
        # upstream keeps `is_complete` as exactly this cross-check under debug_assertions.
        for s in ["(f (g h) i)", "(, (edge \$x0 \$x1) (edge \$x1 \$x2))", "(sym abcdef)"]
            buf = _lf_buf(s)
            (cs, cp) = _LF.PARSE_START
            for i in eachindex(buf)
                (cs, cp) = _LF.subterm_parse_step(buf[i], cs, cp)
                # replay from scratch over the same prefix
                (rs, rp) = _LF.PARSE_START
                for j in 1:i
                    (rs, rp) = _LF.subterm_parse_step(buf[j], rs, rp)
                end
                @test (cs, cp) == (rs, rp)
                # and the O(1) boundary test must equal the O(L) one
                @test (cs == 0 && cp == 0) == _LF.is_complete(view(buf, 1:i))
            end
        end
    end

    @testset "a symbol's payload bytes are consumed as raw, not re-tagged" begin
        # The `payload > 0` arm is what stops a symbol's PAYLOAD being read as a tag. Get this wrong
        # and a symbol whose bytes happen to look like an Arity byte grows phantom subterms — the
        # exact shape of upstream's RelExprEnv::eq panic ("reserved 97"/"reserved 69" are 'a'/'E',
        # payload read as tags), one layer down.
        buf = _lf_buf("(sym abc)")
        @test _LF.is_complete(buf)
        # walk it and assert the parser is INSIDE a payload where the symbol's bytes live
        (s, p) = _LF.PARSE_START
        sawpayload = false
        for b in buf
            (s, p) = _LF.subterm_parse_step(b, s, p)
            p > 0 && (sawpayload = true)
        end
        @test sawpayload            # if never, this test proves nothing about the payload arm
        @test (s, p) == (UInt32(0), UInt32(0))
    end

    @testset "least_ge — and the `k` itself case upstream flags" begin
        # ⚠️ `ByteMask` is IMMUTABLE (Utils.jl:213 — a struct wrapping Bits4), so it is built by
        # folding `with_bit_set` over the Bits4, not by mutating. My first draft called
        # `set_bit(m, b)` and the testset ERRORED rather than failing, which is the more useful
        # outcome: an assertion that cannot run proves nothing at all.
        bits = PathMap.EMPTY_BITS4
        for b in (0x10, 0x40, 0x41, 0xFE)
            bits = PathMap.with_bit_set(bits, UInt8(b))
        end
        m = PathMap.ByteMask(bits)
        @test PathMap.test_bit(m, 0x40) && !PathMap.test_bit(m, 0x11)   # the mask is what I think

        # 🔴 THE LOAD-BEARING ONE. `next_bit` is STRICTLY above its argument, so a seek to a byte
        # that IS present must be answered with that byte. Delegating straight to `next_bit` would
        # skip it, and the join would silently drop every answer at that key — a wrong-ANSWER bug
        # that no crash reports.
        @test _LF.least_ge(m, 0x40) === 0x40
        @test _LF.least_ge(m, 0x10) === 0x10

        @test _LF.least_ge(m, 0x00) === 0x10       # below everything -> least present
        @test _LF.least_ge(m, 0x11) === 0x40       # between -> next above
        @test _LF.least_ge(m, 0x42) === 0xFE
        @test _LF.least_ge(m, 0xFE) === 0xFE       # at the top, present
        @test _LF.least_ge(m, 0xFF) === nothing    # above everything -> exhausted

        # an empty mask never yields, at any k — the cursor's exhaustion path depends on it
        e = PathMap.ByteMask()
        @test _LF.least_ge(e, 0x00) === nothing
        @test _LF.least_ge(e, 0xFF) === nothing
    end
end
