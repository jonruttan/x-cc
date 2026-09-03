# @weight 2

Four limits of the lowering design, lifted.  GLOBALS: the program is
loaded before anything lowers, so a global is memory at a known
address -- a scalar reads and writes as *(ADDR), an array is its base;
a parameter or local of the same name shadows.  SHORT CIRCUITS: the
guarded operand's reads run under a cond effect on the guard, so a
read the C never reaches never happens.  SPILLS: threaded variables
past the lane's four arguments live in scratch cells, read and written
as memory, their entry values stored at the call boundary by one
compiled entry function.  DEEPER LOOPS: the nested state machine is
recursive, so a loop inside a loop inside a loop lowers.  Every
expectation is an oracle row from /usr/bin/cc; the native twins print
what the interpreter prints.

## globals

### a scalar and an array global, read and written natively

```cc
(display (cc-build-run "#include <stdio.h>\nint total; int count = 0; int table[8]; int limit = 5;\nint bump(int x) { total = total + x; count++; return total; }\nint fill(int n) { int i; for (i = 0; i < n; i++) { table[i] = i * i; total = total + table[i]; count++; } return total; }\nint sumsq(int n) { int i; int s; s = 0; for (i = 0; i < n; i++) s = s + table[i]; return s + count; }\nint under(int x) { return x < limit ? x : limit; }\nint main() { int r1 = bump(3); int r2 = bump(4); int r3 = fill(6); int r4 = sumsq(6); printf(\"%d %d %d %d %d %d %d\\n\", r1, r2, r3, r4, total, count, under(9)); return 0; }"))
```
---
```output
native bump
native fill
native sumsq
native under
interp main
3 7 62 63 62 8 5
0
```

## reads under a short circuit

### ||, the ternary's arms, and a chain of &&, each read only under its guard

```cc
(display (cc-build-run "#include <stdio.h>\nint cnt(int *a, int n) { int i; int c; c = 0; for (i = 0; i < n; i++) if (a[i] > 0 || a[i + 1] > 0) c++; return c; }\nint mx(int *a, int n) { int i; int m; m = 0; for (i = 0; i < n; i++) m = a[i] > m ? a[i] : m; return m; }\nint both(int *a, int n) { int i; int c; c = 0; for (i = 0; i < n; i++) c = c + (i + 1 < n && a[i] > 0 && a[i + 1] > 0); return c; }\nint main() { int a[7] = {3, 0, -2, 5, 0, 0, 9}; int c = cnt(a, 6); int m = mx(a, 7); int b = both(a, 7); printf(\"%d %d %d\\n\", c, m, b); return 0; }"))
```
---
```output
native cnt
native mx
native both
interp main
4 9 0
0
```

## spills

### five, four and three threaded variables past the lane's slots

```cc
(display (cc-build-run "#include <stdio.h>\nint stats(int *a, int n) { int i; int s; int mx; int mn; int c; s = 0; mx = -1000; mn = 1000; c = 0; for (i = 0; i < n; i++) { s = s + a[i]; if (a[i] > mx) mx = a[i]; if (a[i] < mn) mn = a[i]; if (a[i] % 2 == 0) c++; } return s * 1000000 + mx * 10000 + (mn + 100) * 100 + c; }\nint tri(int n) { int i; int j; int s; int c; s = 0; c = 0; for (i = 0; i < n; i++) for (j = 0; j <= i; j++) { s = s + j; c++; } return s * 100 + c; }\nint tri2(int a, int b, int n) { int i; int j; int s; s = 0; for (i = a; i < n; i++) for (j = b; j <= i; j++) s = s + j; return s; }\nint main() { int a[6] = {4, -7, 12, 3, 8, 1}; printf(\"%d %d %d\\n\", stats(a, 6), tri(5), tri2(1, 1, 6)); return 0; }"))
```
---
```output
native stats
native tri
native tri2
interp main
21129303 2015 35
0
```

## three-deep loops

### a triple sum, and a matrix product with a store between the levels

```cc
(display (cc-build-run "#include <stdio.h>\nint cube(int n) { int i; int j; int k; int s; s = 0; for (i = 0; i < n; i++) for (j = 0; j < n; j++) for (k = 0; k < n; k++) s = s + i * j * k; return s; }\nint mm(int *a, int *b, int n) { int i; int j; int k; int s; for (i = 0; i < n; i++) for (j = 0; j < n; j++) { s = 0; for (k = 0; k < n; k++) s = s + a[i * n + k] * a[k * n + j]; b[i * n + j] = s; } return b[n * n - 1]; }\nint main() { int a[9] = {1, 2, 3, 4, 5, 6, 7, 8, 9}; int b[9]; int i; int r = mm(a, b, 3); printf(\"%d %d\", cube(4), r); for (i = 0; i < 9; i++) printf(\" %d\", b[i]); printf(\"\\n\"); return 0; }"))
```
---
```output
native cube
native mm
interp main
216 150 30 36 42 66 81 96 102 126 150
0
```
