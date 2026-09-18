# @weight 2
# @timeout-scale 3

Compiled globals.  A global is an eight-byte slot at the front of the data
segment, the way a local is one in the frame, and its initializer -- a
constant, as C asks -- is laid down there at compile time, so the program
starts with it in place.  The entry hands compiled code the data's address
in x22, and every global is an offset from it.  Each case below prints what
the same source prints through /usr/bin/cc, and exits as it does.

## globals

### one with an initializer

```cc
(display (cc-exe-run "int n = 7;\nint main(void) { return n; }"))
```
---
    7

### one without starts at zero, and every function sees the same slot

```cc
(display (cc-exe-run "int count;\nint bump(void) { count++; return count; }\nint main(void) { bump(); bump(); bump(); return count; }"))
```
---
    3

### several, one negative and one a constant expression

```cc
(display (cc-exe-run "int a = 2;\nint b = -3;\nint c = 4 * 5 + 1;\nint main(void) { return a * b + c; }"))
```
---
    15

### one added up through a call, in a loop, then printed

```cc
(display (cc-exe-run "#include <stdio.h>\nint total = 0;\nint add(int v) { total = total + v; return total; }\nint main(void) { int i; for (i = 1; i <= 4; i++) add(i); putchar(48 + total); putchar(10); return 0; }"))
```
---
```output
:
0
```

### a local of the name wins

```cc
(display (cc-exe-run "int n = 5;\nint main(void) { int n = 2; return n; }"))
```
---
    2

### one driving a loop, beside the literals it shares the segment with

```cc
(display (cc-exe-run "#include <stdio.h>\nint seen = 0;\nint main(void) { while (seen < 3) { puts(\"tick\"); seen++; } return seen; }"))
```
---
```output
tick
tick
tick
3
```

## the refusals

### a global that is not an integer

```cc
(display (guard (e (do (display "refused: ") (write e) ""))
  (cc-exe-run "int v[3];\nint main(void) { return 0; }")))
```
---
    refused: #<err:cc cc: compile: not built yet: a global that is not an integer: v>

### one initialized by something that is not a constant

```cc
(display (guard (e (do (display "refused: ") (write e) ""))
  (cc-exe-run "int one(void) { return 1; }\nint g = one();\nint main(void) { return g; }")))
```
---
    refused: #<err:cc cc: compile: not built yet: a global initialized by something other than a constant>
