# @weight 2
# @timeout-scale 3

Compiled `malloc` and `free`.  The heap follows the data, zero-filled by
the kernel, and the runtime's malloc -- written after the program, when
the data's size is final -- takes blocks from it in order, each rounded
up to sixteen bytes.  A size the heap has no room for answers the null
pointer, and `free` gives nothing back.  Each case below prints what the
same source prints through /usr/bin/cc, and exits as it does; where both
columns show, `run` and the compiled executable agree.  `run`'s heap is
smaller and eight-aligned, so the cases that lean on the size or the
alignment are compiled only.

## malloc

### a linked list, built and walked

```cc
(def src "#include <stdlib.h>\nstruct N { int v; struct N *next; };\nint main(void) { struct N *h = 0; int i; for (i = 1; i <= 5; i++) { struct N *n = malloc(sizeof(struct N)); n->v = i * i; n->next = h; h = n; } int s = 0; while (h) { s += h->v; h = h->next; } return s; }")
(display (list (cc-run src) (cc-exe-run src)))
```
---
    (55 55)

### sized by the name being declared: sizeof *n

```cc
(def src "#include <stdio.h>\n#include <stdlib.h>\nstruct node { int v; struct node *next; };\nstruct node *push(struct node *h, int v) { struct node *n = malloc(sizeof *n); n->v = v; n->next = h; return n; }\nint main(void) { struct node *h = 0; int i; for (i = 1; i <= 5; i++) h = push(h, i * i); int s = 0; struct node *p; for (p = h; p; p = p->next) { printf(\"%d \", p->v); s += p->v; } printf(\"\\n%d\\n\", s); return s % 256; }\n")
(display (list (cc-run src) (cc-exe-run src)))
```
---
```output
25 16 9 4 1 
55
25 16 9 4 1 
55
(55 55)
```

### an int array and a string, then both freed

```cc
(display (cc-exe-run "#include <stdio.h>\n#include <stdlib.h>\nint main(void) { int n = 10; int *a = malloc(n * sizeof(int)); int i; for (i = 0; i < n; i++) a[i] = i * 3; char *s = malloc(4); s[0] = 'o'; s[1] = 'k'; s[2] = 0; puts(s); int r = a[9]; free(a); free(s); return r - 20; }"))
```
---
```output
ok
7
```

### two blocks are apart, and each is sixteen-aligned

```cc
(display (cc-exe-run "#include <stdlib.h>\nint main(void) { char *p = malloc(1); char *q = malloc(1); return (p != q) + ((long)p % 16 == 0) * 2 + ((long)q % 16 == 0) * 4; }"))
```
---
    7

### eight megabytes, a block at a time

```cc
(display (cc-exe-run "#include <stdlib.h>\nint main(void) { long total = 0; int i; for (i = 0; i < 1000; i++) { long *b = malloc(1000 * sizeof(long)); b[999] = i; total += b[999]; } return total % 256; }"))
```
---
    44

### a size no heap holds answers the null pointer

```cc
(display (cc-exe-run "#include <stdlib.h>\nint main(void) { return malloc(-1) == 0; }"))
```
---
    1
