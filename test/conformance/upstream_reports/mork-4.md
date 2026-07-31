`unbind` emits its internal 255 sentinel as a `VarRef`

---
For the input `($x $x)` — encoded `[2] $ _1` — `unbind` writes its internal 255 sentinel into the
output as a `VarRef` index.

255 is not a legal `VarRef` under the Rule of 64 (max 63), so the result does not decode: the byte
`0x80 | (255 & 0x3f)` aliases onto an unrelated index rather than round-tripping.

The sentinel appears intended as an in-band "unset" marker; it needs to be filtered before it reaches
the output expression.
