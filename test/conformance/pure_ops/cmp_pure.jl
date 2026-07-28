using MORK

const DIR = ENV["PROBES"]

# Same escaping the conformance gate uses: upstream writes RAW bytes, our dump escapes them.
_norm(b::Vector{UInt8}) =
    join(map(c -> (0x20 <= c < 0x7f) ? string(Char(c)) : "\\x" * string(c; base = 16, pad = 2), b))

"Parse `(opname payload)` lines into opname => payload-rendering."
function parse_lines(lines::Vector{String})
    d = Dict{String, String}()
    for l in lines
        s = strip(l)
        (isempty(s) || !startswith(s, "(")) && continue
        # `split` is codepoint-safe; byte-index slicing here threw StringIndexError on payloads
        # containing bytes >= 0x80 (which most pure ops produce). Harness bug, not an engine one.
        body = s[nextind(s, firstindex(s)):prevind(s, lastindex(s))]
        parts = split(body, ' '; limit = 2)
        d[String(parts[1])] = length(parts) > 1 ? String(strip(parts[2])) : ""
    end
    d
end

function upstream_of(raw_path)
    raw = read(raw_path)
    lines = String[]
    start = 1
    for i in eachindex(raw)
        if raw[i] == UInt8('\n')
            i > start && push!(lines, _norm(raw[start:(i - 1)]))
            start = i + 1
        end
    end
    start <= length(raw) && push!(lines, _norm(raw[start:end]))
    parse_lines(lines)
end

function ours_of(mm2_path)
    s = MORK.new_space()
    MORK.space_add_all_sexpr!(s, read(mm2_path, String))
    MORK.space_metta_calculus!(s, 5000)
    # Normalise OUR lines the same way upstream's raw bytes are normalised, or the comparison
    # comes down to escaping style rather than content (that produced ~90 phantom divergences).
    raw_lines = String.(split(MORK.space_dump_all_sexpr(s), '\n'))
    parse_lines([_norm(Vector{UInt8}(codeunits(l))) for l in raw_lines])
end

tot = miss_ours = miss_up = wrong = agree = 0
report = Tuple{String, String, String, String}[]
for f in sort(readdir(DIR))
    endswith(f, ".mm2") || continue
    base = replace(f, ".mm2" => "")
    rawp = joinpath(DIR, base * ".raw")
    isfile(rawp) || continue
    up = upstream_of(rawp)
    ours = try
        Base.invokelatest(ours_of, joinpath(DIR, f))
    catch e
        println("!! $base OUR ENGINE THREW: ", first(sprint(showerror, e), 120))
        Dict{String, String}()
    end
    for (op, uval) in up
        op == "n" && continue
        global tot += 1
        if !haskey(ours, op)
            global miss_ours += 1
            push!(report, (op, "<ABSENT>", uval, base))
        elseif ours[op] != uval
            global wrong += 1
            push!(report, (op, ours[op], uval, base))
        else
            global agree += 1
        end
    end
    for (op, oval) in ours
        op == "n" && continue
        if !haskey(up, op)
            global miss_up += 1
            push!(report, (op, oval, "<UPSTREAM ABSENT>", base))
        end
    end
end

println("\n=== PURE OP DIFFERENTIAL ===")
println("ops compared      : $tot")
println("AGREE             : $agree")
println("we produce nothing: $miss_ours")
println("wrong value/width : $wrong")
println("upstream nothing  : $miss_up   (we emit where upstream errors)")
println("\n--- divergences ---")
for (op, o, u, b) in sort(report)
    println(rpad(op, 26), " ours=", rpad(o, 26), " upstream=", u)
end
