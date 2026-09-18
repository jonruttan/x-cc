# @weight 2
# @timeout-scale 3

Compiled output.  `putchar` is the one piece of runtime compiled code
calls: the entry writes out a helper that makes the write system call
and hands compiled code its address, since neither the call nor a
program-counter-relative address has a portable mnemonic.  Each case
below prints what the same source prints through /usr/bin/cc, and
exits as it does.

## putchar

### one character

```cc
(display (cc-exe-run "#include <stdio.h>\nint main(void) { putchar(65); putchar(10); return 0; }"))
```
---
```output
A
0
```

### a loop of characters, and a status of its own

```cc
(display (cc-exe-run "#include <stdio.h>\nint main(void) { int i; for (i = 0; i < 5; i++) putchar(48 + i); putchar(10); return 3; }"))
```
---
```output
01234
3
```

### it answers the character it wrote

```cc
(display (cc-exe-run "#include <stdio.h>\nint emit(int c) { return putchar(c); }\nint main(void) { int n = emit(66); putchar(10); return n - 66; }"))
```
---
```output
B
0
```

### a recursive print of a number's digits

```cc
(display (cc-exe-run "#include <stdio.h>\nint digits(int n) { if (n > 9) digits(n / 10); putchar(48 + n % 10); return n; }\nint main(void) { digits(31415); putchar(10); return 0; }"))
```
---
```output
31415
0
```

## the refusal

### the rest of the runtime is not compiled yet

```cc
(display (guard (e (do (display "refused: ") (write e) ""))
  (cc-exe-run "#include <stdlib.h>\nint main(void) { exit(3); }")))
```
---
    refused: #<err:cc cc: compile: not built yet: a call to exit>
