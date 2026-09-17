# @weight 2
# @timeout-scale 3

Compiled calls.  A program is main and the functions beside it, each
with its own frame off x20 and its answer in x0; arguments travel in
four registers, and a function that calls another saves what it needs
to get back.  Each status below is the one the same source gives when
compiled with /usr/bin/cc and run.

## calling

### a function of one argument

```cc
(display (cc-exe-run "int sq(int n) { return n * n; }\nint main(void) { return sq(5); }"))
```
---
    25

### four arguments, and a call as one of them

```cc
(display (cc-exe-run "int add4(int a, int b, int c, int d) { return a + b * 2 + c * 3 + d * 4; }\nint twice(int n) { return n * 2; }\nint main(void) { return add4(1, 2, twice(3), 4) % 256; }"))
```
---
    39

### a callee's locals are its own

```cc
(display (cc-exe-run "int sum(int n) { int s = 0; int i; for (i = 1; i <= n; i++) s += i; return s; }\nint main(void) { int s = 100; return sum(10) + s - 100; }"))
```
---
    55

## recursion

### a recursive factorial

```cc
(display (cc-exe-run "int fact(int n) { if (n < 2) return 1; return n * fact(n - 1); }\nint main(void) { return fact(5); }"))
```
---
    120

### fib, which recurses twice per call

```cc
(display (cc-exe-run "int fib(int n) { if (n < 2) return n; return fib(n - 1) + fib(n - 2); }\nint main(void) { return fib(12) % 256; }"))
```
---
    144

### mutual recursion through a prototype

```cc
(display (cc-exe-run "int odd(int n);\nint even(int n) { if (n == 0) return 1; return odd(n - 1); }\nint odd(int n) { if (n == 0) return 0; return even(n - 1); }\nint main(void) { return even(10) * 2 + odd(7); }"))
```
---
    3

### a loop calling a function, gcd by remainder

```cc
(display (cc-exe-run "int gcd(int a, int b) { while (b != 0) { int t = a % b; a = b; b = t; } return a; }\nint main(void) { return gcd(252, 105); }"))
```
---
    21

## the refusals

### a fifth argument is not compiled yet

```cc
(display (guard (e (do (display "refused: ") (write e) ""))
  (cc-exe-run "int five(int a, int b, int c, int d, int e) { return a + e; }\nint main(void) { return five(1, 2, 3, 4, 5); }")))
```
---
    refused: #<err:cc cc: compile: not built yet: a call with more than four arguments: five>

### nor is a call to a function that is not there

```cc
(display (guard (e (do (display "refused: ") (write e) ""))
  (cc-exe-run "int main(void) { return missing(1); }")))
```
---
    refused: #<err:cc cc: compile: not built yet: a call to missing>
