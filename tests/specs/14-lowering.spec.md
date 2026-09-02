# @weight 2

Three shapes the lowerer used to refuse.  STORES WITH EXITS: the fold's
effect stream carries an exit marker at each exit's program point, and
the stream lowers with every exit tested in its place among the stores
(a conditional that exits carries the continuation into both arms).
SEQUENTIAL LOOPS: two or more loops in a row run as phases of the one
self-call -- a phase counter rides as one more threaded variable, and
each loop's exit is the transition call into the next, its init folded
and the phase advanced.  CROSS-CALLS: a non-recursive callee of the
if/return shape inlines, its parameters substituting to the lowered
arguments; inside a loop body a cross-call evaluates at its program
point through a temp, so its reads order against the stores.  Every
expectation is an oracle row from /usr/bin/cc; the native twins print
what the interpreter prints.

## stores with exits

### return, continue and break among stores

```cc
(display (cc-build-run "#include <stdio.h>\nint firstneg(int *a, int n) { int i; for (i = 0; i < n; i++) { if (a[i] < 0) return i; a[i] = a[i] * 2; } return -1; }\nint skipneg(int *a, int n) { int i; int c; c = 0; for (i = 0; i < n; i++) { if (a[i] < 0) continue; a[i] = a[i] + 1; c++; } return c; }\nint stopat(int *a, int n, int x) { int i; for (i = 0; i < n; i++) { a[i] = a[i] + 100; if (a[i] == x) break; } return i; }\nint main() {\n  int a[6] = {1, 2, -3, 4, -5, 6}; int b[4] = {5, 7, 9, 11}; int i;\n  int r1 = firstneg(a, 6); int r2 = skipneg(a, 6); int r3 = stopat(b, 4, 109);\n  printf(\"%d %d %d\\n\", r1, r2, r3);\n  for (i = 0; i < 6; i++) printf(\"%d \", a[i]);\n  for (i = 0; i < 4; i++) printf(\"%d \", b[i]);\n  printf(\"\\n\"); return 0;\n}"))
```
---
```output
native firstneg
native skipneg
native stopat
interp main
2 4 2
3 5 -3 5 -5 7 105 107 109 11 
0
```

## sequential loops

### two loops, two over memory, three of mixed kinds

```cc
(display (cc-build-run "#include <stdio.h>\nint sumsq(int n) { int i; int s; s = 0; for (i = 1; i <= n; i++) s = s + i * i; for (i = 0; i < 3; i++) s = s * 2; return s; }\nint prefix(int *a, int n) { int i; for (i = 0; i < n; i++) a[i] = i * 3; for (i = 1; i < n; i++) a[i] = a[i] + a[i - 1]; return a[n - 1]; }\nint count3(int n) { int i; int c; c = 0; while (n > 0) { c = c + n % 10; n = n / 10; } for (i = 0; i < 2; i++) c = c + 1; while (c > 20) c = c - 20; return c; }\nint main() { int a[5]; int p = prefix(a, 5); printf(\"%d %d %d %d\\n\", sumsq(4), p, a[2], count3(9876)); return 0; }"))
```
---
```output
native sumsq
native prefix
native count3
interp main
240 30 9 12
0
```

## cross-calls

### leaf callees inline, in bodies, inits and loops; recursion does not

```cc
(display (cc-build-run "#include <stdio.h>\nint sq(int x) { return x * x; }\nint cube(int x) { return sq(x) * x; }\nint max2(int a, int b) { return a > b ? a : b; }\nint sumsq(int n) { int i; int s; s = 0; for (i = 1; i <= n; i++) s = s + sq(i); return s; }\nint upto(int n) { int i; int s = cube(n); for (i = 0; i < n; i++) s = s + max2(i, 3); return s; }\nint get(int *a, int i) { return a[i]; }\nint dbl(int *a, int n) { int i; for (i = 0; i < n; i++) a[i] = get(a, i) * 2; return get(a, 0) + get(a, n - 1); }\nint fact(int n) { return n < 2 ? 1 : n * fact(n - 1); }\nint f2(int n) { return fact(n) + 1; }\nint od(int n);\nint ev(int n) { return n == 0 ? 1 : od(n - 1); }\nint od(int n) { return n == 0 ? 0 : ev(n - 1); }\nint main() { int a[3] = {1, 2, 3}; int d = dbl(a, 3); printf(\"%d %d %d %d %d %d %d\\n\", cube(3), sumsq(4), upto(4), d, a[1], f2(5), ev(7)); return 0; }"))
```
---
```output
native sq
native cube
native max2
native sumsq
native upto
native get
native dbl
native fact
interp f2
interp ev
interp od
interp main
27 30 76 8 4 121 0
0
```
