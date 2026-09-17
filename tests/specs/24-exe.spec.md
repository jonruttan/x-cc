# @weight 2
# @timeout-scale 3

Compiling to an executable.  `cc-compile` writes an executable for the
platform the compiler runs on -- an ad-hoc signed arm64 Mach-O on macOS,
a static x86-64 ELF on Linux; `cc-exe-run` compiles a program to a file,
runs it as a child process, prints what it wrote and answers its exit
status.  Each status below is the one the same source gives when
compiled with /usr/bin/cc and run.

The code generator evaluates expressions on a stack machine through the
platform assembler.  An operator whose result can leave `int`'s 32 bits
sign-extends it again from bit 31, so arithmetic wraps as C's `int`
does, and division truncates toward zero.  An exit status is the low
eight bits of what main returns.

## return values

### a constant

```cc
(display (cc-exe-run "int main(void) { return 42; }"))
```
---
    42

### arithmetic, precedence, and division and remainder of negatives

```cc
(display (list
  (cc-exe-run "int main(void) { return 6 * 7 - 2; }")
  (cc-exe-run "int main(void) { return (2 + 3) * 4 % 7; }")
  (cc-exe-run "int main(void) { return -7 / 2 + 10; }")
  (cc-exe-run "int main(void) { return -7 % 3 + 5; }")))
```
---
    (40 6 7 4)

### a negative status, and a constant and a product past sixteen bits

```cc
(display (list
  (cc-exe-run "int main(void) { return -1; }")
  (cc-exe-run "int main(void) { return 70000 - 69958; }")
  (cc-exe-run "int main(void) { return 1000000 * 3 % 256; }")))
```
---
    (255 42 192)

### bitwise operators, an arithmetic shift, comparisons, and unary operators

```cc
(display (list
  (cc-exe-run "int main(void) { return (1 << 5) | 3 ^ 1; }")
  (cc-exe-run "int main(void) { return -100 >> 2 & 255; }")
  (cc-exe-run "int main(void) { return (3 < 4) + (4 <= 4) * 2 + (5 > 6) * 4 + (7 != 7) * 8 + (2 == 2) * 16; }")
  (cc-exe-run "int main(void) { return !0 + ~(-5); }")))
```
---
    (34 231 19 5)

## the refusal

### a global is not compiled yet

```cc
(display (guard (e (do (display "refused: ") (write e) ""))
  (cc-exe-run "int g = 3;\nint main(void) { return g; }")))
```
---
    refused: #<err:cc cc: compile: not built yet: global declarations>
