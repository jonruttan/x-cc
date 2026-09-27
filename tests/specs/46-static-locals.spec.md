# @weight 2
# @timeout-scale 3

Static locals.  A local declared `static` is kept once for the program,
not made again per call, and its initializer runs once.  Compiled, it has
room in the data laid out with the globals, and its name is its
function's alone; under `run` it is taken from the heap the first time
its declaration is reached.  Each case runs the program under `run`, then
compiled, and shows both statuses, and both outputs where it prints;
every expectation is what the same source prints through /usr/bin/cc.

## static locals

### a counter kept across calls

```cc
(def src "int counter(void) { static int n = 0; n++; return n; }\nint main(void) { counter(); counter(); return counter(); }")
(display (list (cc-run src) (cc-exe-run src)))
```
---
    (3 3)

### a static array with its initializer, and a static index

```cc
(def src "int next(void) { static int buf[4] = {10, 20, 30, 40}; static int i = 0; return buf[i++ % 4]; }\nint main(void) { int s = 0; int k; for (k = 0; k < 6; k++) s += next(); return s; }")
(display (list (cc-run src) (cc-exe-run src)))
```
---
    (130 130)

### two functions' statics of one name are two

```cc
(def src "int a(void) { static int n = 100; return ++n; }\nint b(void) { static int n = 0; return ++n; }\nint main(void) { a(); b(); b(); return (a() - 100) * 10 + b(); }")
(display (list (cc-run src) (cc-exe-run src)))
```
---
    (23 23)

### one static across a recursion

```cc
(def src "int depth(int n) { static int calls = 0; calls++; if (n > 0) return depth(n - 1); return calls; }\nint main(void) { return depth(5); }")
(display (list (cc-run src) (cc-exe-run src)))
```
---
    (6 6)

### a static buffer outlives the call that fills it

```cc
(def src "#include <stdio.h>\nchar *name(void) { static char buf[8]; buf[0] = 'o'; buf[1] = 'k'; buf[2] = 0; return buf; }\nint main(void) { puts(name()); return name()[1]; }")
(display (list (cc-run src) (cc-exe-run src)))
```
---
```output
ok
ok
(107 107)
```
