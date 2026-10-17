# @weight 1
# @timeout-scale 2

Standard headers Lua's sources include.  <locale.h> gives the categories,
each platform's numbers for them, and struct lconv, which localeconv
answers a pointer to; <stdio.h> gives setvbuf's buffering modes, the seek
origins and L_tmpnam; <float.h> gives the limits of float and double, and
<math.h> HUGE_VAL.  A static array of them is laid out before the program
runs.  Each case runs under `run`, then compiled, and shows both outputs
and both statuses; the expectation is what the same source prints
through /usr/bin/cc.

## library headers

### the categories, localeconv and the buffering modes

```cc
(def src "#include <stdio.h>\n#include <locale.h>\nstatic int pick(int i) {\n  static const int cat[] = {LC_ALL, LC_COLLATE, LC_CTYPE, LC_MONETARY, LC_NUMERIC, LC_TIME};\n  static const char *const catnames[] = {\"all\", \"collate\", \"ctype\", \"monetary\", \"numeric\", \"time\", NULL};\n  printf(\"%s=%d \", catnames[i], cat[i] >= 0);\n  return cat[i];\n}\nint main(void) {\n  static const int mode[] = {_IONBF, _IOFBF, _IOLBF};\n  int i;\n  for (i = 0; i < 6; i++) pick(i);\n  printf(\"\\n%c %d\\n\", localeconv()->decimal_point[0], setlocale(LC_ALL, NULL) != NULL);\n  printf(\"%d\\n\", setvbuf(stdout, NULL, mode[2], BUFSIZ));\n  return mode[1];\n}\n")
(display (list (cc-run src) (cc-exe-run src)))
```
---
```output
all=1 collate=1 ctype=1 monetary=1 numeric=1 time=1 
. 1
0
all=1 collate=1 ctype=1 monetary=1 numeric=1 time=1 
. 1
0
(0 0)
```

### float.h's limits, HUGE_VAL, and stdio.h's seek origins

```cc
(def src "#include <stdio.h>\n#include <math.h>\n#include <float.h>\nstatic const int whence[] = {SEEK_SET, SEEK_CUR, SEEK_END};\nint main(void) {\n  double big = DBL_MAX;\n  printf(\"%d %d %d %d\\n\", DBL_MANT_DIG, DBL_MAX_10_EXP, FLT_MANT_DIG, whence[2]);\n  printf(\"%d %d %d\\n\", HUGE_VAL > big, -HUGE_VAL < -big, L_tmpnam > 0);\n  printf(\"%.17g %.17g %g\\n\", DBL_EPSILON, DBL_MIN, (double)FLT_MAX);\n#if DBL_MANT_DIG >= 53\n  printf(\"double\\n\");\n#endif\n  return whence[1];\n}\n")
(display (list (cc-run src) (cc-exe-run src)))
```
---
```output
53 308 24 2
1 1 1
2.2204460492503131e-16 2.2250738585072014e-308 3.40282e+38
double
53 308 24 2
1 1 1
2.2204460492503131e-16 2.2250738585072014e-308 3.40282e+38
double
(1 1)
```
