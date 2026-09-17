# @weight 2

The bitwise family and wide parameter lists.  `&` `|` `^` `<<` `>>`
answer what C answers, `>>` arithmetic on a signed value, including as
compound operators in a loop.  A function takes eight parameters, and
a recursion four deep carries its own.  Every expectation is an oracle
row from /usr/bin/cc.

## bitwise

### shifts, masks, an arithmetic right shift, and compound operators in a loop

```cc
(display (cc-run "#include <stdio.h>\nint mix(int x) { return (x << 3) ^ (x >> 2); }\nint mask(int x, int n) { return x & ((1 << n) - 1); }\nint arith(int x) { return x >> 2; }\nint fold(int x, int n) { int i; for (i = 0; i < n; i++) { x <<= 1; x |= 1; x &= 255; } return x; }\nint popcount(int x) { int c; int i; c = 0; for (i = 0; i < 16; i++) { c = c + (x & 1); x = x >> 1; } return c; }\nint hash(char *s, int n) { int i; int h; h = 5381; for (i = 0; i < n; i++) h = ((h << 5) + h + s[i]) & 1048575; return h; }\nint main() { char w[6] = \"hello\"; printf(\"%d %d %d %d %d %d\\n\", mix(37), mask(1000, 6), arith(-16), fold(3, 5), popcount(4095), hash(w, 5)); return 0; }"))
```
---
```output
289 40 -4 127 12 143513
0
```

## arity

### eight parameters and four-deep recursion

`poly` takes six parameters, `twoloop` runs two loops in a row, and
`r5` carries five values through a recursion, four of them unchanged
in every frame (20-recursion-params has more).

```cc
(display (cc-run "#include <stdio.h>\nint eight(int a, int b, int c, int d, int e, int f, int g, int h) { return a*10000000 + b*1000000 + c*100000 + d*10000 + e*1000 + f*100 + g*10 + h; }\nint r4(int a, int b, int c, int d) { return a == 0 ? b + c + d : r4(a - 1, b + 1, c, d); }\nint r5(int a, int b, int c, int d, int e) { return a == 0 ? b + c + d + e : r5(a - 1, b, c, d, e); }\nint poly(int a, int b, int c, int d, int e, int n) { int i; int s; s = 0; for (i = 0; i < n; i++) s = s + a * i * i * i + b * i * i + c * i + d + e; return s; }\nint twoloop(int a, int b, int c, int d) { int i; for (i = 0; i < a; i++) b = b + 1; for (i = 0; i < c; i++) d = d + 1; return b + d; }\nint main() { printf(\"%d %d %d %d %d\\n\", eight(1,2,3,4,5,6,7,8), r4(3, 10, 5, 2), r5(3, 1, 2, 3, 4), poly(1,2,3,4,5,6), twoloop(3,10,4,20)); return 0; }"))
```
---
```output
12345678 20 10 434 37
0
```
