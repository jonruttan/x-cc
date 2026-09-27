# @weight 2
# @timeout-scale 3

printf's conversions, the same under `run` and compiled: `%d` `%i` `%u`
`%x` `%c` `%s` and `%%`, and `%ld` `%li` `%lu` `%lx`.  An int's
conversion reads the argument's low 32 bits; `%u` and `%x` read them as
unsigned, and the long ones read all 64.  printf answers the count of
bytes it wrote.  Each case runs the program under `run`, then compiled,
and shows both outputs and both statuses; every expectation is what the
same source prints through /usr/bin/cc.

## conversions

### hex, of an int and of a long

```cc
(def src "#include <stdio.h>\nint main(void) { printf(\"%x %x %lx %lx\\n\", 255, -1, 4294967296L, -1L); return 0; }")
(display (list (cc-run src) (cc-exe-run src)))
```
---
```output
ff ffffffff 100000000 ffffffffffffffff
ff ffffffff 100000000 ffffffffffffffff
(0 0)
```

### unsigned, %i, and the long decimals

```cc
(def src "#include <stdio.h>\nint main(void) { printf(\"%u %i %ld %li %lu\\n\", -1, -5, -1234567890123L, 123L, -1L); return 0; }")
(display (list (cc-run src) (cc-exe-run src)))
```
---
```output
4294967295 -5 -1234567890123 123 18446744073709551615
4294967295 -5 -1234567890123 123 18446744073709551615
(0 0)
```

### one unsigned int three ways

```cc
(def src "#include <stdio.h>\nint main(void) { unsigned u = 3735928559u; printf(\"%x %u %d\\n\", u, u, (int)u); return 0; }")
(display (list (cc-run src) (cc-exe-run src)))
```
---
```output
deadbeef 3735928559 -559038737
deadbeef 3735928559 -559038737
(0 0)
```

### the count of bytes written

```cc
(def src "#include <stdio.h>\nint main(void) { int n = printf(\"abc%d\\n\", 42); return n; }")
(display (list (cc-run src) (cc-exe-run src)))
```
---
```output
abc42
abc42
(6 6)
```
