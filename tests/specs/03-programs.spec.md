# @weight 2

Whole programs: recursion, a two-argument recursion, C's exact 1 and
0, a dereference through a parameter, a loop beside a recursive
function, and one function's answers across a sweep of inputs.  Every
expectation is an oracle row from /usr/bin/cc.

## programs

### fib, by recursion

```cc
(display (cc-run "#include <stdio.h>\nint fib(int n) { if (n < 2) return n; return fib(n-1) + fib(n-2); }\nint main() { printf(\"%d\\n\", fib(10)); return 0; }"))
```
---
```output
55
0
```

### gcd: a two-argument self-recursion

```cc
(display (cc-run "#include <stdio.h>\nint gcd(int a, int b) { if (b == 0) return a; return gcd(b, a % b); }\nint main() { printf(\"%d\\n\", gcd(252, 105)); return 0; }"))
```
---
```output
21
0
```

### logic answers C's exact 1 and 0

```cc
(display (cc-run "#include <stdio.h>\nint pick(int a, int b) { return a > 1 && b > 1 ? a * b : !(a || b); }\nint main() { printf(\"%d %d %d\\n\", pick(3, 4), pick(0, 5), pick(0, 0)); return 0; }"))
```
---
```output
12 0 1
0
```

### a dereference through a pointer parameter

```cc
(display (cc-run "#include <stdio.h>\nint deref(int *p) { return *p; }\nint main() { int x = 9; printf(\"%d\\n\", deref(&x)); return 0; }"))
```
---
```output
9
0
```

### a for loop beside a recursive function

```cc
(display (cc-run "#include <stdio.h>\nint tri(int n) { int s = 0; int i; for (i = 1; i <= n; i++) s += i; return s; }\nint fib(int n) { if (n < 2) return n; return fib(n-1) + fib(n-2); }\nint main() { printf(\"%d %d\\n\", tri(10), fib(11)); return 0; }"))
```
---
```output
55 89
0
```

## a sweep

### one function's answers across a sweep of inputs

```cc
(display (cc-run "#include <stdio.h>\nint fib(int n) { if (n < 2) return n; return fib(n-1) + fib(n-2); }\nint main() { int i; for (i = 0; i < 12; i++) { printf(\"%d\", fib(i) % 10); } putchar(10); return 0; }"))
```
---
```output
011235831459
0
```
