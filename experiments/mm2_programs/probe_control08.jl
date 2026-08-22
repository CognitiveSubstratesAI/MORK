# Minimal repro for the Control_08 "(-) removals stay queryable" bug.
# See findings/control_08_phantom_conjunction.md.
#
#   cd ~/code/CognitiveSubstratesAI/MORK
#   printf 'include("experiments/mm2_programs/probe_control08.jl"); exit()\n' | julia --project=. -i tools/repl.jl

using MORK

const PROG = read(joinpath(@__DIR__, "programs", "Control_08_Halts_on_fail.mm2"), String)
const CONJ = "(, (counter (S \$N)) (exec LOOP \$p \$t))"   # the exec's own query pattern

count_conj(s) = (
    n=Ref(0);
    MORK.space_query_multi(s, MORK.sexpr_to_expr(CONJ), (a...) -> (n[]+=1; true));
    n[]
)

# (A) state at counter=Z reached by DECREMENT (run Control_08 four steps)
sa = new_space();
space_add_all_sexpr!(sa, PROG);
space_metta_calculus!(sa, 4)

# (B) the SAME visible atoms, FRESH-built
fresh =
    "(counter Z)\n(exec LOOP (, (counter (S \$N)) (exec LOOP \$p \$t)) " *
    "(O (+ (exec LOOP \$p \$t)) (+ (counter \$N)) (- (counter (S \$N)))))\n"
sb = new_space();
space_add_all_sexpr!(sb, fresh)

println("DECREMENT-REACHED  conj=", count_conj(sa))
println("FRESH-BUILT        conj=", count_conj(sb))
println("dump(A) == dump(B)? ", space_dump_all_sexpr(sa) == space_dump_all_sexpr(sb))

println(
    "\nWhat the phantom matches bind (decrement state) — these are the REMOVED counters:"
)
i = Ref(0)
MORK.space_query_multi(
    sa,
    MORK.sexpr_to_expr(CONJ),
    (binds, expr) -> begin
        i[] += 1
        println(
            "  match $(i[]): ",
            MORK.expr_serialize(expr isa MORK.Expr ? expr.buf : expr)
        )
        true
    end
)
