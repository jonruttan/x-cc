# @weight 2

Nested loops: statements before and after the inner loop, an inner
`break` and an inner `continue`, and a function carrying five
variables through the pair.  Every expectation is an oracle row from
/usr/bin/cc.

## a loop inside a loop

### the square

```cc
(display (cc-run "#include <stdio.h>\nint sq(int n) { int s = 0; int i; int j; for (i = 0; i < n; i++) { for (j = 0; j < n; j++) { s = s + 1; } } return s; }\nint main() { printf(\"%d\\n\", sq(7)); return 0; }"))
```
---
```output
49
0
```

### the triangle: an inner init that reads the outer variable

```cc
(display (cc-run "#include <stdio.h>\nint pairs(int n) { int c = 0; int i; int j; for (i = 0; i < n; i++) for (j = i + 1; j < n; j++) c = c + 1; return c; }\nint main() { printf(\"%d\\n\", pairs(6)); return 0; }"))
```
---
```output
15
0
```

### an if inside the inner body

```cc
(display (cc-run "#include <stdio.h>\nint div3(int n) { int c = 0; int i; int j; for (i = 1; i <= n; i++) { for (j = 1; j <= n; j++) { if ((i + j) % 3 == 0) c = c + 1; } } return c; }\nint main() { printf(\"%d\\n\", div3(5)); return 0; }"))
```
---
```output
9
0
```

## exits from the inner loop

### an inner break is the transition, not the return

```cc
(display (cc-run "#include <stdio.h>\nint brk(int n) { int c = 0; int i; int j; for (i = 0; i < n; i++) { for (j = 0; j < n; j++) { if (j * j > i) break; c = c + 1; } } return c; }\nint main() { printf(\"%d\\n\", brk(6)); return 0; }"))
```
---
```output
13
0
```

### a return from the inner loop leaves both

```cc
(display (cc-run "#include <stdio.h>\nint find(int k) { int i; int j; for (i = 1; i < 50; i++) { for (j = 1; j < 50; j++) { if (i * j == k) return i * 100 + j; } } return -1; }\nint main() { printf(\"%d\\n\", find(91)); return 0; }"))
```
---
```output
713
0
```

## statements around the inner loop

### a statement after the inner loop runs once per outer iteration

```cc
(display (cc-run "#include <stdio.h>\nint post(int n) { int s = 0; int i; int j; for (i = 0; i < n; i++) { for (j = 0; j < i; j++) { s = s + 1; } s = s + 100; } return s; }\nint main() { printf(\"%d\\n\", post(5)); return 0; }"))
```
---
```output
510
0
```

## more variables

### a fifth variable carried through the loops

```cc
(display (cc-run "#include <stdio.h>\nint pre(int n) { int s = 0; int t = 0; int i; int j; for (i = 0; i < n; i++) { t = i * 10; for (j = 0; j < 2; j++) { s = s + t; } } return s; }\nint main() { printf(\"%d\\n\", pre(4)); return 0; }"))
```
---
```output
120
0
```

## a sweep

### nested loops across a sweep of inputs

```cc
(display (cc-run "#include <stdio.h>\nint pairs(int n) { int c = 0; int i; int j; for (i = 0; i < n; i++) for (j = i + 1; j < n; j++) c = c + 1; return c; }\nint main() { int i; for (i = 0; i < 8; i++) printf(\"%d \", pairs(i)); putchar(10); return 0; }"))
```
---
```output
0 0 1 3 6 10 15 21 
0
```
