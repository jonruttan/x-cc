# @weight 2
# @timeout-scale 3

sprintf and snprintf, the same under `run` and compiled: the format is
printf's, and what printf would write goes into the string instead,
with a NUL after it.  snprintf takes no more than its size, the NUL
included, and none at all at size 0; both answer the count printf would
have written.  Each case runs the program under `run`, then compiled,
and shows both outputs and both statuses; every expectation is what the
same source prints through /usr/bin/cc.

## sprintf

### each conversion, a field, an empty string and plain text, with the counts

```cc
(def src "#include <stdio.h>\n#include <string.h>\nint main(void) {\n  char buf[64];\n  int n = sprintf(buf, \"%d-%s-%c-%x\", 42, \"abc\", 'z', 255);\n  puts(buf);\n  printf(\"%d %d\\n\", n, (int)strlen(buf));\n  n = sprintf(buf, \"[%5d|%-5d|%05d]\", 7, -7, 7);\n  puts(buf);\n  n = sprintf(buf, \"%s\", \"\");\n  printf(\"%d [%s]\\n\", n, buf);\n  n = sprintf(buf, \"plain\");\n  printf(\"%d %s\\n\", n, buf);\n  return n;\n}\n")
(display (list (cc-run src) (cc-exe-run src)))
```
---
```output
42-abc-z-ff
11 11
[    7|-7   |00007]
0 []
5 plain
42-abc-z-ff
11 11
[    7|-7   |00007]
0 []
5 plain
(5 5)
```

### appending through the count, into the heap, and the widest numbers

```cc
(def src "#include <stdio.h>\n#include <stdlib.h>\n#include <string.h>\nint main(void) {\n  char line[128];\n  char *p = malloc(32);\n  int len = 0;\n  int i;\n  for (i = 0; i < 5; i++) len += sprintf(line + len, \"%d,\", i * i);\n  printf(\"%s %d\\n\", line, len);\n  sprintf(p, \"%-6s|%6s|%.2s\", \"ab\", \"cd\", \"efgh\");\n  printf(\"[%s] %d\\n\", p, (int)strlen(p));\n  sprintf(line, \"%ld %lu %lx\", -9223372036854775807L - 1, 18446744073709551615UL, 3735928559L);\n  puts(line);\n  return strlen(line);\n}\n")
(display (list (cc-run src) (cc-exe-run src)))
```
---
```output
0,1,4,9,16, 11
[ab    |    cd|ef] 16
-9223372036854775808 18446744073709551615 deadbeef
0,1,4,9,16, 11
[ab    |    cd|ef] 16
-9223372036854775808 18446744073709551615 deadbeef
(50 50)
```

### a sprintf's answer as another's argument, and one in each frame of a recursion

```cc
(def src "#include <stdio.h>\nint fmt(char *out, int size, int v) {\n  return snprintf(out, size, \"<%04d>\", v);\n}\nint depth(char *out, int n) {\n  char mine[16];\n  if (n == 0) return sprintf(out, \"0\");\n  depth(mine, n - 1);\n  return sprintf(out, \"%d(%s)\", n, mine);\n}\nint main(void) {\n  char a[32];\n  char b[32];\n  int n = sprintf(a, \"%d\", sprintf(b, \"%s-%s\", \"x\", \"yz\"));\n  printf(\"%s %s %d\\n\", a, b, n);\n  printf(\"%d \", fmt(a, sizeof a, 42));\n  puts(a);\n  printf(\"%d \", fmt(a, 4, 42));\n  puts(a);\n  depth(b, 3);\n  puts(b);\n  return 0;\n}\n")
(display (list (cc-run src) (cc-exe-run src)))
```
---
```output
4 x-yz 1
6 <0042>
6 <00
3(2(1(0)))
4 x-yz 1
6 <0042>
6 <00
3(2(1(0)))
(0 0)
```

## snprintf

### cut at the size, nothing at size 0, a size of 1, and a null string

```cc
(def src "#include <stdio.h>\nint main(void) {\n  char buf[8];\n  int n;\n  int i;\n  n = snprintf(buf, sizeof buf, \"%s\", \"hello, world\");\n  printf(\"%d [%s]\\n\", n, buf);\n  n = snprintf(buf, 5, \"%d\", 123456);\n  printf(\"%d [%s]\\n\", n, buf);\n  buf[0] = 'Q';\n  n = snprintf(buf, 0, \"%d\", 99);\n  printf(\"%d %c\\n\", n, buf[0]);\n  n = snprintf(buf, 1, \"abc\");\n  printf(\"%d [%s]\\n\", n, buf);\n  n = snprintf(0, 0, \"%ld\", -1234567890123L);\n  printf(\"%d\\n\", n);\n  for (i = 0; i < 8; i++) buf[i] = 'x';\n  n = snprintf(buf, 4, \"%c%c%c%c%c\", 'a', 'b', 'c', 'd', 'e');\n  printf(\"%d [%s] %c\\n\", n, buf, buf[4]);\n  return n;\n}\n")
(display (list (cc-run src) (cc-exe-run src)))
```
---
```output
12 [hello, ]
6 [1234]
2 Q
3 []
14
5 [abc] x
12 [hello, ]
6 [1234]
2 Q
3 []
14
5 [abc] x
(5 5)
```

### padding cut in the middle, a measure then a fill, and %% around a %c

```cc
(def src "#include <stdio.h>\n#include <stdlib.h>\nint main(void) {\n  char small[6];\n  char *p;\n  int m;\n  int n = snprintf(small, sizeof small, \"[%8d]\", -5);\n  printf(\"%d [%s]\\n\", n, small);\n  n = snprintf(small, sizeof small, \"%-10s|\", \"ab\");\n  printf(\"%d [%s]\\n\", n, small);\n  n = snprintf((char *)0, 0, \"%s=%d\", \"width\", 12345);\n  p = malloc(n + 1);\n  m = snprintf(p, n + 1, \"%s=%d\", \"width\", 12345);\n  printf(\"%d %d %s\\n\", n, m, p);\n  n = snprintf(small, sizeof small, \"%%%c%%\", 'q');\n  printf(\"%d [%s]\\n\", n, small);\n  return n;\n}\n")
(display (list (cc-run src) (cc-exe-run src)))
```
---
```output
10 [[    ]
11 [ab   ]
11 11 width=12345
3 [%q%]
10 [[    ]
11 [ab   ]
11 11 width=12345
3 [%q%]
(3 3)
```

## refused

### a format that is not a literal

```cc
(display (guard (e (do (display "refused: ") (write e) ""))
  (cc-exe-run "#include <stdio.h>\nint main(void) { char b[8]; sprintf(b, 1 ? \"a\" : \"b\"); return 0; }")))
```
---
    refused: #<err:cc cc: compile: not built yet: sprintf of a format that is not a literal>

### fewer arguments than conversions

```cc
(display (guard (e (do (display "refused: ") (write e) ""))
  (cc-exe-run "#include <stdio.h>\nint main(void) { char b[8]; snprintf(b, 8, \"%d %d\", 1); return 0; }")))
```
---
    refused: #<err:cc cc: compile: not built yet: snprintf with fewer arguments than conversions>
