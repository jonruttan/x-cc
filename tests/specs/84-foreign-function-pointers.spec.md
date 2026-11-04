# @weight 2
# @timeout-scale 3

A pointer to a function the C library answered -- dlsym's -- holds the
library's address, all 64 bits of it, and a call through it is the C
library's call, its arguments where the C calling convention puts them;
a pointer to one of the program's own functions is called as before.
dlopen, dlsym and dlerror answer pointers.  Every expectation is what the
same source prints through /usr/bin/cc, then its status.

## compiled

### strlen and getenv through dlsym, eight arguments as ptr-call passes them, beside the program's own

```cc
(def src "#include <dlfcn.h>\n#include <stdio.h>\n#include <stdlib.h>\ntypedef long (*lfn)(long, long, long, long, long, long, long, long);\nint twice(int x) { return 2 * x; }\nint main(void) {\n  void *h = dlopen(0, RTLD_LAZY);\n  unsigned long (*len)(const char *) = (unsigned long (*)(const char *))dlsym(h, \"strlen\");\n  lfn ge = (lfn)dlsym(h, \"getenv\");\n  int (*own)(int) = twice;\n  setenv(\"CC_PROBE\", \"yes\", 1);\n  printf(\"%d %s %d\\n\", (int)len(\"hello\"), (char *)ge((long)\"CC_PROBE\", 0, 0, 0, 0, 0, 0, 0), own(21));\n  printf(\"%d %d\\n\", (unsigned long)dlsym(h, \"getenv\") > 0xffffffffUL, dlsym(h, \"no_such_function\") == 0);\n  return (int)len(\"abc\");\n}\n")
(display (cc-exe-run src))
```
---
```output
5 yes 42
1 1
3
```
