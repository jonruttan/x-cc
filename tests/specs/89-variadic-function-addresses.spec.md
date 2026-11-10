# @weight 2
# @timeout-scale 3

A pointer to a function whose parameter list ends in `...` keeps how
many parameters come before it, and a call through it lays the arguments
past those out as a direct call to a variadic function does: through a
va_list for the program's own, on the stack on arm64 macOS for the C
library's.  The address of the program's own variadic function can be
taken.  Every expectation is what the same source prints through
/usr/bin/cc, then its status.

## compiled

### the program's own variadic functions through local pointers

```cc
(def src "#include <stdio.h>\n#include <stdarg.h>\nlong sum(int n, ...) {\n  va_list ap;\n  long s = 0;\n  va_start(ap, n);\n  while (n-- > 0) s += va_arg(ap, long);\n  va_end(ap);\n  return s;\n}\ndouble mean(int n, ...) {\n  va_list ap;\n  double t = 0;\n  int i;\n  va_start(ap, n);\n  for (i = 0; i < n; i++) t += va_arg(ap, double);\n  va_end(ap);\n  return t / n;\n}\nint main(void) {\n  long (*fs)(int, ...) = sum;\n  double (*fm)(int, ...) = &mean;\n  long (*again)(int, ...) = fs;\n  printf(\"%ld %.2f %ld %d\\n\", fs(3, 1L, 20L, 300L), fm(2, 1.5, 2.0), (*again)(0), fs == sum);\n  return (int)fs(2, 40L, 2L);\n}\n")
(display (cc-exe-run src))
```
---
```output
321 1.75 0 1
42
```

### a struct of variadic functions, the program's and printf, and a cast

```cc
(def src "#include <stdio.h>\n#include <stdarg.h>\nstatic int mode_seen = -1;\nstatic int mock_open(const char *path, int flags, ...) {\n  va_list ap;\n  va_start(ap, flags);\n  mode_seen = (flags & 0100) ? va_arg(ap, int) : 0;\n  va_end(ap);\n  printf(\"open %s %d %o\\n\", path, flags, mode_seen);\n  return 7;\n}\nstruct sys { int (*open)(const char *, int, ...); int (*print)(const char *, ...); };\nstatic struct sys sys = { mock_open, printf };\nint main(void) {\n  int (*op)(const char *, int, ...) = (int (*)(const char *, int, ...))mock_open;\n  int a = sys.open(\"x\", 0);\n  int b = sys.open(\"y\", 0101, 0644);\n  sys.print(\"%d %d %s %ld\\n\", a, op(\"z\", 0100, 0600), \"s\", 1234567890123L);\n  return b + mode_seen;\n}\n")
(display (cc-exe-run src))
```
---
```output
open x 0 0
open y 65 644
open z 64 600
7 7 s 1234567890123
135
```

## run

### the program's own variadic functions through local pointers

```cc
(def src "#include <stdio.h>\n#include <stdarg.h>\nlong sum(int n, ...) {\n  va_list ap;\n  long s = 0;\n  va_start(ap, n);\n  while (n-- > 0) s += va_arg(ap, long);\n  va_end(ap);\n  return s;\n}\ndouble mean(int n, ...) {\n  va_list ap;\n  double t = 0;\n  int i;\n  va_start(ap, n);\n  for (i = 0; i < n; i++) t += va_arg(ap, double);\n  va_end(ap);\n  return t / n;\n}\nint main(void) {\n  long (*fs)(int, ...) = sum;\n  double (*fm)(int, ...) = &mean;\n  long (*again)(int, ...) = fs;\n  printf(\"%ld %.2f %ld %d\\n\", fs(3, 1L, 20L, 300L), fm(2, 1.5, 2.0), (*again)(0), fs == sum);\n  return (int)fs(2, 40L, 2L);\n}\n")
(display (cc-run src))
```
---
```output
321 1.75 0 1
42
```
