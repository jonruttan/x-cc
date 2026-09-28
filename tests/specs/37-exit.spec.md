# @weight 2
# @timeout-scale 3

Compiled `exit`.  The status goes into x0 and the program leaves through
the entry's own exit, the one main's return reaches, from whatever depth
it is called at.  Each case below prints what the same source prints
through /usr/bin/cc, and exits as it does; where both columns show,
`run` and the compiled executable agree.

## exit

### from main

```cc
(def src "#include <stdlib.h>\nint main(void) { exit(3); return 0; }")
(display (list (cc-run src) (cc-exe-run src)))
```
---
    (3 3)

### from a function three calls down

```cc
(def src "#include <stdlib.h>\nvoid die(int n) { exit(n + 40); }\nint f(int k) { if (k > 2) die(k); return f(k + 1); }\nint main(void) { f(0); return 9; }")
(display (list (cc-run src) (cc-exe-run src)))
```
---
    (43 43)

### from a switch in a loop, masked to a byte as a status is

```cc
(def src "#include <stdlib.h>\nint main(void) { int i; for (i = 0; i < 10; i++) { switch (i) { case 4: exit(300); } } return 1; }")
(display (list (cc-run src) (cc-exe-run src)))
```
---
    (44 44)

### after output

```cc
(display (cc-exe-run "#include <stdio.h>\n#include <stdlib.h>\nint main(void) { printf(\"bye\\n\"); exit(7); }"))
```
---
```output
bye
7
```
