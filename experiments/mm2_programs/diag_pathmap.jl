using MORK
# Minimal: does a plain remove_val_at! leave the path visible to multi-factor query / zipper iteration?
s = new_space()
space_add_all_sexpr!(s, "(counter (S Z))\n(marker a)\n")
buf = MORK.sexpr_to_expr("(counter (S Z))").buf
MORK.remove_val_at!(s.btm, buf)

println("after remove_val_at!((counter (S Z))):")
println("  val_count     = ", MORK.space_val_count(s))
println("  get_val_at    = ", MORK.get_val_at(s.btm, buf) === nothing ? "ABSENT" : "PRESENT")
println("  dump          = ", repr(strip(space_dump_all_sexpr(s))))

# 2-factor conjunction that includes the removed atom as a factor:
pat = MORK.sexpr_to_expr("(, (counter (S \$N)) (marker \$x))")
n = Ref(0)
MORK.space_query_multi(s, pat, (a...) -> (n[]+=1; true))
println("  conj matches  = ", n[], "   (0 = clean; >0 = remove leaves a query-visible dangling path)")

# raw value iteration via read zipper
rz = MORK.read_zipper_at_path(s.btm, UInt8[])
paths = String[]
while MORK.zipper_to_next_val!(rz)
    push!(paths, try MORK.expr_serialize(copy(rz.prefix_buf)) catch; "<?>" end)
end
println("  zipper vals   = ", paths)
