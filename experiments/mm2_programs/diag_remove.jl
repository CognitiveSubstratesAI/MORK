using MORK
src = read(joinpath(homedir(), "code/CognitiveSubstratesAI/MORK/experiments/mm2_programs/programs/Control_08_Halts_on_fail.mm2"), String)
s = new_space(); space_add_all_sexpr!(s, src); space_metta_calculus!(s, 4)

dumplines = filter(!isempty, split(space_dump_all_sexpr(s), '\n'))
println("space_val_count(s.btm) = ", MORK.space_val_count(s))
println("dump line count        = ", length(dumplines))

# Does the removed atom have a VALUE at its path, or just a dangling path?
for atomstr in ["(counter Z)", "(counter (S Z))", "(counter (S (S Z)))", "(counter (S (S (S Z))))"]
    buf = MORK.sexpr_to_expr(atomstr).buf
    v = MORK.get_val_at(s.btm, buf)
    println(rpad(atomstr, 26), " get_val_at => ", v === nothing ? "ABSENT (no value)" : "PRESENT")
end
