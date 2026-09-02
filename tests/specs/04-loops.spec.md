# @weight 2

Loops in the compile-asm eligible class.  A C function shaped
`{ decls; while|for; return R }` transforms into tail self-recursion:
every threadable variable -- the parameters AND the accumulators --
rides the self-call with its folded new value; accumulators get their
literal inits by arg-padding at the call boundary.  Output is
oracle-checked against the same source through /usr/bin/cc; the build
verdicts and the twin-agreement (built output == interpreted output)
are the spec.

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

## the fold: sequential updates, locals, if

### two accumulators, sequential update, a body-local temp

The `int t;` inside the body is a substitution variable -- it never
needs a parameter slot; `b = a + b; a = b - a;` folds so the second
assignment reads the FIRST's new value, C's sequential semantics.

```cc
(display (cc-build-run "#include <stdio.h>\nint fibit(int n) { int a = 0; int b = 1; int i; for (i = 0; i < n; i++) { int t; b = a + b; a = b - a; } return a; }\nint main() { printf(\"%d\\n\", fibit(10)); return 0; }"))
```
---
```output
native fibit
interp main
55
0
```

### a mutated parameter rides the self-call: gcd is recursive gcd

```cc
(display (cc-build-run "#include <stdio.h>\nint gcd(int a, int b) { while (b != 0) { int t; t = a % b; a = b; b = t; } return a; }\nint main() { printf(\"%d\\n\", gcd(252, 105)); return 0; }"))
```
---
```output
native gcd
interp main
21
0
```

### an if in the body merges as a ternary

```cc
(display (cc-build-run "#include <stdio.h>\nint evens(int n) { int c = 0; int i; for (i = 1; i <= n; i++) { if (i % 2 == 0) c = c + 1; } return c; }\nint main() { printf(\"%d %d\\n\", evens(10), evens(7)); return 0; }"))
```
---
```output
native evens
interp main
5 3
0
```

### if/else over a mutated param: collatz steps

```cc
(display (cc-build-run "#include <stdio.h>\nint steps(int n) { int k = 0; while (n != 1) { if (n % 2 == 0) n = n / 2; else n = 3 * n + 1; k = k + 1; } return k; }\nint main() { printf(\"%d %d\\n\", steps(27), steps(6)); return 0; }"))
```
---
```output
native steps
interp main
111 8
0
```

### a body-local temp read by a later assignment

```cc
(display (cc-build-run "#include <stdio.h>\nint dsum(int n) { int s = 0; while (n > 0) { int d; d = n % 10; s = s + d; n = n / 10; } return s; }\nint main() { printf(\"%d\\n\", dsum(98765)); return 0; }"))
```
---
```output
native dsum
interp main
35
0
```

### two branches writing different accumulators both merge

```cc
(display (cc-build-run "#include <stdio.h>\nint f(int n) { int a = 0; int b = 0; int i; for (i = 0; i < n; i++) { if (i % 3 == 0) { a = a + i; } else { b = b + 1; } } return a * 100 + b; }\nint main() { printf(\"%d\\n\", f(10)); return 0; }"))
```
---
```output
native f
interp main
1806
0
```

## the refusals

### a pre-loop assignment breaks the shape; the whole still runs

`i = n` between the decls and the loop is neither a decl nor the loop
(and its init is a parameter, not a literal) -- the recorded pending.

```cc
(display (cc-build-run "#include <stdio.h>\nint cd(int n) { int t = 0; int i; i = n; while (i > 0) { t = t + i; i = i - 1; } return t; }\nint main() { printf(\"%d\\n\", cd(50)); return 0; }"))
```
---
```output
interp cd
interp main
1275
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
