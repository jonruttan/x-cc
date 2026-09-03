# @weight 2

Struct fields, lowered.  The lane has no notion of a field, but the
cell model already says where one lives: a struct value IS its
address, and a field is a fixed offset from it.  So before lowering,
every `.` and `->` becomes explicit arithmetic over the shared memory
-- `p->x` is `*(p + off)`, `a[i].y` is `*(a + i*size + off)` -- and
the existing load and store machinery takes it from there.  A struct
passed BY VALUE is the one trap: the argument is the caller's address
and C says the callee mutates a copy, so reading through it is right
and writing through it is not.  Every expectation is an oracle row
from /usr/bin/cc.

## fields as arithmetic

### by-value reads, a pointer read and write, a linked-list walk, an array of structs

`mutate` assigns a field of a by-value parameter and refuses; `main`
declares structs, which have no native storage.  Both still run, and
the printed values are the real binary's.

```cc
(display (cc-build-run "#include <stdio.h>\nstruct P { int x; int y; };\nstruct N { int v; struct N *next; };\nint dotp(struct P a, struct P b) { return a.x * b.x + a.y * b.y; }\nint norm(struct P *p) { return p->x * p->x + p->y * p->y; }\nint scale(struct P *p, int k) { p->x = p->x * k; p->y = p->y * k; return p->x + p->y; }\nint suml(struct N *head) { int s; struct N *p; s = 0; p = head; while (p) { s = s + p->v; p = p->next; } return s; }\nint sumarr(struct P *a, int n) { int i; int s; s = 0; for (i = 0; i < n; i++) s = s + a[i].x + a[i].y; return s; }\nint mutate(struct P a) { a.x = 99; return a.x; }\nint main() {\n  struct P u; struct P v; struct P arr[3]; struct N n1; struct N n2; struct N n3; int i;\n  u.x = 3; u.y = 4; v.x = 5; v.y = 6;\n  for (i = 0; i < 3; i++) { arr[i].x = i + 1; arr[i].y = i * 10; }\n  n1.v = 7; n1.next = &n2; n2.v = 8; n2.next = &n3; n3.v = 9; n3.next = 0;\n  printf(\"%d %d %d %d %d %d\\n\", dotp(u, v), norm(&u), scale(&v, 2), suml(&n1), sumarr(arr, 3), mutate(u));\n  printf(\"%d %d %d %d\\n\", v.x, v.y, u.x, u.y);\n  return 0;\n}"))
```
---
```output
native dotp
native norm
native scale
native suml
native sumarr
interp mutate
interp main
39 25 22 24 36 99
10 12 3 4
0
```
