# @weight 2

Enums, unions, function pointers, and #elif.  An enumerator is a
constant folded at parse time (the type is a scalar); a union is a
struct whose fields all sit at offset 0, sized by its widest field; a
function's name used as a value is an id above every cell address,
and a call through a value -- a variable, `(*f)`, an array element, a
struct field -- maps the id back to the function and dispatches as a
named call would, native twin first.  `#elif` continues a conditional
whose earlier branches did not run.  Every expectation is an oracle
row from /usr/bin/cc.

## enums

### enumerators count, assign, fold, and label cases

```cc
(display (cc-run "#include <stdio.h>\nenum Color { RED, GREEN = 5, BLUE };\nenum Bits { B0 = 1 << 0, B1 = 1 << 1, B2 = B1 * 2, BALL = B0 | B1 | B2 };\ntypedef enum { LOW, HIGH } Level;\nint name(enum Color c) { switch (c) { case RED: return 1; case GREEN: return 2; case BLUE: return 3; default: return 0; } }\nint main() { enum Color c = BLUE; Level l = HIGH; int m = -B2; printf(\"%d %d %d %d %d %d %d %d\\n\", RED, GREEN, c, B2, BALL, l, m, name(GREEN) + name(c)); return 0; }"))
```
---
```output
0 5 6 4 7 1 -4 5
0
```

## unions

### fields overlap, a union copies, an anonymous union nests in a struct

```cc
(display (cc-run "#include <stdio.h>\nstruct P { int x; int y; };\nunion V { int i; char c; struct P p; };\nstruct Val { int tag; union { int i; char c; } u; };\nint main() { union V v; union V w; struct Val a; struct Val b;\n  v.p.x = 3; v.p.y = 4; w = v; a.tag = 1; a.u.c = 'A'; b = a; b.u.i = 66;\n  printf(\"%d %d %d %d %d %d\\n\", v.i, w.p.y, a.u.c, b.tag, b.u.c, sizeof(union V) == sizeof(struct P)); return 0; }"))
```
---
```output
3 4 65 1 66 1
0
```

## function pointers

### declared, typedef'd, passed, arrayed, in a struct, called every way

```cc
(display (cc-run "#include <stdio.h>\nint add(int a, int b) { return a + b; }\nint sub(int a, int b) { return a - b; }\nint mul(int a, int b) { return a * b; }\ntypedef int (*binop)(int, int);\nint apply(int (*f)(int, int), int x, int y) { return f(x, y); }\nint (*ops[3])(int, int) = { add, sub, mul };\nint (*g)(int, int);\nstruct Op { char *name; binop fn; };\nint main() {\n  binop f = &mul; int i; int s = 0;\n  struct Op ops2[2] = { {\"add\", add}, {\"sub\", sub} };\n  g = sub;\n  for (i = 0; i < 3; i++) s = s + ops[i](10, 3);\n  printf(\"%d %d %d %d %d\\n\", apply(add, 2, 3), (*f)(4, 5), g(9, 2), s, ops2[1].fn(7, 1));\n  printf(\"%s\\n\", ops2[0].name);\n  if (f == mul && f != add && g) printf(\"same\\n\");\n  return 0;\n}"))
```
---
```output
5 20 7 50 6
add
same
0
```

### a native twin, called through a pointer from interpreted code

```cc
(display (cc-build-run "#include <stdio.h>\nint sq(int n) { return n * n; }\nint twice(int (*f)(int), int x) { return f(f(x)); }\nint main() { printf(\"%d\\n\", twice(sq, 3)); return 0; }"))
```
---
```output
native sq
interp twice
interp main
81
0
```

## #elif

### a chain takes its first true branch and no other, dead or nested

```cc
(display (cc-run "#include <stdio.h>\n#define LEVEL 2\n#if 0\n#define X 1\n#elif defined(LEVEL)\n#define X 2\n#elif 1\n#define X 3\n#else\n#define X 4\n#endif\n#ifdef LEVEL\n#define Y 1\n#elif 1\n#define Y 2\n#else\n#define Y 3\n#endif\n#ifndef LEVEL\n#define Z 1\n#elif defined(NOPE)\n#define Z 2\n#elif !defined(NOPE)\n#define Z 3\n#else\n#define Z 4\n#endif\n#ifdef NOPE\n#if 1\n#define W 1\n#elif 1\n#define W 2\n#endif\n#elif 0\n#define W 3\n#else\n#define W 4\n#endif\nint main() { printf(\"%d %d %d %d\\n\", X, Y, Z, W); return 0; }"))
```
---
```output
2 1 3 4
0
```

## the refusals

### a call through a value that is no function

```cc
(display (cc-run "int main() { int (*f)(int); f = 0; return f(1); }"))
```
---
```output
cc: run failed: #<err:cc cc: run: call through a value that is not a function>
1
```
