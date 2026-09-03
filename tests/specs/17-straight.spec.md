# @weight 2

The third body shape: assignments and a return, with no `if`/`return`
ladder and no loop.  The loop fold already models it -- statements
folded into a map over the parameters, memory reads and writes as
ordered effects, a `return` as a guarded exit -- and without a
self-call nothing needs a lane slot, so every local is
substitution-only and an assigned parameter just threads through the
map.  A `break` or `continue` has no enclosing loop here and refuses.
Every expectation is an oracle row from /usr/bin/cc.

## straight-line bodies

### compound operators, a rotation through a temp, an early return, a swap through memory

```cc
(display (cc-build-run "#include <stdio.h>\nint compound(int x) { x <<= 2; x |= 7; x ^= 255; x &= 1023; x >>= 1; return x; }\nint swap3(int a, int b, int c) { int t; t = a; a = b; b = c; c = t; return a * 100 + b * 10 + c; }\nint early(int x) { int y; y = x * 2; if (y > 10) return 999; y = y + 1; return y; }\nint viamem(int *a) { int t; t = a[0]; a[0] = a[1]; a[1] = t; return a[0] * 10 + a[1]; }\nint main() { int p[2] = {3, 8}; int v = viamem(p); printf(\"%d %d %d %d %d %d %d\\n\", compound(9), swap3(1,2,3), early(2), early(9), v, p[0], p[1]); return 0; }"))
```
---
```output
native compound
native swap3
native early
native viamem
interp main
108 231 5 999 83 8 3
0
```
