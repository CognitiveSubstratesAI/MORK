# test_eval.jl — the FIRST execution of the `eval` + `eval-ffi` crate ports.
#
# 🔴 WHY THIS FILE EXISTS, AND WHY IT IS EMBARRASSING THAT IT DID NOT.
# `src/kernel/Eval.jl` + `EvalFfi.jl` port upstream's `eval` and `eval-ffi` crates: the registry,
# `FuncType`, `StackFrame`, the alloc pool, the `EvalError` contract and `op_skeleton` (the `op!`
# macro skeleton — arity check + error conversion around every op body). Until this file, **not one
# line of it had ever been executed.** `PURE_SCOPE`'s registered functions are only ever REGISTERED;
# nothing calls them, because `_pure_eval_formula` (Sinks.jl) is still the live evaluator.
#
# Worse, the `PURE_SCOPE_UNREGISTERED` docstring claimed *"Empty is the invariant; `test_eval.jl`
# asserts it"* — and NO SUCH TEST FILE EXISTED. A docstring citing a phantom test is the same
# defect class as the 2026-07-29 finding that `cmp_pure.jl` sat unwired beside a correct measurement:
# knowledge that nothing executes changes nothing. [[feedback_verify_the_oracle_runs]]
#
# This matters NOW because the `_pure_eval_formula` -> `scope.eval` migration is about to make this
# code the live pure-sink evaluator. Characterising it BEFORE depending on it is the whole point.
using MORK, Test

const M = MORK

# Build the serialized argument buffer an upstream `ExprSource` would see for `(name a1 a2 …)`:
# Arity(1 + nargs), the head Symbol, then each argument.
_es_sym(bytes) = vcat(UInt8[M.item_byte(M.ExprSymbol(UInt8(length(bytes))))], Vector{UInt8}(bytes))
_es_call2(items...) = vcat(UInt8[M.item_byte(M.ExprArity(UInt8(length(items))))], reduce(vcat, items; init = UInt8[]))
_es_call(name, args...) =
    vcat(UInt8[M.item_byte(M.ExprArity(UInt8(1 + length(args))))], _es_sym(name),
         reduce(vcat, args; init = UInt8[]))

"Run a registered op through its skeleton exactly as `eval_impl` would, returning the sink bytes."
function _es_run(name::String, argbufs::Vector{Vector{UInt8}})
    f = M.PURE_SCOPE.fns[name].func
    src = M.ExprSource(_es_call(name, argbufs...))
    snk = M.ExprSink()
    f(src, snk)
    M.sink_finish(snk)
end

@testset "EvalScope port — first execution" begin
    @testset "registry invariants (the claim the PURE_SCOPE_UNREGISTERED docstring makes)" begin
        # This is the assertion the docstring promised and no file made.
        @test isempty(M.PURE_SCOPE_UNREGISTERED)
        # After deleting all 160 ours-beyond-upstream ops, our table IS upstream's set.
        @test isempty(M.PURE_SCOPE_EXTRA)
        @test length(M.PURE_REGISTER) == 370
        # 370 upstream registrations + the `'` pre-registered by EvalScope() itself.
        @test length(M.PURE_SCOPE.fns) == 371
        @test haskey(M.PURE_SCOPE.fns, "'")
        # Upstream classifies EVERY registration Pure — none are Macro, `ifnz` included.
        @test all(n -> M.PURE_SCOPE.fns[n].ty === M.FuncPure, M.PURE_REGISTER)
        # Every registered name resolves to an implementation or a declared special form.
        @test all(n -> haskey(M.PURE_OPS, n) || n in M.PURE_SPECIAL_FORMS, M.PURE_REGISTER)
    end

    @testset "op_skeleton drives a scalar numeric op end to end" begin
        # `(sub_i64 7 5)` — both operands are 8 big-endian bytes, result is a Symbol of 8 bytes.
        out = _es_run("sub_i64", [_es_sym(M._be_bytes(Int64(7))), _es_sym(M._be_bytes(Int64(5)))])
        @test out == _es_sym(M._be_bytes(Int64(2)))
        # Width is the EXPRESSION's, not the operand's: comparisons return a 1-byte i8.
        out = _es_run("lt_i64", [_es_sym(M._be_bytes(Int64(3))), _es_sym(M._be_bytes(Int64(5)))])
        @test out == _es_sym(UInt8[0x01])
        # nary with a seed and no arity check: zero args must emit the seed.
        @test _es_run("sum_i64", Vector{UInt8}[]) == _es_sym(M._be_bytes(Int64(0)))
        @test _es_run("max_i32", Vector{UInt8}[]) == _es_sym(M._be_bytes(typemin(Int32)))
    end

    @testset "the skeleton supplies the ARITY CHECK the bodies never had" begin
        # Upstream: `if items != 2 { return Err("… takes two arguments") }`. Ported ops carry the
        # check in the SKELETON; calling with the wrong count must raise EvalError, not reach the body.
        @test_throws M.EvalError _es_run("sub_i64", [_es_sym(M._be_bytes(Int64(7)))])
        @test_throws M.EvalError _es_run("sub_i64", [_es_sym(M._be_bytes(Int64(1))),
                                                     _es_sym(M._be_bytes(Int64(2))),
                                                     _es_sym(M._be_bytes(Int64(3)))])
        # `nary` and `tuple` declare NO arity upstream, so any count is admissible.
        @test M.PURE_OP_ARITY["sum_i64"] === nothing
        @test M.PURE_OP_ARITY["tuple"] === nothing
    end

    @testset "the skeleton converts Julia failures into EvalError" begin
        # Upstream returns Err(EvalError) and its caller SKIPS the atom (sinks.rs:1167). A raw
        # DivideError/DomainError escaping the sink would abort more than one row.
        @test_throws M.EvalError _es_run("div_i64", [_es_sym(M._be_bytes(Int64(1))),
                                                     _es_sym(M._be_bytes(Int64(0)))])
        @test_throws M.EvalError _es_run("u8_shl", [_es_sym(UInt8[0x01]),
                                                    _es_sym(M._be_bytes(Int32(8)))])
        @test_throws M.EvalError _es_run("i64_from_string", [_es_sym(Vector{UInt8}("0x10"))])
    end

    # ── the STACK MACHINE itself: eval / push_eval / eval_impl (ported 2026-07-30) ──
    @testset "scope_eval! — upstream's stack machine, end to end" begin
        ev(bytes) = M.scope_eval!(M.PURE_SCOPE, M.ExprSource(bytes, 1))

        # A bare symbol root is copied through unevaluated.
        @test ev(_es_sym("abc")) == _es_sym("abc")

        # Flat call: children land in the frame's sink, then the func runs over its own bytes.
        @test ev(_es_call("sub_i64", _es_sym(M._be_bytes(Int64(7))),
                          _es_sym(M._be_bytes(Int64(5))))) == _es_sym(M._be_bytes(Int64(2)))

        # NESTED: the inner frame's result is written into the OUTER frame's sink before the outer
        # func runs. This is the property that makes evaluation bottom-up and therefore EAGER.
        inner = _es_call("sum_i64", _es_sym(M._be_bytes(Int64(10))), _es_sym(M._be_bytes(Int64(2))))
        @test ev(_es_call("sub_i64", inner, _es_sym(M._be_bytes(Int64(5))))) ==
              _es_sym(M._be_bytes(Int64(7)))

        # Two nested children, so `rest` accounting is exercised on both.
        @test ev(_es_call("sub_i64",
                          _es_call("sum_i64", _es_sym(M._be_bytes(Int64(10))),
                                   _es_sym(M._be_bytes(Int64(5)))),
                          _es_call("sum_i64", _es_sym(M._be_bytes(Int64(1))),
                                   _es_sym(M._be_bytes(Int64(2)))))) ==
              _es_sym(M._be_bytes(Int64(12)))

        # nary with 0 args inside a call: the seed must reach the parent.
        @test ev(_es_call("sub_i64", _es_call("sum_i64"), _es_sym(M._be_bytes(Int64(3))))) ==
              _es_sym(M._be_bytes(Int64(-3)))

        # An unregistered head is upstream's `Err("unknown function")`.
        @test_throws M.EvalError ev(_es_call("bogus_op_xyz", _es_sym("a")))
        # An error ANYWHERE in the tree propagates out of eval (=> the caller skips the atom).
        @test_throws M.EvalError ev(_es_call("sub_i64",
                                             _es_call("div_i64", _es_sym(M._be_bytes(Int64(1))),
                                                      _es_sym(M._be_bytes(Int64(0)))),
                                             _es_sym(M._be_bytes(Int64(5)))))

        # quote splices its argument VERBATIM, so nesting survives and the head is not called.
        quoted = _es_call("'", _es_call("b", _es_sym("c")))
        @test ev(quoted) == _es_call("b", _es_sym("c"))
        @test ev(_es_call("'", _es_sym("x"))) == _es_sym("x")
    end

    # ── the TEN HAND-WRITTEN ops, now native `(ExprSource, ExprSink)` as upstream writes them ──
    #
    # `pure.rs` is 360 `op!` invocations + TEN functions written out by hand (:748-908), each
    # `pub extern "C" fn NAME(expr: *mut ExprSource, sink: *mut ExprSink)`. They are hand-written
    # because each CONSUMES or PRODUCES an EXPRESSION, which the macro cannot express.
    #
    # This testset previously PINNED the opposite: `op_skeleton` demands Symbol arguments and writes
    # Symbol results, so `collapse_symbol`/`hash_expr` threw on an Arity-tagged argument and `tuple`
    # came back flattened into a symbol. That limitation is now GONE — the ten are registered
    # directly, mirroring upstream's own 360/10 split instead of forcing all 370 through one skeleton.
    @testset "the ten hand-written ops, driven natively by the stack machine" begin
        ev(bytes) = M.scope_eval!(M.PURE_SCOPE, M.ExprSource(bytes, 1))
        quote_of(x) = _es_call("'", x)

        # tuple: Arity(items) then each element's WHOLE span, so NESTING SURVIVES.
        @test ev(_es_call("tuple", _es_sym("a"), _es_sym("b"))) ==
              _es_call2(_es_sym("a"), _es_sym("b"))
        @test ev(_es_call("tuple")) == UInt8[M.item_byte(M.ExprArity(UInt8(0)))]
        nested = ev(_es_call("tuple", _es_sym("a"), quote_of(_es_call2(_es_sym("b"), _es_sym("c")))))
        @test nested == _es_call2(_es_sym("a"), _es_call2(_es_sym("b"), _es_sym("c")))
        @test M.byte_item(nested[1]) isa M.ExprArity      # an EXPRESSION, not a flattened symbol

        # collapse_symbol consumes an EXPRESSION of symbols (this is what op_skeleton could not do).
        @test ev(_es_call("collapse_symbol",
                          quote_of(_es_call2(_es_sym("a"), _es_sym("b"), _es_sym("c"))))) ==
              _es_sym("abc")
        # …and enforces upstream's `i + len >= 64` cap, so 63 bytes is the maximum TOTAL.
        @test length(ev(_es_call("collapse_symbol",
                                 quote_of(_es_call2(_es_sym("a"^32), _es_sym("b"^31)))))) == 64
        @test_throws M.EvalError ev(_es_call("collapse_symbol",
                                             quote_of(_es_call2(_es_sym("a"^32), _es_sym("b"^32)))))
        # a non-Symbol element is an Err, NOT a partial result
        @test_throws M.EvalError ev(_es_call("collapse_symbol",
                                             quote_of(_es_call2(_es_sym("a"),
                                                                _es_call2(_es_sym("b"))))))

        # explode_symbol produces an EXPRESSION; round-trips with collapse_symbol.
        @test ev(_es_call("explode_symbol", _es_sym("abc"))) ==
              _es_call2(_es_sym("a"), _es_sym("b"), _es_sym("c"))
        @test ev(_es_call("collapse_symbol", _es_call("explode_symbol", _es_sym("abc")))) ==
              _es_sym("abc")

        @test ev(_es_call("reverse_symbol", _es_sym("abc"))) == _es_sym("cba")
        @test ev(_es_call("encode_hex", _es_sym("aa"))) == _es_sym("6161")
        @test ev(_es_call("decode_hex", _es_sym("6161"))) == _es_sym("aa")
        @test ev(_es_call("encode_base64url", _es_sym("abc"))) == _es_sym("YWJj")
        @test ev(_es_call("decode_base64url", _es_sym("YWJj"))) == _es_sym("abc")

        # hash_expr consumes the WHOLE SPAN (tag byte included) and emits 16 LE bytes.
        h = ev(_es_call("hash_expr", quote_of(_es_sym("symbols"))))
        @test length(h) == 17 && M.byte_item(h[1]) isa M.ExprSymbol   # 1 tag + 16 payload
        @test h != ev(_es_call("hash_expr", quote_of(_es_sym("symbolt"))))

        # ifnz SELECTS between branches the machine has ALREADY evaluated (hence eager).
        one, zero = _es_sym(UInt8[0x01]), _es_sym(UInt8[0x00])
        @test ev(_es_call("ifnz", one, _es_sym("then"), _es_sym("A"),
                          _es_sym("else"), _es_sym("B"))) == _es_sym("A")
        @test ev(_es_call("ifnz", zero, _es_sym("then"), _es_sym("A"),
                          _es_sym("else"), _es_sym("B"))) == _es_sym("B")
        @test ev(_es_call("ifnz", one, _es_sym("then"), _es_sym("A"))) == _es_sym("A")
        # zero condition with no else is upstream's Err("ifnz no else branch")
        @test_throws M.EvalError ev(_es_call("ifnz", zero, _es_sym("then"), _es_sym("A")))
        # arity must be exactly 3 or 5 — the malformed 4-arg shape is rejected
        @test_throws M.EvalError ev(_es_call("ifnz", one, _es_sym("then"), _es_sym("A"),
                                             _es_sym("B")))
        # a multi-byte condition is false only when EVERY byte is zero
        @test ev(_es_call("ifnz", _es_sym(UInt8[0x00, 0x00]), _es_sym("then"), _es_sym("A"),
                          _es_sym("else"), _es_sym("B"))) == _es_sym("B")
        @test ev(_es_call("ifnz", _es_sym(UInt8[0x00, 0x01]), _es_sym("then"), _es_sym("A"),
                          _es_sym("else"), _es_sym("B"))) == _es_sym("A")
    end
end
