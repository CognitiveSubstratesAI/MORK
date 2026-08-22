# pure_edge_values.jl — the defects that live at the EDGE of a pure op's input domain.
#
# WHY THIS FILE EXISTS. The per-op differential probed each op at ONE interior point (`3` for every
# integer, `2.5` for every float) and fed nary ops exactly TWO arguments. It reported 338/341
# AGREEING while 52 op bodies had drifted, and it kept reporting agreement afterwards while three
# more classes were still open. Widening it to 2792 input points — arity {0,1,3,4}, zero, ±1,
# typemin/typemax, NaN, ±0.0, shift == width — took the differential from 2657/2711 to 2707/2711.
#
#   56 divergences -> 4, and the 4 that remain are last-bit libm, not logic.
#
# ⇒ An op's defect lives at the edge of its domain. One interior point per op is a smoke test, not a
# differential. Every expectation below is pinned from the upstream release binary
# (`mork run probe.mm2 probe.raw`, a FILE — stdout mangles the high bytes these ops produce).
using MORK, Test

_ev(name, args...) = MORK.pure_apply(name, Vector{UInt8}[args...])
_f64(x) = MORK._be_bytes(Float64(x))
_f32(x) = MORK._be_bytes(Float32(x))

const _NEG_NAN_64 = UInt8[0xff, 0xf8, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00]
const _POS_NAN_64 = UInt8[0x7f, 0xf8, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00]
const _NEG_NAN_32 = UInt8[0xff, 0xc0, 0x00, 0x00]
const _POS_NAN_32 = UInt8[0x7f, 0xc0, 0x00, 0x00]

@testset "pure op edge values" begin
    # ── Julia RAISES where Rust returns NaN, and inside a pure sink a raise means NO ATOM AT ALL ──
    # This rule was derived for asin/acos/atanh and then not swept: it was still open on eight more
    # ops, which was 48 of the 56 divergences. The NaN SIGN is per-op and had to be MEASURED — a
    # "logs give -NaN" generalisation would have been wrong for log10.
    @testset "out-of-domain NaN, sign pinned per op" begin
        @testset "negative quiet NaN" begin
            @test _ev("sqrt_f64", _f64(-1)) == _NEG_NAN_64
            @test _ev("ln_f64", _f64(-1)) == _NEG_NAN_64
            @test _ev("log2_f64", _f64(-1)) == _NEG_NAN_64
            @test _ev("acosh_f64", _f64(0)) == _NEG_NAN_64
            @test _ev("sin_f64", _f64(Inf)) == _NEG_NAN_64
            @test _ev("cos_f64", _f64(Inf)) == _NEG_NAN_64
            @test _ev("tan_f64", _f64(-Inf)) == _NEG_NAN_64
            @test _ev("atanh_f64", _f64(2.5)) == _NEG_NAN_64
            @test _ev("sqrt_f32", _f32(-1)) == _NEG_NAN_32
            @test _ev("ln_f32", _f32(-1)) == _NEG_NAN_32
            @test _ev("acosh_f32", _f32(0)) == _NEG_NAN_32
            @test _ev("sin_f32", _f32(Inf)) == _NEG_NAN_32
        end
        # log10 sits on the OPPOSITE side from ln and log2. This is why the sign is a measured table
        # and not a rule.
        @testset "positive quiet NaN" begin
            @test _ev("log10_f64", _f64(-1)) == _POS_NAN_64
            @test _ev("log10_f32", _f32(-1)) == _POS_NAN_32
            @test _ev("asin_f64", _f64(2.5)) == _POS_NAN_64
            @test _ev("acos_f64", _f64(2.5)) == _POS_NAN_64
            @test _ev("asin_f32", _f32(2.5)) == _POS_NAN_32
        end
        # In-domain neighbours must NOT be redirected: ln(0) is -Inf, not NaN, and sqrt(-0.0) is -0.0.
        @test _ev("ln_f64", _f64(0)) == _f64(-Inf)
        @test _ev("log2_f64", _f64(0)) == _f64(-Inf)
        @test _ev("sqrt_f64", _f64(-0.0)) == _f64(-0.0)
        @test _ev("acosh_f64", _f64(1)) == _f64(0)
        @test _ev("atanh_f64", _f64(1)) == _f64(Inf)
    end

    # ── signed zero in the nary min/max fold ──
    # `f*::min`/`max` do not specify which operand wins an EQUAL comparison; on this platform both
    # return the SECOND. Julia's `min` returns the first, so min_f* emitted -0.0 where upstream
    # emits +0.0. Julia's `max` happened to agree — by coincidence of its tie-break, not because we
    # encoded the rule.
    @testset "signed zero" begin
        for (op, T, be) in (("min_f64", Float64, _f64), ("max_f64", Float64, _f64),
            ("min_f32", Float32, _f32), ("max_f32", Float32, _f32))
            got = _ev(op, be(-0.0), be(0.0))
            @test got == be(0.0)            # +0.0 …
            @test got[1] & 0x80 == 0x00     # … and specifically NOT the -0.0 bit pattern
        end
        # Ordinary extremes are unaffected by the tie-break rule.
        @test _ev("min_f64", _f64(-1), _f64(2.5)) == _f64(-1)
        @test _ev("max_f64", _f64(-1), _f64(2.5)) == _f64(2.5)
        # NaN is still IGNORED (Rust) rather than propagated (Julia), at either position.
        @test _ev("max_f64", _f64(NaN), _f64(3)) == _f64(3)
        @test _ev("min_f64", _f64(3), _f64(NaN)) == _f64(3)
    end

    # ── float from_string is STRICT ──
    # Julia's `parse` accepts HEX FLOAT literals; Rust's grammar does not. Measured: we emitted
    # 4030000000000000 for `(f64_from_string 0x10)` where upstream emitted nothing.
    # ⚠️ This corrects a claim made earlier the same day that floats needed no guard — the narrower
    # probe set contained only inputs Rust ACCEPTS, and those all agreed. Only reject cases test
    # strictness.
    @testset "float from_string grammar" begin
        for bad in ("0x10", "0X1p3", "1_0", "abc", "", "+", "e5", "1e", "--1", "0b101")
            @test_throws Exception _ev("f64_from_string", Vector{UInt8}(bad))
        end
        for (lit, want) in
            (("0", 0.0), ("-0", -0.0), ("1", 1.0), ("-1", -1.0), ("2.5", 2.5),
            ("1e3", 1000.0), ("1E3", 1000.0), (".5", 0.5), ("5.", 5.0),
            ("+5", 5.0), ("inf", Inf), ("-inf", -Inf), ("infinity", Inf),
            ("Infinity", Inf))
            @test _ev("f64_from_string", Vector{UInt8}(lit)) == _f64(want)
        end
        @test _ev("f64_from_string", Vector{UInt8}("NaN")) == _f64(NaN)
        @test _ev("f64_from_string", Vector{UInt8}("nan")) == _f64(NaN)
    end

    # ── nary arity, the blind spot the old one-point probe could not see ──
    @testset "nary folds from a seed, any arity" begin
        i32(x) = MORK._be_bytes(Int32(x))
        @test _ev("max_i32") == i32(typemin(Int32))       # 0 args -> the SEED
        @test _ev("min_i32") == i32(typemax(Int32))
        @test _ev("sum_i32") == i32(0)
        @test _ev("product_i32") == i32(1)
        @test _ev("max_i32", i32(1), i32(4), i32(9)) == i32(9)   # args 3+ must not be ignored
        @test _ev("sum_i32", i32(1), i32(2), i32(3)) == i32(6)
        @test _ev("product_i32", i32(2), i32(3), i32(4)) == i32(24)
    end

    # ── checked shifts: shift == width must emit NOTHING, not a fabricated 0 ──
    @testset "checked shift at the width boundary" begin
        u8b(x) = UInt8[x]
        i32b(x) = MORK._be_bytes(Int32(x))
        @test _ev("u8_shl", u8b(0x01), i32b(7)) == u8b(0x80)
        @test_throws Exception _ev("u8_shl", u8b(0x01), i32b(8))
        @test_throws Exception _ev("u8_shr", u8b(0x01), i32b(8))
        @test_throws Exception _ev("u64_shl", MORK._be_bytes(UInt64(1)), i32b(64))
    end

    # ── ACCEPTED DEVIATION, asserted as BOUNDED rather than equal ──
    # Four ops differ in the LAST BIT ONLY, because Julia links openlibm and Rust uses the system
    # libm. Matching bit-for-bit would mean reimplementing one libm inside the port. They are pinned
    # here so the difference cannot silently GROW past one ULP — which is the thing that would
    # signal a real logic change rather than a library difference.
    # ⚠️ Do not assume a last-bit difference is libm without checking: `to_degrees_f32` looked like
    # this class and was arithmetic (a double rounding), and was exactly fixable.
    @testset "libm last-bit deviations stay within 1 ULP" begin
        ulps(a, b) = abs(Int(reinterpret(Int64, a)) - Int(reinterpret(Int64, b)))
        ulps32(a, b) = abs(Int(reinterpret(Int32, a)) - Int(reinterpret(Int32, b)))
        got64(op, x) = ntoh(only(reinterpret(Float64, _ev(op, _f64(x)))))
        got32(op, x) = ntoh(only(reinterpret(Float32, _ev(op, _f32(x)))))
        @test ulps(got64("cbrt_f64", 2.5), reinterpret(Float64, 0x3ff5b7209557b0ee)) <= 1
        @test ulps(got64("sin_f64", 2.5), reinterpret(Float64, 0x3fe326af0dcfcab1)) <= 1
        @test ulps32(got32("sinh_f32", 2.5f0), reinterpret(Float32, 0x40c19b47)) <= 1
    end
end
