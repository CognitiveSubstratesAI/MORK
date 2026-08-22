# unit_sink_request.jl — pins `sink_request`, the WRITE ROOT each sink asks for.
#
# WHY THIS EXISTS. Root-doubling (~15 conformance probes) needs upstream's write-rooting model:
# every BTM sink gets a WriteZipper rooted at its own expression's ground prefix minus the keyword
# header (`Sink::request()`, sinks.rs). We have never had that. A previous attempt skipped straight
# to the write side — prepending the root in reduction branches 1+2 — and was MEASURED to fix 11
# probes and BREAK 16 (corpus 237->232). It conflated WHAT THE ROOT IS with HOW IT IS WRITTEN.
#
# So the root is landed alone and pinned here, against an oracle that already exists: the binary's
# own output on the root-doubling probes. Where upstream doubles, it emits `root ++ result`, which
# reveals the root directly:
#
#     (and (ok $z) 2 $i)      -> binary emits (ok (ok $a))       => root is `(ok`
#     (fsum (res p $z) $c $x) -> binary emits (res p (res p $a)) => root is `(res p`
#
# The GROUND-result case is the one that killed the shortcut and is pinned here too: with a ground
# result the first variable sits in the SOURCE slot, so the root runs PAST the result — for
# `(sum (correct) 6 $x)` it is `(correct) 6`, and `root ++ result` is provably not upstream's output.
using MORK, Test

# byte-level constructors so the expectations are readable and independent of the parser
sym(s::AbstractString) = vcat(item_byte(ExprSymbol(UInt8(length(s)))), Vector{UInt8}(s))
ari(n::Int) = UInt8[item_byte(ExprArity(UInt8(n)))]

@testset "sink_request — the write root each sink asks for" begin
    mk(src) = MORK.space_sexpr_to_expr(new_space(), src)

    @testset "root is the ground prefix minus the keyword header" begin
        # (and (ok $z) 2 $i): first var $z is INSIDE the result -> root is the partial result
        @test MORK.sink_request(MORK.AndSink(mk("(and (ok \$z) 2 \$i)"))) ==
            vcat(ari(2), sym("ok"))
        # (fsum (res p $z) $c $x): same shape, two-element result head
        @test MORK.sink_request(
            MORK.FloatReductionSink(mk("(fsum (res p \$z) \$c \$x)"), :sum)
        ) ==
            vcat(ari(3), sym("res"), sym("p"))
    end

    @testset "GROUND result: the root runs past the result into the source slot" begin
        # This is the case that refutes "prepend the root": the root here is result ++ source.
        r = MORK.sink_request(MORK.SumSink(mk("(sum (correct) 6 \$x)")))
        @test r == vcat(ari(1), sym("correct"), sym("6"))
        @test r != vcat(ari(1), sym("correct"))        # NOT just the result
    end

    @testset "header widths are per-sink (2 + length(keyword))" begin
        # same body, different keyword => different amount stripped, same remaining root
        @test MORK.sink_request(MORK.SumSink(mk("(sum (r \$z) 1 \$x)"))) ==
            vcat(ari(2), sym("r"))
        @test MORK.sink_request(MORK.AndSink(mk("(and (r \$z) 1 \$x)"))) ==
            vcat(ari(2), sym("r"))
        @test MORK.sink_request(MORK.CountSink(mk("(count (r \$z) 1 \$x)"))) ==
            vcat(ari(2), sym("r"))
        @test MORK.sink_request(MORK.HashSink(mk("(hash (r \$z) \$z \$x)"))) ==
            vcat(ari(2), sym("r"))
    end

    @testset "a variable immediately after the header gives the EMPTY root" begin
        @test isempty(MORK.sink_request(MORK.AddSink(mk("(+ \$z)"))))
        @test isempty(MORK.sink_request(MORK.SumSink(mk("(sum \$r \$n \$x)"))))
    end

    @testset "non-BTM sinks have no write root" begin
        @test MORK.sink_request(MORK.ACTSink(mk("(ACT \"f\" \$x)"))) === nothing
    end
end
