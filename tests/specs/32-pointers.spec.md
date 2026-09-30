# @weight 2
# @timeout-scale 3

Compiled pointers and arrays.  A pointer is an eight-byte address; `&`
takes one, `*` loads or stores through one at the width of what it points
at, and `+` and `-` move one by whole elements.  An array is its elements
end to end, and where it is used as a value it stands for its first
element's address, so `a[i]` is `*(a + i)`.  A string literal is an array
of chars in the data, and `puts` and `printf`'s `%s` walk any string to
its NUL at run time.  Each case below prints what the same source prints
through /usr/bin/cc, and exits as it does.

## pointers

### a store through a pointer reaches what it points at

```cc
(display (list
  (cc-exe-run "int main(void) { int n = 5; int *p = &n; *p = 7; return n; }")
  (cc-exe-run "void swap(int *a, int *b) { int t = *a; *a = *b; *b = t; }\nint main(void) { int x = 1; int y = 2; swap(&x, &y); return x * 10 + y; }")))
```
---
    (7 21)

### a pointer loads at the width and sign of what it points at

```cc
(display (cc-exe-run "int main(void) { char c = -1; char *p = &c; unsigned char *u = (unsigned char *)&c; return (*p == -1) + (*u == 255) * 2; }"))
```
---
    3

### steps and differences count elements, and pointers compare

```cc
(display (list
  (cc-exe-run "int main(void) { int a[10]; int *p = &a[2]; int *q = &a[7]; return (q - p) * 10 + (p < q); }")
  (cc-exe-run "char buf[8];\nint main(void) { char *p = buf; *p++ = 'o'; *p++ = 'k'; *p = 0; return buf[0] + buf[1] - p[-1] * 0 - 'o' - 'k' + (p - buf); }")))
```
---
    (51 2)

### what an address points at, interpreted and compiled

`&a[1]` points at an int, so `+ 3` steps three of them; `1 + s` and
`2[s]` name a char, as `s + 1` and `s[2]` do; two addresses subtract to
a count, which adds as a number; `&a` points at the whole array; and a
string literal's size counts its NUL.

```cc
(def src "#include <stdio.h>\nstruct P { int x; int y; };\nint main(void) { int a[5] = {10, 20, 30, 40, 50}; char s[] = \"abcde\"; struct P pts[2] = {{1, 2}, {3, 4}}; int *p = &a[3]; long n = (p - a) + 1; printf(\"%d %d %d %d %ld %d %d\\n\", *(&a[1] + 3), *(1 + s), 2[s], *(&pts[0].y + 2), n, (int)((char *)(&a + 1) - (char *)&a), (int)sizeof \"hello\"); return 0; }\n")
(display (list (cc-run src) (cc-exe-run src)))
```
---
```output
50 98 99 4 4 20 6
50 98 99 4 4 20 6
(0 0)
```

## arrays

### elements stored and loaded by subscript

```cc
(display (list
  (cc-exe-run "int main(void) { int a[5]; int i; for (i = 0; i < 5; i++) a[i] = i * i; return a[4] + a[1]; }")
  (cc-exe-run "int main(void) { int a[] = {3, 1, 4, 1, 5}; int *p = a; int s = 0; int i; for (i = 0; i < 5; i++) s += *(p + i); return s; }")))
```
---
    (17 14)

### a short initializer list leaves the rest of the array zero

```cc
(display (cc-exe-run "int dirty(void) { int a[4]; a[0] = 1; a[1] = 2; a[2] = 3; a[3] = 4; return a[0]; }\nint clean(void) { int b[4] = {9}; return b[0] + b[1] + b[2] + b[3]; }\nint main(void) { dirty(); return clean(); }"))
```
---
    9

### an array of arrays, and the sizes of both, interpreted and compiled

Each `[N]` of a declarator wraps the C type the dimensions after it make,
so `int m[2][3]` is two arrays of three ints; `m[i]` is one of them, and
stands for its first element's address in turn.

```cc
(def src "int main(void) { int m[2][3]; int i; int j; for (i = 0; i < 2; i++) for (j = 0; j < 3; j++) m[i][j] = i * 3 + j; return m[1][2] + sizeof(m) + sizeof(m[0]); }")
(display (list (cc-run src) (cc-exe-run src)))
```
---
    (41 41)

### nested initializer lists, and an outer size the list decides

```cc
(display (list
  (cc-exe-run "int main(void) { int m[2][3] = {{1, 2, 3}, {4, 5, 6}}; return m[1][0] * 10 + m[0][2]; }")
  (cc-exe-run "int main(void) { int m[][2] = {{1, 2}, {3, 4}, {5, 6}}; return sizeof(m) + m[2][1]; }")))
```
---
    (43 30)

### a global array, and a global pointer into it

```cc
(display (cc-exe-run "int t[3] = {10, 20, 30};\nint *p;\nint main(void) { p = t + 1; return *p + p[1]; }"))
```
---
    50

## strings

### walked by a pointer to their end

```cc
(display (cc-exe-run "int len(char *s) { int n = 0; while (*s++) n++; return n; }\nint main(void) { return len(\"hello, world\"); }"))
```
---
    12

### a char array from a literal is the program's to change

```cc
(display (cc-exe-run "#include <stdio.h>\nint main(void) { char w[] = \"cat\"; w[0] = 'b'; puts(w); return sizeof(w); }"))
```
---
```output
bat
4
```

### a function answers a pointer into its argument

```cc
(display (cc-exe-run "#include <stdio.h>\nchar *skip(char *s) { while (*s == ' ') s++; return s; }\nint main(void) { puts(skip(\"   hi\")); return 0; }"))
```
---
```output
hi
0
```

### %s of a pointer, from an array of them

```cc
(display (cc-exe-run "#include <stdio.h>\nint main(void) { char *names[2]; int i; names[0] = \"ab\"; names[1] = \"cd\"; for (i = 0; i < 2; i++) printf(\"%d=%s\\n\", i, names[i]); return 0; }"))
```
---
```output
0=ab
1=cd
0
```

### a global char array, changed through a pointer

```cc
(display (cc-exe-run "#include <stdio.h>\nchar g[] = \"global\";\nint main(void) { char *s = g; s[0] = 'G'; printf(\"%s %c %d\\n\", s, *(s + 1), (int)sizeof(g)); return 0; }"))
```
---
```output
Global l 7
0
```

## the refusals

### a global pointer that starts at a number cast to a pointer, moved

```cc
(display (guard (e (do (display "refused: ") (write e) ""))
  (cc-exe-run "int *g = (int *)4096 + 1;\nint main(void) { return g == (int *)4100; }")))
```
---
    refused: #<err:cc cc: compile: not built yet: a global initialized by arithmetic on an address>

### arithmetic other than + and - on an address

```cc
(display (guard (e (do (display "refused: ") (write e) ""))
  (cc-exe-run "int main(void) { int a[2]; int *p = a; return p * 2; }")))
```
---
    refused: #<err:cc cc: compile: not built yet: the operator * on an address>
