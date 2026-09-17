# @weight 2

A call through a function pointer.  A function value is an id handed
out in program order, and a call through a value -- a parameter, an
element of a global table -- maps the id back to the function.  A
value naming no function refuses at run time.  Every expectation is an
oracle row from /usr/bin/cc.

## dispatch on a function value

### through a parameter, called twice, and through a global table

```cc
(display (cc-run "#include <stdio.h>\nint sq(int n) { return n * n; }\nint dbl(int n) { return n * 2; }\nint add(int a, int b) { return a + b; }\nint sub(int a, int b) { return a - b; }\nint twice(int (*f)(int), int x) { return f(f(x)); }\nint apply2(int (*f)(int, int), int a, int b) { return f(a, b); }\nint (*ops[2])(int, int) = { add, sub };\nint viatable(int i, int a, int b) { return ops[i](a, b); }\nint main() { printf(\"%d %d %d %d %d\\n\", twice(sq, 3), twice(dbl, 3), apply2(add, 7, 2), apply2(sub, 7, 2), viatable(1, 10, 4)); return 0; }"))
```
---
```output
81 12 9 5 6
0
```

## a function's address

### a function whose address the program takes

A pointer could name any function whose address the program takes, so
both targets answer through the same dispatch.

```cc
(display (cc-run "#include <stdio.h>\nint good(int n) { return n + 1; }\nint bad(int n) { int t[2] = {1, 2}; return t[1] + n; }\nint call1(int (*f)(int), int x) { return f(x); }\nint main() { int (*p)(int) = bad; printf(\"%d %d\\n\", call1(good, 5), call1(p, 5)); return 0; }"))
```
---
```output
6 7
0
```
