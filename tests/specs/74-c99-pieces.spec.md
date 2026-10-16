# @weight 1
# @timeout-scale 2

C99's and C11's smaller pieces: a variadic macro, its arguments past the
named ones as `__VA_ARGS__`; `__func__`, the name of the function it is
in; `inline` and `restrict`, which change nothing here; `_Static_assert`
at file scope and in a block, and `<assert.h>`'s `static_assert`; a
hexadecimal floating constant.  Each case runs under `run`, then
compiled, and shows both outputs and both statuses; the expectation is
what the same source prints through /usr/bin/cc, on macOS and on glibc
alike.

## C99 and C11

### variadic macros, __func__, inline, restrict, _Static_assert

```cc
(def src "#include <stdio.h>\n#include <string.h>\n#include <assert.h>\n#define LOG(fmt, ...) printf(\"[%s] \" fmt \"\\n\", __func__, __VA_ARGS__)\n#define SHOW(...) printf(#__VA_ARGS__ \" -> %d\\n\", (__VA_ARGS__))\n#define COUNT(...) count_args(__VA_ARGS__, -1)\n_Static_assert(sizeof(long) == 8, \"long is eight bytes\");\nstatic_assert(sizeof(int) == 4, \"int is four bytes\");\nstatic int count_args(int first, ...) { return first; }\nstatic inline int twice(int k) { return k * 2; }\nstatic void copy(int n, int *restrict dst, const int *restrict src) { while (n--) *dst++ = *src++; }\nstatic int helper(int k) {\n  _Static_assert(1 + 1 == 2, \"arithmetic\");\n  LOG(\"k=%d len=%d\", k, (int)strlen(__func__));\n  return twice(k);\n}\nint main(void) {\n  int a[3] = { 4, 5, 6 }, b[3];\n  copy(3, b, a);\n  LOG(\"%d %d %d\", b[0], b[1], b[2]);\n  SHOW(1 + 2 * 3);\n  SHOW(helper(4), 10);\n  printf(\"%d %s\\n\", COUNT(9, 8, 7), __func__);\n  return helper(1);\n}\n")
(display (list (cc-run src) (cc-exe-run src)))
```
---
```output
[main] 4 5 6
1 + 2 * 3 -> 7
[helper] k=4 len=6
helper(4), 10 -> 10
9 main
[helper] k=1 len=6
[main] 4 5 6
1 + 2 * 3 -> 7
[helper] k=4 len=6
helper(4), 10 -> 10
9 main
[helper] k=1 len=6
(2 2)
```

### a _Static_assert that fails is refused with its message

```cc
(def src "_Static_assert(sizeof(int) == 2, \"int is two bytes\");\nint main(void) { return 0; }\n")
(display (guard (e (e msg)) (cc-run src)))
```
---
```output
cc: parse: line 1: static assertion failed: int is two bytes
```

### hexadecimal floating constants, a float's and a global table's among them

`0x1.8p3` is 1.5 times 2 to the 3rd: a hex fraction and a `p` exponent of
decimal digits, the Lexer's number rule reading it whole and the C
library's strtod its value.  A hex integer, `e` among its digits, stays an
integer.

```cc
(def src "#include <stdio.h>\nstatic const double table[] = { 0x1.8p3, 0x.8p-1, 0X1P+4, 0x1.p2 };\nint main(void) {\n  float f = 0x1.4p1f;\n  double sum = 0;\n  for (int i = 0; i < 4; i++) sum += table[i];\n  printf(\"%.4f %.4f %.4f %.4f\\n\", table[0], table[1], table[2], table[3]);\n  printf(\"%.3f %.2f %d %d\\n\", sum, f, (int)(0x1p10 + 0x1e), 0x1e);\n  return (int)sum;\n}\n")
(display (list (cc-run src) (cc-exe-run src)))
```
---
```output
12.0000 0.2500 16.0000 4.0000
32.250 2.50 1054 30
12.0000 0.2500 16.0000 4.0000
32.250 2.50 1054 30
(32 32)
```
