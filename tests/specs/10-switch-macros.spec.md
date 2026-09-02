# @weight 2

switch, and function-like macros.  A switch's matched clause and
every clause after it run as one block -- fallthrough -- until a
break; return and continue pass through to the function or the
enclosing loop.  A function-like macro's arguments are collected as
text across balanced parentheses, substituted at identifier
boundaries into the body, and the result rescanned with the macro
open.  No parentheses are added, as in C.  Every expectation is an
oracle row from /usr/bin/cc.

## switch

### cases, a shared case, a default, returns inside

```cc
(display (cc-run "#include <stdio.h>\nint kind(int c) { switch (c) { case 1: return 10; case 2: case 3: return 23; default: return -1; } }\nint main() { printf(\"%d %d %d\\n\", kind(1), kind(3), kind(9)); return 0; }"))
```
---
```output
10 23 -1
0
```

### fallthrough until a break; default falls too

```cc
(display (cc-run "#include <stdio.h>\nint fall(int c) { int s; s = 0; switch (c) { case 1: s = s + 1; case 2: s = s + 10; break; case 3: s = s + 100; default: s = s + 1000; } return s; }\nint main() { printf(\"%d %d %d %d\\n\", fall(1), fall(2), fall(3), fall(7)); return 0; }"))
```
---
```output
11 10 1100 1000
0
```

### continue inside a switch inside a loop reaches the loop

```cc
(display (cc-run "#include <stdio.h>\nint main() { int i; int n; n = 0; for (i = 0; i < 6; i++) { switch (i % 3) { case 0: continue; case 1: n = n + 1; break; default: n = n + 10; } n = n + 100; } printf(\"%d\\n\", n); return 0; }"))
```
---
```output
422
0
```

## function-like macros

### arguments, nesting, a macro using a macro, no parameters

```cc
(display (cc-run "#include <stdio.h>\n#define MAX(a, b) ((a) > (b) ? (a) : (b))\n#define SQ(x) x * x\n#define TWICE(x) (2 * SQ(x))\n#define ZERO() 0\nint main() { printf(\"%d %d %d %d %d\\n\", MAX(3, 7), MAX(2 + 2, 1), SQ(1 + 2), TWICE(3), ZERO()); return 0; }"))
```
---
```output
7 4 5 18 0
0
```

### the name without its parenthesis is just an identifier

```cc
(display (cc-run "#include <stdio.h>\n#define F(x) (x + 1)\nint main() { int F; F = 41; printf(\"%d %d\\n\", F, F(F)); return 0; }"))
```
---
```output
41 42
0
```

## the operators

### # stringizes (the full story is 13-byvalue-paste)

```cc
(display (cc-run "#include <stdio.h>\n#define STR(x) #x\nint main() { puts(STR(ok)); return 0; }"))
```
---
```output
ok
0
```
