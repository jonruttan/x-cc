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

## through a pointer

### a struct answered through a pointer to the function

```cc
(display (cc-exe-run "struct P { int x; };\nstruct P mk(void) { struct P p = {1}; return p; }\nint main(void) { struct P (*f)(void) = mk; return f().x + 4; }"))
```
---
    5

## the container

### a Mach-O runs from macOS 12.0 and names SDK 13.0

LC_BUILD_VERSION's minos and sdk words, each 0x00XXYY00 for XX.YY, at
offsets 604 and 608.  libmalloc gives a program whose SDK is 12.0 or
older its legacy allocator.  The container is written straight from four
bytes of code, since the code generator writes for the machine it runs
on, and an arm64 program's code does not assemble on x86-64.

```cc
(import cc/macho macho-write!)
(import cc/prims mem-make)
(macho-write! "/tmp/xcc-spec24-version" (pair 4 (mem-make 4)) (pair 0 (mem-make 8)) ())
(def b (File read-all "/tmp/xcc-spec24-version"))
(File unlink "/tmp/xcc-spec24-version")
(display (List map (fn (_ i) (char->int (str-byte-ref b i))) (list 604 605 606 607 608 609 610 611)))
```
---
    (0 0 12 0 0 0 13 0)

### the signature starts at a 16-byte offset, as ld places it

LC_CODE_SIGNATURE's dataoff, at offset 752, is a multiple of 16, as ld
writes it: strip refuses a signature anywhere else.  Exporting `f` ends
the string table 8 bytes past a multiple of 16.

```cc
(import cc/macho macho-write!)
(import cc/prims mem-make)
(macho-write! "/tmp/xcc-spec24-sigoff" (pair 4 (mem-make 4)) (pair 0 (mem-make 8)) () (list (pair "f" (pair (lit text) 0))))
(def b (File read-all "/tmp/xcc-spec24-sigoff"))
(File unlink "/tmp/xcc-spec24-sigoff")
(def word (fn (_ i) (+ (char->int (str-byte-ref b i)) (* 256 (+ (char->int (str-byte-ref b (+ i 1))) (* 256 (char->int (str-byte-ref b (+ i 2)))))))))
(display (% (word 752) 16))
```
---
    0
