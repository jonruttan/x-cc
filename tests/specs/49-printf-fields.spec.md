# @weight 2
# @timeout-scale 3

printf's fields, the same under `run` and compiled: after the `%`, the
flags `-` (the text at the left of the field) and `0` (zeros after the
sign in place of spaces before it), a field width, and a precision after
a `.` -- the least count of digits for a number, and none at all for a
zero at precision 0; the most bytes for a string.  A number with a
precision pads with spaces, whatever its flags.  Each case runs the
program under `run`, then compiled, and shows both outputs and both
statuses; every expectation is what the same source prints through
/usr/bin/cc.

## numbers

### widths, the flags, and precisions, with the count of bytes written

```cc
(def src "#include <stdio.h>\nint main(void) {\n  int n = printf(\"[%5d] [%-5d] [%05d] [%3d] [%5d] [%05d] [%-6d]\\n\", 42, 42, 42, 12345, -42, -42, -42);\n  printf(\"[%.3d] [%8.3d] [%-8.3d] [%05.3d] [%.0d] [%.0d] [%5.0d]\\n\", 7, -7, 7, 7, 0, 5, 0);\n  printf(\"[%8x] [%08x] [%-8x] [%.4x] [%5u] [%05u]\\n\", 255, 255, 255, 10, 3000000000u, 7u);\n  printf(\"[%12ld] [%-12ld] [%020ld] [%.12lx]\\n\", -1234567890123L, 99L, -5L, 255L);\n  return n;\n}\n")
(display (list (cc-run src) (cc-exe-run src)))
```
---
```output
[   42] [42   ] [00042] [12345] [  -42] [-0042] [-42   ]
[007] [    -007] [007     ] [  007] [] [5] [     ]
[      ff] [000000ff] [ff      ] [000a] [3000000000] [00007]
[-1234567890123] [99          ] [-0000000000000000005] [0000000000ff]
[   42] [42   ] [00042] [12345] [  -42] [-0042] [-42   ]
[007] [    -007] [007     ] [  007] [] [5] [     ]
[      ff] [000000ff] [ff      ] [000a] [3000000000] [00007]
[-1234567890123] [99          ] [-0000000000000000005] [0000000000ff]
(57 57)
```

### in a loop, the most negative long, and runs of padding far into the data

```cc
(def src "#include <stdio.h>\nchar big[6000];\nint main(void) {\n  int i;\n  big[5999] = 1;\n  for (i = 1; i <= 1000; i *= 10) printf(\"|%6d|%-6d|%06d|%6x|\\n\", i, -i, i * 3, i * 255);\n  printf(\"[%25ld] [%-25ld] [%025ld]\\n\", -9223372036854775807L - 1, -9223372036854775807L - 1, -9223372036854775807L - 1);\n  printf(\"[%20lx] [%-20lu] [%.0x] [%.0x] [%-03c] [%3c]\\n\", -1L, 18446744073709551615UL, 0, 1, 'x', 'y');\n  return big[5999];\n}\n")
(display (list (cc-run src) (cc-exe-run src)))
```
---
```output
|     1|-1    |000003|    ff|
|    10|-10   |000030|   9f6|
|   100|-100  |000300|  639c|
|  1000|-1000 |003000| 3e418|
[     -9223372036854775808] [-9223372036854775808     ] [-000009223372036854775808]
[    ffffffffffffffff] [18446744073709551615] [] [1] [x  ] [  y]
|     1|-1    |000003|    ff|
|    10|-10   |000030|   9f6|
|   100|-100  |000300|  639c|
|  1000|-1000 |003000| 3e418|
[     -9223372036854775808] [-9223372036854775808     ] [-000009223372036854775808]
[    ffffffffffffffff] [18446744073709551615] [] [1] [x  ] [  y]
(1 1)
```

## strings and characters

### widths and precisions of strings and characters, with the count of bytes written

```cc
(def src "#include <stdio.h>\nint main(void) {\n  const char *s = \"hello\";\n  char c = 'Z';\n  int n = printf(\"[%10s] [%-10s] [%.2s] [%10.2s] [%-10.3s] [%3s] [%.0s]\\n\", s, s, s, s, s, s, s);\n  printf(\"[%4c] [%-4c] [%1c] [%10s] [%-6s] [%.3s]\\n\", c, c, c, \"lit\", \"lit\", \"literal\");\n  return n;\n}\n")
(display (list (cc-run src) (cc-exe-run src)))
```
---
```output
[     hello] [hello     ] [he] [        he] [hel       ] [hello] []
[   Z] [Z   ] [Z] [       lit] [lit   ] [lit]
[     hello] [hello     ] [he] [        he] [hel       ] [hello] []
[   Z] [Z   ] [Z] [       lit] [lit   ] [lit]
(68 68)
```

### - over 0, and - on a character

```cc
(def src "#include <stdio.h>\nint main(void) { printf(\"[%-05d] [%-03x] [%-4c]\\n\", 3, 10, 'z'); return 0; }\n")
(display (list (cc-run src) (cc-exe-run src)))
```
---
```output
[3    ] [a  ] [z   ]
[3    ] [a  ] [z   ]
(0 0)
```

## a table

### rows from a function

```cc
(def src "#include <stdio.h>\nint row(const char *name, int n) { return printf(\"%-8s%5d%8.2s|\\n\", name, n, name); }\nint main(void) { int t = 0; t += row(\"alpha\", 1); t += row(\"be\", -22); t += row(\"\", 333); printf(\"%d\\n\", t); return 0; }\n")
(display (list (cc-run src) (cc-exe-run src)))
```
---
```output
alpha       1      al|
be        -22      be|
          333        |
69
alpha       1      al|
be        -22      be|
          333        |
69
(0 0)
```

## the refusals

### a field width past 4095

```cc
(display (guard (e (do (display "refused: ") (write e) ""))
  (cc-exe-run "#include <stdio.h>\nint main(void) { printf(\"%5000d\\n\", 1); return 0; }")))
```
---
    refused: #<err:cc cc: compile: not built yet: printf's field width past 4095>

### a field width from an argument

```cc
(display (guard (e (do (display "refused: ") (write e) ""))
  (cc-exe-run "#include <stdio.h>\nint main(void) { printf(\"%*d\\n\", 5, 1); return 0; }")))
```
---
    refused: #<err:cc cc: compile: not built yet: printf's %*>
