# Space & Rules Guide

A **Space** is MORK's central computation unit — a mutable collection of
atoms (s-expressions) together with rewrite rules that drive computation.

---

## Creating and Populating a Space

```julia
using MORK

s = new_space()

# Add atoms from multi-line s-expression text
space_add_all_sexpr!(s, """
    (person alice 30)
    (person bob   25)
    (person carol 35)
""")

# Add a single atom
space_add_sexpr!(s, "(person dave 28)")
```

All atoms are immediately indexed.  Duplicate insertion is idempotent.

---

## Atom Format — S-Expressions

MORK atoms are **s-expressions**: symbols, variables, and nested
expressions.

| Syntax | Meaning | Example |
|--------|---------|---------|
| `word` | Symbol | `alice`, `isa`, `+` |
| `$name` | Variable (in patterns) | `$x`, `$person` |
| `42`, `3.14` | Numeric literals | `42`, `3.14` |
| `(f a b)` | Compound expression | `(isa alice human)` |

---

## Writing Rules

Rules are atoms with the special `exec` head:

```
(exec PRIORITY MATCH OUTPUT)
```

| Field | Description |
|-------|-------------|
| `PRIORITY` | Integer or tuple — rules fire in ascending order |
| `MATCH` | `,` (comma) combinator listing source patterns |
| `OUTPUT` | `O` combinator listing output atoms or sink operations |

### Simple Rule

```julia
space_add_all_sexpr!(s, """
    ;; For every person atom, create a greeting
    (exec 0
        (, (person \$name \$age))
        (O (greeting \$name))
    )
""")
```

### Multi-Pattern Match

The `,` combinator requires **all** patterns to match simultaneously
(conjunction over the space).  Variables are unified across patterns:

```julia
space_add_all_sexpr!(s, """
    ;; Find siblings: same parent, different child
    (exec 0
        (, (parent \$p \$a) (parent \$p \$b))
        (O (siblings \$a \$b))
    )
""")
```

### Multiple Outputs

```julia
space_add_all_sexpr!(s, """
    (exec 0
        (, (temperature \$t))
        (O
            (celsius    \$t)                ;; keep original
            (fahrenheit (* \$t 1.8) + 32)  ;; add derived fact
        )
    )
""")
```

---

## Running the Calculus

```julia
max_steps = 100_000
steps = space_metta_calculus!(s, max_steps)

if steps < max_steps
    println("Converged in $steps steps")
else
    println("Hit step cap — may not be at fixed point")
end
```

The calculus repeatedly applies all enabled rules until no rule fires
(fixed point) or the step cap is reached.

**Step cap guidance:** For small examples, `1_000` is sufficient.
For production spaces with many rules, `100_000` or more may be needed.
Never use `typemax(Int)` — always set an explicit cap.

---

## Querying the Space

```julia
# Check atom existence
space_has_sexpr(s, "(greeting alice)")   # true/false

# Count atoms
space_atom_count(s)

# Dump all atoms (for debugging)
println(space_dump_all_sexpr(s))

# Pattern query — returns list of binding sets
bindings = space_query_sexpr(s, "(greeting \$name)")
for b in bindings
    println(b)   # Dict{Symbol, Expr} of variable → value
end
```

### Multi-Pattern Query

```julia
results = space_query_multi_i(s, [
    "(person \$x \$age)",
    "(greeting \$x)"
])
```

---

## Rule Priority

Rules fire in ascending priority order.  Lower priority numbers fire
first.  When multiple rules have the same priority, they all fire in
the same pass.

```julia
space_add_all_sexpr!(s, """
    ;; Phase 1: collect data
    (exec 0 (, (raw \$x))    (O (processed \$x)))
    ;; Phase 2: aggregate (fires after phase 1 has stabilised)
    (exec 1 (, (processed \$x)) (O (done \$x)))
""")
```

For fine-grained ordering within a priority level, use tuple priorities:

```julia
# (1) fires before (2) which fires before (3)
(exec (0 1) ...)
(exec (0 2) ...)
(exec (0 3) ...)
```

---

## Space Snapshots

Save and restore space state:

```julia
snapshot = space_backup(s)
space_metta_calculus!(s, 10_000)
# If results are undesirable:
space_restore!(s, snapshot)
```

---

## Complete Example — Transitive Closure

```julia
s = new_space()
space_add_all_sexpr!(s, """
    (edge a b)
    (edge b c)
    (edge c d)

    ;; Direct edges are reachable
    (exec 0
        (, (edge \$x \$y))
        (O (reachable \$x \$y))
    )

    ;; Transitive: if x reaches y and y reaches z, then x reaches z
    (exec 1
        (, (reachable \$x \$y) (reachable \$y \$z))
        (O (reachable \$x \$z))
    )
""")

space_metta_calculus!(s, 10_000)
println(space_dump_all_sexpr(s))
# => (reachable a b), (reachable a c), (reachable a d),
#    (reachable b c), (reachable b d), (reachable c d), ...
```
