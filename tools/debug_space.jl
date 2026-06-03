#!/usr/bin/env julia
# tools/debug_space.jl — Interactive debugging guide for MORK
#
# Load from warm REPL:
#   include("tools/debug_space.jl")
#
# Prerequisites (install once):
#   using Pkg; Pkg.add(["Debugger", "Cthulhu", "ProfileView"])

println(
    """
MORK Debugging Tools
====================

── Debugger.jl — Step through Julia code interactively ──────────────────

  using Debugger

  # Break at entry to space_metta_calculus!
  s = new_space()
  space_add_all_sexpr!(s, "(fact a)\\n(exec 0 (, (fact \\$x)) (O (done \\$x)))")

  @enter space_metta_calculus!(s, 100)

  # Debugger commands:
  #   n    — step over (next line)
  #   s    — step into function call
  #   so   — step out of current function
  #   c    — continue to next breakpoint
  #   q    — quit debugger
  #   fr   — show current stack frame
  #   `expr — evaluate expr in current context

  # Set a breakpoint at a specific line:
  Debugger.@breakpoint src/kernel/Space.jl 731

── Cthulhu.jl — Type inference descent ──────────────────────────────────

  using Cthulhu

  # Descend into space_metta_calculus! to find type widening / Any types
  s = new_space()
  space_add_all_sexpr!(s, "(fact a)")
  @descend space_metta_calculus!(s, 100)

  # Cthulhu shows type-annotated IR. Look for:
  #   %N  = ... ::Any          ← type widening (bad for performance)
  #   invoke f(...)::Union{...} ← dynamic dispatch (allocates)
  #
  # Navigation keys inside Cthulhu:
  #   Enter  — descend into selected call
  #   B      — go back up
  #   q      — quit
  #   T      — toggle type annotations
  #   O      — toggle optimized IR

  # Check a specific hot function:
  @descend_code_typed space_interpret!(s.btm, sexpr_to_expr("(exec 0 (, (fact \\$x)) (O (done \\$x)))"), 0)

── JET.jl — Static type error detection (already in deps) ───────────────

  using JET

  # Report type errors in the package
  @report_call space_metta_calculus!(new_space(), 100)

  # Full package analysis
  report_package("MORK")

── Profile.jl — CPU profiling ────────────────────────────────────────────

  # See tools/profile_space.jl for a ready-made profiling script
  include("tools/profile_space.jl")

  # After profiling, view flamegraph:
  using ProfileView
  ProfileView.view()

── Quick: find type instabilities ────────────────────────────────────────

  using InteractiveUtils
  s = new_space()
  space_add_all_sexpr!(s, "(fact a)\\n(exec 0 (, (fact \\$x)) (O (done \\$x)))")

  # Show all inferred types (look for ::Any)
  @code_warntype space_metta_calculus!(s, 10)

  # Even more detail:
  @code_typed space_metta_calculus!(s, 10)
"""
)
