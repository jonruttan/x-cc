# @weight 2
# @timeout-scale 3

Compiled structs passed and returned by value.  A struct argument is
copied whole to where the callee's frame will have its top, as the
arguments past the fourth are, so the callee works on a copy of its own.
A call that answers a struct has a slot of its own in the caller's frame
for it, alive until the caller returns; the caller says where that slot
is in a word at the top of the callee's frame, and the callee's return
copies the struct there and answers its address.  Each case below prints
what the same source prints through /usr/bin/cc, and exits as it does;
where both columns show, `run` and the compiled executable agree.

## passed

### a struct argument

```cc
(def src "struct P { int x; int y; };\nint sum(struct P p) { return p.x + p.y; }\nint main(void) { struct P a = {3, 4}; return sum(a); }")
(display (list (cc-run src) (cc-exe-run src)))
```
---
    (7 7)

### the callee's copy is its own

```cc
(def src "struct P { int x; int y; };\nint bump(struct P p) { p.x = 100; return p.x; }\nint main(void) { struct P a = {3, 4}; int r = bump(a); return r + a.x; }")
(display (list (cc-run src) (cc-exe-run src)))
```
---
    (103 103)

### a struct among ints, past the fourth argument

```cc
(def src "struct P { int x; int y; };\nint f(int a, struct P p, int b, int c, int d, int e) { return a + p.x * 10 + p.y * 100 + b + c + d + e; }\nint main(void) { struct P p = {2, 3}; return f(1, p, 4, 5, 6, 7) % 256; }")
(display (list (cc-run src) (cc-exe-run src)))
```
---
    (87 87)

## returned

### a struct answered, and kept

```cc
(def src "struct P { int x; int y; };\nstruct P make(int x, int y) { struct P p; p.x = x; p.y = y; return p; }\nint main(void) { struct P q = make(5, 6); return q.x * 10 + q.y; }")
(display (list (cc-run src) (cc-exe-run src)))
```
---
    (56 56)

### a struct of three chars, through a call and back

```cc
(def src "struct C { char a; char b; char c; };\nstruct C mk(int v) { struct C c; c.a = v; c.b = v + 1; c.c = v + 2; return c; }\nint sum3(struct C c) { return c.a + c.b + c.c; }\nint main(void) { return sum3(mk(10)); }")
(display (list (cc-run src) (cc-exe-run src)))
```
---
    (33 33)

### eighty bytes, out and in

```cc
(def src "struct B { int v[20]; };\nstruct B fill(int k) { struct B b; int i; for (i = 0; i < 20; i++) b.v[i] = i * k; return b; }\nint total(struct B b) { int s = 0; int i; for (i = 0; i < 20; i++) s += b.v[i]; return s; }\nint main(void) { return total(fill(2)) % 256; }")
(display (list (cc-run src) (cc-exe-run src)))
```
---
    (124 124)

### twenty calls deep, and a field of what the outermost answers

```cc
(def src "struct F { long a; long b; };\nstruct F step(struct F f, int n) { if (n == 0) return f; struct F g; g.a = f.b; g.b = f.a + f.b; return step(g, n - 1); }\nint main(void) { struct F s = {0, 1}; return step(s, 20).a % 256; }")
(display (list (cc-run src) (cc-exe-run src)))
```
---
    (109 109)

### two calls' structs in one expression do not share a slot

```cc
(display (cc-exe-run "#include <stdio.h>\nstruct P { int x; int y; };\nstruct P make(int x, int y) { struct P p; p.x = x; p.y = y; return p; }\nstruct P add(struct P a, struct P b) { struct P r; r.x = a.x + b.x; r.y = a.y + b.y; return r; }\nint dot(struct P a, struct P b) { return a.x * b.x + a.y * b.y; }\nint main(void) {\n  struct P u = make(1, 2); struct P v = make(3, 4); struct P w;\n  w = add(u, v);\n  printf(\"%d %d %d %d\\n\", w.x, w.y, add(make(1, 2), make(3, 4)).x, dot(make(5, 6), make(7, 8)));\n  printf(\"%d %d %d %d\\n\", u.x, u.y, v.x, v.y);\n  return 0;\n}"))
```
---
```output
4 6 4 83
1 2 3 4
0
```

## the refusals

### a struct for a parameter that is not one

```cc
(write (guard (e (e msg)) (cc-exe-run "struct P { int x; };\nint f(int n) { return n; }\nint main(void) { struct P p = {1}; return f(p); }")))
```
---
    "cc: compile: not built yet: a struct passed for a parameter that is not one"
