# @weight 2

The build slice: cc-build-run lowers the eligible functions through
the engine's compile-asm lane, reports each verdict (native or
interp), and runs -- SAME program output as cc-run, natively where it
counts.  The twin-agreement rule is the spec: build cases repeat run
cases and must only add the report lines.

## verdicts

### fib compiles native; main stays interpreted

```cc
(display (cc-build-run "#include <stdio.h>\nint fib(int n) { if (n < 2) return n; return fib(n-1) + fib(n-2); }\nint main() { printf(\"%d\\n\", fib(10)); return 0; }"))
```
---
```output
native fib
interp main
55
0
```

### gcd: a two-argument self-recursion

```cc
(display (cc-build-run "#include <stdio.h>\nint gcd(int a, int b) { if (b == 0) return a; return gcd(b, a % b); }\nint main() { printf(\"%d\\n\", gcd(252, 105)); return 0; }"))
```
---
```output
native gcd
interp main
21
0
```

### logic lowers with C's exact 1/0

```cc
(display (cc-build-run "#include <stdio.h>\nint pick(int a, int b) { return a > 1 && b > 1 ? a * b : !(a || b); }\nint main() { printf(\"%d %d %d\\n\", pick(3, 4), pick(0, 5), pick(0, 0)); return 0; }"))
```
---
```output
native pick
interp main
12 0 1
0
```

### pointers stay interpreted, loudly classified

```cc
(display (cc-build-run "#include <stdio.h>\nint deref(int *p) { return *p; }\nint main() { int x = 9; printf(\"%d\\n\", deref(&x)); return 0; }"))
```
---
```output
interp deref
interp main
9
0
```

### a for loop compiles native beside a recursive function

The loop transform: `{ decls; for; return }` becomes tail self-recursion
with the accumulators as extra parameters, so tri is native now (main,
which prints, stays interpreted).

```cc
(display (cc-build-run "#include <stdio.h>\nint tri(int n) { int s = 0; int i; for (i = 1; i <= n; i++) s += i; return s; }\nint fib(int n) { if (n < 2) return n; return fib(n-1) + fib(n-2); }\nint main() { printf(\"%d %d\\n\", tri(10), fib(11)); return 0; }"))
```
---
```output
native tri
native fib
interp main
55 89
0
```

## twin agreement

### the native and interpreted twins answer alike across a sweep

```cc
(display (cc-build-run "#include <stdio.h>\nint fib(int n) { if (n < 2) return n; return fib(n-1) + fib(n-2); }\nint main() { int i; for (i = 0; i < 12; i++) { printf(\"%d\", fib(i) % 10); } putchar(10); return 0; }"))
```
---
```output
native fib
interp main
011235831459
0
```
