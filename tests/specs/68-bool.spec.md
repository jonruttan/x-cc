# @weight 1
# @timeout-scale 2

`_Bool`, C99's: a byte that holds 0 or 1.  Any value converted to one --
an integer, a pointer, a real value, stored, initialized, passed, returned
or cast -- is 1 when it is not 0.  The case runs under `run`, then
compiled, and shows both outputs and both statuses; the expectation is
what the same source prints through /usr/bin/cc.

## _Bool

### stores, initializers, arguments, returns, casts, a field, an array and globals

```cc
(def src "#include <stdio.h>\n_Bool g = 3, h = 0;\n_Bool to_b(int v) { return v; }\nint count(_Bool b) { return b + 10; }\nint main(void) {\n  _Bool a = 5, b = 0, c = 0.5, d = -0.0;\n  char *p = \"x\"; _Bool e = p;\n  _Bool arr[3] = {2, 0, 7};\n  struct s { _Bool f; int n; } s;\n  s.f = 256;\n  printf(\"%d %d %d %d %d\\n\", a, b, c, d, e);\n  printf(\"%d %d %d %d\\n\", arr[0], arr[1], arr[2], (int)sizeof(_Bool));\n  printf(\"%d %d %d %d %d\\n\", s.f, to_b(-3), count(9), g, h);\n  a = a + 1;\n  printf(\"%d %d %d\\n\", a, (_Bool)256, !a);\n  return a + to_b(0);\n}\n")
(display (list (cc-run src) (cc-exe-run src)))
```
---
```output
1 0 1 0 1
1 0 1 1
1 1 11 1 0
1 1 0
1 0 1 0 1
1 0 1 1
1 1 11 1 0
1 1 0
(1 1)
```
