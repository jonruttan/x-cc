# @weight 2
# @timeout-scale 3

Pointers to functions.  A function's name, or `&` of it, is a pointer to
the function; a call through one, from a variable, a parameter, an
element or a field, calls it.  Compiled, the pointer is the function's
address, taken from where the instruction is, and the call hands over
the arguments in the first registers, so a function whose address is
taken takes at most three, none of them a struct, and answers no struct.
The pointer's C type keeps what the function answers.  Each case runs
the program under `run`, then compiled, and shows both outputs and both
statuses; every expectation is what the same source prints through
/usr/bin/cc.

## calls through pointers

### a pointer, a table of them, and one handed to a function

```cc
(def src "#include <stdio.h>\nint add(int a, int b) { return a + b; }\nint sub(int a, int b) { return a - b; }\nint mul(int a, int b) { return a * b; }\nint apply(int (*op)(int, int), int x, int y) { return op(x, y); }\nint main(void) { int (*f)(int, int) = add; int (*ops[3])(int, int) = {add, sub, mul}; int i, acc = 0; for (i = 0; i < 3; i++) acc = acc * 10 + ops[i](7, 3); printf(\"%d %d %d %d\\n\", f(2, 3), apply(sub, 10, 4), apply(mul, 6, 7), acc); f = mul; return f(3, 4) + (f == mul) + (f != add); }\n")
(display (list (cc-run src) (cc-exe-run src)))
```
---
```output
5 6 42 1061
5 6 42 1061
(14 14)
```

### a comparison handed to a sort

```cc
(def src "#include <stdio.h>\nint asc(int a, int b) { return a - b; }\nint desc(int a, int b) { return b - a; }\nvoid sort(int *v, int n, int (*cmp)(int, int)) { int i, j; for (i = 1; i < n; i++) { int x = v[i]; for (j = i - 1; j >= 0 && cmp(v[j], x) > 0; j--) v[j + 1] = v[j]; v[j + 1] = x; } }\nint main(void) { int v[6] = {5, 2, 9, 1, 7, 3}; int i; sort(v, 6, asc); for (i = 0; i < 6; i++) printf(\"%d \", v[i]); sort(v, 6, desc); for (i = 0; i < 6; i++) printf(\"%d \", v[i]); printf(\"\\n\"); return v[0]; }\n")
(display (list (cc-run src) (cc-exe-run src)))
```
---
```output
1 2 3 5 7 9 9 7 5 3 2 1 
1 2 3 5 7 9 9 7 5 3 2 1 
(9 9)
```

### a table of them from a typedef, answering longs, and one answering a string

```cc
(def src "#include <stdio.h>\ntypedef long (*binop)(long, long);\nlong big(long a, long b) { return a * b; }\nlong small(long a, long b) { return a - b; }\nbinop table[2] = {big, small};\nconst char *hello(void) { return \"hello\"; }\nconst char *(*greeter)(void) = hello;\nint main(void) { long r = table[0](100000L, 100000L); printf(\"%ld %ld %s\\n\", r, table[1](5L, 9L), greeter()); return (int)(r % 256); }\n")
(display (list (cc-run src) (cc-exe-run src)))
```
---
```output
10000000000 -4 hello
10000000000 -4 hello
(0 0)
```

### a field of a struct in a global table

```cc
(def src "#include <stdio.h>\nstruct shape { const char *name; int (*area)(int); };\nint square(int s) { return s * s; }\nint tri(int s) { return s * s / 2; }\nstruct shape shapes[2] = {{\"square\", square}, {\"tri\", tri}};\nint main(void) { int i, t = 0; for (i = 0; i < 2; i++) { printf(\"%s %d\\n\", shapes[i].name, shapes[i].area(6)); t += shapes[i].area(4); } struct shape *p = &shapes[1]; return t + p->area(10); }\n")
(display (list (cc-run src) (cc-exe-run src)))
```
---
```output
square 36
tri 18
square 36
tri 18
(74 74)
```

## the refusals

### the address of a function that takes a struct

```cc
(display (guard (e (do (display "refused: ") (write e) ""))
  (cc-exe-run "struct P { int x; };\nint getx(struct P p) { return p.x; }\nint main(void) { int (*f)(struct P) = getx; return 0; }")))
```
---
    refused: #<err:cc cc: compile: not built yet: the address of getx, which takes a struct or more than three arguments, or answers a struct>

### the address of a function of four arguments

```cc
(display (guard (e (do (display "refused: ") (write e) ""))
  (cc-exe-run "int sum4(int a, int b, int c, int d) { return a + b + c + d; }\nint main(void) { int (*f)(int, int, int, int) = sum4; return 0; }")))
```
---
    refused: #<err:cc cc: compile: not built yet: the address of sum4, which takes a struct or more than three arguments, or answers a struct>
