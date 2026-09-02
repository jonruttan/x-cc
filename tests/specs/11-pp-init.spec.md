# @weight 2

Conditional directives, and initializer lists.  The preprocessor's
walk carries a stack of conditional flags -- a line lives when every
open conditional is true; an inactive region still tracks its nesting
so its #endif pairs, and its defines are ignored.  An initializer list
lays values into cells by kind: an array's elements or a struct's
fields in order, nested lists recursing, missing trailing items zero;
`[]` takes its size from the list, or from a string's bytes plus NUL.
Every expectation is an oracle row from /usr/bin/cc.

## conditionals

### ifdef, else, ifndef, undef, if 0, defined

```cc
(display (cc-run "#include <stdio.h>\n#define DEBUG\n#define LEVEL 3\n#ifdef DEBUG\n#define TAG 1\n#else\n#define TAG 2\n#endif\n#ifndef MISSING\n#define M 10\n#endif\n#undef DEBUG\n#ifdef DEBUG\n#define AFTER 100\n#else\n#define AFTER 200\n#endif\n#if 0\n#define DEAD 1\nint broken syntax here\n#endif\n#if defined(LEVEL)\n#define HASLEVEL 1\n#else\n#define HASLEVEL 0\n#endif\n#if !defined(NOPE)\n#define NONOPE 1\n#endif\nint main() { printf(\"%d %d %d %d %d\\n\", TAG, M, AFTER, HASLEVEL, NONOPE); return 0; }"))
```
---
```output
1 10 200 1 1
0
```

### a nested conditional inside a dead region still pairs

```cc
(display (cc-run "#include <stdio.h>\n#ifdef NOPE\n#ifdef ALSO\n#define A 1\n#else\n#define A 2\n#endif\n#else\n#define A 3\n#endif\nint main() { printf(\"%d\\n\", A); return 0; }"))
```
---
```output
3
0
```

## initializer lists

### arrays: sized, unsized, partial (zero-filled), global

```cc
(display (cc-run "#include <stdio.h>\nint g[4] = {1, 2, 3};\nint main() { int a[] = {5, 6, 7, 8}; int c[3] = {42}; int i; int s; s = 0; for (i = 0; i < 4; i++) s = s + a[i]; printf(\"%d %d %d %d %d\\n\", s, g[2], g[3], c[0], c[2]); return 0; }"))
```
---
```output
26 3 0 42 0
0
```

### structs and arrays of structs, nested lists

```cc
(display (cc-run "#include <stdio.h>\nstruct P { int x; int y; };\nstruct P pts[2] = { {1, 2}, {3, 4} };\nint main() { struct P p = {9, 10}; printf(\"%d %d\\n\", pts[1].y, p.x + p.y); return 0; }"))
```
---
```output
4 19
0
```

### a char array from a string: its bytes and the NUL

```cc
(display (cc-run "#include <stdio.h>\nint main() { char w[] = \"hi\"; char v[8] = \"ab\"; printf(\"%d %d %d %d\\n\", w[1], w[2], v[1], v[2]); return 0; }"))
```
---
```output
105 0 98 0
0
```

## the refusals

### #elif stays pending

```cc
(display (guard (e (do (display "refused: ") (write e) "")) (cc-run "#ifdef X\n#elif 1\n#endif\nint main() { return 0; }")))
```
---
    refused: #<err:cc cc: #elif is not built yet>

### an initialized local array keeps its function interpreted

```cc
(display (cc-build-run "#include <stdio.h>\nint sum3(int n) { int a[3] = {1, 2, 3}; int s = 0; int i; for (i = 0; i < 3; i++) s = s + a[i] * n; return s; }\nint main() { printf(\"%d\\n\", sum3(2)); return 0; }"))
```
---
```output
interp sum3
interp main
12
0
```
