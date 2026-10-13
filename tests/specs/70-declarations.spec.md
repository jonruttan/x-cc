# @weight 1
# @timeout-scale 2

C99's declaration in a `for`, its names the loop's own; and a global
declared more than once -- `extern` before its definition, a tentative
definition after it -- which is one object.  Each case runs under `run`,
then compiled, and shows both outputs and both statuses; the expectation
is what the same source prints through /usr/bin/cc.

## Declarations

### a for loop's declaration, which ends with the loop

```cc
(def src "#include <stdio.h>\nint main(void) {\n  int s = 0, i = 100;\n  for (int i = 0, j = 10; i < j; i++, j--) s += i * j;\n  for (char *p = \"abc\"; *p; p++) s += *p;\n  for (int k = 0; k < 3; k++) { int k2 = k * k; if (k2 == 1) continue; s += k2; }\n  printf(\"%d %d\\n\", s, i);\n  return i - 100;\n}\n")
(display (list (cc-run src) (cc-exe-run src)))
```
---
```output
368 100
368 100
(0 0)
```

### extern before the definition, and a tentative definition after it

```cc
(def src "#include <stdio.h>\nextern int count;\nextern int table[];\nint bump(void) { return ++count; }\nint count = 10;\nint count;\nint table[3] = {4, 5, 6};\nint main(void) {\n  bump(); bump();\n  printf(\"%d %d %d\\n\", count, table[2], (int)sizeof table);\n  return count;\n}\n")
(display (list (cc-run src) (cc-exe-run src)))
```
---
```output
12 6 12
12 6 12
(12 12)
```
