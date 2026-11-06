# @weight 2
# @timeout-scale 3

A global past a load's reach -- twelve bits of offset, in units of its
width -- is loaded and stored through its address, worked out at run
time: behind a large array, a char, a short, an int, a long, a double, a
bit-field and a static local are each read, written and stepped.  Every
expectation is what the same source prints through /usr/bin/cc, then its
status.

## compiled

### globals behind a 70000-byte array

```cc
(def src "#include <stdio.h>\nstatic char heap[70000];\nchar c = 'a';\nshort s = -3;\nint i = 7;\nlong l = 1L << 40;\ndouble d = 2.5;\nstruct bf { unsigned lo : 3; unsigned hi : 5; } b = { 5, 17 };\nint counter(void) { static int n = 40; return ++n; }\nint main(void) {\n  heap[69999] = 9;\n  c++; s -= 4; i *= 6; l += 1; d *= 2; b.hi = 30;\n  counter();\n  printf(\"%c %d %d %ld %g %u %u %d %d\\n\", c, s, i, l, d, b.lo, b.hi, counter(), heap[69999]);\n  return i;\n}\n")
(display (cc-exe-run src))
```
---
```output
b -7 42 1099511627777 5 5 30 42 9
42
```
