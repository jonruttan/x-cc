# @weight 2
# @timeout-scale 3

Compiled integer types: `long`, `unsigned int` and `unsigned long` beside
`int` and the narrower C types.  A value is held in a whole register in the
form its C type reads it -- an `int`, and anything narrower, sign-extended
from bit 31, an `unsigned int` zero-extended, a `long` or `unsigned long`
as all 64 bits -- and an operator works in the C type C's usual conversions
give its operands.  A literal's C type comes from its value, its base and
its `u` and `l` suffixes, as C gives it.  Each case below prints what the
same source prints through /usr/bin/cc, and exits as it does.

## long

### arithmetic past 32 bits

```cc
(display (list
  (cc-exe-run "int main(void) { long a = 3000000000; long b = a * 3; return (b / 1000000000) + (b % 7); }")
  (cc-exe-run "long sum(long n) { long s = 0; while (n > 0) { s += n; n--; } return s; }\nint main(void) { long r = sum(100000); return r / 1000000 + (r % 1000 == 50000000 % 1000); }")))
```
---
    (14 137)

## unsigned

### an unsigned int wraps at 32 bits

```cc
(display (cc-exe-run "int main(void) { unsigned int u = 4000000000u; unsigned int v = u + u; return (v / 1000000) % 256; }"))
```
---
    121

### an int meets an unsigned int as one, in a comparison

```cc
(display (cc-exe-run "int main(void) { int i = -1; unsigned int u = 1; return (i < u) * 10 + (-1 < 1) + (i == 0xFFFFFFFFu) * 100; }"))
```
---
    101

### a right shift brings in zeros for an unsigned C type, the sign for a signed one

```cc
(display (cc-exe-run "int main(void) { unsigned int u = 0x80000000u; int s = 0x80000000; return (u >> 28) * 10 + ((s >> 28) & 15); }"))
```
---
    88

### conversions through every width

```cc
(display (cc-exe-run "int main(void) { unsigned char c = 200; unsigned int u = c; int i = u - 300; long l = i; unsigned long ul = l; return (ul > 1000) + (i < 0) * 2 + (l == -100) * 4; }"))
```
---
    7

### globals of the wider C types, stepped past their ends

```cc
(display (cc-exe-run "unsigned int g = 7u;\nlong h = -5000000000;\nint main(void) { g--; g = g - 10; return (g > 100) + (h < -4000000000) * 2 + (g % 1000 == 4294967293u % 1000) * 4; }"))
```
---
    3

### a global's initializer is worked out in its operands' C types

```cc
(display (cc-exe-run "#include <stdio.h>\nunsigned int a = -1u / 2;\nunsigned int b = -1u >> 28;\nunsigned long c = -1ul / 10;\nunsigned long d = -1ul >> 60;\nint e = -7 / 2;\nunsigned int f = -7 % 5u;\nlong g = -1u;\nint main(void) { printf(\"%u %u %lu %lu %d %u %ld\\n\", a, b, c, d, e, f, g); return 0; }"))
```
---
```output
2147483647 15 1844674407370955161 15 -3 4 4294967295
0
```

## unsigned long

### sizeof is one, of a type or of an expression

```cc
(display (cc-exe-run "int main(void) { int x = 0; return (sizeof(int) - 5 < 0) + (sizeof(int) - 5 > 1000) * 2 + (sizeof x - 5 > 1000) * 4 + (-sizeof(char) == 18446744073709551615ul) * 8; }"))
```
---
    14

### division and remainder past 2^63

```cc
(display (list
  (cc-exe-run "int main(void) { unsigned long big = 18446744073709551615ul; unsigned long q = big / 1000000000000ul; return (q % 1000) + (big % 97) + (big > 5) * 100; }")
  (cc-exe-run "int main(void) { unsigned long a = 9223372036854775808ul; unsigned long b = 3; return (a / b) % 256 + (a % b) * 16; }")))
```
---
    (136 202)

## printf

### the long and unsigned conversions, at their extremes

```cc
(display (cc-exe-run "#include <stdio.h>\nint main(void) { long m = -9223372036854775807L - 1; unsigned long top = 18446744073709551615ul; unsigned int w = 4294967295u; printf(\"%ld %lu %u %ld\\n\", m, top, w, 1234567890123L); return 0; }"))
```
---
```output
-9223372036854775808 18446744073709551615 4294967295 1234567890123
0
```
