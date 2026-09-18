# @weight 2
# @timeout-scale 3

Compiled printf.  The format is a literal, so it is laid out at compile
time: it splits into runs of text and conversions, a `%s`'s literal and a
`%%` join the text around them, and what is left for run time is a write
per run of text, one per `%c`, and a conversion to decimal per `%d`, built
in a buffer in the frame.  Every argument is evaluated before anything is
written, as a call's are, and printf answers the count of bytes it wrote.
Each case below prints what the same source prints through /usr/bin/cc,
and exits as it does.

## printf

### text alone

```cc
(display (cc-exe-run "#include <stdio.h>\nint main(void) { printf(\"hello\\n\"); return 0; }"))
```
---
```output
hello
0
```

### a number

```cc
(display (cc-exe-run "#include <stdio.h>\nint main(void) { printf(\"%d\\n\", 42); return 0; }"))
```
---
```output
42
0
```

### zero, a negative, and both ends of int

```cc
(display (cc-exe-run "#include <stdio.h>\nint main(void) { printf(\"%d %d %d %d\\n\", 0, -7, 2147483647, -2147483647 - 1); return 0; }"))
```
---
```output
0 -7 2147483647 -2147483648
0
```

### characters and a percent sign

```cc
(display (cc-exe-run "#include <stdio.h>\nint main(void) { printf(\"%c%c %d%%\\n\", 72, 105, 50); return 0; }"))
```
---
```output
Hi 50%
0
```

### literals for %s

```cc
(display (cc-exe-run "#include <stdio.h>\nint main(void) { printf(\"%s, %s!\\n\", \"hello\", \"world\"); return 0; }"))
```
---
```output
hello, world!
0
```

### it answers the count of bytes it wrote

```cc
(display (cc-exe-run "#include <stdio.h>\nint main(void) { int n = printf(\"abc%d\\n\", 123); return n; }"))
```
---
```output
abc123
7
```

### in a loop, over a global

```cc
(display (cc-exe-run "#include <stdio.h>\nint total;\nint main(void) { int i; for (i = 1; i <= 3; i++) { total = total + i; printf(\"%d: %d\\n\", i, total); } return 0; }"))
```
---
```output
1: 1
2: 3
3: 6
0
```

### an argument runs before anything is written

```cc
(display (cc-exe-run "#include <stdio.h>\nint f(void) { putchar(65); return 1; }\nint main(void) { printf(\"<%d>\\n\", f()); return 0; }"))
```
---
```output
A<1>
0
```

### a printf as another's argument, in the same frame

```cc
(display (cc-exe-run "#include <stdio.h>\nint main(void) { printf(\"%d\\n\", printf(\"hi \")); return 0; }"))
```
---
```output
hi 3
0
```

### beside a recursive call

```cc
(display (cc-exe-run "#include <stdio.h>\nint fact(int n) { if (n < 2) return 1; return n * fact(n - 1); }\nint main(void) { int i; for (i = 1; i <= 5; i++) printf(\"%d! = %d\\n\", i, fact(i)); return 0; }"))
```
---
```output
1! = 1
2! = 2
3! = 6
4! = 24
5! = 120
0
```

## the refusals

### a conversion that is not built yet

```cc
(display (guard (e (do (display "refused: ") (write e) ""))
  (cc-exe-run "#include <stdio.h>\nint main(void) { printf(\"%x\\n\", 255); return 0; }")))
```
---
    refused: #<err:cc cc: compile: not built yet: printf's %x>

### a format that is not a literal

```cc
(display (guard (e (do (display "refused: ") (write e) ""))
  (cc-exe-run "#include <stdio.h>\nint main(void) { printf(1 ? \"a\\n\" : \"b\\n\"); return 0; }")))
```
---
    refused: #<err:cc cc: compile: not built yet: printf of a format that is not a literal>

### fewer arguments than conversions

```cc
(display (guard (e (do (display "refused: ") (write e) ""))
  (cc-exe-run "#include <stdio.h>\nint main(void) { printf(\"%d %d\\n\", 1); return 0; }")))
```
---
    refused: #<err:cc cc: compile: not built yet: printf with fewer arguments than conversions>
