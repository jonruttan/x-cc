# @weight 2

A call through a function pointer, lowered.  A function value is an id
handed out in program order before anything compiles, so the id of
every target is known while the code that tests it is generated: the
dispatch is a chain of tests on the value, each arm calling that
function's door, and a value matching none falls through to the lane's
`(%call HEAD ...)` (x-lang#604), which refuses at run time exactly as
the interpreter does.

The head is tested once per arm, so it has to be free of effects and
cheap to repeat -- a parameter, a read, or arithmetic over those.  Any
function whose address the program takes must have a door, since a
pointer could name any of them and the lane has no way back into the
interpreter.

Every expectation is an oracle row from /usr/bin/cc; the native twins
print what the interpreter prints.

## dispatch on a function value

### through a parameter, called twice, and through a global table

```cc
(display (cc-build-run "#include <stdio.h>\nint sq(int n) { return n * n; }\nint dbl(int n) { return n * 2; }\nint add(int a, int b) { return a + b; }\nint sub(int a, int b) { return a - b; }\nint twice(int (*f)(int), int x) { return f(f(x)); }\nint apply2(int (*f)(int, int), int a, int b) { return f(a, b); }\nint (*ops[2])(int, int) = { add, sub };\nint viatable(int i, int a, int b) { return ops[i](a, b); }\nint main() { printf(\"%d %d %d %d %d\\n\", twice(sq, 3), twice(dbl, 3), apply2(add, 7, 2), apply2(sub, 7, 2), viatable(1, 10, 4)); return 0; }"))
```
---
```output
native sq
native dbl
native add
native sub
native twice
native apply2
native viatable
interp main
81 12 9 5 6
0
```

## the refusal

### an address-taken function with no door keeps its callers interpreted

`bad` has an initialized local array and stays interpreted, so it has
no door.  A pointer could name it, so every call through a value in
this program stays interpreted too -- including the one that names
`good`.

```cc
(display (cc-build-run "#include <stdio.h>\nint good(int n) { return n + 1; }\nint bad(int n) { int t[2] = {1, 2}; return t[1] + n; }\nint call1(int (*f)(int), int x) { return f(x); }\nint main() { int (*p)(int) = bad; printf(\"%d %d\\n\", call1(good, 5), call1(p, 5)); return 0; }"))
```
---
```output
native good
interp bad
interp call1
interp main
6 7
0
```
