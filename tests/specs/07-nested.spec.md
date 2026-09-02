# @weight 2

Nested loops in the compile-asm eligible class.  The lane self-calls
only, so an inner loop is a STATE MACHINE over the one self-call: each
re-entry runs one step of whichever loop is active --
`(if I-cond (if J-cond INNER-STEP TRANSITION) R)` -- where the
transition folds the statements after the inner loop, the outer step,
and a guarded reset of the inner loop (PRE statements and J-init) that
never leaks into R.  An inner `break` is the transition; an inner
`continue` the inner self-call.  Every expectation is an oracle row
from /usr/bin/cc.

## two loops, one self-call

### the square

```cc
(display (cc-build-run "#include <stdio.h>\nint sq(int n) { int s = 0; int i; int j; for (i = 0; i < n; i++) { for (j = 0; j < n; j++) { s = s + 1; } } return s; }\nint main() { printf(\"%d\\n\", sq(7)); return 0; }"))
```
---
```output
native sq
interp main
49
0
```

### the triangle: an inner init that reads the outer variable

```cc
(display (cc-build-run "#include <stdio.h>\nint pairs(int n) { int c = 0; int i; int j; for (i = 0; i < n; i++) for (j = i + 1; j < n; j++) c = c + 1; return c; }\nint main() { printf(\"%d\\n\", pairs(6)); return 0; }"))
```
---
```output
native pairs
interp main
15
0
```

### an if inside the inner body

```cc
(display (cc-build-run "#include <stdio.h>\nint div3(int n) { int c = 0; int i; int j; for (i = 1; i <= n; i++) { for (j = 1; j <= n; j++) { if ((i + j) % 3 == 0) c = c + 1; } } return c; }\nint main() { printf(\"%d\\n\", div3(5)); return 0; }"))
```
---
```output
native div3
interp main
9
0
```

## exits from the inner loop

### an inner break is the transition, not the return

```cc
(display (cc-build-run "#include <stdio.h>\nint brk(int n) { int c = 0; int i; int j; for (i = 0; i < n; i++) { for (j = 0; j < n; j++) { if (j * j > i) break; c = c + 1; } } return c; }\nint main() { printf(\"%d\\n\", brk(6)); return 0; }"))
```
---
```output
native brk
interp main
13
0
```

### a return from the inner loop leaves both

```cc
(display (cc-build-run "#include <stdio.h>\nint find(int k) { int i; int j; for (i = 1; i < 50; i++) { for (j = 1; j < 50; j++) { if (i * j == k) return i * 100 + j; } } return -1; }\nint main() { printf(\"%d\\n\", find(91)); return 0; }"))
```
---
```output
native find
interp main
713
0
```

## statements around the inner loop

### a statement after the inner loop runs once per outer iteration

```cc
(display (cc-build-run "#include <stdio.h>\nint post(int n) { int s = 0; int i; int j; for (i = 0; i < n; i++) { for (j = 0; j < i; j++) { s = s + 1; } s = s + 100; } return s; }\nint main() { printf(\"%d\\n\", post(5)); return 0; }"))
```
---
```output
native post
interp main
510
0
```

## the refusal

### five threaded variables exceed the lane's four args

```cc
(display (cc-build-run "#include <stdio.h>\nint pre(int n) { int s = 0; int t = 0; int i; int j; for (i = 0; i < n; i++) { t = i * 10; for (j = 0; j < 2; j++) { s = s + t; } } return s; }\nint main() { printf(\"%d\\n\", pre(4)); return 0; }"))
```
---
```output
interp pre
interp main
120
0
```

## twin agreement across a sweep

### the nested native agrees with its interpreted twin on every input

```cc
(display (cc-build-run "#include <stdio.h>\nint pairs(int n) { int c = 0; int i; int j; for (i = 0; i < n; i++) for (j = i + 1; j < n; j++) c = c + 1; return c; }\nint main() { int i; for (i = 0; i < 8; i++) printf(\"%d \", pairs(i)); putchar(10); return 0; }"))
```
---
```output
native pairs
interp main
0 0 1 3 6 10 15 21 
0
```
