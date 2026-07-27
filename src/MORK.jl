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

# Kernel: pure numeric primitives. Ports mork/kernel/src/pure.rs.
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

# ── DyckZipper (experiments/expr/dyck/) ──────────────────────────────────────

# Compact bit-packed binary tree representation using Dyck words.
# Ports experiments/expr/dyck/{dyck_zipper.rs,left_branch_impl.rs,lib.rs} (server branch).
include("expr/DyckZipper.jl")

# Extend PathMap's ez_reset! for ExprZipper so both share a single function object.
# Mirrors ExprZipper::reset in upstream Rust.
import PathMap: ez_reset!
ez_reset!(z::ExprZipper) = (z.loc=1; z)
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
