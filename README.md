# x-cc

<p align="center"><img src="docs/bitwise-banner.svg" alt="x-cc, with Bitwise the owl" width="100%"></p>

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
the named call would -- a native twin called through a pointer from
interpreted code stays native.

Structs go by value too: a struct parameter takes its size in the
callee's frame and copies from the argument; a struct returned by
value moves out of the popped frame into a fresh slot in the caller's
(alive until the caller returns), so `make(1, 2).x` and `add(make(1,
2), make(3, 4))` are safe.  In a macro body `#PARAM` is the argument's
text as a string literal and `A ## B` pastes, the rescan lexing the
joined token.

Refused loudly, each a recorded pending: goto, floats, casts to
function-pointer types, byte-accurate sizeof.

`build` lowers the ELIGIBLE functions through the engine's compile-asm
lane to NATIVE machine code, no external toolchain; the rest stay
interpreted (sha256.x's adoption pattern: refuse, fall back).  Three
body shapes lower: `if`/`return` recursion (fib), straight-line
assignments ending in a return, and **loops** -- a
`{ decls; while|for; return }` function transforms into tail self-
recursion, parameters and accumulators alike riding the self-call with
their folded new values (accumulators' literal inits by arg-padding).
The body fold takes assignments to any of them (a mutated parameter
included -- `gcd` compiles to recursive gcd), body-local temps
(substitution-only), `if`/`else` (each written variable merges as a
ternary), early exits -- `return`/`break`/`continue` inside the loop
as guarded exits, plus loop-invariant pre-loop guards, so search loops
and `isprime` go native -- inits over the parameters (a non-literal
init pads as its own tiny lane function, applied at the call boundary)
-- nested loops, two deep, as a state machine over the one self-call
(each re-entry runs a step of whichever loop is active; an inner
`break` is the transition to the outer step) -- and POINTERS.  The
program's memory is one raw buffer that the interpreter and the native
twins address alike (the lane's `%mem-ref-at`/`%mem-set-at!` with the
buffer's data address baked in), so a pointer is a cell index on both
sides and arrays cross the boundary for free: **a native bubble sort
sorts main's array**.  In a loop body, memory reads become load temps
at their evaluation point and stores become effects, emitted in
program order before the tail -- and when exits sit among the stores,
the stream lowers with each exit tested in its place.  **Sequential
loops** run as phases of the one self-call: a phase counter rides as
one more threaded variable and each loop's exit is the transition call
into the next.  **Cross-calls inline**: a non-recursive callee of the
if/return shape lowers with its own parameters, which substitute to
the lowered arguments (`cube` calls `sq`, `sumsq` calls `sq` in its
loop, an init calls `cube`); inside a loop body a cross-call evaluates
at its program point through a temp, so its reads order against the
stores.  **Globals** are memory at a known address, a scalar read and
written as `*(ADDR)`, an array its base.  Reads under `&&`, `||` and
`?:` run under a cond effect on the guard, so a read the C never
reaches never happens.  Threaded variables past the lane's four
arguments **spill** to scratch cells, read and written as memory,
their entry values stored by one compiled entry function at the call
boundary.  Loops nest to **any depth**: the state machine is
recursive, and a matrix product with a store between its levels goes
native.  `x -l cc -- build prog.c` reports each function's verdict and
runs, same output as `run`: fib(24) 67s -> 10.5s wall, a
2,000,000-iteration loop 79s -> 9.5s (the loop itself at machine speed
under the boot).  The **bitwise family lowers too** -- `&` `|` `^`
`<<` `>>` are single ARM64 instructions, and `>>` is arithmetic, so it
matches C on a signed word -- which makes shift-and-mask code (a
djb2 hash, a popcount loop) native.  **Arity**, measured rather than
assumed: a lane function takes any number of parameters, and only a
SELF-CALL is limited to four, which it must fill completely.  So an
eight-parameter leaf is native, a five-parameter recursion is not, and
a loop past four threaded variables spills the rest -- parameters
included, the call passing only what the lane kept.  `X_CC_WHY=1`
reports why each refused function refused, both paths.

A **third body shape** lowers as well: assignments and a return, with
no `if`/`return` ladder and no loop.  The same fold takes it, and
without a self-call nothing needs a lane slot -- every local is
substitution-only and an assigned parameter threads through the map --
so a rotation through a temp, an early return and a swap through
memory all go native.

**Struct fields lower too.**  The lane has no notion of a field, but
the cell model already says where one lives: a struct value IS its
address, and a field is a fixed offset from it, so before lowering
every `.` and `->` becomes explicit arithmetic -- `p->x` is
`*(p + off)`, `a[i].y` is `*(a + i*size + off)` -- and the load and
store machinery takes it from there.  A pointer walk down a linked
list, a sum over an array of structs, and a function reading two
by-value struct parameters are all native.  Writing through a POINTER
is the point and is allowed; assigning a field of a BY-VALUE parameter
would write the caller's copy, so it refuses.

**Local aggregates** get storage in the same pass: an array or struct
declared in a function takes a block of scratch cells, its name stands
for the base, and the declaration goes away -- one block per function
rather than per frame, so a genuinely recursive function with one
refuses while a loop function (same frame) is fine.  Because the pass
is shared, a local array now works in a straight-line body as well as
a loop, and an array of structs indexes with the right stride.

What remains, each a recorded pending and each the lane's own:
recursion of more than four parameters, callees with loops or
recursion, calls through pointers, and structs returned by value.

Paired with x-lang v0.10.0 (`lang.xon` is the checkable row).

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

<p align="center"><img src="docs/bitwise-mark.svg" alt="Bitwise" width="96"></p>
