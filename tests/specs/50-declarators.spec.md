# @weight 2
# @timeout-scale 3

Declarators.  A declaration's specifiers are shared by every declarator
after them, and each declarator's own stars, array dimensions and
parentheses make its C type: `int *p, n;` is a pointer and an int, and
`int (*rows)[3]` a pointer to arrays of three ints.  A typedef takes
declarators as a declaration does, several at once; a parameter declared
an array is a pointer to its element, and a prototype's parameters need
no names; a cast or sizeof takes a type name with dimensions or `(*)`.
Each case runs the program under `run`, then compiled, and shows both
outputs and both statuses; every expectation is what the same source
prints through /usr/bin/cc.

## several declarators

### a pointer and an int from one line, and arithmetic on the int

```cc
(def src "#include <stdio.h>\nint *gp, gn = 40;\nint main(void) { int *p, n = 5; char buf[] = \"hi\"; char *const q = buf, c = 'z'; n = n + 1; gn = gn + 2; p = &n; gp = p; printf(\"%d %d %d %c %c %d\\n\", n, gn, *gp, q[1], c, (int)sizeof(char *const)); return n + gn; }\n")
(display (list (cc-run src) (cc-exe-run src)))
```
---
```output
6 42 6 i z 8
6 42 6 i z 8
(48 48)
```

### sizes from shared specifiers: locals, globals and fields

```cc
(def src "#include <stdio.h>\nstruct S { char *name, tag; int *p, n; };\nchar *g1, g2;\nint main(void) { int *a, b; char *s, c; b = 5; a = &b; s = &c; c = 'q'; struct S x; printf(\"%d %d %d %d %d %d %d\\n\", (int)sizeof b, (int)sizeof c, (int)sizeof a, (int)sizeof x.tag, (int)sizeof x.n, (int)sizeof(struct S), (int)sizeof g2); return *a + *s; }\n")
(display (list (cc-run src) (cc-exe-run src)))
```
---
```output
4 1 8 1 4 32 1
4 1 8 1 4 32 1
(118 118)
```

## pointers to arrays

### a local and a parameter

```cc
(def src "#include <stdio.h>\nint sum_row(int (*m)[3], int r) { int s = 0; int j; for (j = 0; j < 3; j++) s += m[r][j]; return s; }\nint main(void) { int m[2][3] = {{1, 2, 3}, {4, 5, 6}}; int (*p)[3] = m; p++; printf(\"%d %d %d %d\\n\", sum_row(m, 0), sum_row(m, 1), (*p)[2], (int)sizeof *p); return p[0][1]; }\n")
(display (list (cc-run src) (cc-exe-run src)))
```
---
```output
6 15 6 12
6 15 6 12
(5 5)
```

### casts and sizeof of type names

```cc
(def src "#include <stdio.h>\nint main(void) { int m[2][4] = {{1, 2, 3, 4}, {5, 6, 7, 8}}; int *flat = &m[0][0]; int (*rows)[4] = (int (*)[4])flat; printf(\"%d %d %d %d\\n\", rows[1][2], (int)sizeof(int[5]), (int)sizeof(int (*)[4]), (int)sizeof(char[3][2])); return rows[1][3]; }\n")
(display (list (cc-run src) (cc-exe-run src)))
```
---
```output
7 20 8 6
7 20 8 6
(8 8)
```

## typedefs and parameters

### an array, two names at once, and a pointer to an array

```cc
(def src "#include <stdio.h>\ntypedef int vec3[3];\ntypedef struct pair { int a, b; } pair_t, *pair_p;\ntypedef int (*row_t)[3];\nvec3 g = {7, 8, 9};\nint total(vec3 v) { return v[0] + v[1] + v[2]; }\nint main(void) { vec3 v = {1, 2, 3}; pair_t q = {4, 5}; pair_p pp = &q; int m[2][3] = {{0}}; row_t r = m; r[1][2] = 42; printf(\"%d %d %d %d %d %d\\n\", total(v), total(g), pp->b, m[1][2], (int)sizeof(vec3), (int)sizeof(pair_t)); return total(v); }\n")
(display (list (cc-run src) (cc-exe-run src)))
```
---
```output
6 24 5 42 12 8
6 24 5 42 12 8
(6 6)
```

### array parameters, and a prototype's unnamed ones

```cc
(def src "#include <stdio.h>\nint sum(int a[10], int n) { int s = 0; int i; for (i = 0; i < n; i++) s += a[i]; return s; }\nint trace(int m[][3], int n) { int t = 0; int i; for (i = 0; i < n; i++) t += m[i][i]; return t; }\nint add(int, int);\nint main(void) { int a[4] = {1, 2, 3, 4}; int m[3][3] = {{1, 0, 0}, {0, 5, 0}, {0, 0, 9}}; printf(\"%d %d %d\\n\", sum(a, 4), trace(m, 3), add(2, 3)); return trace(m, 3); }\nint add(int x, int y) { return x + y; }\n")
(display (list (cc-run src) (cc-exe-run src)))
```
---
```output
10 15 5
10 15 5
(15 15)
```

## the refusals

### an array of pointers to arrays

```cc
(display (guard (e (do (display "refused: ") (write e) ""))
  (cc-exe-run "int main(void) { int (*rows[2])[3]; return 0; }")))
```
---
    refused: #<err:cc cc: parse: line 1: not built yet: an array of pointers to arrays>
