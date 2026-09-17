# @weight 3

Pointers.  The program's memory is one raw buffer (a string's bytes),
addressed by byte offset, so a pointer is an
offset.  A function reads and writes a caller's array through a
pointer parameter, and every read inside a loop sees exactly the
stores C puts before it.  Every expectation is an
oracle row from /usr/bin/cc.

## a caller's array

### a sum over main's array

```cc
(display (cc-run "#include <stdio.h>\nint sum(int *a, int n) { int s = 0; int i; for (i = 0; i < n; i++) s = s + a[i]; return s; }\nint main() { int a[5]; int i; for (i = 0; i < 5; i++) a[i] = i * i; printf(\"%d\\n\", sum(a, 5)); return 0; }"))
```
---
```output
30
0
```

### a fill that main reads back

```cc
(display (cc-run "#include <stdio.h>\nint fill(int *a, int n) { int i; for (i = 0; i < n; i++) a[i] = i * i; return n; }\nint main() { int b[5]; int i; fill(b, 5); for (i = 0; i < 5; i++) printf(\"%d \", b[i]); putchar(10); return 0; }"))
```
---
```output
0 1 4 9 16 
0
```

## the flagship

### bubble sort on main's array

The swap is the program-order test: `t = a[j]; a[j] = a[j+1];
a[j+1] = t;` -- two loads captured before either store.

```cc
(display (cc-run "#include <stdio.h>\nint sort(int *a, int n) { int i; int j; for (i = 0; i < n; i++) { for (j = 0; j + 1 < n - i; j++) { if (a[j] > a[j+1]) { int t; t = a[j]; a[j] = a[j+1]; a[j+1] = t; } } } return 0; }\nint main() { int a[8]; int i; for (i = 0; i < 8; i++) a[i] = (3 + 7 * i) % 8; sort(a, 8); for (i = 0; i < 8; i++) putchar(48 + a[i]); putchar(10); return 0; }"))
```
---
```output
01234567
0
```

## a local array

### store then load of the same element in one iteration

```cc
(display (cc-run "#include <stdio.h>\nint locarr(int n) { int a[32]; int i; int s = 0; for (i = 0; i < n; i++) { a[i] = i * 3; s = s + a[i]; } return s; }\nint main() { printf(\"%d\\n\", locarr(5)); return 0; }"))
```
---
```output
30
0
```

## stores with an exit

### a store after an early return

```cc
(display (cc-run "#include <stdio.h>\nint findz(int *a, int n) { int i; for (i = 0; i < n; i++) { if (a[i] == 0) return i; a[i] = 0; } return -1; }\nint main() { int b[5]; int i; for (i = 0; i < 5; i++) b[i] = i * i; printf(\"%d\\n\", findz(b, 5)); return 0; }"))
```
---
```output
0
0
```

### two sequential loops are not the shape yet

The sieve fills its table in one loop and sieves in another; the
split takes one loop -- the recorded pending.

```cc
(display (cc-run "#include <stdio.h>\nint sieve(int n) { int p[200]; int c = 0; int i; int j; for (i = 0; i < 200; i++) p[i] = 0; for (i = 2; i <= n; i++) { if (p[i] == 0) { c = c + 1; for (j = i * i; j <= n; j = j + i) p[j] = 1; } } return c; }\nint main() { printf(\"%d %d\\n\", sieve(100), sieve(30)); return 0; }"))
```
---
```output
25 10
0
```

## a sweep

### a sum over every prefix

```cc
(display (cc-run "#include <stdio.h>\nint sum(int *a, int n) { int s = 0; int i; for (i = 0; i < n; i++) s = s + a[i]; return s; }\nint main() { int a[8]; int i; for (i = 0; i < 8; i++) a[i] = i + 1; for (i = 0; i <= 8; i++) printf(\"%d \", sum(a, i)); putchar(10); return 0; }"))
```
---
```output
0 1 3 6 10 15 21 28 36 
0
```
