# @weight 1
# @timeout-scale 2

C99's and C11's smaller pieces: a variadic macro, its arguments past the
named ones as `__VA_ARGS__`; `__func__`, the name of the function it is
in; `inline` and `restrict`, which change nothing here; `_Static_assert`
at file scope and in a block, and `<assert.h>`'s `static_assert`.  The
case runs under `run`, then compiled, and shows both outputs and both
statuses; the expectation is what the same source prints through
/usr/bin/cc, on macOS and on glibc alike.

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
