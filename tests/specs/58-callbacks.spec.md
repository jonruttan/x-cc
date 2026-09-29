# @weight 2
# @timeout-scale 3

The C library calling the program back: a pointer to one of the
program's functions handed to qsort or bsearch.  Compiled, the pointer
leads to a gate after the code, which keeps the library's registers,
takes up the program's own and calls the function; the program's own
calls through a pointer take the same way.  run cannot hand the library
a pointer into the interpreter and refuses by name.  Every expectation
is what the same source prints through /usr/bin/cc.

## compiled

### qsort both ways and bsearch, a hit and a miss

```cc
(def src "#include <stdio.h>\n#include <stdlib.h>\nint up(const void *a, const void *b) { return *(const int *)a - *(const int *)b; }\nint down(const void *a, const void *b) { return *(const int *)b - *(const int *)a; }\nint main(void) {\n  int a[8] = {42, 7, 19, 3, 88, 7, 51, 0};\n  int key = 51;\n  int i;\n  int *hit;\n  qsort(a, 8, sizeof a[0], down);\n  for (i = 0; i < 8; i++) printf(\"%d \", a[i]);\n  printf(\"\\n\");\n  qsort(a, 8, sizeof a[0], up);\n  for (i = 0; i < 8; i++) printf(\"%d \", a[i]);\n  printf(\"\\n\");\n  hit = bsearch(&key, a, 8, sizeof a[0], up);\n  printf(\"%d\\n\", hit ? (int)(hit - a) : -1);\n  key = 50;\n  hit = bsearch(&key, a, 8, sizeof a[0], up);\n  printf(\"%d\\n\", hit ? (int)(hit - a) : -1);\n  return a[7];\n}\n")
(display (cc-exe-run src))
```
---
```output
88 51 42 19 7 7 3 0 
0 3 7 7 19 42 51 88 
6
-1
88
```

### two hundred strings sorted by a comparator that calls strcmp

```cc
(def src "#include <stdio.h>\n#include <stdlib.h>\n#include <string.h>\nint calls = 0;\nint bystr(const void *a, const void *b) {\n  calls++;\n  return strcmp(*(char *const *)a, *(char *const *)b);\n}\nint main(void) {\n  char buf[200][8];\n  char *p[200];\n  int i;\n  unsigned seed = 12345;\n  for (i = 0; i < 200; i++) {\n    seed = seed * 1103515245 + 12345;\n    sprintf(buf[i], \"w%05u\", (seed >> 8) % 100000);\n    p[i] = buf[i];\n  }\n  qsort(p, 200, sizeof p[0], bystr);\n  for (i = 0; i < 200; i += 40) printf(\"%s \", p[i]);\n  printf(\"%s\\n\", p[199]);\n  for (i = 1; i < 200; i++) if (strcmp(p[i - 1], p[i]) > 0) return 1;\n  return calls > 0 ? 0 : 2;\n}\n")
(display (cc-exe-run src))
```
---
```output
w00235 w20697 w34514 w56454 w79648 w99739
0
```

### one comparator called by qsort and through the program's own pointers

```cc
(def src "#include <stdio.h>\n#include <stdlib.h>\nint cmp(const void *a, const void *b) { return *(const char *)a - *(const char *)b; }\nint order(int (*f)(const void *, const void *), char x, char y) { return f(&x, &y); }\nint main(void) {\n  char s[] = \"callback\";\n  int (*g)(const void *, const void *) = cmp;\n  qsort(s, 8, 1, g);\n  printf(\"%s %d %d\\n\", s, order(g, 'a', 'b') < 0, order(cmp, 'z', 'b') > 0);\n  return 0;\n}\n")
(display (cc-exe-run src))
```
---
```output
aabcckll 1 1
0
```

## under run

### a comparator handed to qsort refuses

```cc
(display (cc-run "#include <stdlib.h>\nint cmp(const void *a, const void *b) { return 0; }\nint main(void) { int a[2] = {2, 1}; qsort(a, 2, sizeof a[0], cmp); return a[0]; }"))
```
---
```output
cc: run failed: #<err:cc cc: run: a pointer to a function, handed to qsort>
1
```
