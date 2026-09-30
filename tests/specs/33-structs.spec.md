# @weight 2
# @timeout-scale 3

Compiled structs.  A struct is its fields at the offsets the parser lays
out -- each at its C type's alignment, the whole padded to the widest -- and
a union is one whose fields all sit at 0.  Like an array it is never
loaded whole: `s.f` and `p->f` are its address, or the one a pointer
holds, plus the field's offset, loaded or stored at the field's C type.
Assigning a struct copies its bytes; a braced initializer fills its
fields in order and zeroes the rest.  Each case below prints what the same
source prints through /usr/bin/cc, and exits as it does.

## fields

### stored and loaded through a local

```cc
(display (cc-exe-run "struct P { int x; int y; };\nint main(void) { struct P p; p.x = 3; p.y = 4; return p.x * p.x + p.y * p.y; }"))
```
---
    25

### through a pointer, from another function

```cc
(display (cc-exe-run "struct P { int x; int y; };\nvoid move(struct P *p, int dx) { p->x = p->x + dx; p->y++; }\nint main(void) { struct P p = {1, 2}; move(&p, 10); return p.x * 10 + p.y; }"))
```
---
    113

### each field at its own width, and the padding between

```cc
(display (cc-exe-run "struct R { char tag; int n; short s; };\nint main(void) { struct R r = {'a', 1000, -2}; return sizeof(r) + r.tag - 'a' + (r.n == 1000) + (r.s == -2); }"))
```
---
    14

### a struct inside a struct, reached through a pointer

```cc
(display (cc-exe-run "struct In { short a; char b; };\nstruct Out { char c; struct In in; int d; };\nint main(void) { struct Out o = {1, {2, 3}, 4}; struct Out *p = &o; return p->c + p->in.a * 10 + p->in.b * 100 + o.d * 1000 - 4321 + sizeof(o); }"))
```
---
    12

### a union's fields share their bytes

```cc
(display (cc-exe-run "union U { int i; char c; };\nint main(void) { union U u; u.i = 0x41424344; return u.c + sizeof(u); }"))
```
---
    72

## whole structs

### assignment copies, and the copy stands apart

```cc
(display (cc-exe-run "struct P { int x; int y; };\nint main(void) { struct P a = {5, 6}; struct P b; b = a; a.x = 0; return b.x * 10 + b.y + a.x; }"))
```
---
    56

### a short initializer leaves the rest of the struct zero

```cc
(display (cc-exe-run "struct P { int x; int y; };\nint clean(void) { struct P q = {9}; return q.x + q.y; }\nint dirty(void) { struct P z; z.x = 5; z.y = 6; return z.x; }\nint main(void) { dirty(); return clean(); }"))
```
---
    9

### an array of structs

```cc
(display (cc-exe-run "struct P { int x; int y; };\nint main(void) { struct P ps[3]; int i; int s = 0; for (i = 0; i < 3; i++) { ps[i].x = i; ps[i].y = i * i; } for (i = 0; i < 3; i++) s += ps[i].x + ps[i].y; return s; }"))
```
---
    8

### globals, initialized and copied

```cc
(display (cc-exe-run "struct P { int x; int y; };\nstruct P g = {7, 8};\nstruct P h;\nint main(void) { h = g; g.y = 0; return h.x * 10 + h.y + g.y; }"))
```
---
    78

### a linked list walked by its next pointers

```cc
(display (cc-exe-run "#include <stdio.h>\nstruct Node { int v; struct Node *next; };\nint main(void) { struct Node c = {3, 0}; struct Node b = {2, &c}; struct Node a = {1, &b}; struct Node *p; int s = 0; for (p = &a; p; p = p->next) { printf(\"%d \", p->v); s = s * 10 + p->v; } printf(\"\\n\"); return s % 256; }"))
```
---
```output
1 2 3 
123
```

## the refusals

### an operator on a struct

```cc
(display (guard (e (do (display "refused: ") (write e) ""))
  (cc-exe-run "struct P { int x; };\nint main(void) { struct P a = {1}; struct P b = {1}; return a == b; }")))
```
---
    refused: #<err:cc cc: compile: not built yet: the operator == on a struct>
