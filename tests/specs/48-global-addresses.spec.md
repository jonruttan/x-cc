# @weight 2
# @timeout-scale 3

Globals that start at an address.  The executable is loaded where the
kernel chooses and nothing relocates it, so such a pointer starts as
zeros in the data, and main writes the address -- the data's, in x22,
plus the place of what it names -- before its body runs.  A pointer can
start at a string literal, an array's name, or what & takes of a global,
of an element at a constant index, or of a field; a static local's can
too.  Each case runs the program under `run`, then compiled, and shows
both outputs and both statuses; every expectation is what the same
source prints through /usr/bin/cc.

## pointers that start at an address

### a string literal

```cc
(def src "#include <stdio.h>\nchar *msg = \"hello\";\nint main(void) { puts(msg); return msg[1]; }\n")
(display (list (cc-run src) (cc-exe-run src)))
```
---
```output
hello
hello
(101 101)
```

### a global's address

```cc
(def src "int g = 42;\nint *p = &g;\nint main(void) { *p += 1; return g; }\n")
(display (list (cc-run src) (cc-exe-run src)))
```
---
```output
(43 43)
```

### an array of string literals

```cc
(def src "#include <stdio.h>\nchar *names[] = {\"zero\", \"one\", \"two\"};\nint main(void) { int i; for (i = 0; i < 3; i++) puts(names[i]); return names[2][1]; }\n")
(display (list (cc-run src) (cc-exe-run src)))
```
---
```output
zero
one
two
zero
one
two
(119 119)
```

### an array's name, and an element's address

```cc
(def src "int arr[4] = {1, 2, 3, 4};\nint *q = arr;\nint *r = &arr[2];\nint main(void) { return *q * 10 + *r; }\n")
(display (list (cc-run src) (cc-exe-run src)))
```
---
```output
(13 13)
```

### string literals in an array of structs

```cc
(def src "#include <string.h>\nstruct E { char *name; int v; };\nstruct E table[] = {{\"a\", 1}, {\"bb\", 2}};\nint main(void) { return strlen(table[1].name) * 10 + table[1].v; }\n")
(display (list (cc-run src) (cc-exe-run src)))
```
---
```output
(22 22)
```

### a static local's pointer

```cc
(def src "#include <stdio.h>\nconst char *greet(void) { static const char *s = \"hey\"; return s; }\nint main(void) { puts(greet()); return 0; }\n")
(display (list (cc-run src) (cc-exe-run src)))
```
---
```output
hey
hey
(0 0)
```
