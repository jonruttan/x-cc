# @weight 2

Early exits in the compile-asm eligible class.  return/break/continue
inside a loop body are GUARDED EXITS -- (guard . value) pairs the fold
collects beside the update map, the guard being the conjunction of the
path conditions above it -- and the lowered body is those exits as
nested ifs ending in the ordinary self-call.  `break` exits with the
function's R at the break-point map; `continue` exits with a self-call
from the continue-point map (step applied).  A pre-loop `if (C)
return E;` guard wraps the loop when it is loop-invariant.  Every
expectation is an oracle row from /usr/bin/cc.

## return inside the loop

### the search loop: first divisor

```cc
(display (cc-build-run "#include <stdio.h>\nint firstdiv(int n) { int d; for (d = 2; d < n; d++) { if (n % d == 0) return d; } return n; }\nint main() { printf(\"%d %d\\n\", firstdiv(91), firstdiv(97)); return 0; }"))
```
---
```output
native firstdiv
interp main
7 97
0
```

### a pre-loop guard, then a return in the loop: isprime

```cc
(display (cc-build-run "#include <stdio.h>\nint isprime(int n) { int d; if (n < 2) return 0; for (d = 2; d * d <= n; d++) { if (n % d == 0) return 0; } return 1; }\nint main() { printf(\"%d %d %d\\n\", isprime(97), isprime(91), isprime(2)); return 0; }"))
```
---
```output
native isprime
interp main
1 0 1
0
```

### a return under nested ifs carries both conditions

```cc
(display (cc-build-run "#include <stdio.h>\nint nested(int n) { int i; for (i = 0; i < n; i++) { if (i > 3) { if (i % 5 == 0) return i * 10; } } return -1; }\nint main() { printf(\"%d %d\\n\", nested(20), nested(4)); return 0; }"))
```
---
```output
native nested
interp main
50 -1
0
```

## break and continue

### break leaves with the values at the break point

```cc
(display (cc-build-run "#include <stdio.h>\nint isqrt(int n) { int i = 0; while (1 == 1) { if ((i + 1) * (i + 1) > n) break; i = i + 1; } return i; }\nint main() { printf(\"%d %d\\n\", isqrt(99), isqrt(100)); return 0; }"))
```
---
```output
native isqrt
interp main
9 10
0
```

### continue skips the rest of the body but not the step

```cc
(display (cc-build-run "#include <stdio.h>\nint oddsum(int n) { int s = 0; int i; for (i = 1; i <= n; i++) { if (i % 2 == 0) continue; s = s + i; } return s; }\nint main() { printf(\"%d\\n\", oddsum(10)); return 0; }"))
```
---
```output
native oddsum
interp main
25
0
```

## the refusals: a guard must be loop-invariant

### a guard that reads an accumulator stays interpreted

An accumulator holds its init only on the first entry; the guard would
re-run on every self-call re-entry with the current value.

```cc
(display (cc-build-run "#include <stdio.h>\nint g(int n) { int s = 0; int i; if (s > 0) return 9; for (i = 0; i < n; i++) s = s + i; return s; }\nint main() { printf(\"%d\\n\", g(5)); return 0; }"))
```
---
```output
interp g
interp main
10
0
```

### a guard that reads a parameter the body assigns stays interpreted

```cc
(display (cc-build-run "#include <stdio.h>\nint h(int n) { int k = 0; if (n < 0) return 0; while (n > 0) { k = k + 1; n = n - 1; } return k; }\nint main() { printf(\"%d\\n\", h(7)); return 0; }"))
```
---
```output
interp h
interp main
7
0
```

## twin agreement across a sweep

### native isprime agrees with its interpreted twin on 0..20

```cc
(display (cc-build-run "#include <stdio.h>\nint isprime(int n) { int d; if (n < 2) return 0; for (d = 2; d * d <= n; d++) { if (n % d == 0) return 0; } return 1; }\nint main() { int i; for (i = 0; i <= 20; i++) printf(\"%d\", isprime(i)); putchar(10); return 0; }"))
```
---
```output
native isprime
interp main
001101010001010001010
0
```
