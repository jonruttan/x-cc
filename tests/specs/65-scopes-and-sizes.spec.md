# @weight 2
# @timeout-scale 3

A local is scoped as C scopes it: a name declared again in a sibling block,
or in an inner block over an outer one or a parameter, is a variable of its
own, and a static local in each of two blocks is two.  An array's size is a
constant expression -- `N + 1`, `sizeof(int) * 2`, an enum's arithmetic --
and `<stdio.h>`, `<stdlib.h>`, `<string.h>` and `<stddef.h>` give
`size_t`.  Every expectation is what the same source prints through
/usr/bin/cc, then its status.

## run

### sibling and nested blocks, a shadowed parameter and pointer, two statics, sizes from expressions, size_t

```cc
(def src "#include <stdio.h>\n#include <string.h>\n#define N 3\nenum { K = 2 };\nstatic int twice(int x) { return 2 * x; }\nint pick(int v, int which) {\n  if (which) { int v = 10; v += which; return v; }\n  else { long v = 20; return (int)v; }\n}\nint sum(int n) {\n  int total = 0;\n  {\n    int i;\n    for (i = 0; i < n; i++) { int t = i * i; total += t; }\n  }\n  {\n    int i = 100, t = 1;\n    total += i + t;\n    {\n      int t = 2;\n      total += t;\n    }\n    total += t;\n  }\n  return total;\n}\nint counted(void) {\n  int r = 0;\n  { static int c = 0; c++; r += c; }\n  { static int c = 10; c++; r += c; }\n  return r;\n}\nint calls(void) {\n  int (*f)(int) = twice;\n  { int (*f)(int) = 0; if (f) return -1; }\n  return f(21);\n}\nint main(void) {\n  int grid[N][N + 1];\n  char name[sizeof(int) * 2];\n  long table[K * 3 - 1];\n  size_t len = strlen(\"hello\");\n  int i, j, s = 0;\n  for (i = 0; i < N; i++) for (j = 0; j < N + 1; j++) grid[i][j] = i * 10 + j;\n  for (i = 0; i < N; i++) s += grid[i][N];\n  strcpy(name, \"seven\");\n  printf(\"%d %d %d %d\\n\", pick(5, 1), pick(5, 0), sum(4), s);\n  printf(\"%d %d %d\\n\", counted(), counted(), calls());\n  printf(\"%d %d %d %s %lu\\n\", (int)sizeof grid, (int)sizeof name, (int)(sizeof table / sizeof table[0]), name, (unsigned long)len);\n  return (int)len;\n}\n")
(display (cc-run src))
```
---
```output
11 20 118 39
12 14 42
48 8 5 seven 5
5
```

## compiled

### sibling and nested blocks, a shadowed parameter and pointer, two statics, sizes from expressions, size_t

```cc
(def src "#include <stdio.h>\n#include <string.h>\n#define N 3\nenum { K = 2 };\nstatic int twice(int x) { return 2 * x; }\nint pick(int v, int which) {\n  if (which) { int v = 10; v += which; return v; }\n  else { long v = 20; return (int)v; }\n}\nint sum(int n) {\n  int total = 0;\n  {\n    int i;\n    for (i = 0; i < n; i++) { int t = i * i; total += t; }\n  }\n  {\n    int i = 100, t = 1;\n    total += i + t;\n    {\n      int t = 2;\n      total += t;\n    }\n    total += t;\n  }\n  return total;\n}\nint counted(void) {\n  int r = 0;\n  { static int c = 0; c++; r += c; }\n  { static int c = 10; c++; r += c; }\n  return r;\n}\nint calls(void) {\n  int (*f)(int) = twice;\n  { int (*f)(int) = 0; if (f) return -1; }\n  return f(21);\n}\nint main(void) {\n  int grid[N][N + 1];\n  char name[sizeof(int) * 2];\n  long table[K * 3 - 1];\n  size_t len = strlen(\"hello\");\n  int i, j, s = 0;\n  for (i = 0; i < N; i++) for (j = 0; j < N + 1; j++) grid[i][j] = i * 10 + j;\n  for (i = 0; i < N; i++) s += grid[i][N];\n  strcpy(name, \"seven\");\n  printf(\"%d %d %d %d\\n\", pick(5, 1), pick(5, 0), sum(4), s);\n  printf(\"%d %d %d\\n\", counted(), counted(), calls());\n  printf(\"%d %d %d %s %lu\\n\", (int)sizeof grid, (int)sizeof name, (int)(sizeof table / sizeof table[0]), name, (unsigned long)len);\n  return (int)len;\n}\n")
(display (cc-exe-run src))
```
---
```output
11 20 118 39
12 14 42
48 8 5 seven 5
5
```
