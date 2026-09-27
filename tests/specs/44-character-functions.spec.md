# @weight 2
# @timeout-scale 3

`<ctype.h>`'s classifications and case changes, and `abs`, under `run`
and compiled.  The classifications -- `isdigit`, `isalpha`, `isalnum`,
`isspace`, `isupper`, `islower` -- are ranges of codes in one table, which
`run` reads and the compiled runtime is written from; each answers 1 or 0.
`toupper` and `tolower` move a letter thirty-two.  Each case runs the
program under `run`, then compiled, and shows both statuses, and both
outputs where it prints; every expectation is what the same source prints
through /usr/bin/cc.  C's classifications answer any nonzero number for
true, so the programs compare them with 0.

## classifications

### each one, in and out

```cc
(def src "#include <ctype.h>\nint main(void) { return (isdigit('7') != 0) + (isdigit('a') != 0) * 2 + (isalpha('Q') != 0) * 4 + (isalpha('5') != 0) * 8 + (isspace('\\t') != 0) * 16 + (isspace('x') != 0) * 32 + (isalnum('_') != 0) * 64 + (isalnum('z') != 0) * 128; }")
(display (list (cc-run src) (cc-exe-run src)))
```
---
    (149 149)

### upper and lower, and EOF in none

```cc
(def src "#include <ctype.h>\nint main(void) { return (isupper('A') != 0) + (islower('A') != 0) * 2 + (isupper('z') != 0) * 4 + (islower('z') != 0) * 8 + (isdigit(-1) != 0) * 16; }")
(display (list (cc-run src) (cc-exe-run src)))
```
---
    (9 9)

### counting the digits, letters and spaces of a string

```cc
(def src "#include <ctype.h>\nint main(void) { char *s = \"a1 b22 c333\\tx\"; int d = 0; int a = 0; int sp = 0; while (*s) { if (isdigit(*s)) d++; else if (isalpha(*s)) a++; else if (isspace(*s)) sp++; s++; } return d * 100 + a * 10 + sp; }")
(display (list (cc-run src) (cc-exe-run src)))
```
---
    (131 131)

## case and abs

### a string up and down, and two absolute values

```cc
(def src "#include <stdio.h>\n#include <ctype.h>\n#include <stdlib.h>\nint main(void) { char s[] = \"Hello, World 42\"; int i; for (i = 0; s[i]; i++) putchar(toupper(s[i])); putchar(10); for (i = 0; s[i]; i++) putchar(tolower(s[i])); putchar(10); return abs(-7) + abs(3); }")
(display (list (cc-run src) (cc-exe-run src)))
```
---
```output
HELLO, WORLD 42
hello, world 42
HELLO, WORLD 42
hello, world 42
(10 10)
```
