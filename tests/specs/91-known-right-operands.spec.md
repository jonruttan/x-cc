# @weight 1
# @timeout-scale 3

A binary operation's right operand whose value is known when the program
is compiled goes straight to the register the operation reads it from:
an integer constant, an integer constant cast to an address (NULL is
one), and a sizeof.  Each expectation is what the same source prints
through /usr/bin/cc.

## known right operands

### NULL, an address cast from a constant, and sizeof

```cc
(display (cc-exe-run "#include <stdio.h>\n#include <string.h>\nstruct node { struct node *next; int v; };\nstatic int count(struct node *p) { int n = 0; while (p != NULL) { n += p->v; p = p->next; } return n; }\nint main(void) {\n  struct node c = { NULL, 4 }, b = { &c, 20 }, a = { &b, 300 };\n  char buf[32]; char *end = buf + sizeof buf; char *q = (char *)-1; long s = 0; int i;\n  for (i = 0; i < 40; i++) s += sizeof(struct node) * i - sizeof s;\n  printf(\"%d %d %d %ld %d %d %d %d\\n\", count(&a), count(NULL), (int)(end - sizeof(int) - buf), s,\n    q == (char *)-1, q != NULL, (unsigned long)q > (unsigned long)(char *)0xffffffffu, (int)(sizeof(int) << 3));\n  return 0;\n}\n"))
```
---
```output
324 0 28 12160 1 1 1 32
0
```
