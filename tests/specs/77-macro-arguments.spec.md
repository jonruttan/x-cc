# @weight 1
# @timeout-scale 2

A macro's arguments are expanded before they go into its body, as C's
preprocessor does them, so a call nested in its own argument expands:
`next(next(&a))`.  Beside # and ## an argument goes in as written: STR(N)
spells N, XSTR(N) spells 7, and CAT(N, _value) pastes N_value.  The case
runs under `run`, then compiled, and shows both outputs and both
statuses; the expectation is what the same source prints through
/usr/bin/cc.

## macro arguments

### expanded before substitution, as written beside # and ##

```cc
(def src "#include <stdio.h>\nstruct node { int v; struct node *next; };\n#define next(p) ((p)->next)\n#define val(p) ((p)->v)\n#define TWICE(x) ((x) * 2)\n#define STR(x) #x\n#define XSTR(x) STR(x)\n#define CAT(a, b) a ## b\n#define N 7\nint main(void) {\n  struct node c = { 3, 0 }, b = { 2, &c }, a = { 1, &b };\n  int var7 = 70, N_value = 5;\n  printf(\"%d %d %d\\n\", val(next(next(&a))), val(next(&a)), TWICE(TWICE(N)));\n  printf(\"%s %s %d %d\\n\", STR(N), XSTR(N), CAT(var, 7), CAT(N, _value));\n  return val(next(next(&a)));\n}\n")
(display (list (cc-run src) (cc-exe-run src)))
```
---
```output
3 2 28
N 7 70 5
3 2 28
N 7 70 5
(3 3)
```

### an expansion read again with what follows it

A macro's expansion that ends in a function-like macro's name calls it
with the ( that follows the expansion: `#define again twice`, then
again(3), as Lua's `#define setobj2n setobj` is used.  A macro that names
itself is still left alone.

```cc
(def src "#include <stdio.h>\n#define twice(x) ((x) * 2)\n#define again twice\n#define pick(n) twice\n#define h h\nint h(int a) { return a + 100; }\nint main(void) {\n  printf(\"%d %d %d\\n\", again(3), pick(0)(5), h(1));\n  return again(2);\n}\n")
(display (list (cc-run src) (cc-exe-run src)))
```
---
```output
6 10 101
6 10 101
(4 4)
```
