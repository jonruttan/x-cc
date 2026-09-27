# @weight 2
# @timeout-scale 3

Globals that start at an address.  The executable is loaded where the
kernel chooses and nothing relocates it, so such a pointer starts as
zeros in the data, and main writes the address -- the data's, in x22,
plus the place of what it names -- before its body runs.  A pointer can
start at a string literal, an array, or what & takes of a global, of an
element at a constant index, or of a field, and at any of these moved by
a constant or cast to another pointer; a static local's can too.  Each
case runs the program under `run`, then compiled, and shows
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

## moved by a constant

A constant added to such an address, or taken from it, moves it by that
many of what it points at; a cast to another pointer changes what that
is.

### an array and an element's address, moved

```cc
(def src "int a[5] = {10, 20, 30, 40, 50};\nint *p = a + 2;\nint *q = &a[1] + 3;\nint *r = a + 4 - 1;\nint main(void) { return *p + *q + *r; }\n")
(display (list (cc-run src) (cc-exe-run src)))
```
---
```output
(120 120)
```

### a string literal, moved

```cc
(def src "#include <stdio.h>\nchar *s = \"hello\" + 1;\nint main(void) { puts(s); return s[0]; }\n")
(display (list (cc-run src) (cc-exe-run src)))
```
---
```output
ello
ello
(101 101)
```

### a byte of an int, through a cast

```cc
(def src "int g = 0x0102;\nchar *c = (char *)&g + 1;\nint main(void) { return *c; }\n")
(display (list (cc-run src) (cc-exe-run src)))
```
---
```output
(1 1)
```

### one before an array's first element

```cc
(def src "int a[3] = {1, 2, 3};\nint *one = a - 1;\nint main(void) { return one[1] * 10 + one[3]; }\n")
(display (list (cc-run src) (cc-exe-run src)))
```
---
```output
(13 13)
```

### a row of an array of arrays, and a field that is an array

```cc
(def src "int m[2][3] = {{1, 2, 3}, {4, 5, 6}};\nint *row = m[1];\nstruct S { char name[8]; int n; };\nstruct S s = {\"abc\", 5};\nchar *nm = s.name + 1;\nint main(void) { return row[2] * 10 + nm[0]; }\n")
(display (list (cc-run src) (cc-exe-run src)))
```
---
```output
(158 158)
```

### a struct pointer moved by a struct, and string literals moved in a list

```cc
(def src "#include <stdio.h>\nstruct P { int x; int y; };\nstruct P pts[3] = {{1, 2}, {3, 4}, {5, 6}};\nstruct P *second = pts + 1;\nint *last = &pts[2].x + 1;\nchar *parts[] = {\"abc\" + 1, \"xyz\" + 2};\nint main(void) { puts(parts[0]); puts(parts[1]); return second->y * 10 + *last; }\n")
(display (list (cc-run src) (cc-exe-run src)))
```
---
```output
bc
z
bc
z
(46 46)
```

### a static local's pointer, moved

```cc
(def src "#include <stdio.h>\nint arr[4] = {7, 8, 9, 10};\nint *from(void) { static int *p = arr + 3; return p--; }\nint main(void) { int a = *from(); int b = *from(); printf(\"%d %d\\n\", a, b); return a + b; }\n")
(display (list (cc-run src) (cc-exe-run src)))
```
---
```output
10 9
10 9
(19 19)
```
