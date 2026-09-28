# @weight 2
# @timeout-scale 3

C's arithmetic, the same under `run` and compiled.  An operand narrower
than an int promotes to one, and a binary operator's operands meet in
the C type C's usual conversions give them -- an unsigned long if either
is one, else a long, else an unsigned int, else an int -- so -1 < 1u is
false, an unsigned int wraps before it divides, and an unsigned long
divides, compares and shifts right as unsigned.  Every expression has
the C type C gives it, so `sizeof` answers it and `*p++` reads what p
points at.  Each case runs the program under `run`, then compiled, and
shows both outputs and both statuses; every expectation is what the same
source prints through /usr/bin/cc.

## the usual conversions

### signed against unsigned: comparisons, division and remainder

```cc
(def src "#include <stdio.h>\nint main(void) { printf(\"%d %d %d %d\\n\", -1 < 1u, -1L < 1u, -1 / 2u == 2147483647u, (unsigned)-7 % 3u); printf(\"%u %u %u\\n\", (4000000000u + 500000000u) / 2u, ~0u >> 28, (0u - 1u) / 16u); printf(\"%d %d %ld\\n\", -8 >> 1, (-7) / 2, (long)(-9) % 4L); return -1 < 1u; }\n")
(display (list (cc-run src) (cc-exe-run src)))
```
---
```output
0 1 1 0
102516352 15 268435455
-4 -3 -1
0 1 1 0
102516352 15 268435455
-4 -3 -1
(0 0)
```

### an unsigned long: division, comparison, a shift, and an FNV-1a hash

```cc
(def src "#include <stdio.h>\nint main(void) { unsigned long big = 18446744073709551615UL; unsigned long m = 9223372036854775808UL; printf(\"%lu %lu %lu\\n\", big / 10UL, big % 10UL, m >> 63); printf(\"%d %d %d %d\\n\", big > 1UL, m > 1UL, (long)m < 0L, big == (unsigned long)-1L); unsigned long h = 14695981039346656037UL; const char *s = \"abc\"; while (*s) { h ^= (unsigned char)*s++; h *= 1099511628211UL; } printf(\"%lx\\n\", h); return (int)(h & 127); }\n")
(display (list (cc-run src) (cc-exe-run src)))
```
---
```output
1844674407370955161 5 1
1 1 1 1
e71fa2190541574b
1844674407370955161 5 1
1 1 1 1
e71fa2190541574b
(75 75)
```

### an unsigned int hash, wrapping as it goes

```cc
(def src "#include <stdio.h>\nunsigned int hash(const char *s) { unsigned int h = 5381; int c; while ((c = *s++)) h = ((h << 5) + h) + c; return h; }\nint main(void) { printf(\"%u %u %x\\n\", hash(\"hello\"), hash(\"\"), hash(\"x-cc\")); return hash(\"abc\") % 256; }\n")
(display (list (cc-run src) (cc-exe-run src)))
```
---
```output
261238937 5381 7c9fa990
261238937 5381 7c9fa990
(139 139)
```

### negative operands of the bitwise operators

```cc
(def src "#include <stdio.h>\nint main(void) { int a = -12; printf(\"%d %d %d %d %d\\n\", a & 7, a | 3, a ^ -1, ~a, a >> 2); unsigned int u = (unsigned int)a; printf(\"%u %u %x\\n\", u >> 28, u & 0xFF, u); long l = -1L; printf(\"%ld %lx\\n\", l << 4, (unsigned long)l >> 60); return ~a; }\n")
(display (list (cc-run src) (cc-exe-run src)))
```
---
```output
4 -9 11 11 -3
15 244 fffffff4
-16 f
4 -9 11 11 -3
15 244 fffffff4
-16 f
(11 11)
```

## the C type of an expression

### sizeof of expressions

```cc
(def src "#include <stdio.h>\nint main(void) { int a[10]; long l = 0; char c = 'x'; short s = 1; printf(\"%d %d %d %d %d %d\\n\", (int)sizeof a, (int)sizeof a[0], (int)sizeof l, (int)sizeof c, (int)sizeof(s + s), (int)sizeof(c + 1L)); return (int)sizeof a; }\n")
(display (list (cc-run src) (cc-exe-run src)))
```
---
```output
40 4 8 1 4 8
40 4 8 1 4 8
(40 40)
```

### *p++ reads what p points at; promotions of narrow operands

```cc
(def src "#include <stdio.h>\nint main(void) { long vals[3] = {5000000000L, -7L, 42L}; long *p = vals; long a = *p++; long b = *p++; char text[8] = \"ab\"; text[3] = 'z'; char out[8]; char *d = out; const char *s = text; int n = 0; while ((*d++ = *s++)) n++; printf(\"%ld %ld %d %s %d\\n\", a, b, n, out, (int)sizeof(*p++)); unsigned char uc = 200; char sc = 100; short sh = -2; printf(\"%d %d %d %d\\n\", uc + sc, sc * sc, sh * 3, (int)sizeof(uc + sc)); return n; }\n")
(display (list (cc-run src) (cc-exe-run src)))
```
---
```output
5000000000 -7 2 ab 8
300 10000 -6 4
5000000000 -7 2 ab 8
300 10000 -6 4
(2 2)
```
