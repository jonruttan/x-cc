# @weight 3

End to end: (cc-run SOURCE) executes the program -- output on stdout,
main's status (masked to 255) as the value, so a case's last line is
the exit status.  Every expectation here was taken from the same
source compiled with /usr/bin/cc and run -- the oracle.

## the basics

### return is the exit status

```cc
(display (cc-run "int main() { return 42; }"))
```
---
    42

### hello, world

```cc
(display (cc-run "#include <stdio.h>\nint main() { puts(\"hello, world\"); return 0; }"))
```
---
```output
hello, world
0
```

### printf: %d %c %s %x

```cc
(display (cc-run "#include <stdio.h>\nint main() { printf(\"%d %c %s|%x\\n\", -7, 65, \"str\", 255); return 0; }"))
```
---
```output
-7 A str|ff
0
```

### precedence, truncating division, its remainder

```cc
(display (cc-run "#include <stdio.h>\nint main() { printf(\"%d %d %d %d\\n\", 2+3*4, (2+3)*4, -7/2, -7%2); return 0; }"))
```
---
```output
14 20 -3 -1
0
```

## functions

### recursion: fib(10)

```cc
(display (cc-run "#include <stdio.h>\nint fib(int n) { if (n < 2) return n; return fib(n-1) + fib(n-2); }\nint main() { printf(\"%d\\n\", fib(10)); return 0; }"))
```
---
```output
55
0
```

### mutual recursion through a prototype

```cc
(display (cc-run "#include <stdio.h>\nint is_odd(int n);\nint is_even(int n) { if (n == 0) return 1; return is_odd(n - 1); }\nint is_odd(int n) { if (n == 0) return 0; return is_even(n - 1); }\nint main() { printf(\"%d %d\\n\", is_even(10), is_odd(7)); return 0; }"))
```
---
```output
1 1
0
```

### a global counts across calls

```cc
(display (cc-run "#include <stdio.h>\nint count = 0;\nvoid bump() { count++; }\nint main() { bump(); bump(); bump(); printf(\"%d\\n\", count); return 0; }"))
```
---
```output
3
0
```

## memory

### a pointer writes through

```cc
(display (cc-run "#include <stdio.h>\nint main() { int x = 5; int *p = &x; *p = 7; printf(\"%d\\n\", x); return 0; }"))
```
---
```output
7
0
```

### arrays decay into functions

```cc
(display (cc-run "#include <stdio.h>\nint sum(int *a, int n) { int s = 0; int i; for (i = 0; i < n; i++) s += a[i]; return s; }\nint main() { int a[5]; int i; for (i = 0; i < 5; i++) a[i] = i * i; printf(\"%d\\n\", sum(a, 5)); return 0; }"))
```
---
```output
30
0
```

### strings index and measure

```cc
(display (cc-run "#include <stdio.h>\nint len(char *s) { int n = 0; while (s[n]) n++; return n; }\nint main() { char *s = \"abcde\"; printf(\"%c %d\\n\", s[1], len(s)); return 0; }"))
```
---
```output
b 5
0
```

### malloc, size-model-independent

```cc
(display (cc-run "#include <stdio.h>\n#include <stdlib.h>\nint main() { int *a = malloc(4 * sizeof(int)); int i; for (i = 0; i < 4; i++) a[i] = i + 1; printf(\"%d\\n\", a[0] + a[3]); return 0; }"))
```
---
```output
5
0
```

## control

### sum loop

```cc
(display (cc-run "#include <stdio.h>\nint main() { int s = 0; int i; for (i = 1; i <= 10; i++) s += i; printf(\"%d\\n\", s); return 0; }"))
```
---
```output
55
0
```

### break and continue

```cc
(display (cc-run "#include <stdio.h>\nint main() { int i; for (i = 0; i < 10; i++) { if (i == 3) continue; if (i == 6) break; putchar(48 + i); } putchar(10); return 0; }"))
```
---
```output
01245
0
```

### short circuits do not run; the ternary picks

```cc
(display (cc-run "#include <stdio.h>\nint hit = 0;\nint side() { hit = 1; return 1; }\nint main() { int r = 0 && side(); printf(\"%d %d %d\\n\", r, hit, 1 ? 4 : 5); return 0; }"))
```
---
```output
0 0 4
0
```

### exit unwinds from anywhere

```cc
(display (cc-run "#include <stdlib.h>\nint main() { exit(3); }"))
```
---
    3

## operators

### shifts and bitwise

```cc
(display (cc-run "#include <stdio.h>\nint main() { printf(\"%d %d %d %d\\n\", 1 << 5, 255 >> 4, 12 & 10, 12 ^ 10); return 0; }"))
```
---
```output
32 15 8 6
0
```

### a macro is a token splice

```cc
(display (cc-run "#include <stdio.h>\n#define N 6\nint main() { printf(\"%d\\n\", N * 7); return 0; }"))
```
---
```output
42
0
```

## in anger

### bubble sort, start to finish

```cc
(display (cc-run "#include <stdio.h>\nint main() { int a[8]; int i; int j; int t;\n  for (i = 0; i < 8; i++) a[i] = (3 + 7 * i) % 8;\n  for (i = 0; i < 8; i++) for (j = 0; j + 1 < 8 - i; j++)\n    if (a[j] > a[j+1]) { t = a[j]; a[j] = a[j+1]; a[j+1] = t; }\n  for (i = 0; i < 8; i++) putchar(48 + a[i]);\n  putchar(10); return 0; }"))
```
---
```output
01234567
0
```

## the cell model, on the record

### sizeof counts cells, not bytes

Every scalar is one cell here; sizeof(int) is 1 and an array's sizeof
is its element count.  Byte-accurate sizes are the recorded pending;
programs that scale by sizeof (the malloc idiom) run unchanged.

```cc
(display (cc-run "#include <stdio.h>\nint main() { int a[5]; printf(\"%d %d\\n\", sizeof(a), sizeof(int)); return 0; }"))
```
---
```output
5 1
0
```
