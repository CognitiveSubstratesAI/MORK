using MORK
src = read(joinpath(homedir(), "code/CognitiveSubstratesAI/MORK/experiments/mm2_programs/programs/Control_08_Halts_on_fail.mm2"), String)

function conj_matches(s)
    pat = MORK.sexpr_to_expr("(, (counter (S \$N)) (exec LOOP \$p \$t))")
    n = Ref(0); MORK.space_query_multi(s, pat, (a...) -> (n[]+=1; true)); n[]
end
function exec_match(s)  # does (exec LOOP $p $t) alone match?
    pat = MORK.sexpr_to_expr("(exec LOOP \$p \$t)")
    n = Ref(0); MORK.space_query_multi(s, pat, (a...) -> (n[]+=1; true)); n[]
end
function counter_match(s)
    pat = MORK.sexpr_to_expr("(counter (S \$N))")
    n = Ref(0); MORK.space_query_multi(s, pat, (a...) -> (n[]+=1; true)); n[]
end

# (A) reached-by-decrement state at counter=Z
s = new_space(); space_add_all_sexpr!(s, src); space_metta_calculus!(s, 4)
println("DECREMENT-REACHED  conj=$(conj_matches(s))  exec=$(exec_match(s))  counter(S N)=$(counter_match(s))")

# (B) fresh-built state at counter=Z (the SAME visible atoms)
fresh = "(counter Z)\n(exec LOOP (, (counter (S \$N)) (exec LOOP \$p \$t)) (O (+ (exec LOOP \$p \$t)) (+ (counter \$N)) (- (counter (S \$N)))))\n"
s2 = new_space(); space_add_all_sexpr!(s2, fresh)
println("FRESH-BUILT        conj=$(conj_matches(s2))  exec=$(exec_match(s2))  counter(S N)=$(counter_match(s2))")

println("DECREMENT dump == FRESH dump? ", space_dump_all_sexpr(s) == space_dump_all_sexpr(s2))
