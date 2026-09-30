# @weight 2
# @timeout-scale 3

run calls the C library: a function the program does not define is the
library's, found by name, and handed real addresses.  printf, fprintf,
sprintf, snprintf, dprintf, scanf, fscanf and sscanf go through their v-
forms with the arguments laid out as a va_list, and the answer is converted
to the C type the function's header
declares.  Each case runs the program under `run`; every expectation is
what the same source prints through /usr/bin/cc.

## the library under run

### strtol with its end pointer, strdup, realloc, strcat and strtok

```cc
(def src "#include <stdio.h>\n#include <stdlib.h>\n#include <string.h>\nint main(void) {\n  char *end;\n  long v = strtol(\"  -0x1fz\", &end, 16);\n  char *d = strdup(\"hello\");\n  char *p = malloc(4);\n  int i;\n  char line[] = \"a,bb,,ccc\";\n  char *tok;\n  printf(\"%ld [%s]\\n\", v, end);\n  d[0] = 'J';\n  printf(\"%s %d\\n\", d, (int)strlen(d));\n  for (i = 0; i < 4; i++) p[i] = 'a' + i;\n  p = realloc(p, 64);\n  p[4] = 0;\n  strcat(p, \"-more\");\n  printf(\"%s\\n\", p);\n  for (tok = strtok(line, \",\"); tok; tok = strtok(0, \",\")) printf(\"<%s>\", tok);\n  printf(\"\\n\");\n  free(d);\n  free(p);\n  return 0;\n}\n")
(display (cc-run src))
```
---
```output
-31 [z]
Jello 5
abcd-more
<a><bb><ccc>
0
```

### snprintf's other conversions, the stdout stream, and printf with seven arguments

```cc
(def src "#include <stdio.h>\nint main(void) {\n  char buf[32];\n  int n = snprintf(buf, sizeof buf, \"%o|%5.2s|%-4c|%+d|%#x\", 64, \"abcdef\", 'z', 7, 255);\n  fprintf(stdout, \"%s %d\\n\", buf, n);\n  fputs(\"fputs line\\n\", stdout);\n  putc('!', stdout);\n  fputc('\\n', stdout);\n  printf(\"%s %s %d\\n\", \"many\", \"args\", printf(\"%d %d %d %d %d %d %d\\n\", 1, 2, 3, 4, 5, 6, 7));\n  return n;\n}\n")
(display (cc-run src))
```
---
```output
100|   ab|z   |+7|0xff 22
fputs line
!
1 2 3 4 5 6 7
many args 14
22
```

### the classifications, toupper, strchr, strcmp, memcmp and strspn

```cc
(def src "#include <stdio.h>\n#include <ctype.h>\n#include <string.h>\nint main(void) {\n  const char *s = \"Hello, World 42!\";\n  int up = 0, dig = 0, i;\n  char r[32];\n  for (i = 0; s[i]; i++) {\n    if (isupper(s[i])) up++;\n    if (isdigit(s[i])) dig++;\n    r[i] = toupper(s[i]);\n  }\n  r[i] = 0;\n  printf(\"%d %d %s %s\\n\", up, dig, r, strchr(s, 'W'));\n  printf(\"%d %d %d\\n\", strcmp(\"abc\", \"abd\") < 0, memcmp(\"ab\", \"ab\", 2), (int)strspn(\"aaab\", \"a\"));\n  return up;\n}\n")
(display (cc-run src))
```
---
```output
2 2 HELLO, WORLD 42! World 42!
1 0 3
2
```

## refused

### a pointer to the program's function, handed to the library

```cc
(display (cc-run "int cmp(const void *a, const void *b) { return 0; }\nint main(void) { int a[2] = {2, 1}; qsort(a, 2, sizeof a[0], cmp); return a[0]; }"))
```
---
```output
cc: run failed: #<err:cc cc: run: a pointer to a function, handed to qsort>
1
```
