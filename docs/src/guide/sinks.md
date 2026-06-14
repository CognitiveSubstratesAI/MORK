# Sources and Sinks

MORK's exec calculus has two extension points around plain pattern matching:
**sources** process the *match* side at query time (the `I` input clause), and
**sinks** process the *output* side at rewrite time (the `O` output clause).

```
(exec PRIORITY (I SOURCE1 SOURCE2 ...) (O SINK1 SINK2 ...))
```

A plain `(, …)` match clause reads the space's trie directly; an `(I …)` clause
lets each pattern be served by a *source* other than the default trie read.

---

## Sources

A **source** supplies the matches for one pattern in an `(I …)` clause. The
functor of the sub-expression selects which source is used (dispatched by
`asource_new` in `src/kernel/Sources.jl`):

| Source | Pattern form | Matches |
|--------|--------------|---------|
| *(default)* | a plain pattern in a `(, …)` clause | the space's BTM trie |
| `BTM` | `(BTM …)` | the `[2] BTM` prefix subtrie |
| `ACT` | `(ACT <name> …)` | a memory-mapped `<name>.act` ArenaCompactTree file (read without loading it into the live space) |
| `==` | `(== <primary> <secondary>)` | secondary paths **equal** to the primary binding |
| `!=` | `(!= <primary> <secondary>)` | secondary paths **not equal** to the primary binding |
| *(grounded)* | `(<registered-fn> …)` | a registered Julia grounded function — checked **first**, so registered functions take priority over a trie query (see `GroundedSource`) |

The comparison sources `==` / `!=` are backed by a `DependentZipper`: the
secondary pattern is constrained by the primary's binding — `==` to the single
matching path, `!=` to the COW-shared complement (`btm \ {path}`). The multi-
source query driver is `space_query_multi_i`.

```
;; form: an (I …) clause whose patterns are served by sources
(exec 0 (I (== \$x \$y) (rel \$y \$z)) (O (linked \$x \$z)))
```

---

## Sinks

A **sink** is an output combinator in the `O` clause of a rule. Instead of
simply asserting new atoms, sinks perform **stateful aggregation** over
multiple rule firings.

```
(exec PRIORITY MATCH (O SINK1 SINK2 ...))
```

---

## Remove Sink — `-`

Removes matched atoms from the space.

```
(- ATOM)
```

**Example** — consume source atoms after processing:

```julia
space_add_all_sexpr!(s, """
    (task pending clean-dishes)
    (task pending write-report)

    ;; Mark tasks as done, removing the pending form
    (exec 0
        (, (task pending \$t))
        (O (- (task pending \$t))
           (+ (task done    \$t)))
    )
""")
```

After the calculus:
- `(task pending clean-dishes)` — **removed**
- `(task done clean-dishes)` — **added**

---

## Add Sink — `+`

Asserts atoms into the space (explicit form; bare atoms in `O` also assert).

```
(+ ATOM)
```

The `+` form is equivalent to a bare atom in the output:

```julia
# These two rules are equivalent:
(exec 0 (, (n \$x)) (O (+ (result \$x))))
(exec 0 (, (n \$x)) (O    (result \$x) ))
```

---

## Float Reduction Sinks

These sinks aggregate numeric values across all rule firings, reducing
them to a single accumulator atom.

### Syntax

```
(fmin (ACCUMULATOR $c) $c VALUE)
(fmax (ACCUMULATOR $c) $c VALUE)
(fsum (ACCUMULATOR $c) $c VALUE)
(fprod (ACCUMULATOR $c) $c VALUE)
```

| Sink | Operation |
|------|-----------|
| `fmin` | Minimum over all matched values |
| `fmax` | Maximum over all matched values |
| `fsum` | Sum of all matched values |
| `fprod` | Product of all matched values |

**Arguments:**
- `(ACCUMULATOR $c)` — atom head for the accumulator; `$c` is the current value
- `$c` — variable bound to the current accumulator value
- `VALUE` — the new value to merge (can be a variable or literal)

### Example — Temperature Statistics

```julia
space_add_all_sexpr!(s, """
    (reading 5.8)
    (reading 9.6)
    (reading 5.4)
    (reading 61.0)

    (exec 0
        (, (reading \$x))
        (O
            (fmin (stats:min \$c) \$c \$x)
            (fmax (stats:max \$c) \$c \$x)
            (fsum (stats:sum \$c) \$c \$x)
        )
    )

    ;; Remove source atoms after aggregation
    (exec 1
        (, (reading \$x))
        (O (- (reading \$x)))
    )
""")

space_metta_calculus!(s, 100_000)
println(space_dump_all_sexpr(s))
# => (stats:min 5.4)
# => (stats:max 61.0)
# => (stats:sum 81.8)
```

### Notes

- The accumulator variable `$c` is unified with the **current** accumulator
  value on each firing.  The sink updates the atom in-place.
- Multiple float reduction sinks can appear in a single `O` clause,
  each maintaining its own accumulator.
- The product of `{5.8, 9.6, 5.4, 61.0}` ≈ 18340.99.

---

## Count Sink

Counts the number of times a pattern fires.

```
(count (COUNTER $c) $c)
```

**Example:**

```julia
space_add_all_sexpr!(s, """
    (item a)
    (item b)
    (item c)

    (exec 0
        (, (item \$x))
        (O (count (total \$c) \$c))
    )
""")

space_metta_calculus!(s, 10_000)
# => (total 3)
```

---

## Head and Tail Sinks

`head` keeps the **N lexicographically-smallest** matched paths; `tail` keeps the
**N largest**. Both accumulate across all matches of a rule and write the kept
set once.

```
(head N <expr>)
(tail N <expr>)
```

**Example** — keep the 2 smallest / largest patterns:

```julia
space_add_all_sexpr!(s, """
    (pattern a) (pattern b) (pattern c) (pattern d) (pattern e)
    (exec 0 (, (pattern \$x)) (O (head 2 \$x)))
""")
space_metta_calculus!(s, 10_000)
# => kept: a, b           (head: the 2 smallest)
# (tail 2 \$x) instead keeps: d, e
```

The kept template `<expr>` is built per match from the bindings; the top/bottom-N
by byte path are retained. The firing form is `(O (head|tail N …))` — the `O`
output functor is what routes to the sink (a `(, …)` wrapper asserts a literal).

---

## Bipolar Sinks

Bipolar sinks manage **positive** and **negative** evidence separately,
supporting paraconsistent reasoning.

```
(+ (positive ATOM))   ;; assert positive evidence
(- (negative ATOM))   ;; retract negative evidence
```

**Example — evidence aggregation:**

```julia
space_add_all_sexpr!(s, """
    (evidence positive alice trustworthy)
    (evidence positive alice trustworthy)
    (evidence negative alice trustworthy)

    (exec 0
        (, (evidence positive \$x \$prop))
        (O (+ (supports \$x \$prop)))
    )

    (exec 0
        (, (evidence negative \$x \$prop))
        (O (- (contradicts \$x \$prop)))
    )
""")
```

---

## Combining Sinks

Multiple sinks can appear in a single `O` clause.  They all operate on
the same matched variable bindings:

```julia
space_add_all_sexpr!(s, """
    (measurement 10.0)
    (measurement 20.0)
    (measurement 30.0)

    (exec 0
        (, (measurement \$x))
        (O
            (fsum  (total \$c)   \$c \$x)   ;; accumulate sum
            (fmax  (peak  \$c)   \$c \$x)   ;; track maximum
            (count (n     \$c)   \$c)        ;; count firings
            (- (measurement \$x))            ;; consume source
        )
    )
""")

space_metta_calculus!(s, 10_000)
# => (total 60.0)
# => (peak 30.0)
# => (n 3)
```

---

## Sink Implementation Notes

Sinks are implemented in `src/kernel/Sinks.jl` and resolve during
`space_metta_calculus!`.  Each sink maintains state in the space itself
as accumulator atoms — there is no separate sink state outside the space.

This means:
- Accumulator atoms are visible in `space_dump_all_sexpr` at any time
- Snapshots capture sink state automatically
- Rules can match on accumulator atoms to trigger further computation
