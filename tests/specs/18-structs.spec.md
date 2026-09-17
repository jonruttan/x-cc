# @weight 2

Struct fields as arithmetic over memory.  A struct value is its
address and a field is a fixed offset from it, so `p->x` is
`*(p + off)` and `a[i].y` is `*(a + i*size + off)`.  A struct passed
by value is a copy the callee may write without the caller seeing it.
Every expectation is an oracle row from /usr/bin/cc.

## fields as arithmetic

### by-value reads, a pointer read and write, a linked-list walk, an array of structs

`mutate` assigns a field of its by-value parameter, and the caller's
struct keeps its own values.

```cc
(display (cc-run "#include <stdio.h>\nstruct P { int x; int y; };\nstruct N { int v; struct N *next; };\nint dotp(struct P a, struct P b) { return a.x * b.x + a.y * b.y; }\nint norm(struct P *p) { return p->x * p->x + p->y * p->y; }\nint scale(struct P *p, int k) { p->x = p->x * k; p->y = p->y * k; return p->x + p->y; }\nint suml(struct N *head) { int s; struct N *p; s = 0; p = head; while (p) { s = s + p->v; p = p->next; } return s; }\nint sumarr(struct P *a, int n) { int i; int s; s = 0; for (i = 0; i < n; i++) s = s + a[i].x + a[i].y; return s; }\nint mutate(struct P a) { a.x = 99; return a.x; }\nint main() {\n  struct P u; struct P v; struct P arr[3]; struct N n1; struct N n2; struct N n3; int i;\n  u.x = 3; u.y = 4; v.x = 5; v.y = 6;\n  for (i = 0; i < 3; i++) { arr[i].x = i + 1; arr[i].y = i * 10; }\n  n1.v = 7; n1.next = &n2; n2.v = 8; n2.next = &n3; n3.v = 9; n3.next = 0;\n  printf(\"%d %d %d %d %d %d\\n\", dotp(u, v), norm(&u), scale(&v, 2), suml(&n1), sumarr(arr, 3), mutate(u));\n  printf(\"%d %d %d %d\\n\", v.x, v.y, u.x, u.y);\n  return 0;\n}"))
```
---
```output
39 25 22 24 36 99
10 12 3 4
0
```
