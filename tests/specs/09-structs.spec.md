# @weight 3

Structs in the cell model.  A struct is its fields laid end to end,
a field is an offset in cells, `p->f` is a load at `p + offset`, and a
pointer to a struct steps by the struct's size.  Every expectation
here is an oracle row from /usr/bin/cc, except the sizeof case, which
is the cell model on the record.

## fields

### dot on a local, arrow through a pointer parameter

```cc
(display (cc-run "#include <stdio.h>\nstruct P { int x; int y; };\nint len2(struct P *p) { return p->x * p->x + p->y * p->y; }\nint main() { struct P p; p.x = 3; p.y = 4; printf(\"%d %d\\n\", p.x * p.x + p.y * p.y, len2(&p)); return 0; }"))
```
---
```output
25 25
0
```

## arrays of structs and pointer arithmetic

### an element's field, ++ and + stepping by the struct's size

```cc
(display (cc-run "#include <stdio.h>\nstruct P { int x; int y; };\nint main() { struct P a[3]; struct P *q; int i; for (i = 0; i < 3; i++) { a[i].x = i; a[i].y = 10 * i; } q = a; q++; q = q + 1; printf(\"%d %d %d\\n\", a[2].y, q->x, (q - 1)->y); return 0; }"))
```
---
```output
20 2 10
0
```

## the linked list

### malloc'd nodes, next pointers, a walk

```cc
(display (cc-run "#include <stdio.h>\n#include <stdlib.h>\nstruct N { int val; struct N *next; };\nint main() { struct N *head; struct N *n; int i; int s; head = 0; for (i = 1; i <= 4; i++) { n = malloc(sizeof(struct N)); n->val = i * i; n->next = head; head = n; } s = 0; for (n = head; n != 0; n = n->next) s = s + n->val; printf(\"%d %d\\n\", s, head->next->val); return 0; }"))
```
---
```output
30 9
0
```

## typedef, nesting, copy

### a typedef'd anonymous struct with a nested struct, copied whole

```cc
(display (cc-run "#include <stdio.h>\nstruct P { int x; int y; };\ntypedef struct { int a; struct P pt; } Q;\nint main() { Q q1; Q q2; q1.a = 7; q1.pt.x = 5; q1.pt.y = 6; q2 = q1; q2.pt.x = 9; printf(\"%d %d %d\\n\", q2.a, q2.pt.y, q1.pt.x); return 0; }"))
```
---
```output
7 6 5
0
```

## by value

### a struct passed by value is a copy in the callee's frame

```cc
(display (cc-run "#include <stdio.h>\nstruct P { int x; int y; };\nint sum(struct P p) { p.x = p.x + p.y; return p.x; }\nint main() { struct P q; q.x = 1; q.y = 2; printf(\"%d %d\\n\", sum(q), q.x); return 0; }"))
```
---
```output
3 1
0
```

## the cell model, on the record

### sizeof a struct counts its cells

Two int fields are two cells; the real machine says 8.  Programs that
scale by sizeof (the malloc idiom above) run unchanged.

```cc
(display (cc-run "#include <stdio.h>\nstruct P { int x; int y; };\nstruct Q { struct P a[3]; int n; };\nint main() { printf(\"%d %d\\n\", sizeof(struct P), sizeof(struct Q)); return 0; }"))
```
---
```output
2 7
0
```
