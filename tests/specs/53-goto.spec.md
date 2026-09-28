# @weight 2
# @timeout-scale 3

goto.  `goto NAME;` goes to the statement labelled `NAME:` anywhere in
its function: out of loops and blocks, back to an earlier statement, or
into a loop's body, a block or an arm of an `if`, which then goes on as
it would from there.  Compiled, every local has its slot for the whole
function, so a goto is a branch.  Under `run` it passes up to the block
that holds the label, which goes on from there; the declarations it
passes over are bound but not initialized, as C leaves them.  Each case
runs the program under `run`, then compiled, and shows both outputs and
both statuses; every expectation is what the same source prints through
/usr/bin/cc.

## goto

### out of two loops

```cc
(def src "#include <stdio.h>\nint find(int m[][3], int n, int want) { int i, j; for (i = 0; i < n; i++) for (j = 0; j < 3; j++) if (m[i][j] == want) goto found; return -1; found: return i * 3 + j; }\nint main(void) { int m[2][3] = {{1, 2, 3}, {4, 5, 6}}; printf(\"%d %d\\n\", find(m, 2, 5), find(m, 2, 9)); return find(m, 2, 6); }\n")
(display (list (cc-run src) (cc-exe-run src)))
```
---
```output
4 -1
4 -1
(5 5)
```

### back to an earlier statement, as a loop

```cc
(def src "#include <stdio.h>\nint main(void) { int n = 0; int total = 0; again: n++; { int sq = n * n; total += sq; } if (n < 5) goto again; printf(\"%d %d\\n\", n, total); return total; }\n")
(display (list (cc-run src) (cc-exe-run src)))
```
---
```output
5 55
5 55
(55 55)
```

### into a loop's body, which goes on as the loop

```cc
(def src "#include <stdio.h>\nint main(void) { int i = 10, hits = 0; goto inside; for (i = 0; i < 3; i++) { hits += 100; inside: hits += i; } printf(\"%d %d\\n\", i, hits); return hits % 256; }\n")
(display (list (cc-run src) (cc-exe-run src)))
```
---
```output
11 10
11 10
(10 10)
```

### into an arm of an if

```cc
(def src "#include <stdio.h>\nint main(void) { int x = 0; if (x) { skip: x += 5; } else { x += 1; if (x < 3) goto skip; } printf(\"%d\\n\", x); return x; }\n")
(display (list (cc-run src) (cc-exe-run src)))
```
---
```output
6
6
(6 6)
```

### cleaning up: past a declaration to the labels at the end

```cc
(def src "#include <stdio.h>\n#include <stdlib.h>\nint work(int fail_at) { int status = 0; char *a = malloc(8); if (fail_at == 1) { status = 1; goto out_a; } char *b = malloc(8); if (fail_at == 2) { status = 2; goto out_b; } status = 3; out_b: free(b); out_a: free(a); return status; }\nint main(void) { printf(\"%d %d %d\\n\", work(1), work(2), work(3)); return work(3); }\n")
(display (list (cc-run src) (cc-exe-run src)))
```
---
```output
1 2 3
1 2 3
(3 3)
```

### a scanner of a switch and two labels

```cc
(def src "#include <stdio.h>\nint main(void) { const char *s = \"a1b22c\"; int letters = 0, digits = 0, i = 0; next: switch (s[i]) { case 0: goto done; default: if (s[i] >= '0' && s[i] <= '9') digits++; else letters++; } i++; goto next; done: printf(\"%d %d %d\\n\", letters, digits, i); return letters * 10 + digits; }\n")
(display (list (cc-run src) (cc-exe-run src)))
```
---
```output
3 3 6
3 3 6
(33 33)
```

## the refusals

### a goto to a label the function does not have

C refuses it, and so does the compiler, by name; `run` stops at the goto
with the same words.

```cc
(display (guard (e (do (display "refused: ") (write e) ""))
  (cc-exe-run "int main(void) { goto nowhere; return 0; }")))
```
---
    refused: #<err:cc cc: compile: not built yet: a goto to a label the function does not have: nowhere>
