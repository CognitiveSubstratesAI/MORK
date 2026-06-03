using BenchmarkTools
using MORK
using PathMap
const PM = PathMap.PathMap

# ── Setup helpers — build fresh state per sample ──────────────────────────────

function setup_ground_space(n::Int)
    s = new_space()
    for i in 1:n
        space_add_all_sexpr!(s, string("(fact atom", i, ")"))
    end
    space_add_all_sexpr!(s, raw"(exec 0 (, (fact $x)) (O (found $x)))")
    s
end

function setup_two_source_space(n::Int)
    s = new_space()
    for i in 1:n
        space_add_all_sexpr!(s, string("(left l", i, ")"))
        space_add_all_sexpr!(s, string("(right r", i, ")"))
    end
    space_add_all_sexpr!(s, raw"(exec 0 (, (left $x) (right $y)) (O (pair $x $y)))")
    s
end

function setup_float_sink_space(n::Int)
    s = new_space()
    for i in 1:n
        space_add_all_sexpr!(s, string("(reading ", float(i), ")"))
    end
    space_add_all_sexpr!(s, raw"(exec 0 (, (reading $x)) (O (fsum total by $x)))")
    s
end

function setup_chain_space()
    s = new_space()
    space_add_all_sexpr!(s,
        raw"(state 0)" * "\n" * raw"(exec 0 (, (state $n)) (O (state (+ $n 1))))")
    s
end

function setup_pm_1k()
    m = PM{Int}()
    for i in 1:1000
        set_val_at!(m, Vector{UInt8}(string("key:", i)), i)
    end
    m
end

function setup_pm_500_pair()
    a, b = PM{Nothing}(), PM{Nothing}()
    for i in 1:500
        set_val_at!(a, Vector{UInt8}(string("a:key", i)), nothing)
        set_val_at!(b, Vector{UInt8}(string("b:key", i)), nothing)
    end
    a, b
end

function setup_pm_500_overlap()
    a, b = PM{Nothing}(), PM{Nothing}()
    for i in 1:500
        set_val_at!(a, Vector{UInt8}(string("shared:key", i)), nothing)
        set_val_at!(b, Vector{UInt8}(string("shared:key", i)), nothing)
        i <= 250 && set_val_at!(a, Vector{UInt8}(string("only_a:key", i)), nothing)
    end
    a, b
end

function setup_pm_100_bool()
    m = PM{Bool}()
    for i in 1:100
        set_val_at!(m, Vector{UInt8}(string("path:", i)), true)
    end
    m
end

function setup_serialized_io(n::Int)
    m = setup_pm_100_bool()
    io = IOBuffer()
    serialize_paths(m, io)
    seekstart(io)
    io
end

# ── Benchmark kernels — what actually gets timed ──────────────────────────────

run_calculus(s, steps) = space_metta_calculus!(s, steps)

function insert_1k()
    m = PM{Int}()
    for i in 1:1000
        set_val_at!(m, Vector{UInt8}(string("key:", i)), i)
    end
    m
end

function lookup_1k(m)
    v = 0
    for i in 1:1000
        r = get_val_at(m, Vector{UInt8}(string("key:", i)))
        v += r === nothing ? 0 : r
    end
    v
end

function serialize_100(m)
    io = IOBuffer()
    serialize_paths(m, io)
    io
end

function deserialize_100(io)
    seekstart(io)
    m = PM{Bool}()
    deserialize_paths(m, io, true)
    m
end

# ── BenchmarkGroup ────────────────────────────────────────────────────────────

const SUITE = BenchmarkGroup()

# space: measure only calculus (setup excluded from timing)
SUITE["space"] = BenchmarkGroup(["calculus"])
SUITE["space"]["ground_match_200"] = @benchmarkable run_calculus(s, 999_999) setup=(
    s=setup_ground_space(200)
)
SUITE["space"]["two_source_10x10"] = @benchmarkable run_calculus(s, 999_999) setup=(
    s=setup_two_source_space(10)
)
SUITE["space"]["float_sinks_fsum_50"] = @benchmarkable run_calculus(s, 999_999) setup=(
    s=setup_float_sink_space(50)
)
SUITE["space"]["chain_100_steps"] = @benchmarkable run_calculus(s, 100) setup=(
    s=setup_chain_space()
)
SUITE["space"]["build_200_atoms"] = @benchmarkable setup_ground_space(200)

# pathmap: core trie ops
SUITE["pathmap"] = BenchmarkGroup(["trie"])
SUITE["pathmap"]["insert_1k"] = @benchmarkable insert_1k()
SUITE["pathmap"]["lookup_1k"] = @benchmarkable lookup_1k(m) setup=(m=setup_pm_1k())
SUITE["pathmap"]["pjoin_500"] = @benchmarkable pjoin(a, b) setup=(
    (a, b)=setup_pm_500_pair()
)
SUITE["pathmap"]["psubtract_500"] = @benchmarkable psubtract(a, b) setup=(
    (a, b)=setup_pm_500_overlap()
)
SUITE["pathmap"]["serialize_100"] = @benchmarkable serialize_100(m) setup=(
    m=setup_pm_100_bool()
)
SUITE["pathmap"]["deserialize_100"] = @benchmarkable deserialize_100(io) setup=(
    io=setup_serialized_io(100)
)

# expr: unification patterns
SUITE["expr"] = BenchmarkGroup(["unification"])
SUITE["expr"]["unify_flat_pair"] = @benchmarkable run_calculus(s, 100) setup = begin
    s = new_space()
    space_add_all_sexpr!(s,
        raw"(fact (pair a b))" * "\n" *
        raw"(exec 0 (, (fact (pair $x $y))) (O (got $x $y)))")
end
SUITE["expr"]["unify_nested_tree"] = @benchmarkable run_calculus(s, 100) setup = begin
    s = new_space()
    space_add_all_sexpr!(s,
        raw"(data (tree (node a (node b c))))" * "\n" *
        raw"(exec 0 (, (data (tree (node $x (node $y $z))))) (O (found $x $y $z)))")
end

# ── Run & report ──────────────────────────────────────────────────────────────

if abspath(PROGRAM_FILE) == @__FILE__
    println("Tuning benchmarks...")
    tune!(SUITE)

    println("Running benchmarks...")
    results = run(SUITE; verbose=true)

    println("\n══════════════════════════════════════════════════════")
    println("  MORK / PathMap Benchmark Results")
    println("══════════════════════════════════════════════════════")
    for (group, grp_results) in sort(collect(results); by=first)
        println("\n[$group]")
        for (name, trial) in sort(collect(grp_results); by=first)
            m = median(trial)
            println(rpad("  $name", 34),
                rpad(BenchmarkTools.prettytime(m.time), 14),
                "$(m.allocs) allocs  $(BenchmarkTools.prettymemory(m.memory))")
        end
    end
end
