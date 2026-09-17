# @weight 2
# @timeout-scale 3

Compiled string literals.  A literal is read-only, so it rides in the
same segment as the code: the literals a program uses are laid end to
end after it, each NUL-terminated and each distinct text stored once,
and the entry hands compiled code the area's address the way it hands
over the runtime helper's.  `puts` writes a literal and the newline it
adds in one write, both known at compile time.  Each case below prints
what the same source prints through /usr/bin/cc, and exits as it does.

## puts

### a literal and its newline

```cc
(display (cc-exe-run "#include <stdio.h>\nint main(void) { puts(\"hi\"); return 0; }"))
```
---
```output
hi
0
```

### the same text twice, and another beside it

```cc
(display (cc-exe-run "#include <stdio.h>\nint main(void) { puts(\"a\"); puts(\"a\"); puts(\"b\"); return 0; }"))
```
---
```output
a
a
b
0
```

### it answers a number that is not negative

```cc
(display (cc-exe-run "#include <stdio.h>\nint main(void) { int n = puts(\"x\"); return n < 0; }"))
```
---
```output
x
0
```

### an empty literal is still a line

```cc
(display (cc-exe-run "#include <stdio.h>\nint main(void) { puts(\"\"); putchar(46); putchar(10); return 0; }"))
```
---
```output

.
0
```

### the escapes the lexer decoded

```cc
(display (cc-exe-run "#include <stdio.h>\nint main(void) { puts(\"a\\nb\"); puts(\"q\\\"q\"); puts(\"c\\\\d\"); return 0; }"))
```
---
```output
a
b
q"q
c\d
0
```

### from a function, in a loop, with a status of its own

```cc
(display (cc-exe-run "#include <stdio.h>\nint say(int n) { puts(\"tick\"); return n; }\nint main(void) { int i; int s = 0; for (i = 0; i < 3; i++) s = s + say(i); return s; }"))
```
---
```output
tick
tick
tick
3
```

### beside putchar

```cc
(display (cc-exe-run "#include <stdio.h>\nint main(void) { putchar(62); puts(\"go\"); return 0; }"))
```
---
```output
>go
0
```

## the refusal

### an argument that is not a literal

```cc
(display (guard (e (do (display "refused: ") (write e) ""))
  (cc-exe-run "#include <stdio.h>\nint main(void) { puts(1 ? \"a\" : \"b\"); return 0; }")))
```
---
    refused: #<err:cc cc: compile: not built yet: puts of something other than a literal>
