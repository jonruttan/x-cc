# @weight 2
# @timeout-scale 3

Compiled frames past four kilobytes.  A frame is laid out low to high:
the slot the runtime writes a byte from, the scalars -- parameters and
locals that are not arrays or structs -- where a load reaches them,
printf's area, then the arrays and structs, which are reached through
their address from any distance, and at the top the arguments the caller
stored there, which the prologue copies down.  The prologue takes the
frame off x20 in steps an immediate holds, up to a megabyte a frame, out
of a four-megabyte region.  Each case below prints what the same source
prints through /usr/bin/cc, and exits as it does; where both columns
show, `run` and the compiled executable agree.

## frames

### twenty thousand chars, and a local declared after them

```cc
(def src "int main(void) { char buf[20000]; buf[0] = 3; buf[19999] = 4; int s = buf[0] * 10 + buf[19999]; return s; }")
(display (list (cc-run src) (cc-exe-run src)))
```
---
    (34 34)

### every one of them written and read back

Forty thousand turns of a loop are past what `run` does within its
allocation ceiling, so this one is compiled only.

```cc
(display (cc-exe-run "int main(void) { char buf[20000]; int i; for (i = 0; i < 20000; i++) buf[i] = i % 7; int s = 0; for (i = 0; i < 20000; i++) s += buf[i]; return s % 256; }"))
```
---
    93

### a char after twelve kilobytes of ints

```cc
(def src "int main(void) { int a[3000]; char c = 'z'; a[2999] = 5; return c + a[2999]; }")
(display (list (cc-run src) (cc-exe-run src)))
```
---
    (127 127)

### four kilobytes a call, a hundred calls deep

`run`'s memory is smaller than the hundred frames, so this one is
compiled only.

```cc
(display (cc-exe-run "int f(int n) { int big[1000]; big[999] = n; if (n == 0) return 0; return big[999] + f(n - 1); }\nint main(void) { return f(100) % 256; }"))
```
---
    186

### printf and putchar past a big array

```cc
(def src "#include <stdio.h>\nint main(void) { char buf[10000]; int i = 42; char big[5000]; buf[9999] = 1; big[4999] = 'k'; printf(\"%d %d %d\\n\", i, (int)sizeof(buf), buf[9999]); putchar(big[4999]); putchar(10); return 0; }")
(display (list (cc-run src) (cc-exe-run src)))
```
---
```output
42 10000 1
k
42 10000 1
k
(0 0)
```

### a fifth argument and a struct argument, under a big frame

```cc
(def src "struct P { int x; int y; };\nint g(int a, int b, int c, int d, char e) { char big[40000]; big[0] = e; return big[0] + a + d; }\nint h(struct P p) { int arr[9000]; arr[8999] = p.y; return p.x + arr[8999]; }\nint main(void) { struct P p = {3, 4}; return g(1, 2, 3, 4, 'A') + h(p); }")
(display (list (cc-run src) (cc-exe-run src)))
```
---
    (77 77)

### a struct answered from under fifty kilobytes

```cc
(def src "struct P { int x; int y; };\nstruct P mk(int v) { char pad[50000]; pad[0] = 1; struct P r; r.x = v; r.y = pad[0]; return r; }\nint main(void) { struct P q = mk(9); return q.x * 10 + q.y; }")
(display (list (cc-run src) (cc-exe-run src)))
```
---
    (91 91)

## the refusals

### a frame past a megabyte

```cc
(write (guard (e (e msg)) (cc-exe-run "int main(void) { char buf[2000000]; buf[0] = 1; return buf[0]; }")))
```
---
    "cc: compile: not built yet: a frame past a megabyte"
