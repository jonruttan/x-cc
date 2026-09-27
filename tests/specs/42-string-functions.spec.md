# @weight 2
# @timeout-scale 3

`strlen`, `strcmp`, `strcpy`, `memcpy` and `memset`, under `run` and
compiled.  Compiled, each is a runtime function the generator writes after
the program's last function when the program calls it and does not define
its own, as `malloc` is.  Each case runs the program under `run`, then
compiled, and shows both statuses, and both outputs where it prints; every
expectation is what the same source prints through /usr/bin/cc.

## strlen

### the bytes before the NUL

```cc
(def src "#include <string.h>\nint main(void) { char *s = \"hello\"; return strlen(s) + strlen(\"\") * 100; }")
(display (list (cc-run src) (cc-exe-run src)))
```
---
    (5 5)

### it answers a size_t, which is unsigned

`run`'s arithmetic is not unsigned yet, so this one is compiled only.

```cc
(display (cc-exe-run "#include <string.h>\nint main(void) { char *s = \"hello\"; return strlen(s) + (strlen(s) - 10 > 0) * 20; }"))
```
---
    25

## strcmp

### the sign of the first difference, each byte an unsigned char

```cc
(def src "#include <string.h>\nint main(void) { char hi[2]; hi[0] = (char)200; hi[1] = 0; return (strcmp(\"abc\", \"abc\") == 0) + (strcmp(\"abc\", \"abd\") < 0) * 2 + (strcmp(\"b\", \"a\") > 0) * 4 + (strcmp(\"ab\", \"abc\") < 0) * 8 + (strcmp(hi, \"a\") > 0) * 16; }")
(display (list (cc-run src) (cc-exe-run src)))
```
---
    (31 31)

## copies

### strcpy, twice into one buffer

```cc
(def src "#include <stdio.h>\n#include <string.h>\nint main(void) { char buf[20]; strcpy(buf, \"hi\"); strcpy(buf + 2, \" there\"); puts(buf); return strlen(buf); }")
(display (list (cc-run src) (cc-exe-run src)))
```
---
```output
hi there
hi there
(8 8)
```

### memset and memcpy, over ints and chars

```cc
(def src "#include <stdio.h>\n#include <string.h>\nint main(void) { int a[5] = {1, 2, 3, 4, 5}; int b[5]; char c[4]; memset(b, 0, sizeof(b)); memcpy(b + 1, a, 3 * sizeof(int)); memset(c, 'x', 3); c[3] = 0; puts(c); return b[0] * 1000 + b[1] * 100 + b[2] * 10 + b[3] + b[4]; }")
(display (list (cc-run src) (cc-exe-run src)))
```
---
```output
xxx
xxx
(123 123)
```

### each answers where it wrote

```cc
(def src "#include <string.h>\nint main(void) { char buf[4]; return (memset(buf, 0, 1) == buf) + (memcpy(buf, \"a\", 1) == buf) * 2 + (strcpy(buf, \"b\") == buf) * 4; }")
(display (list (cc-run src) (cc-exe-run src)))
```
---
    (7 7)

## the refusals

### strcmp with one argument

```cc
(write (guard (e (e msg)) (cc-exe-run "#include <string.h>\nint main(void) { return strcmp(\"a\"); }")))
```
---
    "cc: compile: not built yet: strcmp with other than two arguments"
