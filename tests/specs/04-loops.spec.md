# @weight 2

Loops: `for` and `while` bodies with accumulators, a mutated
parameter, a body-local temp, an `if` in the body, branches writing
different accumulators, and a loop three deep.  Every expectation is
an oracle row from /usr/bin/cc.

## for loops

### the summation loop

```cc
(display (cc-run "#include <stdio.h>\nint tri(int n) { int s = 0; int i; for (i = 1; i <= n; i++) s += i; return s; }\nint main() { printf(\"%d\\n\", tri(100)); return 0; }"))
```
---
```output
5050
0
```

### factorial by product accumulator

```cc
(display (cc-run "#include <stdio.h>\nint fact(int n) { int r = 1; int i; for (i = 1; i <= n; i++) r = r * i; return r; }\nint main() { printf(\"%d\\n\", fact(6)); return 0; }"))
```
---
```output
720
0
```

### a for-INIT literal seeds the loop var

```cc
(display (cc-run "#include <stdio.h>\nint pow2(int n) { int r = 1; int i; for (i = 0; i < n; i++) r = r * 2; return r; }\nint main() { printf(\"%d\\n\", pow2(10)); return 0; }"))
```
---
```output
1024
0
```

## while loops

### an accumulator while with a literal decl-init loop var

```cc
(display (cc-run "#include <stdio.h>\nint sumto(int n) { int t = 0; int i; for (i = 1; i <= n; i++) t = t + i; return t; }\nint sumw(int n) { int t = 0; int i = 1; while (i <= n) { t = t + i; i = i + 1; } return t; }\nint main() { printf(\"%d %d\\n\", sumto(50), sumw(50)); return 0; }"))
```
---
```output
1275 1275
0
```

## the fold: sequential updates, locals, if

### two accumulators, sequential update, a body-local temp

The `int t;` inside the body is a substitution variable -- it never
needs a parameter slot; `b = a + b; a = b - a;` folds so the second
assignment reads the first's new value, C's sequential semantics.

```cc
(display (cc-run "#include <stdio.h>\nint fibit(int n) { int a = 0; int b = 1; int i; for (i = 0; i < n; i++) { int t; b = a + b; a = b - a; } return a; }\nint main() { printf(\"%d\\n\", fibit(10)); return 0; }"))
```
---
```output
55
0
```

### a mutated parameter: gcd as a loop

```cc
(display (cc-run "#include <stdio.h>\nint gcd(int a, int b) { while (b != 0) { int t; t = a % b; a = b; b = t; } return a; }\nint main() { printf(\"%d\\n\", gcd(252, 105)); return 0; }"))
```
---
```output
21
0
```

### an if in the body merges as a ternary

```cc
(display (cc-run "#include <stdio.h>\nint evens(int n) { int c = 0; int i; for (i = 1; i <= n; i++) { if (i % 2 == 0) c = c + 1; } return c; }\nint main() { printf(\"%d %d\\n\", evens(10), evens(7)); return 0; }"))
```
---
```output
5 3
0
```

### if/else over a mutated param: collatz steps

```cc
(display (cc-run "#include <stdio.h>\nint steps(int n) { int k = 0; while (n != 1) { if (n % 2 == 0) n = n / 2; else n = 3 * n + 1; k = k + 1; } return k; }\nint main() { printf(\"%d %d\\n\", steps(27), steps(6)); return 0; }"))
```
---
```output
111 8
0
```

### a body-local temp read by a later assignment

```cc
(display (cc-run "#include <stdio.h>\nint dsum(int n) { int s = 0; while (n > 0) { int d; d = n % 10; s = s + d; n = n / 10; } return s; }\nint main() { printf(\"%d\\n\", dsum(98765)); return 0; }"))
```
---
```output
35
0
```

### two branches writing different accumulators both merge

```cc
(display (cc-run "#include <stdio.h>\nint f(int n) { int a = 0; int b = 0; int i; for (i = 0; i < n; i++) { if (i % 3 == 0) { a = a + i; } else { b = b + 1; } } return a * 100 + b; }\nint main() { printf(\"%d\\n\", f(10)); return 0; }"))
```
---
```output
1806
0
```

## the refusals

### a loop three deep

```cc
(display (cc-run "#include <stdio.h>\nint c3(int n) { int s = 0; int i; int j; for (i = 0; i < n; i++) { for (j = 0; j < n; j++) { int k; for (k = 0; k < 2; k++) s = s + 1; } } return s; }\nint main() { printf(\"%d\\n\", c3(3)); return 0; }"))
```
---
```output
18
0
```

## a sweep

### a loop's answers across a sweep of inputs

```cc
(display (cc-run "#include <stdio.h>\nint tri(int n) { int s = 0; int i; for (i = 1; i <= n; i++) s += i; return s; }\nint main() { int i; for (i = 0; i < 8; i++) printf(\"%d \", tri(i)); putchar(10); return 0; }"))
```
---
```output
0 1 3 6 10 15 21 28 
0
```
