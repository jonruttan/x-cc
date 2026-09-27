# @weight 2
# @timeout-scale 3

`strcat`, `strncmp`, `strncpy`, `strchr`, `memcmp` and `atoi`, under `run`
and compiled, where each is a runtime function written after the program
when it is called.  Each case runs the program under `run`, then
compiled, and shows both statuses, and both outputs where it prints;
every expectation is what the same source prints through /usr/bin/cc.

## strings

### strcat, twice onto one buffer

```cc
(def src "#include <stdio.h>\n#include <string.h>\nint main(void) { char buf[32]; strcpy(buf, \"foo\"); strcat(buf, \"bar\"); strcat(buf, \"!\"); puts(buf); return strlen(buf); }")
(display (list (cc-run src) (cc-exe-run src)))
```
---
```output
foobar!
foobar!
(7 7)
```

### strncmp over a count, stopping at a NUL

```cc
(def src "#include <string.h>\nint main(void) { return (strncmp(\"abcdef\", \"abcxyz\", 3) == 0) + (strncmp(\"abcdef\", \"abcxyz\", 4) < 0) * 2 + (strncmp(\"a\", \"b\", 0) == 0) * 4 + (strncmp(\"ab\", \"ab\", 10) == 0) * 8; }")
(display (list (cc-run src) (cc-exe-run src)))
```
---
    (15 15)

### strncpy pads with NULs, and stops at its count

```cc
(def src "#include <string.h>\nint main(void) { char buf[8]; memset(buf, 'z', 8); strncpy(buf, \"hi\", 5); int r = (buf[0] == 'h') + (buf[2] == 0) * 2 + (buf[4] == 0) * 4 + (buf[5] == 'z') * 8; r += (strncpy(buf, \"abcdefgh\", 3) == buf) * 16 + (buf[3] == 0) * 32; return r; }")
(display (list (cc-run src) (cc-exe-run src)))
```
---
    (63 63)

### strchr finds a char, not one, and the NUL

```cc
(def src "#include <string.h>\nint main(void) { char *s = \"hello\"; return (strchr(s, 'l') - s) + (strchr(s, 'z') == 0) * 10 + (strchr(s, 0) == s + 5) * 100; }")
(display (list (cc-run src) (cc-exe-run src)))
```
---
    (112 112)

## bytes and numbers

### memcmp reads each byte as an unsigned char

```cc
(def src "#include <string.h>\nint main(void) { char a[2]; char b[2]; a[0] = (char)200; a[1] = 0; b[0] = 1; b[1] = 0; return (memcmp(\"abc\", \"abd\", 3) < 0) + (memcmp(\"abc\", \"abd\", 2) == 0) * 2 + (memcmp(a, b, 1) > 0) * 4; }")
(display (list (cc-run src) (cc-exe-run src)))
```
---
    (7 7)

### atoi past spaces and a sign, to the first non-digit

```cc
(def src "#include <stdlib.h>\nint main(void) { return atoi(\"42\") + atoi(\"-17\") + atoi(\"  7x\") + atoi(\"+3\") + atoi(\"\") * 100; }")
(display (list (cc-run src) (cc-exe-run src)))
```
---
    (35 35)
