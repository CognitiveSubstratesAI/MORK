# ZAM selectivity diagnostic (Mork_theory_spec §10 — MEASURE before engineering for Σγ>1).
#
# For each leg p of a join, compute the selectivity exponent  γ̂(p) = −log_N(|P(p)|/N),
# where |P(p)| = posting-list size (atoms whose path matches the leg's constant-anchored prefix)
# and N = total atoms. Sum across legs and report the predicted regime (Thm 1):
#   Σγ̂ > 1 → E|P∩| = O(1)         (ZAM streams a constant # of candidates — favorable)
#   Σγ̂ ≈ 1 → Θ(1)
#   Σγ̂ < 1 → Θ(N^(1−Σγ̂))         (sublinear; ZAM still helps; flat → scan-and-unify = WAM baseline)
#
# MORK-native (no MorkSupercompiler dep) so it runs in the warm MORK REPL.
# Prefix encoding mirrors Selectivity.jl `dynamic_count`, extended to LEADING GROUND ARGS.

using MORK: ExprArity, ExprSymbol, item_byte, Space, new_space, space_val_count,
    space_add_all_sexpr!
using PathMaps: read_zipper_at_path, zipper_val_count, zipper_to_next_val!

# ── minimal top-level sexpr tokenizer: "(in 12345 $pre $cnt)" → ["in","12345","\$pre","\$cnt"] ──
function _leg_items(str::AbstractString)::Vector{String}
    s = strip(str)
    (startswith(s, "(") && endswith(s, ")")) ||
        error("leg must be a parenthesized s-expr: $str")
    inner = s[nextind(s, 1):prevind(s, lastindex(s))]
    items = String[]
    depth = 0
    buf = IOBuffer()
    for c in inner
        if c == '('
            depth += 1
            print(buf, c)
        elseif c == ')'
            depth -= 1
            print(buf, c)
        elseif isspace(c) && depth == 0
            t = String(take!(buf))
            isempty(t) || push!(items, t)
        else
            print(buf, c)
        end
    end
    t = String(take!(buf))
    isempty(t) || push!(items, t)
    return items
end

_is_ground_sym(tok::AbstractString) = !startswith(tok, "\$") && !startswith(tok, "(")

# constant-anchored prefix: arity byte + head + leading ground symbols (numbers ARE symbols), stop at first var/sublist
function leg_prefix(str::AbstractString)::Union{Vector{UInt8}, Nothing}
    items = _leg_items(str)
    n = length(items)
    (n == 0 || n > 63) && return nothing
    pre = UInt8[item_byte(ExprArity(UInt8(n)))]
    for tok in items
        _is_ground_sym(tok) || break          # SVar ($..) or nested (..) ends the anchored prefix
        length(tok) > 63 && break
        push!(pre, item_byte(ExprSymbol(UInt8(length(tok)))))
        append!(pre, codeunits(tok))
    end
    return pre
end

# Count |P(p)| by ITERATION (zipper_to_next_val!), not zipper_val_count — the latter is unreliable
# on mmap'd ACT trees (returns 0 for some prefixes depending on StraightPath/LOUDS node structure;
# verified 2026-06-18 on FlyWire S_rule). Iteration matches info_flow's own counting and is exact.
function leg_count(btm, str::AbstractString)::Int
    p = leg_prefix(str)
    p === nothing && return -1
    rz = read_zipper_at_path(btm, p)
    n = 0
    while zipper_to_next_val!(rz)
        n += 1
    end
    return n
end

gamma_hat(count::Int, N::Int)::Float64 =
    (N <= 1 || count <= 0) ? Inf : -log(count / N) / log(N)

# ── join-shape diagnostic (btm + explicit N — works on Space.btm OR a mmap'd ACT tree) ──
function join_selectivity_btm(btm, N::Int, legs::Vector{<:AbstractString})
    rows = map(legs) do l
        c = leg_count(btm, l)
        (leg=l, count=c, gamma=gamma_hat(c, N))
    end
    Σ = sum(r.gamma for r in rows)
    regime = if Σ > 1 + 1e-9
        "Σγ̂>1 → O(1)  [ZAM-FAVORABLE]"
    elseif isapprox(Σ, 1; atol=1e-2)
        "Σγ̂≈1 → Θ(1)"
    else
        "Σγ̂<1 → Θ(N^(1−Σγ̂)) sublinear"
    end
    return (N=N, rows=rows, sum_gamma=Σ, regime=regime)
end

join_selectivity(s::Space, legs::Vector{<:AbstractString}) =
    join_selectivity_btm(s.btm, space_val_count(s), legs)

function report(r)
    println("  N = ", r.N)
    for row in r.rows
        println("    ", rpad(row.leg, 30), " |P|=", rpad(row.count, 10),
            " γ̂=", lpad(round(row.gamma; digits=3), 7))
    end
    println("    Σγ̂ = ", round(r.sum_gamma; digits=3), "   → ", r.regime)
end

# ── self-validation of the encoding (adversarial: symbol AND number leading-ground args) ──
function zam_selfcheck()
    s = new_space()
    space_add_all_sexpr!(
        s,
        join(
            [
                "(parent john a)", "(parent john b)", "(parent john c)",   # parent john → 3
                "(parent mary d)", "(parent mary e)",                       # parent mary → 2
                "(parent bob f)",                                           # parent → 6 total
                "(age a 10)", "(age b 20)", "(age c 30)",                   # age → 3
                "(v 10 a)", "(v 10 b)", "(v 20 c)"                         # NUMBER as leading ground arg
            ], "\n")
    )
    btm = s.btm
    @assert space_val_count(s) == 12 "N"
    @assert leg_count(btm, "(parent \$x \$y)") == 6 "head+arity"
    @assert leg_count(btm, "(parent john \$y)") == 3 "symbol-anchored"
    @assert leg_count(btm, "(parent john a)") == 1 "fully ground"
    @assert leg_count(btm, "(age \$x \$y)") == 3 "head age"
    @assert leg_count(btm, "(v 10 \$x)") == 2 "NUMBER-anchored (10 as leading ground arg)"
    @assert leg_count(btm, "(v 20 \$x)") == 1 "number-anchored 20"
    println(
        "zam_selfcheck PASS — constant-anchored prefix encoding (symbols + numbers) verified"
    )
end

# ── demo on representative join shapes ──
function zam_demo()
    # synthetic connectome-shaped store: (in <post> <pre> <cnt>), one relation, fan-out per post
    s = new_space()
    lines = String[]
    for post in 1:200, pre in 1:50
        push!(lines, "(in $post $pre $(post*pre % 7 + 1))")
    end
    space_add_all_sexpr!(s, join(lines, "\n"))   # 10_000 edges
    println("=== demo: connectome-shaped (in post pre cnt), N=", space_val_count(s), " ===")

    println("[unanchored 2-leg join — both legs bind only head+arity]")
    report(join_selectivity(s, ["(in \$p \$r \$c)", "(in \$r \$q \$d)"]))

    println("[anchored 2-leg join — leg-1 binds post=12]")
    report(join_selectivity(s, ["(in 12 \$r \$c)", "(in \$r \$q \$d)"]))

    println("[both legs anchored on a post constant]")
    report(join_selectivity(s, ["(in 12 \$r \$c)", "(in 7 \$q \$d)"]))
end
