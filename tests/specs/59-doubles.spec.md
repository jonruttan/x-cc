# @weight 2
# @timeout-scale 3

`double`: its values are the IEEE bits, held where a long would be, and its
operations the machine's -- run's through the platform's stubs
(x/num/float), the compiler's in the d registers.  The maths functions are
the library's.  Every expectation is what the same source prints through
/usr/bin/cc, then its status.

## run

### arithmetic, compound assignment, ++ and --, and printf's conversions

```cc
(def src "#include <stdio.h>\nint main(void) {\n  double x = 1.5, y = 2;\n  double z = x * y + 0.25;\n  printf(\"%f %g %e %.2f\\n\", z, x + y, x - y * 10, 1e3 / 7);\n  printf(\"%g %g %g %g\\n\", 0.1 + 0.2, 1.0 / 3, -x / 4, 2.5e-3 * 4);\n  printf(\"%.17g %a\\n\", 0.1, 1.0);\n  x += 0.5; y *= 3; z /= 2; y -= 1;\n  printf(\"%g %g %g\\n\", x, y, z);\n  x++; ++y; z--; --z;\n  printf(\"%g %g %g %g\\n\", x, y, z, -z);\n  return (int)(x * y);\n}\n")
(display (cc-run src))
```
---
```output
3.250000 3.5 -1.850000e+01 142.86
0.3 0.333333 -0.375 0.01
0.10000000000000001 0x1p+0
2 5 1.625
3 6 -0.375 0.375
18
```

### conversions to and from the integer types, unsigned long past 2^63 both ways

```cc
(def src "#include <stdio.h>\nint main(void) {\n  double d = -7.9;\n  int i = d;\n  unsigned u = 3000000000.0;\n  long l = -1e15;\n  unsigned long big = 18446744073709551615UL;\n  unsigned long top = 9223372036854775808UL;\n  char c = 65.7;\n  short s = -300.2;\n  double from_big = big;\n  double from_top = top;\n  printf(\"%d %u %ld %d %d\\n\", i, u, l, c, s);\n  printf(\"%g %g %lu %lu\\n\", from_big, from_top, (unsigned long)1e19, (unsigned long)from_top);\n  printf(\"%g %g %g\\n\", (double)7 / 2, (double)(7 / 2), 7 / 2.0);\n  printf(\"%d %d %ld\\n\", (int)2.999, (int)-2.999, (long)(3.5 * 2));\n  i = 10; d = i / 4; printf(\"%g\\n\", d);\n  d = i; d = d / 4; printf(\"%g\\n\", d);\n  return (int)(d * 10) % 256;\n}\n")
(display (cc-run src))
```
---
```output
-7 3000000000 -1000000000000000 65 -300
1.84467e+19 9.22337e+18 10000000000000000000 9223372036854775808
3.5 3 3.5
2 -2 7
2
2.5
25
```

### the maths library, and atof

```cc
(def src "#include <stdio.h>\n#include <math.h>\n#include <stdlib.h>\nint main(void) {\n  printf(\"%.6f %.6f %.6f\\n\", sqrt(2), sin(1), cos(1));\n  printf(\"%.6f %.6f %.6f\\n\", exp(1), log(10), log10(1000));\n  printf(\"%g %g %g %g\\n\", pow(2, 0.5), fabs(-3.25), floor(-2.5), ceil(2.1));\n  printf(\"%g %g %g %g\\n\", fmod(10, 3), atan2(1, 1) * 4, hypot(3, 4), round(2.5));\n  printf(\"%g %g %g\\n\", trunc(-2.7), atof(\"  -12.5e1xyz\"), sqrt(16) + 1);\n  return (int)sqrt(81);\n}\n")
(display (cc-run src))
```
---
```output
1.414214 0.841471 0.540302
2.718282 2.302585 3.000000
1.41421 3.25 -3 3
1 3.14159 5 3
-2 -125 5
9
```

### globals, parameters, answers, arrays, a struct and a pointer, all doubles

```cc
(def src "#include <stdio.h>\nstruct pt { double x; int tag; double y; };\ndouble g = 1.0 / 4;\ndouble h = -2.5;\ndouble k = 3;\ndouble zero;\nlong n = 2.75;\ndouble gs[3] = {1, 2.5, -0.5};\ndouble half(double x) { return x / 2; }\nint trunc3(double x) { return x; }\ndouble avg(int a, int b) { return (a + b) / 2.0; }\ndouble root(double v) {\n  double r = v;\n  int i;\n  for (i = 0; i < 30; i++) r = (r + v / r) / 2;\n  return r;\n}\ndouble sum(double *a, int n) { double s = 0; int i; for (i = 0; i < n; i++) s += a[i]; return s; }\nvoid scale(double *p, double f) { *p = *p * f; }\nint main(void) {\n  double a[4] = {1.5, 2, 3.25};\n  struct pt p;\n  double v = 3;\n  p.x = 1.25; p.tag = 7; p.y = p.x * 4;\n  scale(&v, 1.5);\n  printf(\"%g %g %g %g %g %ld\\n\", g, h, k, zero, gs[1] + gs[2], n);\n  printf(\"%g %d %g %.10f\\n\", half(5), trunc3(-7.9), avg(3, 4), root(2));\n  printf(\"%g %g %g %d\\n\", sum(a, 4), p.x + p.y, v, p.tag);\n  return half(9);\n}\n")
(display (cc-run src))
```
---
```output
0.25 -2.5 3 0 2 2
2.5 -7 3.5 1.4142135624
6.75 6.25 4.5 7
4
```

### comparisons and tests: NaN, both zeros, the infinities, && || ! and the loops

```cc
(def src "#include <stdio.h>\nint main(void) {\n  double x = 1.5, y = 2, zero = 0.0, nz = -0.0;\n  double nan = zero / zero;\n  double inf = 1 / zero;\n  int count = 0;\n  printf(\"%d %d %d %d %d %d\\n\", x < y, x > y, x <= 1.5, x >= y, x == 1.5, x != 1.5);\n  printf(\"%d %d %d %d %d\\n\", nan == nan, nan != nan, nan < 1, nan >= 1, !nan);\n  printf(\"%d %d %d %d\\n\", !zero, !nz, !x, zero == nz);\n  printf(\"%d %d %d\\n\", x && y, zero || nz, zero || x);\n  printf(\"%g %g %g %g\\n\", x > y ? x : 1, x < y ? 2 : y, inf, -inf);\n  if (nz) count = 100;\n  if (x) count++;\n  while (x > 0.1) { x = x / 2; count++; }\n  do { y -= 0.5; count++; } while (y);\n  for (x = 0; x < 1; x += 0.25) count++;\n  printf(\"%d %g %g\\n\", count, x, y);\n  return count;\n}\n")
(display (cc-run src))
```
---
```output
1 0 1 0 1 0
0 1 0 0 0
1 1 0 1
1 0 1
1 2 inf -inf
13 1 0
13
```

### sscanf and sprintf with doubles

```cc
(def src "#include <stdio.h>\nint main(void) {\n  double d = 0;\n  int i = 0;\n  char buf[64];\n  sscanf(\"2.5 17\", \"%lf %d\", &d, &i);\n  sprintf(buf, \"%.3f|%8.2e|%-6g|\", d * i, d, d);\n  printf(\"%s\\n\", buf);\n  printf(\"%5.1f %+g %.0f %G\\n\", -d, d, 2.5, 1e-10);\n  return i;\n}\n")
(display (cc-run src))
```
---
```output
42.500|2.50e+00|2.5   |
 -2.5 +2.5 2 1E-10
17
```

### strtod: a number at a time, the end pointer stepping past each, and none

```cc
(def src "#include <stdio.h>\n#include <stdlib.h>\nint main(void) {\n  const char *text = \" 1.5 -2 3e2 0x10 junk\";\n  char *end;\n  double sum = 0;\n  int n = 0;\n  for (;;) {\n    double v = strtod(text, &end);\n    if (end == text) break;\n    printf(\"%g \", v);\n    sum += v;\n    n++;\n    text = end;\n  }\n  printf(\"| %g %d [%s] %g\\n\", sum, n, text, strtod(\"7.25\", NULL));\n  return n;\n}\n")
(display (cc-run src))
```
---
```output
1.5 -2 300 16 | 315.5 4 [ junk] 7.25
4
```

## compiled

### arithmetic, compound assignment, ++ and --, and printf's conversions

```cc
(def src "#include <stdio.h>\nint main(void) {\n  double x = 1.5, y = 2;\n  double z = x * y + 0.25;\n  printf(\"%f %g %e %.2f\\n\", z, x + y, x - y * 10, 1e3 / 7);\n  printf(\"%g %g %g %g\\n\", 0.1 + 0.2, 1.0 / 3, -x / 4, 2.5e-3 * 4);\n  printf(\"%.17g %a\\n\", 0.1, 1.0);\n  x += 0.5; y *= 3; z /= 2; y -= 1;\n  printf(\"%g %g %g\\n\", x, y, z);\n  x++; ++y; z--; --z;\n  printf(\"%g %g %g %g\\n\", x, y, z, -z);\n  return (int)(x * y);\n}\n")
(display (cc-exe-run src))
```
---
```output
3.250000 3.5 -1.850000e+01 142.86
0.3 0.333333 -0.375 0.01
0.10000000000000001 0x1p+0
2 5 1.625
3 6 -0.375 0.375
18
```

### conversions to and from the integer types, unsigned long past 2^63 both ways

```cc
(def src "#include <stdio.h>\nint main(void) {\n  double d = -7.9;\n  int i = d;\n  unsigned u = 3000000000.0;\n  long l = -1e15;\n  unsigned long big = 18446744073709551615UL;\n  unsigned long top = 9223372036854775808UL;\n  char c = 65.7;\n  short s = -300.2;\n  double from_big = big;\n  double from_top = top;\n  printf(\"%d %u %ld %d %d\\n\", i, u, l, c, s);\n  printf(\"%g %g %lu %lu\\n\", from_big, from_top, (unsigned long)1e19, (unsigned long)from_top);\n  printf(\"%g %g %g\\n\", (double)7 / 2, (double)(7 / 2), 7 / 2.0);\n  printf(\"%d %d %ld\\n\", (int)2.999, (int)-2.999, (long)(3.5 * 2));\n  i = 10; d = i / 4; printf(\"%g\\n\", d);\n  d = i; d = d / 4; printf(\"%g\\n\", d);\n  return (int)(d * 10) % 256;\n}\n")
(display (cc-exe-run src))
```
---
```output
-7 3000000000 -1000000000000000 65 -300
1.84467e+19 9.22337e+18 10000000000000000000 9223372036854775808
3.5 3 3.5
2 -2 7
2
2.5
25
```

### the maths library, and atof

```cc
(def src "#include <stdio.h>\n#include <math.h>\n#include <stdlib.h>\nint main(void) {\n  printf(\"%.6f %.6f %.6f\\n\", sqrt(2), sin(1), cos(1));\n  printf(\"%.6f %.6f %.6f\\n\", exp(1), log(10), log10(1000));\n  printf(\"%g %g %g %g\\n\", pow(2, 0.5), fabs(-3.25), floor(-2.5), ceil(2.1));\n  printf(\"%g %g %g %g\\n\", fmod(10, 3), atan2(1, 1) * 4, hypot(3, 4), round(2.5));\n  printf(\"%g %g %g\\n\", trunc(-2.7), atof(\"  -12.5e1xyz\"), sqrt(16) + 1);\n  return (int)sqrt(81);\n}\n")
(display (cc-exe-run src))
```
---
```output
1.414214 0.841471 0.540302
2.718282 2.302585 3.000000
1.41421 3.25 -3 3
1 3.14159 5 3
-2 -125 5
9
```

### globals, parameters, answers, arrays, a struct and a pointer, all doubles

```cc
(def src "#include <stdio.h>\nstruct pt { double x; int tag; double y; };\ndouble g = 1.0 / 4;\ndouble h = -2.5;\ndouble k = 3;\ndouble zero;\nlong n = 2.75;\ndouble gs[3] = {1, 2.5, -0.5};\ndouble half(double x) { return x / 2; }\nint trunc3(double x) { return x; }\ndouble avg(int a, int b) { return (a + b) / 2.0; }\ndouble root(double v) {\n  double r = v;\n  int i;\n  for (i = 0; i < 30; i++) r = (r + v / r) / 2;\n  return r;\n}\ndouble sum(double *a, int n) { double s = 0; int i; for (i = 0; i < n; i++) s += a[i]; return s; }\nvoid scale(double *p, double f) { *p = *p * f; }\nint main(void) {\n  double a[4] = {1.5, 2, 3.25};\n  struct pt p;\n  double v = 3;\n  p.x = 1.25; p.tag = 7; p.y = p.x * 4;\n  scale(&v, 1.5);\n  printf(\"%g %g %g %g %g %ld\\n\", g, h, k, zero, gs[1] + gs[2], n);\n  printf(\"%g %d %g %.10f\\n\", half(5), trunc3(-7.9), avg(3, 4), root(2));\n  printf(\"%g %g %g %d\\n\", sum(a, 4), p.x + p.y, v, p.tag);\n  return half(9);\n}\n")
(display (cc-exe-run src))
```
---
```output
0.25 -2.5 3 0 2 2
2.5 -7 3.5 1.4142135624
6.75 6.25 4.5 7
4
```

### comparisons and tests: NaN, both zeros, the infinities, && || ! and the loops

```cc
(def src "#include <stdio.h>\nint main(void) {\n  double x = 1.5, y = 2, zero = 0.0, nz = -0.0;\n  double nan = zero / zero;\n  double inf = 1 / zero;\n  int count = 0;\n  printf(\"%d %d %d %d %d %d\\n\", x < y, x > y, x <= 1.5, x >= y, x == 1.5, x != 1.5);\n  printf(\"%d %d %d %d %d\\n\", nan == nan, nan != nan, nan < 1, nan >= 1, !nan);\n  printf(\"%d %d %d %d\\n\", !zero, !nz, !x, zero == nz);\n  printf(\"%d %d %d\\n\", x && y, zero || nz, zero || x);\n  printf(\"%g %g %g %g\\n\", x > y ? x : 1, x < y ? 2 : y, inf, -inf);\n  if (nz) count = 100;\n  if (x) count++;\n  while (x > 0.1) { x = x / 2; count++; }\n  do { y -= 0.5; count++; } while (y);\n  for (x = 0; x < 1; x += 0.25) count++;\n  printf(\"%d %g %g\\n\", count, x, y);\n  return count;\n}\n")
(display (cc-exe-run src))
```
---
```output
1 0 1 0 1 0
0 1 0 0 0
1 1 0 1
1 0 1
1 2 inf -inf
13 1 0
13
```

### sscanf and sprintf with doubles

```cc
(def src "#include <stdio.h>\nint main(void) {\n  double d = 0;\n  int i = 0;\n  char buf[64];\n  sscanf(\"2.5 17\", \"%lf %d\", &d, &i);\n  sprintf(buf, \"%.3f|%8.2e|%-6g|\", d * i, d, d);\n  printf(\"%s\\n\", buf);\n  printf(\"%5.1f %+g %.0f %G\\n\", -d, d, 2.5, 1e-10);\n  return i;\n}\n")
(display (cc-exe-run src))
```
---
```output
42.500|2.50e+00|2.5   |
 -2.5 +2.5 2 1E-10
17
```

### strtod: a number at a time, the end pointer stepping past each, and none

```cc
(def src "#include <stdio.h>\n#include <stdlib.h>\nint main(void) {\n  const char *text = \" 1.5 -2 3e2 0x10 junk\";\n  char *end;\n  double sum = 0;\n  int n = 0;\n  for (;;) {\n    double v = strtod(text, &end);\n    if (end == text) break;\n    printf(\"%g \", v);\n    sum += v;\n    n++;\n    text = end;\n  }\n  printf(\"| %g %d [%s] %g\\n\", sum, n, text, strtod(\"7.25\", NULL));\n  return n;\n}\n")
(display (cc-exe-run src))
```
---
```output
1.5 -2 300 16 | 315.5 4 [ junk] 7.25
4
```

## refused

### % on a double, under run

```cc
(display (cc-run "int main(void) { double d = 5; return d % 2; }"))
```
---
```output
cc: run failed: #<err:cc cc: run: the operator % on a double>
1
```

### % on a double, compiled

```cc
(write (guard (e (e msg)) (cc-exe-run "int main(void) { double d = 5; return d % 2; }")))
```
---
    "cc: compile: not built yet: the operator % on a double"

### ~ on a double, compiled

```cc
(write (guard (e (e msg)) (cc-exe-run "int main(void) { double d = 5; return ~d; }")))
```
---
    "cc: compile: not built yet: the operator ~ on a double"

### long double

```cc
(write (guard (e (e msg)) (cc-run "int main(void) { long double d = 5; return 0; }")))
```
---
    "cc: parse: line 1: not built yet: long double"

### double long

```cc
(write (guard (e (e msg)) (cc-run "int main(void) { double long d = 5; return 0; }")))
```
---
    "cc: parse: line 1: not built yet: long double"
