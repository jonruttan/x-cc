# @weight 2
# @timeout-scale 3

Compiled locals and control flow.  A local is a slot in the frame the
entry reserves, addressed from x19; `if`, `while`, `do`, `for`,
`break` and `continue` are branches to labels the assembler resolves.
Each status below is the one the same source gives when compiled with
/usr/bin/cc and run.

## locals

### declarations, arithmetic and assignment

```cc
(display (cc-exe-run "int main(void) { int a = 3; int b = a * 4; a = a + b; return a; }"))
```
---
    15

### a declaration with no initializer answers zero

```cc
(display (cc-exe-run "int main(void) { int a; int b = 5; return a + b; }"))
```
---
    5

### ++ and --, before and after

```cc
(display (cc-exe-run "int main(void) { int i = 5; int a = i++; int b = ++i; int c = i--; return a * 100 + b * 10 + c + i; }"))
```
---
    71

## branches

### if and else

```cc
(display (cc-exe-run "int main(void) { int n = 7; if (n > 5) return n + 1; else return 2; }"))
```
---
    8

### the ternary picks one arm

```cc
(display (cc-exe-run "int main(void) { int n = 9; int m = n > 4 ? n * 2 : n - 1; return m; }"))
```
---
    18

### && and || run the right operand only when they must

```cc
(display (cc-exe-run "int main(void) { int hit = 0; int r = 0 && (hit = 1); int q = 1 || (hit = 2); return r * 100 + q * 10 + hit; }"))
```
---
    10

## loops

### a while loop with an accumulator

```cc
(display (cc-exe-run "int main(void) { int s = 0; int i = 1; while (i <= 10) { s += i; i++; } return s; }"))
```
---
    55

### a do-while runs its body first

```cc
(display (cc-exe-run "int main(void) { int i = 0; int s = 0; do { s += i * i; i++; } while (i < 5); return s; }"))
```
---
    30

### a for loop, with continue and break

```cc
(display (cc-exe-run "int main(void) { int s = 0; int i; for (i = 0; i < 10; i++) { if (i == 3) continue; if (i == 7) break; s += i; } return s; }"))
```
---
    18

### loops nest

```cc
(display (cc-exe-run "int main(void) { int i; int j; int s = 0; for (i = 1; i <= 5; i++) for (j = 1; j <= 5; j++) s += i * j; return s % 256; }"))
```
---
    225

## the refusals

### a local that is not an integer is not compiled yet

```cc
(display (guard (e (do (display "refused: ") (write e) ""))
  (cc-exe-run "int main(void) { int a[4]; a[0] = 1; return a[0]; }")))
```
---
    refused: #<err:cc cc: compile: not built yet: a local that is not an integer>

### so is a pointer

```cc
(display (guard (e (do (display "refused: ") (write e) ""))
  (cc-exe-run "int main(void) { int a = 1; int *p = &a; return *p; }")))
```
---
    refused: #<err:cc cc: compile: not built yet: a local that is not an integer>
