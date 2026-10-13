# @weight 1
# @timeout-scale 2

setjmp and longjmp: a longjmp out of a recursion, back to a setjmp that
answers its value -- 1 for a 0 -- and a setjmp a longjmp comes back to more
than once.  The case runs under `run`, then compiled, and shows both
outputs and both statuses; the expectation is what the same source prints
through /usr/bin/cc, on macOS and on glibc alike.

## setjmp

### longjmp out of a recursion, and back to the same setjmp again

```cc
(def src "#include <stdio.h>\n#include <setjmp.h>\nstatic jmp_buf top;\nstatic int depth;\nstatic int dive(int n) {\n  char pad[64];\n  pad[0] = (char)n;\n  depth++;\n  if (n == 0) longjmp(top, 0);\n  if (n == 7) longjmp(top, 42);\n  return dive(n - 1) + pad[0];\n}\nint main(void) {\n  volatile int tries = 0;\n  int r = setjmp(top);\n  tries++;\n  printf(\"r=%d tries=%d depth=%d\\n\", r, (int)tries, depth);\n  if (r == 0) dive(10);\n  else if (r == 42) { depth = 0; dive(3); }\n  jmp_buf inner;\n  int k = setjmp(inner);\n  if (k < 3) { printf(\"inner %d\\n\", k); longjmp(inner, k + 1); }\n  printf(\"done %d %d\\n\", k, (int)sizeof(jmp_buf) >= 32);\n  return r + k;\n}\n")
(display (list (cc-run src) (cc-exe-run src)))
```
---
```output
r=0 tries=1 depth=0
r=42 tries=2 depth=4
r=1 tries=3 depth=4
inner 0
inner 1
inner 2
done 3 1
r=0 tries=1 depth=0
r=42 tries=2 depth=4
r=1 tries=3 depth=4
inner 0
inner 1
inner 2
done 3 1
(4 4)
```
