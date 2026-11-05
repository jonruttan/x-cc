# @weight 1
# @timeout-scale 3

A function declared inside a block, `extern` or not, declares nothing
more than one at file scope does: the call is made as for any name.  A
declarator that is a pointer to a function is still a variable.  Every
expectation is what the same source prints through /usr/bin/cc, then its
status.

## compiled

### the C library's function and the program's own, declared in main

```cc
(def src "#include <stdio.h>\n#include <stddef.h>\nint main(void) {\n  extern char *strndup(const char *, size_t);\n  int twice(int);\n  static int (*own)(int);\n  char *p = strndup(\"hello\", 3);\n  own = twice;\n  printf(\"%s %d %d\\n\", p, twice(21), own(2));\n  return 0;\n}\nint twice(int x) { return 2 * x; }\n")
(display (cc-exe-run src))
```
---
```output
hel 42 4
0
```
