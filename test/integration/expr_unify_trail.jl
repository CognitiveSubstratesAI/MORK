# THE UNDO TRAIL — `expr_unify_into!` / `expr_unify_unwind!` (upstream `cfa8abf`).
#
# The trail replaces "clone the map and re-solve every prior equation per candidate" with "solve the
# new equation against the LIVE map, and unwind by removing what you inserted". It rests on two
# claims, and this file tests both rather than trusting either:
#
#  1. UNWINDING IS REMOVAL — "an insert target is ALWAYS a previously-unbound key, so removal
#     restores the map". If that is ever false, an unwind leaves a stale binding and every later
#     candidate is solved against a corrupted map: WRONG ANSWERS, no error.
#
#  2. THE DEREF CLOSURE IS UNCHANGED — the solved form's SHAPE may differ from a from-scratch solve
#     (path compression, which end of a var-var equation survived), but downstream observes bindings
#     ONLY BY DEREFERENCE. So the test compares DEREFS, not maps. Comparing maps structurally would
#     fail on a difference upstream explicitly permits — and would be asserting the representation
#     instead of the contract. [[feedback_assert_the_contract_not_the_representation]]
#
# ⚠️ ON FAILURE THE MAP IS LEFT DIRTY: a failed solve may insert before it contradicts. The caller
# must unwind on BOTH paths. That case is tested here too, because it is the one a happy-path test
# would miss and the one that corrupts silently.

# ⚠️ SCOPE — THIS FILE TESTS THE PRIMITIVES, NOT THE JOIN'S USE OF THEM. Its name overpromises:
# a reader scanning the suite list will assume trail coverage lives here, and a JOIN-side unwind bug
# is structurally outside it. MEASURED by mutation (2026-08-21): deleting the unwind from
# `match_candidate!`'s SUCCESS path survives this file and is killed by `leapfrog_layer3d.jl`;
# deleting it from the FAILURE path survives BOTH plus the differential and end-to-end suites.
# ⇒ For join-side trail cases see `leapfrog_layer3d.jl`; for the mutation matrix and what each
#   mutant kills, see `tools/mutation_trail.sh`.

using MORK, Test, Random

_t_env(n, s) = MORK.ExprEnv(UInt8(n), UInt8(0), UInt32(0), MORK.sexpr_to_expr(s))

# ⚠️ A VARIABLE'S IDENTITY IS `(namespace, ee.v)`, NOT ITS NAME. `_t_env(0, "$x")` and
# `_t_env(0, "$y")` are THE SAME KEY (0,0) — the de Bruijn encoding drops names, and both envs carry
# v=0. A first draft of this file bound "$x" then "$y" in namespace 0 and asserted the map had grown;
# it had not, because the second unify CONTRADICTED the first instead of inserting. The test was
# wrong, not the code. Use an explicit (n, v) to get distinct variables.
_t_var(n, v) = MORK.ExprEnv(UInt8(n), UInt8(v), UInt32(0), MORK.sexpr_to_expr("\$x"))

"Follow bindings to the term a variable resolves to — the ONLY thing downstream observes."
function _t_deref(b, e)
    cur = e
    for _ in 0:length(b)
        v = MORK.ee_var_opt(cur)
        v === nothing && return cur
        nxt = get(b, v, nothing)
        nxt === nothing && return cur
        cur = nxt
    end
    cur
end

"A comparable rendering of every variable's resolved value."
function _t_closure(b)
    out = Dict{MORK.ExprVar, Vector{UInt8}}()
    for (k, _) in b
        r = _t_deref(b, MORK.ExprEnv(k[1], k[2], UInt32(0), MORK.sexpr_to_expr("\$x")))
        out[k] = Vector{UInt8}(MORK.ee_subsexpr(r).buf)
    end
    out
end

@testset "undo trail — unwinding restores, deref closure is preserved" begin

    @testset "🔑 MARK → SOLVE → UNWIND restores the map EXACTLY" begin
        b = MORK.Bindings()
        trail = MORK.ExprVar[]

        # establish a base state
        MORK.expr_unify_into!(b, [(_t_var(0, 0), _t_env(1, "(f a)"))], trail)
        base_len = length(b)
        base_closure = _t_closure(b)
        @test base_len >= 1                       # anti-vacuity: something really was bound

        # …then bind a candidate and unwind it
        mark = length(trail)
        r2 = MORK.expr_unify_into!(b, [(_t_var(0, 1), _t_env(2, "(g b)"))], trail)
        @test !(r2 isa MORK.UnificationFailure)   # a DISTINCT variable, so it binds
        @test length(b) > base_len                # the candidate really did insert
        MORK.expr_unify_unwind!(b, trail, mark)

        @test length(b) == base_len               # …and the unwind removed exactly it
        @test _t_closure(b) == base_closure       # ⇐ the property this file exists for
        @test length(trail) == mark
    end

    @testset "🔴 A FAILED SOLVE LEAVES THE MAP DIRTY — the caller must unwind anyway" begin
        # `$x` is bound to `(f a)`; unifying it against `(g b)` must FAIL. A failed solve may have
        # inserted before contradicting, so the unwind is required on the failure path too. A test
        # that only unwound after success would miss the case that silently corrupts.
        b = MORK.Bindings()
        trail = MORK.ExprVar[]
        MORK.expr_unify_into!(b, [(_t_var(0, 0), _t_env(1, "(f a)"))], trail)
        base_len = length(b)
        base_closure = _t_closure(b)

        mark = length(trail)
        r = MORK.expr_unify_into!(b, [(_t_var(0, 0), _t_env(2, "(g b)"))], trail)
        @test r isa MORK.UnificationFailure        # it really did contradict
        MORK.expr_unify_unwind!(b, trail, mark)
        @test length(b) == base_len
        @test _t_closure(b) == base_closure
    end

    @testset "INCREMENTAL == FROM-SCRATCH, by deref (not by map shape)" begin
        pairs = [(_t_var(0, 0), _t_env(1, "(f \$u)")),
                 (_t_var(0, 1), _t_var(0, 0)),
                 (_t_var(1, 0), _t_env(3, "c"))]

        scratch = MORK.expr_unify(copy(pairs))
        @test !(scratch isa MORK.UnificationFailure)

        inc = MORK.Bindings()
        trail = MORK.ExprVar[]
        for p in pairs
            r = MORK.expr_unify_into!(inc, [p], trail)
            @test !(r isa MORK.UnificationFailure)
        end
        # SHAPES MAY DIFFER — upstream permits it. Closures may not.
        @test _t_closure(inc) == _t_closure(scratch)
    end

    @testset "randomised mark/unwind — nesting, failures, and shapes nobody chose" begin
        rng = MersenneTwister(0x7241)
        terms = ["a", "b", "(f a)", "(g b)", "(f \$u)", "\$w"]
        for _ in 1:200
            b = MORK.Bindings()
            trail = MORK.ExprVar[]
            MORK.expr_unify_into!(b, [(_t_env(0, "\$x"), _t_env(1, rand(rng, terms)))], trail)
            base_len, base_closure = length(b), _t_closure(b)

            # a nest of marks, unwound in reverse — the shape the join's recursion actually makes
            marks = Int[]
            for d in 1:rand(rng, 1:3)
                push!(marks, length(trail))
                MORK.expr_unify_into!(b, [(_t_var(0, d), _t_env(d + 1, rand(rng, terms)))], trail)
            end
            for m in reverse(marks)
                MORK.expr_unify_unwind!(b, trail, m)
            end
            @test length(b) == base_len
            @test _t_closure(b) == base_closure
            @test isempty(trail) || length(trail) == marks[1]
        end
    end
end
