# @weight 2

Loops in the compile-asm eligible class.  A C function shaped
`{ decls; while|for; return R }` transforms into tail self-recursion:
the accumulator and loop variables become extra parameters, initialized
by arg-padding at the call boundary.  Output is oracle-checked against
the same source through /usr/bin/cc; the build verdicts and the
twin-agreement (built output == interpreted output) are the spec.

## for loops go native

### the summation loop

```cc
(display (cc-build-run "#include <stdio.h>\nint tri(int n) { int s = 0; int i; for (i = 1; i <= n; i++) s += i; return s; }\nint main() { printf(\"%d\\n\", tri(100)); return 0; }"))
```
---
```output
native tri
interp main
5050
0
```

### factorial by product accumulator

```cc
(display (cc-build-run "#include <stdio.h>\nint fact(int n) { int r = 1; int i; for (i = 1; i <= n; i++) r = r * i; return r; }\nint main() { printf(\"%d\\n\", fact(6)); return 0; }"))
```
---
```output
native fact
interp main
720
0
```

### a for-INIT literal seeds the loop var

```cc
(display (cc-build-run "#include <stdio.h>\nint pow2(int n) { int r = 1; int i; for (i = 0; i < n; i++) r = r * 2; return r; }\nint main() { printf(\"%d\\n\", pow2(10)); return 0; }"))
```
---
```output
native pow2
interp main
1024
0
```

## while loops go native

### an accumulator while with a literal decl-init loop var

```cc
(display (cc-build-run "#include <stdio.h>\nint sumto(int n) { int t = 0; int i; for (i = 1; i <= n; i++) t = t + i; return t; }\nint sumw(int n) { int t = 0; int i = 1; while (i <= n) { t = t + i; i = i + 1; } return t; }\nint main() { printf(\"%d %d\\n\", sumto(50), sumw(50)); return 0; }"))
```
---
```output
native sumto
native sumw
interp main
1275 1275
0
```

## two accumulators, sequential update

### fibonacci by iteration (a, b threaded together)

```cc
(display (cc-build-run "#include <stdio.h>\nint fibit(int n) { int a = 0; int b = 1; int i; for (i = 0; i < n; i++) { int t; b = a + b; a = b - a; } return a; }\nint main() { printf(\"%d\\n\", fibit(10)); return 0; }"))
```
---
```output
interp fibit
interp main
55
0
```

## the refusals

### a loop that mutates a parameter stays interpreted

```cc
(display (cc-build-run "#include <stdio.h>\nint gcd(int a, int b) { while (b != 0) { int t; t = a % b; a = b; b = t; } return a; }\nint main() { printf(\"%d\\n\", gcd(252, 105)); return 0; }"))
```
---
```output
interp gcd
interp main
21
0
```

## twin agreement across a sweep

### the native loop and its interpreted twin agree on every input

```cc
(display (cc-build-run "#include <stdio.h>\nint tri(int n) { int s = 0; int i; for (i = 1; i <= n; i++) s += i; return s; }\nint main() { int i; for (i = 0; i < 8; i++) printf(\"%d \", tri(i)); putchar(10); return 0; }"))
```
---
```output
native tri
interp main
0 1 3 6 10 15 21 28 
0
```
