# x-cc

A C compiler on x-lang -- the self-hosting arc's final tier, slice
one: the full front end (preprocessor subset, lexer, recursive-descent
parser with all fifteen expression levels) and an evaluator with a
real memory model, so

    x -l cc -- run prog.c

EXECUTES C, oracle-checked: every spec expectation comes from the same
source compiled with /usr/bin/cc and run.  fib recurses, pointers
write through, arrays decay into functions, bubble sort sorts, and the
output matches the real binary byte for byte.

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
/* */ comments.

Refused loudly, each a recorded pending: struct/union/enum/typedef,
switch, goto, floats, function pointers, initializer lists,
function-like macros, #ifdef, byte-accurate sizeof.

`build` is here, slice one: the ELIGIBLE functions -- integers all
the way, every path a return, self-calls only (the lane's own rule) --
lower through the engine's compile-asm lane to NATIVE machine code, no
external toolchain, and the rest stay interpreted (sha256.x's adoption
pattern: refuse, fall back).  `x -l cc -- build prog.c` reports each
function's verdict (native/interp) and runs: same output as `run`,
measured 67s -> 10.5s wall on fib(24), the compiled function itself at
machine speed.  Pointers, loops, globals and cross-calls in the lane
are the recorded pendings -- each one lane feature away.

Paired with x-lang v0.9.0 (`lang.xon` is the checkable row).

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
    cc/build.x        the eligible-class lowerer onto compile-asm
    cc/cli.x          run FILE.c | build FILE.c
    tests/            markdown specs + the platform's runner, vendored nowhere
