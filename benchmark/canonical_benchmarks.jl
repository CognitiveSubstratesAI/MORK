"""
Canonical MORK benchmark suite — Julia port of upstream kernel/bench_scripts/.

Benchmarks mirror the 11 workloads tracked by parse_mork_bench.py:
  3-clique, 4-clique, 5-clique, counter_machine, exponential,
  exponential_fringe, finite_domain, odd_even_sort, process_calculus,
  transitive_trans, transitive_detect

Upstream source: ~/dev-zone/MORK/kernel/src/main.rs
  bench_clique_no_unify   (lines 4465–4543)
  bench_transitive_no_unify (lines 4424–4465)
  bench_cm0               (lines 3622–3700)
  exponential             (lines 4831–4860)
  exponential_fringe      (lines 4861–4900)
  bench_finite_domain     (lines 4543–4620)
  sink_odd_even_sort      (lines 2339–2390)
  process_calculus_bench  (lines 227–270)
"""

using BenchmarkTools
using MORK

const SUITE_CANONICAL = BenchmarkGroup()

# ── Helpers ───────────────────────────────────────────────────────────────────

"""Deterministic seeded PRNG — mirrors StdRng::from_seed([0;32]) in Rust."""
mutable struct SeededRNG
    state::UInt64
end
SeededRNG() = SeededRNG(0x12345678ABCDEF01)

function next_rand!(rng::SeededRNG, n::Int)
    rng.state = rng.state * 6364136223846793005 + 1442695040888963407
    Int(rng.state >> 33) % n
end

"""Build clique-detection query for k nodes. Mirrors clique_query() in main.rs."""
function clique_query(k::Int)
    edges = join(["(edge \$x$i \$x$j)" for i in 0:(k - 1) for j in (i + 1):(k - 1)], " ")
    vars = join(["\$x$i" for i in 0:(k - 1)], " ")
    "(exec 0 (, $edges) (, ($k-clique $vars)))"
end

"""Build Peano numeral string for n."""
function peano(n::Int)
    n == 0 ? "Z" : "(S $(peano(n-1)))"
end

# ── 1. k-Clique (3, 4, 5) ─────────────────────────────────────────────────────
# Upstream: bench_clique_no_unify(200, 3600, 5)
# Scaled down: 50 nodes, 400 edges → runs in <5s for 3-clique

SUITE_CANONICAL["clique"] = BenchmarkGroup(["graph"])

function setup_clique_space(nnodes::Int, nedges::Int)
    rng = SeededRNG()
    s = new_space()
    edges = Set{String}()
    while length(edges) < nedges
        i = next_rand!(rng, nnodes)
        j = next_rand!(rng, nnodes)
        i == j && continue
        i, j = minmax(i, j)
        push!(edges, "(edge $i $j)")
    end
    space_add_all_sexpr!(s, join(edges, "\n"))
    s
end

for k in 3:5
    SUITE_CANONICAL["clique"]["$(k)-clique"] = @benchmarkable begin
        s2 = deepcopy(s)
        space_add_all_sexpr!(s2, $(clique_query(k)))
        space_metta_calculus!(s2, 1)
    end setup=(s=setup_clique_space(50, 400)) seconds=30
end

# ── 2. Transitive closure ──────────────────────────────────────────────────────
# Upstream: bench_transitive_no_unify(50000, 1000000) — scaled to 200 nodes, 600 edges

SUITE_CANONICAL["transitive"] = BenchmarkGroup(["graph"])

function setup_transitive_space(nnodes::Int, nedges::Int)
    rng = SeededRNG()
    s = new_space()
    edges = String[]
    for _ in 1:nedges
        i = next_rand!(rng, nnodes)
        j = next_rand!(rng, nnodes)
        push!(edges, "(edge $i $j)")
    end
    space_add_all_sexpr!(s, join(edges, "\n"))
    s
end

SUITE_CANONICAL["transitive"]["transitive_trans"] = @benchmarkable begin
    s2 = deepcopy(s)
    space_add_all_sexpr!(s2, raw"(exec 0 (, (edge $x $y) (edge $y $z)) (, (trans $x $z)))")
    space_metta_calculus!(s2, 999_999)
end setup=(s=setup_transitive_space(200, 600)) seconds=15

SUITE_CANONICAL["transitive"]["transitive_detect"] = @benchmarkable begin
    s2 = deepcopy(s)
    space_add_all_sexpr!(
        s2,
        raw"(exec 0 (, (edge $x $y) (edge $y $z) (edge $z $w)) (, (dtrans $x $y $z $w)))"
    )
    space_metta_calculus!(s2, 999_999)
end setup=(s=setup_transitive_space(200, 600)) seconds=15

# ── 3. Counter machine ─────────────────────────────────────────────────────────
# Upstream: bench_cm0(3) — Peano counter machine copying register 2 to register 3
# Scaled: copy=2 (Peano SS Z = 2 steps)

SUITE_CANONICAL["counter_machine"] = BenchmarkGroup(["simulation"])

function counter_machine_src(to_copy::Int)
    """
    (program Z (JZ 2 (S (S (S (S (S Z)))))))
    (program (S Z) (DEC 2))
    (program (S (S Z)) (INC 3))
    (program (S (S (S Z))) (INC 1))
    (program (S (S (S (S Z)))) (JZ 0 Z))
    (program (S (S (S (S (S Z))))) (JZ 1 (S (S (S (S (S (S (S (S (S Z)))))))))))
    (program (S (S (S (S (S (S Z)))))) (DEC 1))
    (program (S (S (S (S (S (S (S Z))))))) (INC 2))
    (program (S (S (S (S (S (S (S (S Z)))))))) (JZ 0 (S (S (S (S (S Z)))))))
    (program (S (S (S (S (S (S (S (S (S Z))))))))) H)
    (state Z (REG 0 Z))
    (state Z (REG 1 Z))
    (state Z (REG 2 $(peano(to_copy))))
    (state Z (REG 3 Z))
    (state Z (REG 4 Z))
    (state Z (IC Z))
    (if (S \$n) \$x \$y \$x)
    (if Z \$x \$y \$y)
    (0 != 1) (0 != 2) (0 != 3) (0 != 4)
    (1 != 0) (1 != 2) (1 != 3) (1 != 4)
    (2 != 1) (2 != 0) (2 != 3) (2 != 4)
    (3 != 1) (3 != 2) (3 != 0) (3 != 4)
    (4 != 1) (4 != 2) (4 != 0) (4 != 3)
    ((step JZ \$ts)
      (, (state \$ts (IC \$i)) (program \$i (JZ \$r \$j)) (state \$ts (REG \$r \$v)) (if \$v (S \$i) \$j \$ni) (state \$ts (REG \$k \$kv)))
      (, (state (S \$ts) (IC \$ni)) (state (S \$ts) (REG \$k \$kv))))
    ((step INC \$ts)
      (, (state \$ts (IC \$i)) (program \$i (INC \$r)) (state \$ts (REG \$r \$v)) (\$r != \$o) (state \$ts (REG \$o \$ov)))
      (, (state (S \$ts) (IC (S \$i))) (state (S \$ts) (REG \$r (S \$v))) (state (S \$ts) (REG \$o \$ov))))
    ((step DEC \$ts)
      (, (state \$ts (IC \$i)) (program \$i (DEC \$r)) (state \$ts (REG \$r (S \$v))) (\$r != \$o) (state \$ts (REG \$o \$ov)))
      (, (state (S \$ts) (IC (S \$i))) (state (S \$ts) (REG \$r \$v)) (state (S \$ts) (REG \$o \$ov))))
    (exec (clocked Z)
            (, (exec (clocked \$ts) \$p1 \$t1)
               (state \$ts (IC \$_))
               ((step \$k \$ts) \$p0 \$t0))
            (, (exec (\$k \$ts) \$p0 \$t0)
               (exec (clocked (S \$ts)) \$p1 \$t1)))
    """
end

SUITE_CANONICAL["counter_machine"]["cm_copy2"] = @benchmarkable begin
    s = new_space()
    space_add_all_sexpr!(s, src)
    space_metta_calculus!(s, 999_999)
end setup=(src=counter_machine_src(2)) seconds=30

# ── 4. Exponential growth ──────────────────────────────────────────────────────
# Upstream: exponential(max_steps) — space doubles each step via M/W bifurcation

SUITE_CANONICAL["exponential"] = BenchmarkGroup(["growth"])

const EXPONENTIAL_SRC = raw"""
((step app)
 (, (num $1) )
 (, (num (M $1))
    (num (W $1)) ))
((step app)
 (, (num (M $1))
    (num (W $1)) )
 (, (num (C $1)) ))
(num Z)
(exec metta
      (, ((step $x) $p0 $t0)
         (exec metta $p1 $t1) )
      (, (exec $x $p0 $t0)
         (exec metta $p1 $t1) ))
"""

SUITE_CANONICAL["exponential"]["exponential_500"] = @benchmarkable begin
    s = new_space()
    space_add_all_sexpr!(s, EXPONENTIAL_SRC)
    space_metta_calculus!(s, 500)
end seconds=15

# ── 5. Exponential fringe ──────────────────────────────────────────────────────
# Upstream: exponential_fringe(steps) — layered growth with successor chain

function exponential_fringe_src(n_layers::Int)
    succs = join(["(succ $i $(i+1))" for i in 0:(n_layers - 1)], "\n")
    """
$succs
((step meet \$k)
 (, (num \$k \$1) (succ \$k \$sk) )
 (, (num \$sk (M \$1))
    (num \$sk (W \$1)) ))
((step join \$k)
 (, (num \$k (M \$1)) (succ \$k \$sk)
    (num \$k (W \$1)) )
 (, (num \$sk (C \$1)) ))
(num 0 Z)
(exec (metta 0)
      (, (exec (metta \$k) \$p1 \$t1) (succ \$k \$sk)
         ((step \$x \$k) \$p0 \$t0) )
      (, (exec (0 \$x) \$p0 \$t0)
         (exec (metta \$sk) \$p1 \$t1) ))
"""
end

SUITE_CANONICAL["exponential"]["exponential_fringe_4"] = @benchmarkable begin
    s = new_space()
    space_add_all_sexpr!(s, src)
    space_metta_calculus!(s, 999_999_999)
end setup=(src=exponential_fringe_src(4)) seconds=15

# ── 6. Odd-even sort ──────────────────────────────────────────────────────────
# Upstream: sink_odd_even_sort — sorts 5 elements A..E using +/- update sinks
#
# ⚠ Rule-of-64 note: the phase rule pattern has 5 sources (ExprArity=6).
# Julia MORK warns "6 sources (>4) may be slow" because the 5-factor
# ProductZipper must traverse O(btm_atoms^5) path combinations — exponential.
# In Rust, native speed makes this tractable. In Julia, the same workload is
# ~100x slower. The benchmark is capped at seconds=15 to measure throughput
# within the timeout rather than waiting for convergence.

SUITE_CANONICAL["odd_even_sort"] = BenchmarkGroup(["sorting"])

const ODD_EVEN_SRC = raw"""
(lt A B) (lt A C) (lt A D) (lt A E) (lt B C) (lt B D) (lt B E) (lt C D) (lt C E) (lt D E)
(succ 0 1) (succ 1 2) (succ 2 3) (succ 3 4) (succ 4 5)
(parity 0 even) (parity 1 odd) (parity 2 even) (parity 3 odd) (parity 4 even)
(A 0 B)
(A 1 A)
(A 2 E)
(A 3 C)
(A 4 D)
((phase $p)  (, (parity $i $p) (succ $i $si) (A $i $e) (A $si $se) (lt $se $e))
             (O (- (A $i $e)) (- (A $si $se)) (+ (A $i $se)) (+ (A $si $e))))
(phase 0 odd) (phase 1 even)
(exec repeat (, (A $k $_) (phase $kp $phase) ((phase $phase) $p0 $t0))
             (, (exec ($k $kp) $p0 $t0)))
"""

# Capped at 5 steps: measures 5-factor ProductZipper throughput rather than convergence.
SUITE_CANONICAL["odd_even_sort"]["sort_5_elements"] = @benchmarkable begin
    s = new_space()
    space_add_all_sexpr!(s, ODD_EVEN_SRC)
    space_metta_calculus!(s, 5)
end seconds=15

# ── 7. Process calculus (concurrent counter machine) ─────────────────────────
# Upstream: process_calculus_bench(steps=1000, x=3, y=1)

function process_calculus_src(x::Int, y::Int)
    """
(exec (IC 0 1 {})
               (, (exec (IC \$x \$y (S \$c)) \$sp \$st)
                  ((exec \$x) \$p \$t))
               (, (exec (IC \$y \$x \$c) \$sp \$st)
                  (exec (R \$x) \$p \$t)))
((exec 0)
 (, (exec 0 \$p \$t))
 (, (exec 0 \$p \$t) (! result \$p \$t)))
((exec 1)
 (, (exec 1 \$p \$t))
 (, (exec 1 \$p \$t) (! result \$p \$t)))
(exec (R 0) (, (exec (R 0) \$p \$t)) (, (exec 0 \$p \$t)))
(exec (R 1) (, (exec (R 1) \$p \$t)) (, (exec 1 \$p \$t)))
    """
end

SUITE_CANONICAL["process_calculus"] = BenchmarkGroup(["simulation"])

SUITE_CANONICAL["process_calculus"]["pc_1000_steps"] = @benchmarkable begin
    s = new_space()
    space_add_all_sexpr!(s, src)
    space_metta_calculus!(s, 1000)
end setup=(src=process_calculus_src(3, 1)) seconds=15

# ── 8. Finite domain arithmetic ───────────────────────────────────────────────
# Upstream: bench_finite_domain(10000) — 10k 4-arg constraint evaluations on 64-element domain
# Scaled: 500 inputs (vs 10k) for fast CI

const FD_SYMS = vcat(
    string.(0:9),
    ["?", "@"],
    collect(string.(collect('A':'Z'))),
    collect(string.(collect('a':'z')))
)  # 64 symbols

function finite_domain_src(n_inputs::Int)
    rng = SeededRNG()
    DS = 64
    function bop(sym, f)
        lines = String[]
        for x in 0:(DS - 1), y in 0:(DS - 1)
            z = f(x, y)
            z == typemax(Int) && continue
            push!(lines, "($(FD_SYMS[x+1]) $sym $(FD_SYMS[y+1]) = $(FD_SYMS[z+1]))")
        end
        join(lines, "\n")
    end
    function uop(sym, f)
        lines = String[]
        for x in 0:(DS - 1)
            z = f(x)
            z == typemax(Int) && continue
            push!(lines, "($sym $(FD_SYMS[x+1]) = $(FD_SYMS[z+1]))")
        end
        join(lines, "\n")
    end
    ops = join(
        [
            bop("+", (x, y) -> (x+y) % DS),
            bop("-", (x, y) -> mod(x-y, DS)),
            bop("*", (x, y) -> (x*y) % DS),
            bop("/", (x, y) -> y==0 ? typemax(Int) : x÷y),
            bop("\\/", (x, y) -> max(x, y)),
            bop("/\\", (x, y) -> min(x, y)),
            uop("sq", x -> (x*x) % DS),
            uop("sqrt", x -> isqrt(x))
        ], "\n")
    args = join(
        [
            "(args $(FD_SYMS[next_rand!(rng,DS)+1]) $(FD_SYMS[next_rand!(rng,DS)+1]) $(FD_SYMS[next_rand!(rng,DS)+1]) $(FD_SYMS[next_rand!(rng,DS)+1]))"
            for _ in 1:n_inputs
        ],
        "\n"
    )
    ops * "\n" * args * "\n" *
    raw"(exec 0 (, (args $x0 $y0 $x1 $y1) ($x0 /\ $x1 = $xl) ($x0 \/ $x1 = $xh) ($y0 /\ $y1 = $yl) ($y0 \/ $y1 = $yh) ($xh - $xl = $dx) ($yh - $yl = $dy) (sq $dx = $dx2) (sq $dy = $dy2) ($dx2 + $dy2 = $d2) (sqrt $d2 = $d)) (, (res $d)))"
end

SUITE_CANONICAL["finite_domain"] = BenchmarkGroup(["arithmetic"])

SUITE_CANONICAL["finite_domain"]["fd_500_inputs"] = @benchmarkable begin
    s = new_space()
    space_add_all_sexpr!(s, src)
    space_metta_calculus!(s, 1)
end setup=(src=finite_domain_src(500)) seconds=30

# ── Runner ────────────────────────────────────────────────────────────────────

if abspath(PROGRAM_FILE) == @__FILE__
    println("Tuning canonical benchmarks...")
    tune!(SUITE_CANONICAL)

    println("Running canonical benchmarks...")
    results = run(SUITE_CANONICAL; verbose=true)

    println("\n══════════════════════════════════════════════════════")
    println("  MORK Canonical Benchmark Results")
    println("══════════════════════════════════════════════════════")
    for (group, grp_results) in sort(collect(results); by=first)
        println("\n[$group]")
        for (name, trial) in sort(collect(grp_results); by=first)
            m = median(trial)
            println(rpad("  $name", 34),
                rpad(BenchmarkTools.prettytime(m.time), 14),
                "$(m.allocs) allocs")
        end
    end
end
