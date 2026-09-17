# @weight 2

One function calls another: a callee with a loop, called twice and
from two callers, a recursive callee, and two functions that call each
other.  Every expectation is an oracle row from /usr/bin/cc.

## calls between functions

### a callee with a loop, called twice, and a recursive callee

```cc
(display (cc-run "#include <stdio.h>\nint sumto(int n) { int i; int s; s = 0; for (i = 1; i <= n; i++) s = s + i; return s; }\nint twice(int n) { return sumto(n) * 2; }\nint hyp(int a, int b) { return sumto(a) + sumto(b); }\nint fact(int n) { return n < 2 ? 1 : n * fact(n - 1); }\nint viafact(int n) { return fact(n) + 1; }\nint main() { printf(\"%d %d %d %d\\n\", sumto(4), twice(4), hyp(3, 4), viafact(5)); return 0; }"))
```
---
```output
10 20 16 121
0
```

## mutual recursion

### two functions that call each other

```cc
(display (cc-run "#include <stdio.h>\nint od(int n);\nint ev(int n) { return n == 0 ? 1 : od(n - 1); }\nint od(int n) { return n == 0 ? 0 : ev(n - 1); }\nint main() { printf(\"%d %d\\n\", ev(8), od(8)); return 0; }"))
```
---
```output
1 0
0
```
