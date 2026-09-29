# @weight 2
# @timeout-scale 3

`float`: its values are the single's 32 bits, held where an unsigned int
would be, and its + - * / are the double's rounded to a single, which is
the single-precision answer.  An integer converts to one in one rounding.
A float handed to a function past its declared parameters -- printf's --
goes as a double, as C promotes it.  Every expectation is what the same
source prints through /usr/bin/cc, then its status.

## run

### single-precision arithmetic, f constants, compound assignment, ++ and --, and printf

```cc
(def src "#include <stdio.h>\nint main(void) {\n  float a = 0.1f, b = 0.2f;\n  float x = 16777216;\n  float big = 1e38f;\n  double d = a;\n  float h = 0.5F;\n  printf(\"%.10f %.10f %d\\n\", a + b, a * 3, (int)sizeof(float));\n  x = x + 1;\n  printf(\"%.1f %g %.17g\\n\", x, big * 10, d);\n  printf(\"%g %g %g %g\\n\", a / b, b - a, h + 1, -h);\n  a += 1.5f; b *= 4; x -= 16; h /= 8;\n  printf(\"%.9g %.9g %.1f %g\\n\", a, b, x, h);\n  a++; --b;\n  printf(\"%.9g %.9g %g\\n\", a, b, a + (double)b);\n  return (int)(a * 10);\n}\n")
(display (cc-run src))
```
---
```output
0.3000000119 0.3000000119 4
16777216.0 inf 0.10000000149011612
0.5 0.1 1.5 -0.5
1.60000002 0.800000012 16777200.0 0.0625
2.5999999 -0.199999988 2.4
26
```

### conversions: an integer to a float in one rounding, a float to each integer type

```cc
(def src "#include <stdio.h>\nint main(void) {\n  int i = 16777217;\n  long v = (1L << 60) + (1L << 36) + 1;\n  unsigned long u = 18446744073709551615UL;\n  unsigned long w = (1UL << 63) + (1UL << 39) + 1;\n  float fi = i, fv = v, fu = u, fw = w;\n  float f = -7.9f;\n  int back = f;\n  unsigned ub = 3000000000.0f;\n  char c = 65.7f;\n  long lb = 1e18f;\n  printf(\"%.1f %.1f %.1f %.1f\\n\", fi, fv, fu, fw);\n  printf(\"%d %u %d %ld\\n\", back, ub, c, lb);\n  printf(\"%lu %lu\\n\", (unsigned long)fu - 1, (unsigned long)1e19f);\n  printf(\"%g %g\\n\", (float)1 / 3, (double)((float)1 / 3));\n  return back + 20;\n}\n")
(display (cc-run src))
```
---
```output
16777216.0 1152921642045800448.0 18446744073709551616.0 9223373136366403584.0
-7 3000000000 65 999999984306749440
18446744073709551614 9999999980506447872
0.333333 0.333333
13
```

### globals, parameters, answers, arrays, a struct and a pointer, all floats

```cc
(def src "#include <stdio.h>\nstruct p { float x; char tag; float y; double z; };\nfloat g = 1.0f / 3;\nfloat h = 2.5;\nfloat k = 3;\nfloat zero;\nfloat gs[3] = {1, 2.5f, -0.5};\ndouble gd = 1.0f / 3;\nfloat half(float v) { return v / 2; }\nint trunc3(float v) { return v; }\nfloat avg(int a, int b) { return (a + b) / 2.0f; }\ndouble widen(float v) { return v; }\nfloat sum(float *a, int n) { float s = 0; int i; for (i = 0; i < n; i++) s += a[i]; return s; }\nvoid scale(float *q, float f) { *q = *q * f; }\nint main(void) {\n  float a[4] = {1.5f, 2, 3.25};\n  struct p s;\n  float v = 3;\n  s.x = 1.25f; s.tag = 'q'; s.y = s.x * 4; s.z = s.y;\n  scale(&v, 1.5f);\n  printf(\"%.9g %g %g %g %g %.17g\\n\", g, h, k, zero, gs[1] + gs[2], gd);\n  printf(\"%g %d %g %.17g\\n\", half(5), trunc3(-7.9f), avg(3, 4), widen(0.1f));\n  printf(\"%g %g %g %c %g %d\\n\", sum(a, 4), s.x + s.y, v, s.tag, s.z, (int)sizeof s);\n  return half(9);\n}\n")
(display (cc-run src))
```
---
```output
0.333333343 2.5 3 0 2 0.3333333432674408
2.5 -7 3.5 0.10000000149011612
6.75 6.25 4.5 q 5 24
4
```

### comparisons and tests: NaN, both zeros, the infinities, a float against a double

```cc
(def src "#include <stdio.h>\nint main(void) {\n  float x = 1.5f, y = 2, zero = 0, nz = -0.0f;\n  float nan = zero / zero;\n  float inf = 1 / zero;\n  double dd = 1.5;\n  int count = 0;\n  printf(\"%d %d %d %d %d %d\\n\", x < y, x > y, x <= 1.5, x >= y, x == 1.5, x == dd);\n  printf(\"%d %d %d %d %d\\n\", nan == nan, nan != nan, nan < 1, !nan, 0.1f == 0.1);\n  printf(\"%d %d %d %d\\n\", !zero, !nz, !x, zero == nz);\n  printf(\"%d %d %d\\n\", x && y, zero || nz, zero || x);\n  printf(\"%g %g %g %g\\n\", x > y ? x : 1, x < y ? 2.5 : y, inf, -inf);\n  if (nz) count = 100;\n  if (x) count++;\n  while (x > 0.1f) { x = x / 2; count++; }\n  do { y -= 0.5f; count++; } while (y);\n  for (x = 0; x < 1; x += 0.25f) count++;\n  printf(\"%d %g %g\\n\", count, x, y);\n  return count;\n}\n")
(display (cc-run src))
```
---
```output
1 0 1 0 1 1
0 1 0 0 0
1 1 0 1
1 0 1
1 2.5 inf -inf
13 1 0
13
```

### sscanf's %f, and a float handed to the maths library as a double

```cc
(def src "#include <stdio.h>\n#include <math.h>\nint main(void) {\n  float f = 0;\n  int i = 0;\n  char buf[64];\n  sscanf(\"2.5 17\", \"%f %d\", &f, &i);\n  sprintf(buf, \"%.3f|%8.2e|%-6g|\", f * i, f, f);\n  printf(\"%s\\n\", buf);\n  printf(\"%.6f %.6f %g\\n\", sqrt(f), pow(f, 2), floor(-f));\n  return i;\n}\n")
(display (cc-run src))
```
---
```output
42.500|2.50e+00|2.5   |
1.581139 6.250000 -3
17
```

## compiled

### single-precision arithmetic, f constants, compound assignment, ++ and --, and printf

```cc
(def src "#include <stdio.h>\nint main(void) {\n  float a = 0.1f, b = 0.2f;\n  float x = 16777216;\n  float big = 1e38f;\n  double d = a;\n  float h = 0.5F;\n  printf(\"%.10f %.10f %d\\n\", a + b, a * 3, (int)sizeof(float));\n  x = x + 1;\n  printf(\"%.1f %g %.17g\\n\", x, big * 10, d);\n  printf(\"%g %g %g %g\\n\", a / b, b - a, h + 1, -h);\n  a += 1.5f; b *= 4; x -= 16; h /= 8;\n  printf(\"%.9g %.9g %.1f %g\\n\", a, b, x, h);\n  a++; --b;\n  printf(\"%.9g %.9g %g\\n\", a, b, a + (double)b);\n  return (int)(a * 10);\n}\n")
(display (cc-exe-run src))
```
---
```output
0.3000000119 0.3000000119 4
16777216.0 inf 0.10000000149011612
0.5 0.1 1.5 -0.5
1.60000002 0.800000012 16777200.0 0.0625
2.5999999 -0.199999988 2.4
26
```

### conversions: an integer to a float in one rounding, a float to each integer type

```cc
(def src "#include <stdio.h>\nint main(void) {\n  int i = 16777217;\n  long v = (1L << 60) + (1L << 36) + 1;\n  unsigned long u = 18446744073709551615UL;\n  unsigned long w = (1UL << 63) + (1UL << 39) + 1;\n  float fi = i, fv = v, fu = u, fw = w;\n  float f = -7.9f;\n  int back = f;\n  unsigned ub = 3000000000.0f;\n  char c = 65.7f;\n  long lb = 1e18f;\n  printf(\"%.1f %.1f %.1f %.1f\\n\", fi, fv, fu, fw);\n  printf(\"%d %u %d %ld\\n\", back, ub, c, lb);\n  printf(\"%lu %lu\\n\", (unsigned long)fu - 1, (unsigned long)1e19f);\n  printf(\"%g %g\\n\", (float)1 / 3, (double)((float)1 / 3));\n  return back + 20;\n}\n")
(display (cc-exe-run src))
```
---
```output
16777216.0 1152921642045800448.0 18446744073709551616.0 9223373136366403584.0
-7 3000000000 65 999999984306749440
18446744073709551614 9999999980506447872
0.333333 0.333333
13
```

### globals, parameters, answers, arrays, a struct and a pointer, all floats

```cc
(def src "#include <stdio.h>\nstruct p { float x; char tag; float y; double z; };\nfloat g = 1.0f / 3;\nfloat h = 2.5;\nfloat k = 3;\nfloat zero;\nfloat gs[3] = {1, 2.5f, -0.5};\ndouble gd = 1.0f / 3;\nfloat half(float v) { return v / 2; }\nint trunc3(float v) { return v; }\nfloat avg(int a, int b) { return (a + b) / 2.0f; }\ndouble widen(float v) { return v; }\nfloat sum(float *a, int n) { float s = 0; int i; for (i = 0; i < n; i++) s += a[i]; return s; }\nvoid scale(float *q, float f) { *q = *q * f; }\nint main(void) {\n  float a[4] = {1.5f, 2, 3.25};\n  struct p s;\n  float v = 3;\n  s.x = 1.25f; s.tag = 'q'; s.y = s.x * 4; s.z = s.y;\n  scale(&v, 1.5f);\n  printf(\"%.9g %g %g %g %g %.17g\\n\", g, h, k, zero, gs[1] + gs[2], gd);\n  printf(\"%g %d %g %.17g\\n\", half(5), trunc3(-7.9f), avg(3, 4), widen(0.1f));\n  printf(\"%g %g %g %c %g %d\\n\", sum(a, 4), s.x + s.y, v, s.tag, s.z, (int)sizeof s);\n  return half(9);\n}\n")
(display (cc-exe-run src))
```
---
```output
0.333333343 2.5 3 0 2 0.3333333432674408
2.5 -7 3.5 0.10000000149011612
6.75 6.25 4.5 q 5 24
4
```

### comparisons and tests: NaN, both zeros, the infinities, a float against a double

```cc
(def src "#include <stdio.h>\nint main(void) {\n  float x = 1.5f, y = 2, zero = 0, nz = -0.0f;\n  float nan = zero / zero;\n  float inf = 1 / zero;\n  double dd = 1.5;\n  int count = 0;\n  printf(\"%d %d %d %d %d %d\\n\", x < y, x > y, x <= 1.5, x >= y, x == 1.5, x == dd);\n  printf(\"%d %d %d %d %d\\n\", nan == nan, nan != nan, nan < 1, !nan, 0.1f == 0.1);\n  printf(\"%d %d %d %d\\n\", !zero, !nz, !x, zero == nz);\n  printf(\"%d %d %d\\n\", x && y, zero || nz, zero || x);\n  printf(\"%g %g %g %g\\n\", x > y ? x : 1, x < y ? 2.5 : y, inf, -inf);\n  if (nz) count = 100;\n  if (x) count++;\n  while (x > 0.1f) { x = x / 2; count++; }\n  do { y -= 0.5f; count++; } while (y);\n  for (x = 0; x < 1; x += 0.25f) count++;\n  printf(\"%d %g %g\\n\", count, x, y);\n  return count;\n}\n")
(display (cc-exe-run src))
```
---
```output
1 0 1 0 1 1
0 1 0 0 0
1 1 0 1
1 0 1
1 2.5 inf -inf
13 1 0
13
```

### sscanf's %f, and a float handed to the maths library as a double

```cc
(def src "#include <stdio.h>\n#include <math.h>\nint main(void) {\n  float f = 0;\n  int i = 0;\n  char buf[64];\n  sscanf(\"2.5 17\", \"%f %d\", &f, &i);\n  sprintf(buf, \"%.3f|%8.2e|%-6g|\", f * i, f, f);\n  printf(\"%s\\n\", buf);\n  printf(\"%.6f %.6f %g\\n\", sqrt(f), pow(f, 2), floor(-f));\n  return i;\n}\n")
(display (cc-exe-run src))
```
---
```output
42.500|2.50e+00|2.5   |
1.581139 6.250000 -3
17
```

## refused

### % on a float, under run

```cc
(display (cc-run "int main(void) { float f = 5; return f % 2; }"))
```
---
```output
cc: run failed: #<err:cc cc: run: the operator % on a float>
1
```

### % on a float, compiled

```cc
(write (guard (e (e msg)) (cc-exe-run "int main(void) { float f = 5; return f % 2; }")))
```
---
    "cc: compile: not built yet: the operator % on a float"

### ~ on a float, compiled

```cc
(write (guard (e (e msg)) (cc-exe-run "int main(void) { float f = 5; return ~f; }")))
```
---
    "cc: compile: not built yet: the operator ~ on a float"
