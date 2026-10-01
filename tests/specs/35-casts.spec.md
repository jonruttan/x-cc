# @weight 2
# @timeout-scale 3

Casts.  `(C-TYPE) e` converts e's value to C-TYPE: a narrower integer C type
keeps the low bytes and reads them with its own sign, a wider one extends
by the sign of the C type it came from, a pointer takes the address and
steps by what it now points at, and `void` keeps nothing.  The cast's
C type is the one arithmetic and comparisons see.  Each case below prints
what the same source prints through /usr/bin/cc, and exits as it does;
where both columns show, `run` and the compiled executable agree.

## integer C types

### a narrower C type keeps the low bytes, read with its own sign

```cc
(def src "int main(void) { return ((char)300 == 44) + ((unsigned char)-1 == 255) * 2 + ((short)40000 == -25536) * 4 + ((unsigned short)-1 == 65535) * 8 + ((signed char)200 < 0) * 16; }")
(display (list (cc-run src) (cc-exe-run src)))
```
---
    (31 31)

### to an unsigned int and back to an int

```cc
(def src "int main(void) { int n = -1; unsigned u = (unsigned)n; return (u > 0) + ((unsigned)n >> 28 == 15) * 2 + ((int)3000000000u < 0) * 4 + ((int)4294967296L == 0) * 8; }")
(display (list (cc-run src) (cc-exe-run src)))
```
---
    (15 15)

### the cast's C type is the one a comparison works in

```cc
(def src "int main(void) { int n = -1; return ((unsigned)n > 1) + (n < (int)1u) * 2 + ((unsigned char)n == 255) * 4; }")
(display (list (cc-run src) (cc-exe-run src)))
```
---
    (7 7)

### a cast to long widens before the multiplication does

```cc
(display (cc-exe-run "int main(void) { int x = 100000; unsigned a = 100000; long p = (long)x * x; long q = a * a; long r = (long)a * a; return (p == 10000000000) + (q == 1410065408) * 2 + (r == 10000000000) * 4; }"))
```
---
    7

### to the 64-bit C types, through printf

```cc
(display (cc-exe-run "#include <stdio.h>\nint main(void) { int n = -2; printf(\"%lu %ld %u\\n\", (unsigned long)n, (long)(unsigned)n, (unsigned)(char)-3); return 0; }"))
```
---
```output
18446744073709551614 4294967294 4294967293
0
```

## pointers

### a pointer cast changes what the pointer reads and steps by

```cc
(def src "int main(void) { int n = 0x01020304; char *c = (char *)&n; int a[3] = {10, 20, 30}; int *q = (int *)((char *)a + 4); return c[0] + c[3] * 10 + *q; }")
(display (list (cc-run src) (cc-exe-run src)))
```
---
    (34 34)

### an address to a long and back

```cc
(def src "int main(void) { int a[4]; long d = (long)&a[3] - (long)&a[0]; int *p = (int *)(long)&a[2]; *p = 9; return d + a[2]; }")
(display (list (cc-run src) (cc-exe-run src)))
```
---
    (21 21)

## void

### a cast to void keeps nothing, and its operand still runs

```cc
(def src "int main(void) { int n = 3; (void)n; (void)(n = 5); return n; }")
(display (list (cc-run src) (cc-exe-run src)))
```
---
    (5 5)

## globals

### a global's initializer through a cast

```cc
(display (cc-exe-run "char c = (char)300;\nint u = (unsigned char)-1;\nlong l = (int)4294967295u;\nunsigned long m = (unsigned long)-1 >> 60;\nint main(void) { return (c == 44) + (u == 255) * 2 + (l == -1) * 4 + (m == 15) * 8; }"))
```
---
    15

## pointers to functions

### a function's name cast to a pointer to one, then called through it

```cc
(def src "int f(void) { return 1; }\nint main(void) { int (*g)(void) = (int (*)(void))f; return g(); }")
(write (list (cc-run src) (cc-exe-run src)))
```
---
    (1 1)
