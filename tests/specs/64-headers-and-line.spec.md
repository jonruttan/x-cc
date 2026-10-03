# @weight 2
# @timeout-scale 3

The macros a standard header gives: `<math.h>`'s `M_PI` and the rest,
`<limits.h>`'s limits, `CHAR_MIN` and `CHAR_MAX` as plain `char` is on the
platform; and `__LINE__`, the number of the line it is on -- through a
macro, the line the macro is used on, and in a call that runs over lines,
the line it ends on.  Every expectation is what the same source prints
through /usr/bin/cc, then its status.

## run

### math.h and limits.h constants, __LINE__ directly, through a macro, and in a call over two lines

```cc
(def src "#include <stdio.h>\n#include <math.h>\n#include <limits.h>\n#define HERE __LINE__\n#define SHOW(x) printf(\"%s=%d\\n\", #x, x)\nint main(void) {\n  printf(\"%.6f %.6f %.6f\\n\", M_PI, M_E, M_SQRT2);\n  printf(\"%d %d %u %ld %lu\\n\", INT_MAX, INT_MIN, UINT_MAX, LONG_MIN, ULONG_MAX);\n  printf(\"%d %d %d %d\\n\", CHAR_BIT, SHRT_MIN, USHRT_MAX, SCHAR_MIN);\n  printf(\"%d %d\\n\", __LINE__, HERE);\n  SHOW(\n    __LINE__);\n  return __LINE__;\n}\n")
(display (cc-run src))
```
---
```output
3.141593 2.718282 1.414214
2147483647 -2147483648 4294967295 -9223372036854775808 18446744073709551615
8 -32768 65535 -128
10 10
__LINE__=12
13
```

## compiled

### math.h and limits.h constants, __LINE__ directly, through a macro, and in a call over two lines

```cc
(def src "#include <stdio.h>\n#include <math.h>\n#include <limits.h>\n#define HERE __LINE__\n#define SHOW(x) printf(\"%s=%d\\n\", #x, x)\nint main(void) {\n  printf(\"%.6f %.6f %.6f\\n\", M_PI, M_E, M_SQRT2);\n  printf(\"%d %d %u %ld %lu\\n\", INT_MAX, INT_MIN, UINT_MAX, LONG_MIN, ULONG_MAX);\n  printf(\"%d %d %d %d\\n\", CHAR_BIT, SHRT_MIN, USHRT_MAX, SCHAR_MIN);\n  printf(\"%d %d\\n\", __LINE__, HERE);\n  SHOW(\n    __LINE__);\n  return __LINE__;\n}\n")
(display (cc-exe-run src))
```
---
```output
3.141593 2.718282 1.414214
2147483647 -2147483648 4294967295 -9223372036854775808 18446744073709551615
8 -32768 65535 -128
10 10
__LINE__=12
13
```
