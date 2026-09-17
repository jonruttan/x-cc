# x-cc

<p align="center"><img src="docs/bitwise-banner.svg" alt="x-cc, with Bitwise the owl" width="100%"></p>

A C compiler on x-lang: a front end (preprocessor subset, lexer,
recursive-descent parser with all fifteen expression levels), a code
generator on the platform assembler, and Mach-O and ELF writers, so

    x -l cc -- build prog.c -o prog

writes an executable that the operating system runs directly: an arm64
Mach-O on macOS, an x86-64 ELF on Linux, for the platform the compiler
runs on.  No external assembler, linker or `codesign` is involved: the
instructions are encoded by x/tool/asm, the container is laid out, and
the Mach-O's ad-hoc code signature is hashed in x.

The Mach-O is dynamic, naming dyld and libSystem as the macOS kernel
requires of every executable; the ELF is static.  Both make system calls
directly rather than calling into a C library.  The code generator
evaluates expressions on a stack machine; an operator whose result can
leave `int`'s 32 bits sign-extends it again from bit 31, so arithmetic
wraps as C's `int` does.

Compiled so far: `int main(void) { return EXPR; }`, where EXPR is
built from integer constants, `+ - * / %`, `& | ^ << >>`, the six
comparisons, and unary `- ~ !`.  Anything else refuses by name.
Locals, control flow, calls, the runtime library and byte-accurate
types come next.

    x -l cc -- run prog.c

runs the same front end through an evaluator with a real memory model
instead, and is the reference the compiler is checked against: every
spec expectation comes from the same source compiled with /usr/bin/cc
and run.  Under `run`, fib recurses, pointers write through, arrays
decay into functions, bubble sort sorts, and the output matches the
real binary byte for byte.

THE CELL MODEL: memory is one vector of cells; every scalar is one
cell, sizeof any scalar is 1, pointer arithmetic counts cells.
Addresses are real (0 is NULL and guarded), locals live in memory so
&local works, the stack grows down and the heap up.  Programs that
scale by sizeof -- the malloc idiom -- run unchanged; byte-accurate
sizes are the recorded pending.

Working: int/char/void/pointer/array declarations (specifier soup
accepted, erased); all C89 operators with C precedence, short-circuit
&& || and the ternary; truncating division; if/else, while, do, for,
break, continue, return; functions with recursion and prototypes;
globals; string literals (interned); character constants; `#include`
(dropped -- the runtime provides putchar, puts, printf %d %c %s %x,
malloc, free, exit), object-like `#define` spliced token-wise; // and
/* */ comments.  By-value struct functions stay interpreted under
`build`; a scalar function they call still lowers.

Structs, too: `struct S { ... };`, `typedef struct { ... } T;`,
fields by `.` and `->`, nested structs, arrays of structs, pointers to
structs stepping by the struct's size, struct assignment as a cell
copy, `sizeof` a struct as its cell count, and the linked list built
from `malloc(sizeof(struct N))` -- oracle-checked.  A field access
whose chain the evaluator cannot type (a call's result) resolves by
the field's name when exactly one struct has it.

`switch` runs its matched clause and every clause after it as one
block -- fallthrough -- until a `break`; `return` and `continue` pass
through to the function or the enclosing loop.  Function-like macros
collect their arguments as text across balanced parentheses,
substitute at identifier boundaries, and rescan with the macro open;
no parentheses are added, as in C.

`#ifdef`/`#ifndef`/`#elif`/`#else`/`#endif`/`#undef` and the `#if`
forms a build header needs (`0`, `1`, `defined`) select lines; an
inactive region still tracks its nesting.  Initializer lists lay
values into cells by kind -- `int a[] = {…}` sized by the list,
`struct P p = {…}`, nested lists for arrays of structs, missing
trailing items zero, `char s[] = "…"` from the string's bytes.

Enums fold at parse time (`enum { A, B = 1 << 3, C }` -- constant
expressions, counting on from the last; the type is a scalar; `case
RED:` labels).  A union is a struct whose fields all sit at offset 0,
sized by its widest -- overlap, copy, nesting anonymously in a struct.
Function pointers: `int (*f)(int, int)` as a local, global, parameter,
struct field or typedef, arrays of them with initializer lists; a
function's name is its value (an id above every cell address, never
NULL), and `f(x)`, `(*f)(x)`, `ops[i](x)`, `p->fn(x)` all dispatch as
the named call would.

Structs go by value too: a struct parameter takes its size in the
callee's frame and copies from the argument; a struct returned by
value moves out of the popped frame into a fresh slot in the caller's
(alive until the caller returns), so `make(1, 2).x` and `add(make(1,
2), make(3, 4))` are safe.  In a macro body `#PARAM` is the argument's
text as a string literal and `A ## B` pastes, the rescan lexing the
joined token.

Refused loudly, each a recorded pending: goto, floats, casts to
function-pointer types, byte-accurate sizeof.

Paired with x-lang v0.13.0 (`lang.xon` is the checkable row).

## Tests

    make test           # the suite, loud on any failure
    make check          # judged against tests/contract/known-failures.txt

## Layout

    lang.xon          what this bundle IS (self-contained)
    run.x             the entry: operands mean "be cc"
    cc/pp.x           comments out, #include dropped, #define collected
    cc/lex.x          C tokens, macros spliced token-wise
    cc/parse.x        the fifteen-level ladder, declarations, statements
    cc/eval.x         the cell machine: memory, frames, calls, builtins
    cc/gen.x          code generation, through x/tool/asm
    cc/image.x        the byte image an executable is built in
    cc/macho.x        the macOS executable and its ad-hoc signature
    cc/elf.x          the Linux executable
    cc/cli.x          run FILE.c | build FILE.c [-o OUT]
    tests/            markdown specs + the platform's runner, vendored nowhere

<p align="center"><img src="docs/bitwise-mark.svg" alt="Bitwise" width="96"></p>
