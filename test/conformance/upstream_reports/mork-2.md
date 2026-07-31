`encode_hex` emits an over-long symbol at 32 bytes and aborts at 33

---
`encode_hex` (pure.rs:748-760) writes into a fixed `[0u8; 64]` and emits `buf[..2*len]`.

| input length | result |
|---|---|
| 32 bytes | a **64-byte symbol** — `SymbolSize` is 1..63, so the emitted atom is structurally invalid |
| 33 bytes | writes past the array and **panics**, aborting the process with no output |

The 32-byte case is the more troubling one: it is silent, and the resulting atom cannot be decoded
under the Rule of 64.

Bounds-checking the input length and returning `Err` would match how the rest of the file handles
invalid input.
