# @weight 2
# @timeout-scale 3

A cast to a pointer to a function, `(RET (*)(PARAMS))`: its C type is the
pointer's, which a call through it answers RET by; the value is the
function's as it was.  The parameters' types are not kept, as a
declarator's are not.  Every expectation is what the same source prints
through /usr/bin/cc, then its status.

## run

### round trips through void (*)(void) and a typedef, a call through a cast, a pointer answered, sizeof, a null one

```cc
(def src "#include <stdio.h>\ntypedef void (*anyfn)(void);\nint add1(int x) { return x + 1; }\nint twice(int x) { return 2 * x; }\nchar *name(void) { return \"seven\"; }\nint apply(anyfn f, int v) { return ((int (*)(int))f)(v); }\nint main(void) {\n  anyfn tab[2] = { (void (*)(void))add1, (anyfn)twice };\n  int (*g)(int) = (int (*)(int))tab[1];\n  char *(*n)(void) = (char *(*)(void))name;\n  int (*z)(int) = (int (*)(int))0;\n  printf(\"%d %d %d\\n\", apply(tab[0], 4), g(21), ((int (*)(int))tab[0])(9));\n  printf(\"%s %d %d\\n\", n(), (int)sizeof((int (*)(int))0), z == 0);\n  return apply((anyfn)add1, 40);\n}\n")
(display (cc-run src))
```
---
```output
5 42 10
seven 8 1
41
```

## compiled

### round trips through void (*)(void) and a typedef, a call through a cast, a pointer answered, sizeof, a null one

```cc
(def src "#include <stdio.h>\ntypedef void (*anyfn)(void);\nint add1(int x) { return x + 1; }\nint twice(int x) { return 2 * x; }\nchar *name(void) { return \"seven\"; }\nint apply(anyfn f, int v) { return ((int (*)(int))f)(v); }\nint main(void) {\n  anyfn tab[2] = { (void (*)(void))add1, (anyfn)twice };\n  int (*g)(int) = (int (*)(int))tab[1];\n  char *(*n)(void) = (char *(*)(void))name;\n  int (*z)(int) = (int (*)(int))0;\n  printf(\"%d %d %d\\n\", apply(tab[0], 4), g(21), ((int (*)(int))tab[0])(9));\n  printf(\"%s %d %d\\n\", n(), (int)sizeof((int (*)(int))0), z == 0);\n  return apply((anyfn)add1, 40);\n}\n")
(display (cc-exe-run src))
```
---
```output
5 42 10
seven 8 1
41
```

### qsort with a comparator cast to the type the library takes

```cc
(def src "#include <stdio.h>\n#include <stdlib.h>\nint cmp(const int *a, const int *b) { return *a - *b; }\nint main(void) {\n  int a[5] = {5, 3, 9, 1, 7};\n  int i;\n  qsort(a, 5, sizeof a[0], (int (*)(const void *, const void *))cmp);\n  for (i = 0; i < 5; i++) printf(\"%d \", a[i]);\n  printf(\"\\n\");\n  return a[4];\n}\n")
(display (cc-exe-run src))
```
---
```output
1 3 5 7 9 
9
```
