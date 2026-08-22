# alloc_budget.jl — allocation regression gates for Unit A + B fixes
#
# C1: child-mask helpers must allocate only the Iterators.Filter wrapper struct
#     (48 bytes — fixed-size, independent of child count) rather than the old
#     collect(ByteMask) + filter(...) which allocated O(N_children) vectors.
# C2: space_metta_calculus! per-step budget caps the driver-loop overhead.
#     Space_interpret! legitimately allocates (sink objects, binding Dicts);
#     this gate catches regressions that re-introduce collect/vcat in the loop.
#
# Run standalone: julia --project=. test/alloc_budget.jl
# Run via runtests.jl: included automatically

using Test
using MORK

@testset "Allocation budget (Unit A + B)" begin

    # ── C1: child-mask helpers allocate only the Iterators.Filter wrapper ────
    @testset "C1: _var/_size/_arity_children — small fixed alloc (no collect)" begin
        s = new_space()
        space_add_all_sexpr!(s, "(isa robin bird) (likes alice pizza) (edge a b)")
        rz = MORK.read_zipper_at_path(s.btm, UInt8[])
        MORK.zipper_to_next_val!(rz)

        # Warm up JIT (first call may include compilation overhead)
        for _ in 1:3
            for h in [MORK._var_children, MORK._size_children, MORK._arity_children]
                count = 0
                for b in h(rz)

                    count += Int(b)
                end
                count
            end
        end

        # After JIT warmup: each helper allocates only the Iterators.Filter struct
        # (fixed ~48 bytes) regardless of child count. Old code allocated O(N) vectors.
        # Threshold: 128 bytes — well above the 48-byte struct, well below any vector.
        THRESHOLD_C1 = 128
        for h in [MORK._var_children, MORK._size_children, MORK._arity_children]
            n = @allocated (
                count=0;
                for b in h(rz)

                    count += Int(b)
                end;
                count
            )
            @test n <= THRESHOLD_C1
            @info "$(nameof(h)): $n bytes (threshold $THRESHOLD_C1)"
        end
    end

    # ── C2: driver loop per-step budget ──────────────────────────────────────
    @testset "C2: space_metta_calculus! — per-step alloc budget" begin
        s = new_space()
        for i in 1:5
            space_add_all_sexpr!(s, "(isa node$i type$i)")
            space_add_all_sexpr!(
                s, "(exec 0 (, (isa node$i type$i)) (, (confirmed node$i)))"
            )
        end
        space_metta_calculus!(s, typemax(Int))  # JIT warmup run

        for i in 1:5
            space_add_all_sexpr!(s, "(exec 0 (, (isa node$i type$i)) (, (c2_node$i)))")
        end
        allocs = @allocated space_metta_calculus!(s, typemax(Int))
        per_step = allocs / 5

        # Threshold: 90 KB/step (baseline measured 67 KB post-pjoin-skip; ~33%
        # headroom for JIT/measurement noise). Catches re-introduction of the
        # pjoin path on data rules (~+12 KB) or collect/vcat (~+few KB).
        # Previously 220 KB against the old 165 KB baseline — retightened after
        # the pjoin skip dropped actual to 67 KB.
        THRESHOLD_C2 = 90_000
        @test per_step <= THRESHOLD_C2
        @info "space_metta_calculus! per step: $(round(Int, per_step)) bytes (threshold $THRESHOLD_C2)"
    end

    # ── C3: structural prefix helper returns correct values ──────────────────
    @testset "C3: _pat_overlaps_exec_prefix — structural walk, not flat scan" begin
        # pat_expr is ALWAYS the `(, …)` / `(I …)` conjunction the exec matches over (interpret
        # requires the `,`/`I` functor). A conjunct can bind the just-removed exec — so the fast path
        # (skipping the ~12KB re-insert) must be SKIPPED — iff it is a bare variable, a variable-headed
        # compound OF EXEC'S ARITY (`(exec loc pat tpl)` == 4), or literally `(exec …)`. Everything else
        # keeps the fast path. Updated 2026-07-23 with the fix to the bare-variable case (a byte-scan
        # for the literal `exec` prefix missed it — Control_02/03 produced no output). raw"..." strings
        # don't interpolate — $x is a literal dollar + name.
        needs_exec = [
            raw"(, $x)",                        # bare-variable conjunct — matches the exec itself (THE BUG CASE)
            raw"(, (exec $l $p $t))",           # explicit meta-rule matching execs
            raw"(, ($h $a $b $c))",             # variable head, arity 4 == exec's arity
            raw"(, (isa $x bird) $y)"          # a LATER bare-variable conjunct still counts
        ]
        for p in needs_exec
            @test MORK._pat_overlaps_exec_prefix(MORK.sexpr_to_expr(p)) == true
        end

        # Data conjunctions must return false → fast path (no re-insert).
        fast_path = [
            raw"(, (isa $x thing))",            # concrete head ≠ exec → cannot match (exec …)
            raw"(, (edge $a $b))",
            raw"(, ($x $y))",                   # var head but arity 2 ≠ 4 → cannot match the arity-4 exec
            raw"(, (isa $x bird) (edge $a $b))" # multi-factor data rule
        ]
        for p in fast_path
            @test MORK._pat_overlaps_exec_prefix(MORK.sexpr_to_expr(p)) == false
        end

        # Integration: data exec rule produces results after the optimization.
        s = new_space()
        space_add_all_sexpr!(s, "(isa robin bird) (isa sparrow bird)")
        space_add_all_sexpr!(s, raw"(exec 0 (, (isa $x bird)) (, (confirmed $x)))")
        space_metta_calculus!(s, 1000)
        out = space_dump_all_sexpr(s)
        @test any(occursin("confirmed robin", l) for l in split(out, "\n"))
        @test any(occursin("confirmed sparrow", l) for l in split(out, "\n"))
    end

end
