# @weight 1
# @timeout-scale 2

Forms Lua's sources use.  A line ending in a backslash goes on with
the next, so a macro body runs over several lines.  A declarator's name
may stand in parentheses, `int (twice) (int x)`, which keeps a
function-like macro of that name from expanding there; the name is the
same function's.  Each case runs under `run`, then compiled, and shows
both outputs and both statuses; the expectation is what the same source
prints through /usr/bin/cc.

## Lua header forms

### spliced lines and a parenthesized name

```cc
(def src "#include <stdio.h>\n#define ADD(a, b) \\\n  ((a) + \\\n   (b))\nextern int (twice) (int x);\nconst char *(name) (void);\n#define twice(x) (-(x))\nint (twice) (int x) { return x * 2; }\nconst char *(name) (void) { return \"lua\"; }\nint main(void) {\n  printf(\"%d %d %d %s\\n\", ADD(2, 3), (twice)(4), twice(4), name());\n  return ADD(1, 2);\n}\n")
(display (list (cc-run src) (cc-exe-run src)))
```
---
```output
5 8 -4 lua
5 8 -4 lua
(3 3)
```

### casts in constant expressions, an extern array nothing defines, offsetof and BUFSIZ

A cast to an integer type in a constant expression wraps to that type's
width.  An array declared extern without a size, never defined, is a
declaration only.

```cc
(def src "#include <stdio.h>\n#include <stddef.h>\nextern const char ident[];\nstruct pt { char tag; int x; double y; };\nenum { WRAP = (unsigned char)300, NEG = (signed char)200, ONE = (_Bool)7 };\nstatic char buf[(int)(4 * sizeof(int))];\nint main(void) {\n  printf(\"%d %d %d %d\\n\", (int)sizeof buf, WRAP, NEG, ONE);\n  printf(\"%d %d %d\\n\", (int)offsetof(struct pt, x), (int)offsetof(struct pt, y), BUFSIZ > 0);\n  return WRAP;\n}\n")
(display (list (cc-run src) (cc-exe-run src)))
```
---
```output
16 44 -56 1
4 8 1
16 44 -56 1
4 8 1
(44 44)
```
