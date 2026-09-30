# @weight 2
# @timeout-scale 3

Compiled calls of more than four arguments.  The first four travel in
x0, x1, x2 and x8; the caller stores the rest just below its own frame's
base, which is where the frame the callee takes next has its top, so the
callee finds them there as parameters.  Every argument is worked out
before any is stored, so a call inside an argument cannot overwrite
them.  Each case below prints what the same source prints through
/usr/bin/cc, and exits as it does; where both columns show, `run` and the
compiled executable agree.

## arguments

### six ints, each weighed by its place

```cc
(def src "int sum6(int a, int b, int c, int d, int e, int f) { return a + 2*b + 3*c + 4*d + 5*e + 6*f; }\nint main(void) { return sum6(1, 2, 3, 4, 5, 6); }")
(display (list (cc-run src) (cc-exe-run src)))
```
---
    (91 91)

### a parameter past the fourth takes its own C type

```cc
(display (cc-exe-run "long f(char a, short b, int c, long d, char e, long f2, unsigned char g) { return a + b + c + d + e + f2 + g; }\nint main(void) { return (f(1, 2, 3, 4, 511, 10000000000L, 511) == 10000000264L) + (f(0, 0, 0, 0, -1, 0, -1) == 254) * 2; }"))
```
---
    3

### five arguments through ten calls deep, rotated each time

```cc
(def src "int ack5(int n, int a, int b, int c, int d) { if (n == 0) return a * 1000 + b * 100 + c * 10 + d; return ack5(n - 1, b, c, d, a + 1); }\nint main(void) { return ack5(10, 1, 2, 3, 4) % 256; }")
(display (list (cc-run src) (cc-exe-run src)))
```
---
    (13 13)

### a call in the fifth argument

```cc
(def src "int g5(int a, int b, int c, int d, int e) { return a * 10000 + b * 1000 + c * 100 + d * 10 + e; }\nint main(void) { return g5(1, 2, 3, 4, g5(0, 0, 0, 0, 5)) % 256; }")
(display (list (cc-run src) (cc-exe-run src)))
```
---
    (57 57)

### the callee assigns to its fifth and sixth

```cc
(display (cc-exe-run "#include <stdio.h>\nint h(int a, int b, int c, int d, int e, int f) { e = e + f; f = 0; return a + b + c + d + e + f; }\nint main(void) { printf(\"%d\\n\", h(1, 1, 1, 1, 20, 30)); return 0; }"))
```
---
```output
54
0
```
