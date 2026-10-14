# @weight 1
# @timeout-scale 2

C99's designated initializers -- `.field =` and `[index] =`, nested and
chained, mixed with plain items, each place no designator names a zero --
and compound literals, `(TYPE){ ... }`: an object made where its
statement starts, passed and returned by value, decayed to a pointer, and
taken the address of.  Each case runs under `run`, then compiled, and
shows both outputs and both statuses; the expectation is what the same
source prints through /usr/bin/cc.

## designated initializers

### fields by name, elements by index, nested, chained, and mixed with plain ones

```cc
(def src "#include <stdio.h>\n#include <string.h>\n\n/* designated initializers: struct fields by name, array elements by index,\n   nested, mixed with positional ones, and the rest zero */\nstruct point { int x, y, z; };\nstruct line { struct point a, b; const char *tag; };\nenum colour { RED, GREEN, BLUE, NCOLOURS };\nstatic const char *names[NCOLOURS] = { [BLUE] = \"blue\", [RED] = \"red\", [GREEN] = \"green\" };\nstatic int squares[10] = { [2] = 4, [3] = 9, [9] = 81 };\nstatic struct line diag = { .b = { .x = 5, .y = 5 }, .tag = \"diag\", .a.z = 1 };\n\nint main(void) {\n  struct point p = { .y = 2, .x = 1 };\n  struct point q = { 7, .z = 9 };\n  int a[6] = { 1, [4] = 5, 6 };\n  int sum = 0;\n  for (int i = 0; i < 10; i++) sum += squares[i];\n  printf(\"%d %d %d | %d %d %d\\n\", p.x, p.y, p.z, q.x, q.y, q.z);\n  printf(\"%d %d %d %d %d %d\\n\", a[0], a[1], a[2], a[3], a[4], a[5]);\n  printf(\"%s %s %s %d\\n\", names[0], names[1], names[2], sum);\n  printf(\"%s %d %d %d %d\\n\", diag.tag, diag.a.z, diag.b.x, diag.b.y, diag.a.x);\n  return sum % 50;\n}\n")
(display (list (cc-run src) (cc-exe-run src)))
```
---
```output
1 2 0 | 7 0 9
1 0 0 0 5 6
red green blue 94
diag 1 5 5 0
1 2 0 | 7 0 9
1 0 0 0 5 6
red green blue 94
diag 1 5 5 0
(44 44)
```

## compound literals

### by value, returned, decayed to a pointer, assigned, and taken the address of

```cc
(def src "#include <stdio.h>\n\n/* compound literals: a struct passed and returned by value, an array\n   decayed to a pointer, one assigned to a struct, one taken the address of */\nstruct vec { double x, y; };\nstatic double dot(struct vec a, struct vec b) { return a.x * b.x + a.y * b.y; }\nstatic struct vec scale(struct vec v, double k) { return (struct vec){ v.x * k, v.y * k }; }\nstatic int total(const int *p, int n) { int s = 0; while (n--) s += *p++; return s; }\n\nint main(void) {\n  struct vec v = scale((struct vec){ 1.5, -2 }, 2);\n  struct vec *pv = &(struct vec){ .y = 4 };\n  int t = total((int[]){ 3, 1, 4, 1, 5 }, 5);\n  v = (struct vec){ v.y, v.x };\n  printf(\"%.1f %.1f %.2f %.1f %d\\n\", v.x, v.y, dot(v, (struct vec){ 1, 1 }), pv->y, t);\n  return t;\n}\n")
(display (list (cc-run src) (cc-exe-run src)))
```
---
```output
-4.0 3.0 -1.00 4.0 14
-4.0 3.0 -1.00 4.0 14
(14 14)
```

### refused where it would be made only once: a loop's condition

```cc
(def src "struct p { int x; };\nint f(struct p v) { return v.x; }\nint main(void) { int i = 0; while (f((struct p){ i }) < 3) i++; return i; }\n")
(display (guard (e (e msg)) (cc-run src)))
```
---
```output
cc: parse: line 3: not built yet: a compound literal in a while loop's condition
```
