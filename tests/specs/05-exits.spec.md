# @weight 2

Early exits: return/break/continue
inside a loop body, under nested conditions, and a pre-loop `if (C)
return E;` guard before the loop.  `break` leaves with the values at
the break point; `continue` skips the rest of the body and still runs
the step.  Every expectation is an oracle row from /usr/bin/cc.

## return inside the loop

### the search loop: first divisor

```cc
(display (cc-run "#include <stdio.h>\nint firstdiv(int n) { int d; for (d = 2; d < n; d++) { if (n % d == 0) return d; } return n; }\nint main() { printf(\"%d %d\\n\", firstdiv(91), firstdiv(97)); return 0; }"))
```
---
```output
7 97
0
```

### a pre-loop guard, then a return in the loop: isprime

```cc
(display (cc-run "#include <stdio.h>\nint isprime(int n) { int d; if (n < 2) return 0; for (d = 2; d * d <= n; d++) { if (n % d == 0) return 0; } return 1; }\nint main() { printf(\"%d %d %d\\n\", isprime(97), isprime(91), isprime(2)); return 0; }"))
```
---
```output
1 0 1
0
```

### a return under nested ifs carries both conditions

```cc
(display (cc-run "#include <stdio.h>\nint nested(int n) { int i; for (i = 0; i < n; i++) { if (i > 3) { if (i % 5 == 0) return i * 10; } } return -1; }\nint main() { printf(\"%d %d\\n\", nested(20), nested(4)); return 0; }"))
```
---
```output
50 -1
0
```

## break and continue

### break leaves with the values at the break point

```cc
(display (cc-run "#include <stdio.h>\nint isqrt(int n) { int i = 0; while (1 == 1) { if ((i + 1) * (i + 1) > n) break; i = i + 1; } return i; }\nint main() { printf(\"%d %d\\n\", isqrt(99), isqrt(100)); return 0; }"))
```
---
```output
9 10
0
```

### continue skips the rest of the body but not the step

```cc
(display (cc-run "#include <stdio.h>\nint oddsum(int n) { int s = 0; int i; for (i = 1; i <= n; i++) { if (i % 2 == 0) continue; s = s + i; } return s; }\nint main() { printf(\"%d\\n\", oddsum(10)); return 0; }"))
```
---
```output
25
0
```

## guards that read what the body changes

### a guard that reads an accumulator

```cc
(display (cc-run "#include <stdio.h>\nint g(int n) { int s = 0; int i; if (s > 0) return 9; for (i = 0; i < n; i++) s = s + i; return s; }\nint main() { printf(\"%d\\n\", g(5)); return 0; }"))
```
---
```output
10
0
```

### a guard that reads a parameter the body assigns

```cc
(display (cc-run "#include <stdio.h>\nint h(int n) { int k = 0; if (n < 0) return 0; while (n > 0) { k = k + 1; n = n - 1; } return k; }\nint main() { printf(\"%d\\n\", h(7)); return 0; }"))
```
---
```output
7
0
```

## a sweep

### isprime over 0..20

```cc
(display (cc-run "#include <stdio.h>\nint isprime(int n) { int d; if (n < 2) return 0; for (d = 2; d * d <= n; d++) { if (n % d == 0) return 0; } return 1; }\nint main() { int i; for (i = 0; i <= 20; i++) printf(\"%d\", isprime(i)); putchar(10); return 0; }"))
```
---
```output
001101010001010001010
0
```
