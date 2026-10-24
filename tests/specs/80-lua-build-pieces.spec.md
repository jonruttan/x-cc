# @weight 1
# @timeout-scale 2

Two things a program the size of Lua asks for.  A header wrapped whole in
#ifndef G ... #endif is not read again once G is defined, which is what
keeps a header a dozen others include from being read a dozen times; a
header with anything outside its guard, one with no guard, and a guarded
one whose G was #undef'd are read every time.  And the C library's frexp,
ldexp and modf take a double and an int or a pointer together, and each
goes in its own kind of register, compiled and under `run` alike.  Each
case shows what /usr/bin/cc prints for the same source.

## Lua build pieces

### include guards: read once, and every time they do not cover the file

```cc
(def put (fn (_ path text)
  (def fd (File open path (list 'wronly 'creat 'trunc) 420))
  (File write fd text (Str8 length text))
  (File close fd)))
(put "/tmp/xcc-spec80-a.h" "#ifndef A_H\n#define A_H\nint a = 1;\n#endif\n")
(put "/tmp/xcc-spec80-b.h" "count++;\n")
(put "/tmp/xcc-spec80-c.h" "#ifndef C_H\n#define C_H\n#endif\ncount += 10;\n")
(put "/tmp/xcc-spec80-d.h" "#ifndef D_H\n#define D_H\ncount += 100;\n#endif\n")
(def units (list (pair "/tmp/xcc-spec80-main.c" "#include <stdio.h>\n#include \"xcc-spec80-a.h\"\n#include \"xcc-spec80-a.h\"\nint main(void) {\n  int count = 0;\n#include \"xcc-spec80-b.h\"\n#include \"xcc-spec80-b.h\"\n#include \"xcc-spec80-c.h\"\n#include \"xcc-spec80-c.h\"\n#include \"xcc-spec80-d.h\"\n#include \"xcc-spec80-d.h\"\n#undef D_H\n#include \"xcc-spec80-d.h\"\n  printf(\"%d\\n\", a + count);\n  return count % 256;\n}\n")))
(display (list (cc-run units) (cc-exe-run units)))
```
---
```output
223
223
(222 222)
```

### frexp, ldexp and modf, compiled and under run

```cc
(def src "#include <stdio.h>\n#include <math.h>\nint main(void) {\n  int e = 0;\n  double ip = 0;\n  double m = frexp(2.5, &e);\n  double f = modf(3.75, &ip);\n  printf(\"%g %d %g %g %g\\n\", m, e, ldexp(m, e), f, ip);\n  return e;\n}\n")
(display (list (cc-exe-run src) (cc-run src)))
```
---
```output
0.625 2 2.5 0.75 3
0.625 2 2.5 0.75 3
(2 2)
```
