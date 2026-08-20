# MORK — Julia port of trueagi-io/MORK
# PathMap substrate lives in the PathMap package (sivaji1012/PathMap.git).
# Upstream references:
#   - pathmap: ~/JuliaAGI/dev-zone/PathMap
#   - MORK:    ~/JuliaAGI/dev-zone/MORK (branches: main, origin/server)
module MORK

using Base64
using PathMap

# ── Phase 2: Expression layer (mork/expr/) ────────────────────────────────────

# Core expression types: byte encoding, ExprZipper, ExprEnv.
# Ports mork/expr/src/lib.rs.
include("expr/Expr.jl")

# Expression algorithms: traverseh, ee_args!, unify, apply.
# Ports the algorithmic half of mork/expr/src/lib.rs.
include("expr/ExprAlg.jl")

# ── Phase 3: Interning, frontend, kernel ──────────────────────────────────────

# Symbol interning. Ports mork/interning/src/lib.rs.
include("interning/Interning.jl")

# Frontend parsers: MeTTa sexpr + JSON. Ports mork/frontend/src/.
include("frontend/ImmutableString.jl")
include("frontend/Frontend.jl")
include("frontend/HEParser.jl")
include("frontend/RosettaParser.jl")
include("frontend/CZ2Parser.jl")
include("frontend/CZ3Parser.jl")

# Kernel: query source abstraction (BTM/ACT/Z3/CmpSource).
# Ports mork/kernel/src/sources.rs.
include("kernel/Prefix.jl")
include("kernel/Sources.jl")

# Kernel: XXH3-128. Ports xxhash-rust's const_xxh3.rs, which is what upstream
# `Expr::hash()` (mork/expr/src/lib.rs:310) actually resolves to in this
# workspace: cfg(gxhash) is OFF, so gxhash128 is the stub at lib.rs:76 that
# forwards to `xxhash_rust::const_xxh3::xxh3_128`. Must precede Pure.jl (the
# `hash_expr` pure-op is its consumer).
include("kernel/XXH3.jl")

# Kernel: the evaluator. Eval.jl <- mork/experiments/eval/src/lib.rs (registry + STACK MACHINE),
# plus the `eval-ffi` crate's TYPES, which live in the same file because that crate exists only for
# the C ABI (`no_std`, `repr(C)`, `extern "C"` FuncPtr) and we port none of it — the substrate stays
# Julia-native. Named for the CRATE, not a type: it was `EvalScope.jl` until 2026-07-30.
#
# ⚠️ BOTH PRECEDE Pure.jl, which is upstream's own dependency direction. They used to come AFTER it,
# because this file hosted the registration loop — but that loop is upstream's `pub fn register`,
# which lives in pure.rs. It moved to the end of Pure.jl and the include order followed the real
# dependency.
include("kernel/Eval.jl")

# Kernel: the arity constants upstream's `op!` arms hard-code, extracted from pure.rs and vendored.
include("kernel/PureOpArity.jl")

# Kernel: pure numeric primitives. Ports mork/kernel/src/pure.rs — INCLUDING its `pub fn register`
# (pure.rs:910-1300), which is the last thing in this file exactly as it is the last thing in that
# one. Must follow the two above: `pure_register!` reads PURE_REGISTER/PURE_OP_ARITY and calls into
# the EvalScope API.
include("kernel/Pure.jl")

# Kernel: write sinks. Ports mork/kernel/src/sinks.rs.
include("kernel/Sinks.jl")

# Kernel: Space + query engine. Ports mork/kernel/src/space.rs.
include("kernel/Space.jl")

# Kernel: top-level entry points. Ports mork/kernel/src/main.rs.
include("kernel/Main.jl")

# ── Server layer ──────────────────────────────────────────────────────────────
#
# Lives in the separate MorkServer package (sivaji1012/MorkServer) so kernel
# consumers (Core, MorkSupercompiler, etc.) don't pull HTTP + JSON3 transitive
# deps for code they never use. Same split as upstream Rust's kernel/ crate vs
# server/ crate. Files previously included from `src/server/` moved to
# `packages/MorkServer/src/` on 2026-05-30 (this commit). Pkg-add MorkServer
# explicitly if you need the HTTP layer.

# ── MorkL VM (experiments/morkl_interpreter/) ─────────────────────────────────

# Register-based VM for relational trie algebra.
# Ports experiments/morkl_interpreter/src/{lib.rs,cf_iter.rs} (server branch).
include("morkl/MorkL.jl")

# ── TrieJoin (ADR-056 Lever A, P1) ────────────────────────────────────────────
# Empty-tail conjunctive join via trie meet (pmeet) instead of naive ProductZipper.
# Substrate primitive only — not yet wired into _space_query_multi_inner! (phase P1b).
include("kernel/TrieJoin.jl")
export trie_argset, trie_join_unary

# ── Leapfrog (upstream kernel/src/leapfrog.rs, MORK PR #146) ─────────────────
# Worst-case-optimal unification join. Being adopted BOTTOM-UP, each layer validated before the
# next carries it — LAYER 1 ONLY so far (byte-scan + resumable subterm parser, no zipper, no join).
# ⚠️ NO CONSUMER YET AND THAT IS DELIBERATE: `_space_query_multi_inner!` is untouched, so the live
# engine still takes the P5 `_connected_join_emit!` path. Wiring happens when the join exists and
# is gated against it, not before. [[feedback_parses_is_not_fires]]
# WHY: measured 2026-08-20 on upstream's clique4 generator — ours 19 080 ms vs leapfrog 175 ms at
# 200x3600, with OUR exponent the worst of the three (145x vs 54x vs 6.3x). See Leapfrog.jl header.
include("kernel/Leapfrog.jl")
# The engine-facing entry (upstream `query_multi_leapfrog`). Separate file because it sits ABOVE the
# Leapfrog module and below Space.jl's contract — it is routing, not join machinery.
include("kernel/LeapfrogEntry.jl")
using .Leapfrog: subterm_parse_step, least_ge, is_complete

# ── DyckZipper (experiments/expr/dyck/) ──────────────────────────────────────

# Compact bit-packed binary tree representation using Dyck words.
# Ports experiments/expr/dyck/{dyck_zipper.rs,left_branch_impl.rs,lib.rs} (server branch).
include("expr/DyckZipper.jl")

# Extend PathMap's ez_reset! for ExprZipper so both share a single function object.
# Ports ExprZipper::reset (expr/src/lib.rs:1412-1419).
#
# ⚠️ This was `z.loc = 1` alone until the breadcrumb trace was ported. Upstream's reset ALSO clears
# the trace and re-pushes the root frame — without that, a reset zipper keeps the stack from wherever
# it had walked to, and the trace-based traversal would resume mid-expression. Thirteen kernel call
# sites reset zippers, so the two halves have to move together.
import PathMap: ez_reset!
function ez_reset!(z::ExprZipper)
    z.loc = 1
    z.trace = nothing     # dropped, not rebuilt — it re-materialises at the root on next use
    z
end
export ez_reset!

"""
    version() -> VersionNumber
"""
version() = v"0.1.0"

export version
# Grounding mechanism (Phase 2) — re-exported from kernel/Sources.jl
export GROUNDED_REGISTRY, register_grounded!, is_grounded

# PrecompileTools workload — caches hot method instances during Pkg.precompile().
include("precompile.jl")

end # module MORK
