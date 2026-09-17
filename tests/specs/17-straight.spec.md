# @weight 2

Straight-line bodies: assignments and a return, with no `if`/`return`
ladder and no loop -- compound operators, a rotation through a temp,
an early return, and a swap through memory.  Every expectation is an
oracle row from /usr/bin/cc.

## straight-line bodies

### compound operators, a rotation through a temp, an early return, a swap through memory

```cc
(display (cc-run "#include <stdio.h>\nint compound(int x) { x <<= 2; x |= 7; x ^= 255; x &= 1023; x >>= 1; return x; }\nint swap3(int a, int b, int c) { int t; t = a; a = b; b = c; c = t; return a * 100 + b * 10 + c; }\nint early(int x) { int y; y = x * 2; if (y > 10) return 999; y = y + 1; return y; }\nint viamem(int *a) { int t; t = a[0]; a[0] = a[1]; a[1] = t; return a[0] * 10 + a[1]; }\nint main() { int p[2] = {3, 8}; int v = viamem(p); printf(\"%d %d %d %d %d %d %d\\n\", compound(9), swap3(1,2,3), early(2), early(9), v, p[0], p[1]); return 0; }"))
```
---
```output
108 231 5 999 83 8 3
0
```
