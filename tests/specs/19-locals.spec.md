# @weight 2

Local aggregates.  An array or struct declared inside a function needs
storage, and the native scratch region above the program's memory is
where it goes: the name then stands for its base address, exactly as a
struct parameter does, and the declaration itself goes away.  One
block per function rather than per frame, so a genuinely recursive
function with one refuses -- its frames would share the storage --
while a loop function's self-call is the same frame and is fine.  The
allocation is one pass shared by all three body shapes, so a local
array works in a straight-line body as well as a loop.  Every
expectation is an oracle row from /usr/bin/cc.

## local aggregates

### a struct, an array, an array of structs, one in a straight-line body

```cc
(display (cc-build-run "#include <stdio.h>\nstruct P { int x; int y; };\nint localstruct(int a, int b) { struct P p; p.x = a * 2; p.y = b * 3; return p.x + p.y; }\nint localarr(int n) { int t[8]; int i; int s; s = 0; for (i = 0; i < n; i++) t[i] = i * i; for (i = 0; i < n; i++) s = s + t[i]; return s; }\nint localstructs(int n) { struct P q[4]; int i; int s; s = 0; for (i = 0; i < n; i++) { q[i].x = i; q[i].y = i * 10; } for (i = 0; i < n; i++) s = s + q[i].x + q[i].y; return s; }\nint straightarr(int a, int b) { int t[2]; t[0] = a; t[1] = b; return t[0] * 10 + t[1]; }\nint rec(int n) { int t[2]; t[0] = n; return n <= 1 ? 1 : t[0] * rec(n - 1); }\nint main() { printf(\"%d %d %d %d %d\\n\", localstruct(3, 4), localarr(5), localstructs(4), straightarr(7, 8), rec(5)); return 0; }"))
```
---
```output
native localstruct
native localarr
native localstructs
native straightarr
interp rec
interp main
18 30 66 78 120
0
```
