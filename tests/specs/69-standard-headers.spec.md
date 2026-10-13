# @weight 1
# @timeout-scale 2

The standard headers past stdio's: each is lines of C in place of its
`#include`.  Each case runs under `run`, then compiled, and shows both
outputs and both statuses; the expectation is what the same source prints
through /usr/bin/cc.

## Standard headers

### stdint.h, inttypes.h, stdbool.h and sys/types.h: fixed-width types, their limits and printf conversions

```cc
(def src "#include <stdio.h>\n#include <stdint.h>\n#include <inttypes.h>\n#include <stdbool.h>\n#include <sys/types.h>\nint main(void) {\n  int8_t a = -128; uint8_t b = 255; int16_t c = INT16_MIN; uint16_t d = UINT16_MAX;\n  int32_t e = INT32_MIN; uint32_t f = UINT32_MAX; int64_t g = INT64_MIN; uint64_t h = UINT64_MAX;\n  bool t = true, u = 7;\n  ssize_t s = -1; off_t o = 1L << 40; pid_t p = 42;\n  printf(\"%d %u %d %u\\n\", a, b, c, d);\n  printf(\"%\" PRId32 \" %\" PRIu32 \" %\" PRId64 \" %\" PRIu64 \"\\n\", e, f, g, h);\n  printf(\"%08\" PRIx32 \" %\" PRIX64 \"\\n\", (uint32_t)0xbeef, UINT64_C(0xABCDEF0123));\n  printf(\"%d %d %d %d\\n\", t, u, false, (int)sizeof(bool));\n  printf(\"%d %d %d %d\\n\", (int)sizeof(int8_t), (int)sizeof(uint16_t), (int)sizeof(int32_t), (int)sizeof(uintptr_t));\n  printf(\"%zd %ld %d %d\\n\", s, (long)o, p, SIZE_MAX > 0);\n  return (int)(f & 7) + INT32_C(1);\n}\n")
(display (list (cc-run src) (cc-exe-run src)))
```
---
```output
-128 255 -32768 65535
-2147483648 4294967295 -9223372036854775808 18446744073709551615
0000beef ABCDEF0123
1 1 0 1
1 2 4 8
-1 1099511627776 42 1
-128 255 -32768 65535
-2147483648 4294967295 -9223372036854775808 18446744073709551615
0000beef ABCDEF0123
1 1 0 1
1 2 4 8
-1 1099511627776 42 1
(8 8)
```

### time.h's struct tm, errno.h's errno, assert.h, and the library's pointers strtok_r and gmtime_r answer

```cc
(def src "#include <stdio.h>\n#include <string.h>\n#include <time.h>\n#include <time.h>\n#include <errno.h>\n#include <assert.h>\nint main(void) {\n  time_t when = 86400 * 365L + 3661;\n  struct tm tm;\n  char text[] = \"a,b;;c\", *save, *w, buf[32];\n  struct tm *q = gmtime_r(&when, &tm);\n  printf(\"%d %d %d %d:%d:%d %d %d\\n\", q == &tm, tm.tm_year, tm.tm_mon, tm.tm_hour, tm.tm_min, tm.tm_sec, tm.tm_wday, tm.tm_yday);\n  strftime(buf, sizeof buf, \"%Y-%m-%d %H:%M\", &tm);\n  printf(\"%s %d\\n\", buf, (int)sizeof(struct tm));\n  for (w = strtok_r(text, \",;\", &save); w; w = strtok_r(NULL, \",;\", &save)) printf(\"[%s]\", w);\n  printf(\"\\n\");\n  errno = 0;\n  printf(\"%d \", fopen(\"no/such/dir/file\", \"r\") == NULL);\n  printf(\"%d %d\\n\", errno == ENOENT, errno);\n  assert(when > 0);\n  return EINVAL;\n}\n")
(display (list (cc-run src) (cc-exe-run src)))
```
---
```output
1 71 0 1:1:1 5 0
1971-01-01 01:01 56
[a][b][c]
1 1 2
1 71 0 1:1:1 5 0
1971-01-01 01:01 56
[a][b][c]
1 1 2
(22 22)
```

### assert.h under NDEBUG checks nothing

```cc
(def src "#define NDEBUG\n#include <assert.h>\nint main(void) {\n  assert(0);\n  return 3;\n}\n")
(display (list (cc-run src) (cc-exe-run src)))
```
---
```output
(3 3)
```
