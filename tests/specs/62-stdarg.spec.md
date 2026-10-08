# @weight 2
# @timeout-scale 3

A variadic function of the program's own, `int f(int n, ...)`, with
`<stdarg.h>`: `va_start`, `va_arg`, `va_copy` and `va_end`, and a
`va_list` handed on to the C library's v- functions or to the program's
own.  Every expectation is what the same source prints through
/usr/bin/cc, then its status.

## run

### va_arg of a long, a double, a char * and an int; va_copy; vprintf; a va_list handed on

```cc
(def src "#include <stdio.h>\n#include <stdarg.h>\nstatic int nlog = 0;\nvoid logf_(const char *fmt, ...) {\n  va_list ap;\n  va_start(ap, fmt);\n  printf(\"[%d] \", ++nlog);\n  vprintf(fmt, ap);\n  va_end(ap);\n}\nlong vsum(int n, va_list ap) {\n  long s = 0;\n  while (n-- > 0) s += va_arg(ap, long);\n  return s;\n}\nlong sum(int n, ...) {\n  va_list ap, again;\n  long s;\n  va_start(ap, n);\n  va_copy(again, ap);\n  s = vsum(n, ap);\n  s += va_arg(again, long) * 1000;\n  va_end(again);\n  va_end(ap);\n  return s;\n}\ndouble mean(int n, ...) {\n  va_list ap;\n  double t = 0;\n  int i;\n  va_start(ap, n);\n  for (i = 0; i < n; i++) t += va_arg(ap, double);\n  va_end(ap);\n  return t / n;\n}\nint pick(int which, ...) {\n  va_list ap;\n  int i, v = 0;\n  char *s;\n  va_start(ap, which);\n  for (i = 0; i <= which; i++) { s = va_arg(ap, char *); v = va_arg(ap, int); }\n  va_end(ap);\n  printf(\"%s=%d\\n\", s, v);\n  return v;\n}\nint main(void) {\n  float f = 1.5f;\n  logf_(\"hello %s, %d\\n\", \"world\", 42);\n  logf_(\"%5.2f%% %c\\n\", 12.345, 'x');\n  logf_(\"none\\n\");\n  printf(\"%ld\\n\", sum(4, 1L, 2L, 3L, 4L));\n  printf(\"%.3f\\n\", mean(3, 1.0, 2.5, f));\n  pick(1, \"a\", -1, \"b\", -2, \"c\", -3);\n  return nlog + pick(2, \"x\", 1, \"y\", 2, \"z\", 3);\n}\n")
(display (cc-run src))
```
---
```output
[1] hello world, 42
[2] 12.35% x
[3] none
1010
1.667
b=-2
z=3
6
```

## compiled

### va_arg of a long, a double, a char * and an int; va_copy; vprintf; a va_list handed on

```cc
(def src "#include <stdio.h>\n#include <stdarg.h>\nstatic int nlog = 0;\nvoid logf_(const char *fmt, ...) {\n  va_list ap;\n  va_start(ap, fmt);\n  printf(\"[%d] \", ++nlog);\n  vprintf(fmt, ap);\n  va_end(ap);\n}\nlong vsum(int n, va_list ap) {\n  long s = 0;\n  while (n-- > 0) s += va_arg(ap, long);\n  return s;\n}\nlong sum(int n, ...) {\n  va_list ap, again;\n  long s;\n  va_start(ap, n);\n  va_copy(again, ap);\n  s = vsum(n, ap);\n  s += va_arg(again, long) * 1000;\n  va_end(again);\n  va_end(ap);\n  return s;\n}\ndouble mean(int n, ...) {\n  va_list ap;\n  double t = 0;\n  int i;\n  va_start(ap, n);\n  for (i = 0; i < n; i++) t += va_arg(ap, double);\n  va_end(ap);\n  return t / n;\n}\nint pick(int which, ...) {\n  va_list ap;\n  int i, v = 0;\n  char *s;\n  va_start(ap, which);\n  for (i = 0; i <= which; i++) { s = va_arg(ap, char *); v = va_arg(ap, int); }\n  va_end(ap);\n  printf(\"%s=%d\\n\", s, v);\n  return v;\n}\nint main(void) {\n  float f = 1.5f;\n  logf_(\"hello %s, %d\\n\", \"world\", 42);\n  logf_(\"%5.2f%% %c\\n\", 12.345, 'x');\n  logf_(\"none\\n\");\n  printf(\"%ld\\n\", sum(4, 1L, 2L, 3L, 4L));\n  printf(\"%.3f\\n\", mean(3, 1.0, 2.5, f));\n  pick(1, \"a\", -1, \"b\", -2, \"c\", -3);\n  return nlog + pick(2, \"x\", 1, \"y\", 2, \"z\", 3);\n}\n")
(display (cc-exe-run src))
```
---
```output
[1] hello world, 42
[2] 12.35% x
[3] none
1010
1.667
b=-2
z=3
6
```

## refused

### the address of a variadic function, compiled

```cc
(display (guard (e (do (display "refused: ") (write e) ""))
  (cc-exe-run "int f(int n, ...) { return n; }\nint main(void) { int (*g)(int, ...) = f; return g(1); }\n")))
```
---
    refused: #<err:cc cc: compile: not built yet: the address of f, which is variadic>

### a struct from va_arg

```cc
(display (guard (e (do (display "refused: ") (write e) ""))
  (cc-run "#include <stdarg.h>\nstruct P { int x; };\nint f(int n, ...) { va_list ap; struct P p; va_start(ap, n); p = va_arg(ap, struct P); va_end(ap); return p.x; }\nint main(void) { return 0; }\n")))
```
---
    refused: #<err:cc cc: parse: line 3: not built yet: a struct from va_arg>

### a ... with no parameter before it

```cc
(display (guard (e (do (display "refused: ") (write e) ""))
  (cc-run "int f(...) { return 0; }\nint main(void) { return f(); }\n")))
```
---
    refused: #<err:cc cc: parse: line 1: a ... with no parameter before it>
