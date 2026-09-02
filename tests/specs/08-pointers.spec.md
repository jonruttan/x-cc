# @weight 3

Pointers in the compile-asm eligible class.  The program's memory is
ONE raw buffer (a string's bytes) that the interpreter addresses
through ptr ref-word/set-word! and the native twins through the lane's
%mem-ref-at / %mem-set-at! with the buffer's data address baked in --
so a pointer is a cell index on both sides and arrays cross the
native/interpreted boundary for free.  In a loop body, memory reads
are pulled out into load temps at their evaluation point and stores
are effects, emitted in program order before the tail, so every read
sees exactly the stores C puts before it.  Every expectation is an
oracle row from /usr/bin/cc.

## arrays cross the boundary

### a native sum over main's array

```cc
(display (cc-build-run "#include <stdio.h>\nint sum(int *a, int n) { int s = 0; int i; for (i = 0; i < n; i++) s = s + a[i]; return s; }\nint main() { int a[5]; int i; for (i = 0; i < 5; i++) a[i] = i * i; printf(\"%d\\n\", sum(a, 5)); return 0; }"))
```
---
```output
native sum
interp main
30
0
```

### a native fill that main reads back

```cc
(display (cc-build-run "#include <stdio.h>\nint fill(int *a, int n) { int i; for (i = 0; i < n; i++) a[i] = i * i; return n; }\nint main() { int b[5]; int i; fill(b, 5); for (i = 0; i < 5; i++) printf(\"%d \", b[i]); putchar(10); return 0; }"))
```
---
```output
native fill
interp main
0 1 4 9 16 
0
```

## the flagship

### bubble sort, native, on main's array

The swap is the program-order test: `t = a[j]; a[j] = a[j+1];
a[j+1] = t;` -- two loads captured before either store.

```cc
(display (cc-build-run "#include <stdio.h>\nint sort(int *a, int n) { int i; int j; for (i = 0; i < n; i++) { for (j = 0; j + 1 < n - i; j++) { if (a[j] > a[j+1]) { int t; t = a[j]; a[j] = a[j+1]; a[j+1] = t; } } } return 0; }\nint main() { int a[8]; int i; for (i = 0; i < 8; i++) a[i] = (3 + 7 * i) % 8; sort(a, 8); for (i = 0; i < 8; i++) putchar(48 + a[i]); putchar(10); return 0; }"))
```
---
```output
native sort
interp main
01234567
0
```

## a local array in the native scratch region

### store then load of the same cell in one iteration

```cc
(display (cc-build-run "#include <stdio.h>\nint locarr(int n) { int a[32]; int i; int s = 0; for (i = 0; i < n; i++) { a[i] = i * 3; s = s + a[i]; } return s; }\nint main() { printf(\"%d\\n\", locarr(5)); return 0; }"))
```
---
```output
native locarr
interp main
30
0
```

## stores with an exit

### a store after an early return lowers as the stream (14-lowering has the story)

```cc
(display (cc-build-run "#include <stdio.h>\nint findz(int *a, int n) { int i; for (i = 0; i < n; i++) { if (a[i] == 0) return i; a[i] = 0; } return -1; }\nint main() { int b[5]; int i; for (i = 0; i < 5; i++) b[i] = i * i; printf(\"%d\\n\", findz(b, 5)); return 0; }"))
```
---
```output
native findz
interp main
0
0
```

### two sequential loops are not the shape yet

The sieve fills its table in one loop and sieves in another; the
split takes one loop -- the recorded pending.

```cc
(display (cc-build-run "#include <stdio.h>\nint sieve(int n) { int p[200]; int c = 0; int i; int j; for (i = 0; i < 200; i++) p[i] = 0; for (i = 2; i <= n; i++) { if (p[i] == 0) { c = c + 1; for (j = i * i; j <= n; j = j + i) p[j] = 1; } } return c; }\nint main() { printf(\"%d %d\\n\", sieve(100), sieve(30)); return 0; }"))
```
---
```output
interp sieve
interp main
25 10
0
```

## twin agreement across a sweep

### the native sum agrees with its interpreted twin on every prefix

```cc
(display (cc-build-run "#include <stdio.h>\nint sum(int *a, int n) { int s = 0; int i; for (i = 0; i < n; i++) s = s + a[i]; return s; }\nint main() { int a[8]; int i; for (i = 0; i < 8; i++) a[i] = i + 1; for (i = 0; i <= 8; i++) printf(\"%d \", sum(a, i)); putchar(10); return 0; }"))
```
---
```output
native sum
interp main
0 1 3 6 10 15 21 28 36 
0
```
