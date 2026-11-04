# @weight 2
# @timeout-scale 3

The name of a C library function, with or without `&`, is that
function's address: a local initializer, a static one, a struct's
initializer list.  A call through it is the library's call, and it
compares equal to the name.  Every expectation is what the same source
prints through /usr/bin/cc, then its status.

## compiled

### strlen and calloc held by locals

```cc
(def src "#include <stdio.h>\n#include <stdlib.h>\n#include <string.h>\nint main(void) {\n  size_t (*len)(const char *) = strlen;\n  void *(*al)(size_t, size_t) = &calloc;\n  int *p = al(4, sizeof(int));\n  printf(\"%d %d %d\\n\", (int)len(\"hello\"), p[3], len == strlen);\n  return (int)len(\"abc\");\n}\n")
(display (cc-exe-run src))
```
---
```output
5 0 1
3
```

### a static pointer and a struct of library functions

```cc
(def src "#include <stdio.h>\n#include <stdlib.h>\n#include <string.h>\nsize_t (*len)(const char *) = strlen;\nstruct ops { void *(*al)(size_t, size_t); void (*fr)(void *); int (*put)(const char *); };\nstatic struct ops ops = { calloc, free, puts };\nint main(void) {\n  int *p = ops.al(4, sizeof(int));\n  printf(\"%d %d %d\\n\", (int)len(\"hello\"), p[3], ops.fr == free);\n  ops.fr(p);\n  ops.put(\"done\");\n  return 0;\n}\n")
(display (cc-exe-run src))
```
---
```output
5 0 1
done
0
```
