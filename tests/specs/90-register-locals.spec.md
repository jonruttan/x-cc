# @weight 1
# @timeout-scale 3

Locals held in registers.  A function holds its most-used integer and
pointer locals and parameters in the registers the C convention keeps
across calls -- arm64's x23 to x28, x86-64's r15 and rbp -- saved in its
prologue and put back as it returns.  A local whose address is taken stays
in the frame, and so does every local of a function that calls setjmp.
Each expectation is what the same source prints through /usr/bin/cc.

## held locals

### recursion, values that wrap at their C type's width, and narrowed parameters

```cc
(display (cc-exe-run "#include <stdio.h>\nstatic int fib(int n) { int a = n - 1; int b = n - 2; if (n < 2) return n; return fib(a) + fib(b); }\nstatic int narrow(char c, unsigned short h) { return c + h; }\nint main(void) {\n  unsigned char c = 250; short s = 32767; int x = 2147483647; unsigned u = 0; int i;\n  for (i = 0; i < 10; i++) c++;\n  s++; x++; u--;\n  printf(\"%d %d %d %d %u %d\\n\", fib(15), c, s, x < 0, u, narrow((char)300, (unsigned short)70000));\n  return 0;\n}\n"))
```
---
```output
610 4 -32768 1 4294967295 4508
0
```

### more locals than registers, all live through a loop

```cc
(display (cc-exe-run "#include <stdio.h>\nint main(void) {\n  long a = 1, b = 2, c = 3, d = 4, e = 5, f = 6, g = 7, h = 8, k = 9; int i;\n  for (i = 0; i < 100; i++) { a += b; b += c; c += d; d += e; e += f; f += g; g += h; h += k; k += 1; }\n  printf(\"%ld %ld %ld %ld %ld %ld %ld %ld %ld\\n\", a, b, c, d, e, f, g, h, k);\n  return 0;\n}\n"))
```
---
```output
3713899703396 340243729292 27366776488 1902171984 111907400 5416831 207057 5858 109
0
```

### a callback from qsort, a longjmp past a function that holds locals, and a local whose address is taken

`main` holds its locals across the call to `middle`, which calls setjmp;
`clobber` holds its own in the same registers and longjmps back.

```cc
(display (cc-exe-run "#include <stdio.h>\n#include <stdlib.h>\n#include <setjmp.h>\nstatic int cmp(const void *p, const void *q) { int x = *(const int *)p; int y = *(const int *)q; return (x > y) - (x < y); }\nstatic jmp_buf back;\nstatic void clobber(int n) {\n  int a = n, b = n * 2, c = n * 3, d = n * 4, e = n * 5, f = n * 6, i;\n  for (i = 0; i < 3; i++) { a++; b++; c++; d++; e++; f++; }\n  longjmp(back, a + b + c + d + e + f);\n}\nstatic int middle(void) { int r = setjmp(back); if (r == 0) clobber(100); return r; }\nint main(void) {\n  int v[6] = { 5, 3, 9, 1, 7, 2 }; int kept = 11, also = 22, i, sum = 0, r;\n  int w = 0; int *p = &w;\n  qsort(v, 6, sizeof v[0], cmp);\n  for (i = 0; i < 6; i++) sum = sum * 10 + v[i];\n  r = middle();\n  *p = 5;\n  printf(\"%d %d %d %d %d\\n\", sum, kept, also, r, w);\n  return 0;\n}\n"))
```
---
```output
123579 11 22 2118 5
0
```
