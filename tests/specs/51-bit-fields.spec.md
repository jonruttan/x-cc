# @weight 2
# @timeout-scale 3

Bit-fields.  A field declared `TYPE NAME : WIDTH` takes WIDTH bits of a
unit of its C type, the unit at a multiple of that type's size: the next
WIDTH bits when they fit in the unit, else the start of the next one.
An unnamed one only pads, and width 0 starts the next unit.  A field of
another C type can sit in the unit's other bytes.  A read takes the
field's bits with the sign of its C type, and a write keeps the unit's
other bits; the field promotes to int in arithmetic.  Each case runs the
program under `run`, then compiled, and shows both outputs and both
statuses; every expectation is what the same source prints through
/usr/bin/cc.

## fields

### stores wrap to the width, and a signed field keeps its sign

```cc
(def src "#include <stdio.h>\nstruct flags { unsigned int a : 3; unsigned int b : 5; int c : 4; };\nint main(void) { struct flags f; f.a = 9; f.b = 31; f.c = -3; printf(\"%u %u %d %d\\n\", f.a, f.b, f.c, (int)sizeof f); f.a++; f.b += 3; f.c = f.c * 3; printf(\"%u %u %d\\n\", f.a, f.b, f.c); return f.a + f.b; }\n")
(display (list (cc-run src) (cc-exe-run src)))
```
---
```output
1 31 -3 4
2 2 7
1 31 -3 4
2 2 7
(4 4)
```

### what an assignment and a step answer

```cc
(def src "#include <stdio.h>\nstruct F { unsigned a : 3; int b : 3; };\nint main(void) { struct F f = {0, 0}; char c; unsigned char uc = 255; int r = (f.a = 9); int s = (f.b = 5); int t = ++f.a; int u = f.b--; int w = (c = 300); int v = ++uc; printf(\"%d %d %d %d %u %d %d %d\\n\", r, s, t, u, f.a, f.b, w, v); return r + s + t + u; }\n")
(display (list (cc-run src) (cc-exe-run src)))
```
---
```output
1 -3 2 -3 2 -4 44 0
1 -3 2 -3 2 -4 44 0
(253 253)
```

### a field in arithmetic, and a struct copied whole

```cc
(def src "#include <stdio.h>\nstruct S { int a : 7; unsigned b : 1; };\nint main(void) { struct S s = {-64, 1}; struct S t; int i, n = 0; t = s; for (i = 0; i < 5; i++) { t.a -= 30; n = n * 3 + (t.a < 0) + t.b; } printf(\"%d %d %d %u\\n\", t.a, s.a, n, (unsigned)(s.b - 2)); return n % 256; }\n")
(display (list (cc-run src) (cc-exe-run src)))
```
---
```output
42 -64 133 4294967295
42 -64 133 4294967295
(133 133)
```

## layout

### a field that would not fit starts the next unit; unnamed and width 0

```cc
(def src "#include <stdio.h>\nstruct A { unsigned a : 30; unsigned b : 4; };\nstruct B { char c; int x : 4; int y : 12; char d; };\nstruct C { int p : 3; int : 5; int q : 3; int : 0; int r : 2; };\nint main(void) { struct B b = {'z', -2, 1000, 'w'}; struct C c = {1, 2, 3}; printf(\"%d %d %d\\n\", (int)sizeof(struct A), (int)sizeof(struct B), (int)sizeof(struct C)); printf(\"%c %d %d %c %d %d %d\\n\", b.c, b.x, b.y, b.d, c.p, c.q, c.r); return b.y % 256; }\n")
(display (list (cc-run src) (cc-exe-run src)))
```
---
```output
8 4 8
z -2 1000 w 1 2 -1
8 4 8
z -2 1000 w 1 2 -1
(232 232)
```

### the bits, as a union shows them

```cc
(def src "#include <stdio.h>\nunion U { struct { unsigned lo : 4; unsigned mid : 8; unsigned hi : 20; } s; unsigned int all; };\nint main(void) { union U u; u.all = 0; u.s.lo = 0xA; u.s.mid = 0xBC; u.s.hi = 0x12345; printf(\"%x\\n\", u.all); u.all = 0xFFFFFFFF; u.s.mid = 0; printf(\"%x %u %u\\n\", u.all, u.s.lo, u.s.hi); return u.s.lo; }\n")
(display (list (cc-run src) (cc-exe-run src)))
```
---
```output
12345bca
fffff00f 15 1048575
12345bca
fffff00f 15 1048575
(15 15)
```

## initializers

### a global array of them, and fields through a pointer

```cc
(def src "#include <stdio.h>\nstruct P { unsigned r : 5, g : 6, b : 5; };\nstruct P palette[3] = { {31, 0, 0}, {0, 63, 0}, {1, 2, 3} };\nunsigned pack(const struct P *p) { return (p->r << 11) | (p->g << 5) | p->b; }\nint main(void) { struct P *q = &palette[2]; q->g = q->g + 40; printf(\"%x %x %x %d\\n\", pack(&palette[0]), pack(&palette[1]), pack(q), (int)sizeof palette); return q->g; }\n")
(display (list (cc-run src) (cc-exe-run src)))
```
---
```output
f800 7e0 d43 12
f800 7e0 d43 12
(42 42)
```

### fields of other C types in the unit, a union, and a static

```cc
(def src "#include <stdio.h>\nstruct M { char c; int x : 4; int y : 6; char d; };\nstruct N { int x : 4; char c; short s : 3; };\nstruct M gm = {'a', 5, -7, 'b'};\nstruct N gn[2] = {{-3, 'q', 2}, {7, 'r', -1}};\nunion V { unsigned f : 5; unsigned char b; };\nunion V gv = {21};\nint main(void) { static struct N sn = {1, 's', 3}; printf(\"%c %d %d %c %d %d\\n\", gm.c, gm.x, gm.y, gm.d, (int)sizeof(struct M), (int)sizeof(struct N)); printf(\"%d %c %d %d %c %d %u %u %d %c %d\\n\", gn[0].x, gn[0].c, gn[0].s, gn[1].x, gn[1].c, gn[1].s, gv.f, gv.b, sn.x, sn.c, sn.s); return gm.y + 100; }\n")
(display (list (cc-run src) (cc-exe-run src)))
```
---
```output
a 5 -7 b 4 4
-3 q 2 7 r -1 21 21 1 s 3
a 5 -7 b 4 4
-3 q 2 7 r -1 21 21 1 s 3
(93 93)
```

## the refusals

### a bit-field of a long

```cc
(display (guard (e (do (display "refused: ") (write e) ""))
  (cc-exe-run "struct D { char c; long v : 40; };\nint main(void) { struct D d; d.v = 1; return 0; }")))
```
---
    refused: #<err:cc cc: parse: line 1: not built yet: a bit-field of a long>
