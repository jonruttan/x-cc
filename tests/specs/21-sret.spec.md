# @weight 2

Structs returned by value.  A struct value is an address, so a
returning function answers wherever it built its result -- and because
that place is one block per function rather than per call, the CALL
BOUNDARY copies those cells into a fresh slot in the caller's frame.
That is what the interpreter already does, and it is what keeps two
calls to the same function from sharing one result: in
`add(make(1, 2), make(3, 4))` both arguments come from `make`, and
each is copied out before the next call runs.  Every expectation is an
oracle row from /usr/bin/cc.

## returning a struct

### built from parameters, from two struct arguments, and nested in one expression

```cc
(display (cc-build-run "#include <stdio.h>\nstruct P { int x; int y; };\nstruct P make(int x, int y) { struct P p; p.x = x; p.y = y; return p; }\nstruct P add(struct P a, struct P b) { struct P r; r.x = a.x + b.x; r.y = a.y + b.y; return r; }\nint dot(struct P a, struct P b) { return a.x * b.x + a.y * b.y; }\nint main() {\n  struct P u = make(1, 2); struct P v = make(3, 4); struct P w;\n  w = add(u, v);\n  printf(\"%d %d %d %d\\n\", w.x, w.y, add(make(1, 2), make(3, 4)).x, dot(make(5, 6), make(7, 8)));\n  printf(\"%d %d %d %d\\n\", u.x, u.y, v.x, v.y);\n  return 0;\n}"))
```
---
```output
native make
native add
native dot
interp main
4 6 4 83
1 2 3 4
0
```
