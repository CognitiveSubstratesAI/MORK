`mod_i*` aborts the process on a zero divisor and on `typemin % -1`

---
The `mod_i8/16/32/64/128` arms apply Rust's `%` with no guard. Both a zero divisor and
`i64::MIN % -1` panic, and a panic inside `extern "C"` is a non-unwinding **abort** — the whole
saturation run dies and no output file is written, rather than the offending atom being skipped.

Every other failure mode in `pure.rs` returns `Err(EvalError)` and skips the atom, so this looks like
an oversight rather than a design choice.

```
(mod_i64 <8 bytes> <8 zero bytes>)     -> process aborts
(mod_i64 <i64::MIN>  <-1>)             -> process aborts
```

A guard returning `Err` on both shapes would match the surrounding arms.
