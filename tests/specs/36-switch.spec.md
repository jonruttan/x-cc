# @weight 2
# @timeout-scale 3

Compiled `switch`.  The value is compared with each case label in turn,
and the first to match -- else the default, wherever it sits, else
nothing -- is where the body is entered; the clauses after it run on
until a `break`, which leaves the switch.  A `continue` in a switch is
the enclosing loop's.  C promotes the value, and each label converts to
its C type.  Each case below prints what the same source prints through
/usr/bin/cc, and exits as it does, under `run` and compiled.

## switch

### a case per value, and the default for the rest

```cc
(def src "int f(int n) { switch (n) { case 1: return 10; case 2: return 20; default: return 30; } }\nint main(void) { return f(1) + f(2) + f(7); }")
(display (list (cc-run src) (cc-exe-run src)))
```
---
    (60 60)

### a clause runs on into the next until a break

```cc
(def src "int main(void) { int s = 0; int i; for (i = 0; i < 5; i++) { switch (i) { case 0: s += 1; case 1: s += 10; break; case 3: s += 100; break; default: s += 1000; } } return s % 256; }")
(display (list (cc-run src) (cc-exe-run src)))
```
---
    (73 73)

### a continue in a switch is the loop's

```cc
(def src "int main(void) { int s = 0; int i; for (i = 0; i < 6; i++) { switch (i % 3) { case 0: continue; case 1: s += i; break; } s += 100; } return s - 300; }")
(display (list (cc-run src) (cc-exe-run src)))
```
---
    (105 105)

### a default in the middle runs on into the cases after it

```cc
(def src "int g(int n) { int r = 0; switch (n) { case 1: r = 1; break; default: r = 5; case 2: r += 2; } return r; }\nint main(void) { return g(1) * 100 + g(2) * 10 + g(7); }")
(display (list (cc-run src) (cc-exe-run src)))
```
---
    (127 127)

### a char's value promotes, and a long's labels are longs

```cc
(def src "int main(void) { char c = -1; long big = 4294967296L; int r = 0; switch (c) { case -1: r = 1; break; case 255: r = 2; break; } switch (big) { case 4294967296L: r += 10; break; case 0: r += 20; } return r; }")
(display (list (cc-run src) (cc-exe-run src)))
```
---
    (11 11)

### declarations in a clause's block

```cc
(def src "int h(int n) { switch (n) { case 1: { int t = n * 2; return t; } case 2: { int u = 40; int v = 2; return u + v; } } return 0; }\nint main(void) { return h(1) + h(2) + h(3); }")
(display (list (cc-run src) (cc-exe-run src)))
```
---
    (44 44)

### a switch in a switch, in two loops

```cc
(display (cc-exe-run "#include <stdio.h>\nint main(void) { int i; int j; for (i = 0; i < 3; i++) for (j = 0; j < 2; j++) switch (i) { case 0: switch (j) { case 0: printf(\"a\"); break; default: printf(\"b\"); } break; case 1: printf(\"c\"); default: printf(\"d\"); } printf(\"\\n\"); return 0; }"))
```
---
```output
abcdcddd
0
```

## the refusals

### a case label that is not a constant

```cc
(write (guard (e (e msg)) (cc-exe-run "int main(void) { int n = 1; int m = 1; switch (n) { case m: return 1; } return 0; }")))
```
---
    "cc: compile: not built yet: a case label that is not a constant"
