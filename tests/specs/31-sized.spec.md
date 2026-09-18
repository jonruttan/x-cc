# @weight 2
# @timeout-scale 3

Compiled storage at the size of its kind.  A local, a parameter and a
global each take the size and alignment of their kind, and a value loads
at that width, extended by its sign.  Arithmetic happens in int, which is
what C's promotions make of `char` and `short`; a store narrows the value
back to its kind, and so does the value an assignment answers and the
value a `char` or `short` function returns.  `long` and the unsigned kinds
of int's width or more want arithmetic of their own, and refuse by name.
Each case below prints what the same source prints through /usr/bin/cc,
and exits as it does.

## locals

### a char keeps its low byte, and a step past its top wraps

```cc
(display (list
  (cc-exe-run "int main(void) { char c = 300; return c; }")
  (cc-exe-run "int main(void) { char c = 127; c++; return c + 200; }")
  (cc-exe-run "int main(void) { unsigned char u = 255; u++; return u; }")))
```
---
    (44 72 0)

### a short is sixteen bits either way

```cc
(display (list
  (cc-exe-run "int main(void) { short s = 40000; return s < 0; }")
  (cc-exe-run "int main(void) { unsigned short w = 65535; w = w + 1; return w; }")
  (cc-exe-run "int main(void) { int i = 70000; short s = i; return s == 4464; }")))
```
---
    (1 0 1)

### an assignment answers the value it stored

```cc
(display (cc-exe-run "int main(void) { char c; int n = (c = 200); return n == -56; }"))
```
---
    1

### every width in one frame

```cc
(display (cc-exe-run "#include <stdio.h>\nint main(void) { char a = 1; int b = 2; short c = 3; char d = 4; printf(\"%d\\n\", a + b * 10 + c * 100 + d * 1000); return 0; }"))
```
---
```output
4321
0
```

## parameters and returns

### a char parameter, and a char function's answer

```cc
(display (list
  (cc-exe-run "char half(char c) { return c / 2; }\nint main(void) { return half(-100) + 100; }")
  (cc-exe-run "char wrap(int v) { return v; }\nint main(void) { return wrap(300); }")))
```
---
    (50 44)

## globals

### a narrow global, initialized and stepped

```cc
(display (list
  (cc-exe-run "char g = 300;\nshort h = -2;\nint main(void) { g++; return g + h; }")
  (cc-exe-run "unsigned char n;\nint main(void) { int i; for (i = 0; i < 260; i++) n++; return n; }")))
```
---
    (43 4)

## the refusals

### a long and an unsigned int

```cc
(write (list
  (guard (e (e msg)) (cc-exe-run "int main(void) { long l = 1; return l; }"))
  (guard (e (e msg)) (cc-exe-run "unsigned int u;\nint main(void) { return 0; }"))))
```
---
    ("cc: compile: not built yet: the type long" "cc: compile: not built yet: the type unsigned int")

### a parameter that is a pointer

```cc
(display (guard (e (do (display "refused: ") (write e) ""))
  (cc-exe-run "int first(int *p) { return 0; }\nint main(void) { return 0; }")))
```
---
    refused: #<err:cc cc: compile: not built yet: a parameter that is not an integer>
