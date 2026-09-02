# @weight 2

Structs by value, and # / ## in macros.  A struct parameter takes its
size in the callee's frame and copies from the argument's address; a
struct returned by value moves out of the popped frame into a fresh
slot in the caller's frame (alive until the caller returns), so
`make(1, 2).x` and `add(make(1, 2), make(3, 4))` are safe.  In a
macro body `#PARAM` is the argument's text as a string literal and
`A ## B` pastes, the rescan lexing the joined token.  Every
expectation is an oracle row from /usr/bin/cc.

## structs by value

### passed, returned, chained, from a pointer's pointee

```cc
(display (cc-run "#include <stdio.h>\nstruct P { int x; int y; };\nstruct P make(int x, int y) { struct P p; p.x = x; p.y = y; return p; }\nstruct P add(struct P a, struct P b) { a.x = a.x + b.x; a.y = a.y + b.y; return a; }\nint dot(struct P a, struct P b) { return a.x * b.x + a.y * b.y; }\nstruct P scale(struct P *p, int k) { struct P r = *p; r.x = r.x * k; r.y = r.y * k; return r; }\nint main() {\n  struct P a = make(1, 2); struct P b; struct P c;\n  b = make(3, 4);\n  c = add(a, b);\n  printf(\"%d %d %d %d\\n\", c.x, c.y, a.x, dot(a, b));\n  printf(\"%d %d\\n\", add(make(1, 2), make(3, 4)).x, make(5, 6).y);\n  c = scale(&b, 10);\n  printf(\"%d %d %d\\n\", c.x, c.y, b.x);\n  return c.x + dot(make(1, 1), make(2, 3));\n}"))
```
---
```output
4 6 1 11
4 6
30 40 3
35
```

### by-value functions stay interpreted; the rest still lower

```cc
(display (cc-build-run "#include <stdio.h>\nstruct P { int x; int y; };\nstruct P make(int x, int y) { struct P p; p.x = x; p.y = y; return p; }\nint dot(struct P a, struct P b) { return a.x * b.x + a.y * b.y; }\nint sq(int n) { return n * n; }\nint main() { printf(\"%d\\n\", sq(dot(make(1, 2), make(3, 4)))); return 0; }"))
```
---
```output
interp make
interp dot
native sq
interp main
121
0
```

## # and ## in macros

### stringize, paste, and a pasted name declared and used

```cc
(display (cc-run "#include <stdio.h>\n#define STR(x) #x\n#define SHOW(e) printf(\"%s = %d\\n\", #e, e)\n#define GLUE(a, b) a ## b\n#define VAR(n) v ## n\n#define DECL(t, n) t GLUE(var_, n)\nint main() {\n  int v1 = 10; int v2 = 20; int x = 3;\n  DECL(int, z) = 7;\n  SHOW(x * 2 + 1);\n  SHOW(VAR(1) + VAR(2));\n  printf(\"%s|%s|%d\\n\", STR(hello world), STR(\"q\\\"uote\"), GLUE(1, 5) + var_z);\n  return 0;\n}"))
```
---
```output
x * 2 + 1 = 7
VAR(1) + VAR(2) = 30
hello world|"q\"uote"|22
0
```
