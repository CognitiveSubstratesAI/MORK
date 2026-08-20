# Leapfrog RANDOMIZED DIFFERENTIAL — the assembled unify join vs the live engine, on generated shapes.
#
# 🔑 WHY RANDOMIZED AND NOT MORE HAND CASES. The five shapes in `leapfrog_end_to_end.jl` are the ones
# I already knew to doubt, and a test written from what I suspect can only confirm what I suspect.
# The engine (`space_query_multi`, full unification, byte-differentialled against the upstream Rust)
# answers ANY shape, so the honest test is to let a generator pick shapes I did not think of and make
# the two disagree. [[feedback_adversarial_test_inputs]] · [[feedback_metta_rules_verify_by_oracle_not_syntax]]
#
# The generator deliberately produces the cases the equality-based `ground_leapfrog` gets WRONG:
#   · facts containing stored variables, at either column and at both
#   · REPEATED query variables — `(edge $x $x)` — which need `catch_up` to see at all
#   · ground symbol columns mixed with variable columns
#   · 1-, 2- and 3-factor conjunctions, so a variable can be shared across more than two relations
#
# ⚠️ THE COUNTERS ARE ANTI-VACUITY, NOT DECORATION. A generator that produced only empty answers
# would pass every assertion here while testing nothing; the testset fails if too few cases have a
# non-empty answer set. That failure mode is not hypothetical — a green suite over vacuous cases is
# how 47 "conformance" programs turned out to verify nothing.

using MORK, Test, Random
const _DIFF = MORK.Leapfrog

const _D_ARITY3 = MORK.item_byte(MORK.ExprArity(0x03))

# A generated column is one of:
#   Int          — query variable `v`
#   String       — a ground symbol
#   (:c, sub)    — a COMPOUND `(f sub)`, which is what reaches `uj_consume_compound` and the trap
#                  that a stored wildcard may capture the WHOLE subterm.
#
# ⚠️ A COMPOUND CARRYING A VARIABLE MUST PASS THAT VARIABLE'S ID AS `intro`: `push_steps!` numbers a
# `NewVar` by the introduced-count it is handed, so `intro` IS the id the step gets. Give it 0 for a
# term holding `$v2` and the factor silently joins on the wrong variable — a wrong ANSWER, not an
# error. This is why the compound cases were hand-checked against the engine before being generated.
_d_colvar(x) = x isa Int ? x : (x isa Tuple && x[2] isa Int ? x[2] : 0)

function _d_col(x)
    if x isa Int
        _DIFF.unify_var_col(x)
    elseif x isa Tuple
        _DIFF.unify_term_col(MORK.sexpr_to_expr(_d_coltext(x)), _d_colvar(x))
    else
        _DIFF.unify_term_col(MORK.sexpr_to_expr(String(x)))
    end
end

_d_coltext(x) = x isa Int    ? "\$v$(x)" :
                x isa Tuple  ? "(f $(_d_coltext(x[2])))" : String(x)

"A factor over `rel`'s 2-argument facts."
_d_factor(rel::AbstractString, c1, c2) = _DIFF.UnifyFactor(UInt8[_D_ARITY3],
    [_DIFF.unify_term_col(MORK.sexpr_to_expr(rel)), _d_col(c1), _d_col(c2)])

"The same factor as query text, so the engine is asked the identical question."
_d_text(rel, c1, c2) = "($rel $(_d_coltext(c1)) $(_d_coltext(c2)))"

function _d_engine(s, body::AbstractString)
    n = Ref(0)
    MORK.space_query_multi(s.btm, MORK.sexpr_to_expr(body), (_b, _l) -> (n[] += 1; true))
    n[]
end

function _d_ours(s, factors::Vector{_DIFF.UnifyFactor}, nvars::Int)
    n = Ref(0)
    _DIFF.unify_leapfrog(s.btm, factors, nvars, (_b, _st) -> (n[] += 1; true))
    n[]
end

@testset "leapfrog randomized differential vs the engine" begin
    rng = MersenneTwister(0x1eaf)
    syms = ["a", "b", "c", "d"]
    rels = ["edge", "link"]

    nonempty = 0
    agreed   = 0
    cases    = 0

    for trial in 1:600
        # ── a space mixing ground facts with facts that carry STORED VARIABLES ──────────────────
        lines = String[]
        for _ in 1:rand(rng, 2:6)
            r = rand(rng, rels)
            # A stored arg is a wildcard, a symbol, or a COMPOUND — so a stored wildcard sometimes
            # faces a compound query column and sometimes the reverse.
            arg() = (t = rand(rng);
                     t < 0.22 ? "\$w" : t < 0.40 ? "(f $(rand(rng, syms)))" : rand(rng, syms))
            push!(lines, "($r $(arg()) $(arg()))")
        end
        s = MORK.new_space()
        MORK.space_add_all_sexpr!(s, join(unique(lines), "\n") * "\n")

        # ── a conjunctive query over a small variable pool, so variables REPEAT across factors ──
        nvars = rand(rng, 1:3)
        nfac  = rand(rng, 1:3)
        facs  = _DIFF.UnifyFactor[]
        texts = String[]
        for _ in 1:nfac
            r  = rand(rng, rels)
            gencol() = (t = rand(rng);
                        t < 0.60 ? rand(rng, 0:(nvars - 1)) :
                        t < 0.80 ? (:c, rand(rng, 0:(nvars - 1))) :
                        t < 0.90 ? (:c, rand(rng, syms)) : rand(rng, syms))
            c1 = gencol()
            c2 = gencol()
            push!(facs, _d_factor(r, c1, c2))
            push!(texts, _d_text(r, c1, c2))
        end
        # 🔴 ALWAYS WRAP, EVEN FOR ONE CONJUNCT. A bare `(link $a $b)` is read by the engine as a
        # CONJUNCTION whose head is `link` and whose conjuncts are `$a` and `$b` — each matching
        # every atom, so a 4-atom space answered 16. The first differential run blamed the join for
        # 64 divergences that were this line. [[feedback_verify_the_oracle_runs]]
        body = "(, " * join(texts, " ") * ")"

        eng  = _d_engine(s, body)
        ours = _d_ours(s, facs, nvars)

        cases += 1
        eng > 0 && (nonempty += 1)
        if ours == eng
            agreed += 1
        else
            # Print the case BEFORE failing — a differential that reports only a count leaves the
            # next session re-deriving which shape broke.
            println("  🔴 trial $trial  engine=$eng ours=$ours")
            println("     space: ", replace(MORK.space_dump_all_sexpr(s), "\n" => " | "))
            println("     query: ", body, "   nvars=", nvars)
        end
        @test ours == eng
    end

    @test cases == 600
    # Anti-vacuity: a generator that never produced an answer would pass everything above.
    @test nonempty >= 90
    @test agreed == cases
end
