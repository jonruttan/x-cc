# x-cc card

## Run

```sh
x -l cc -- run FILE.c [ARG ...]
x -l cc -- FILE.c -o OUT
x -l cc -- run tests/card/hello.c -> hello, 42
d=$(mktemp -d); x -l cc -- tests/card/hello.c -o $d/h && $d/h -> hello, 42
```

```cc
#include <stdio.h>

int main(void) {
    printf("hello, %d\n", 6 * 7);                        // -> hello, 42
    return 0;
}
```

| Run                            | Is                                          |
|--------------------------------|---------------------------------------------|
| `x -l cc -- run FILE.c ARG ...` | the program interpreted; ARGs are its argv |
| `x -l cc -- FILE.c -o OUT`     | an executable for this machine, at OUT      |
| `x -l cc -- FILE.c`            | the same, at `a.out`                        |
| `x -l cc -- -c FILE.c`         | an object, `FILE.o`, for a later link       |
| `x -l cc -- A.c B.c LIB.o -o OUT` | several files and objects, one program   |
| `-D NAME[=VALUE]` `-U NAME`    | define a macro, or undefine one             |
| `-I DIR`                       | look for `#include "..."` files in DIR too  |
| `-fsyntax-only`                | read the files and stop                     |
| `-dumpmachine`                 | the target's name                           |
| `-O` `-g` `-W...` `-std=` `-l` | taken and ignored                           |
| `x -l cc -- --help`            | the options                                 |
| the exit status                | what main returns, run or built             |

## Types

| C type                         | Bytes | Holds                               |
|--------------------------------|-------|-------------------------------------|
| `char`, signed or unsigned     | 1     | a byte                              |
| `short` `unsigned short`       | 2     | 16 bits                             |
| `int` `unsigned`               | 4     | 32 bits; arithmetic wraps as C's    |
| `long` `long long`, unsigned too | 8   | 64 bits                             |
| `float`                        | 4     | an IEEE single                      |
| `double`                       | 8     | an IEEE double                      |
| `_Bool`, `bool` of `<stdbool.h>` | 1   | 0 or 1                              |
| `T *`                          | 8     | an address                          |
| `enum { A, B = 8, C }`         | 4     | names for constants, counting on    |

```cc
#include <stdio.h>
#include <stdint.h>
#include <stdbool.h>

int main(void) {
    printf("%zu %zu %zu %zu\n", sizeof(char), sizeof(short), sizeof(int),
           sizeof(long));                                // -> 1 2 4 8
    printf("%zu %zu %zu\n", sizeof(float), sizeof(double),
           sizeof(void *));                              // -> 4 8 8
    unsigned char c = 250;
    c += 10;
    int big = 2147483647;
    unsigned int u = 0;
    printf("%d %u\n", c, u - 1);                         // -> 4 4294967295
    int64_t wide = (int64_t)big + 1;
    bool yes = 42;
    printf("%lld %d\n", (long long)wide, yes);           // -> 2147483648 1
    printf("%d %d %.2f\n", 7 / 2, -7 % 3, 7 / 2.0);      // -> 3 -1 3.50
    enum { RED, GREEN = 1 << 3, BLUE };
    printf("%d %d %d\n", RED, GREEN, BLUE);              // -> 0 8 9
    return 0;
}
```

## Control flow

| Statement                          | Does                                    |
|------------------------------------|-----------------------------------------|
| `if (E) S else S`                  | one branch                              |
| `while (E) S` `do S while (E);`    | a loop; `do` runs S once first          |
| `for (int i = 0; E; i++) S`        | a loop with its own counter             |
| `break;` `continue;`               | leave the loop; go to its next pass     |
| `switch (E) { case K: ... default: }` | falls through to the next `break`    |
| `goto NAME;` `NAME: S`             | a jump inside the function              |
| `E ? A : B` `A && B` `A \|\| B`    | only the operand that is needed is run  |

```cc
#include <stdio.h>

int main(void) {
    int sum = 0;
    for (int i = 1; i <= 10; i++) {
        if (i % 2) continue;
        sum += i;
    }
    printf("%d\n", sum);                                 // -> 30
    int n = 27, steps = 0;
    while (n != 1) {
        n = n % 2 ? 3 * n + 1 : n / 2;
        steps++;
    }
    printf("%d\n", steps);                               // -> 111
    do { steps -= 100; } while (steps > 0);
    switch (steps) {
    case -89: printf("a");
    case 0:   printf("b"); break;
    default:  printf("c");
    }
    printf("\n");                                        // -> ab
    for (int i = 0;; i++)
        if (i * i > 50) { printf("%d\n", i); goto done; } // -> 8
done:
    return 0;
}
```

## Pointers, arrays, structs

| Form                              | Is                                       |
|-----------------------------------|------------------------------------------|
| `&X` `*P`                         | X's address; what P points at            |
| `P + N` `P[N]`                    | N elements on; the element there         |
| `int a[] = {5, 3, 8}`             | an array sized by its list               |
| `struct point { int x, y; }`      | a struct; `S.x`, and `P->x` by pointer   |
| `{.y = 4, .x = 3}` `{[2] = 9}`    | designators; what none names is zero     |
| `(struct point){1, 2}`            | a compound literal                       |
| `union { ... }`                   | fields that share their bytes            |
| `typedef T NAME;`                 | a name for a C type                      |
| `int a[n][m]`                     | a variable-length array, in a function   |
| `int flag : 3;`                   | a bit-field, of an integer type but long |

```cc
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

struct point { int x, y; };
typedef struct node { int value; struct node *next; } node;

void swap(int *a, int *b) { int t = *a; *a = *b; *b = t; }

int main(void) {
    int a[] = {5, 3, 8, 1};
    swap(&a[0], a + 3);
    printf("%d %d %zu\n", a[0], *(a + 3), sizeof a / sizeof a[0]); // -> 1 5 4
    struct point p = {.y = 4, .x = 3}, q = p;
    struct point *pp = &q;
    pp->x += 10;
    printf("%d %d %d\n", p.x, q.x, pp->y);               // -> 3 13 4
    node *head = NULL;
    for (int i = 1; i <= 3; i++) {
        node *n = malloc(sizeof(node));
        n->value = i * i;
        n->next = head;
        head = n;
    }
    for (node *n = head; n; n = n->next) printf("%d", n->value);
    printf("\n");                                        // -> 941
    char s[16] = "card";
    strcat(s, "!");
    printf("%s %zu %c\n", s, strlen(s), s[1]);           // -> card! 5 a
    union { unsigned int word; unsigned char bytes[4]; } w = {0x01020304};
    printf("%d\n", w.bytes[0]);                          // -> 4
    return 0;
}
```

## Functions

| Form                              | Is                                       |
|-----------------------------------|------------------------------------------|
| `int f(int a, int b) { ... }`     | a function; it may call itself           |
| `int f(int, int);`                | a prototype, for a use before the body   |
| `static int n;` in a function     | a local kept between calls               |
| `int f(int n, ...)`               | variadic: `va_start` `va_arg` `va_end`   |
| `int (*g)(int, int) = f;`         | a pointer to a function; `g(1, 2)` calls |
| `struct point f(struct point p)`  | structs go and come back by value        |
| `__func__`                        | the function's name, a string            |
| `main(int argc, char **argv)`     | the command line                         |

```cc
#include <stdio.h>
#include <stdlib.h>
#include <stdarg.h>

int fib(int n) { return n < 2 ? n : fib(n - 1) + fib(n - 2); }

int count(void) { static int calls; return ++calls; }

int total(int n, ...) {
    va_list ap;
    int sum = 0;
    va_start(ap, n);
    while (n--) sum += va_arg(ap, int);
    va_end(ap);
    return sum;
}

int add(int a, int b) { return a + b; }
int mul(int a, int b) { return a * b; }

int by_value(const void *a, const void *b) {
    return *(const int *)a - *(const int *)b;
}

int main(void) {
    printf("%d\n", fib(20));                             // -> 6765
    count(); count();
    printf("%d %d\n", count(), total(3, 10, 20, 30));    // -> 3 60
    int (*ops[])(int, int) = {add, mul};
    printf("%d %d\n", ops[0](6, 7), ops[1](6, 7));       // -> 13 42
    int v[] = {4, 1, 3, 2};
    qsort(v, 4, sizeof v[0], by_value);
    printf("%d%d%d%d %s\n", v[0], v[1], v[2], v[3], __func__); // -> 1234 main
    return 0;
}
```

## Preprocessor

| Directive                          | Does                                    |
|------------------------------------|-----------------------------------------|
| `#include <stdio.h>`               | a standard header's macros and types    |
| `#include "file.h"`                | a file, from the including file's place |
| `#define NAME VALUE`               | a macro                                 |
| `#define F(x) ((x) * (x))`         | a macro with parameters                 |
| `#x` `a ## b` `__VA_ARGS__`        | a string of x; pasted; the `...` words  |
| `#if E` `#elif E` `#else` `#endif` | lines chosen by a constant expression   |
| `#ifdef NAME` `#ifndef NAME`       | lines chosen by whether NAME is defined |
| `#undef NAME`                      | forget a macro                          |
| `__LINE__` `__FILE__`              | the line's number; the file's path      |
| `_Static_assert(E, "why")`         | refuses the program when E is 0         |

```cc
#include <stdio.h>

#define SIZE 8
#define SQUARE(x) ((x) * (x))
#define NAME(x) #x
#define JOIN(a, b) a ## b
#define SHOW(fmt, ...) printf(fmt "\n", __VA_ARGS__)

#if SIZE > 4 && !defined(SMALL)
#define MODE "big"
#else
#define MODE "small"
#endif

int main(void) {
    int JOIN(total, 1) = SQUARE(SIZE + 1);
    SHOW("%d %s %s", total1, NAME(SIZE), MODE);          // -> 81 SIZE big
    SHOW("%d", __LINE__);                                // -> 18
#ifdef SIZE
    _Static_assert(sizeof(int) == 4, "int is 32 bits");
    SHOW("%s", "ok");                                    // -> ok
#endif
    return 0;
}
```

## Numbers

| Form                               | Is                                      |
|------------------------------------|-----------------------------------------|
| `42` `052` `0x2a` `42u` `42L`      | an integer: decimal, octal, hex, typed  |
| `1.5` `1e3` `1.5f` `0x1.8p3`       | a double; with `f`, a float             |
| `'a'` `'\n'` `'\x41'`              | a character, an int                     |
| `+ - * / %`                        | arithmetic; `/` of integers truncates   |
| `& \| ^ ~ << >>`                   | bits                                    |
| `(int)X`                           | X converted to a C type                 |
| `sqrt` `pow` `fmod` `sin` ...      | `<math.h>`: the C library's own         |
| `INT_MAX` `UINT64_MAX` `M_PI`      | `<limits.h>` `<stdint.h>` `<math.h>`    |

```cc
#include <stdio.h>
#include <math.h>
#include <limits.h>

int main(void) {
    double r = sqrt(2.0);
    float f = 1.0f / 3;
    printf("%.4f %.0f %.1f\n", r, pow(2, 10), fmod(7.5, 2));
    printf("%.7f %d\n", f, (int)3.99);
    // -> 1.4142 1024 1.5
    // -> 0.3333333 3
    printf("%d %x %o\n", INT_MAX, 255, 8);               // -> 2147483647 ff 10
    printf("%d %d %d\n", 6 & 3, 6 | 3, 6 ^ 3);           // -> 2 7 5
    printf("%d %d %d\n", 1 << 10, -16 >> 2, ~0);         // -> 1024 -4 -1
    printf("%.3f\n", M_PI);                              // -> 3.142
    return 0;
}
```

## Input and output

| Call                               | Does                                    |
|------------------------------------|-----------------------------------------|
| `printf(FMT, ...)` `puts(S)` `putchar(C)` | write to standard output         |
| `fprintf(stderr, FMT, ...)`        | write to a stream                       |
| `snprintf(BUF, SIZE, FMT, ...)`    | write into a buffer                     |
| `fgets(BUF, SIZE, stdin)` `getchar()` | read a line; a character             |
| `fopen` `fread` `fwrite` `fclose`  | files, by the C library                 |
| `malloc` `calloc` `realloc` `free` | memory, by the C library                |
| `strlen` `strcpy` `strcmp` `memcpy` ... | `<string.h>`                       |
| `isalpha` `isdigit` `toupper` ...  | `<ctype.h>`                             |
| any other function of the C library | called by name, six arguments at most  |

```input
one two
xy 12
```

```cc
#include <stdio.h>
#include <string.h>
#include <ctype.h>

int main(int argc, char **argv) {
    char line[64];
    int lines = 0, letters = 0;
    while (fgets(line, sizeof line, stdin)) {
        lines++;
        for (char *p = line; *p; p++)
            if (isalpha(*p)) letters++;
    }
    printf("%d %d %d\n", lines, letters, argc);          // -> 2 8 1
    char buf[32];
    snprintf(buf, sizeof buf, "%05d|%-4s|%4s|", 42, "ab", "cd");
    puts(buf);                                           // -> 00042|ab  |  cd|
    return 0;
}
```

## Headers

| Header                                  | Gives                              |
|-----------------------------------------|------------------------------------|
| `stdio.h` `stdlib.h` `string.h`         | `EOF` `NULL` `EXIT_FAILURE`        |
| `stddef.h` `stdint.h` `inttypes.h`      | `size_t` `offsetof` `int64_t`      |
| `stdbool.h` `limits.h` `float.h`        | `bool` `INT_MAX` `DBL_EPSILON`     |
| `math.h` `errno.h` `assert.h`           | `M_PI` `HUGE_VAL` `errno` `assert` |
| `stdarg.h` `setjmp.h` `signal.h`        | `va_list` `jmp_buf` `SIGUSR1`      |
| `time.h` `locale.h`                     | `struct tm` `struct lconv`         |
| `unistd.h` `fcntl.h` `dlfcn.h`          | the system's calls                 |
| `sys/types.h` `sys/stat.h` `sys/wait.h` | `ssize_t` `struct stat`            |
| `dirent.h` `sys/syscall.h`              | `struct dirent`                    |
| any other header                        | nothing: the line is dropped       |
| a function no header here declares      | the C library's, called by name    |

## Differs

| Here                                        | In C                          |
|---------------------------------------------|-------------------------------|
| `long double` is refused by name            | a C type                      |
| a bit-field of a `long` is refused          | allowed by most compilers     |
| a compound literal in a `for`'s condition or step is refused | allowed      |
| `__DATE__` and `__TIME__` are not defined   | when the program was built    |
| `#ifdef __FILE__` and `#ifdef __LINE__` are false | true                    |
| `#ifdef __STDC__`, `__STDC_VERSION__` are false | true                      |
| a header not in Headers gives nothing       | its macros and types          |
| a call to a function nothing defines is refused by name | a link error      |
| under `run`, a read through a null pointer stops by name | a crash          |
| a refusal reads `not built yet: WHAT`       | a diagnostic                  |
| `-O`, `-g`, `-W` change nothing             | optimizing, debugging, warning |

## More

| Where                               | What                              |
|-------------------------------------|-----------------------------------|
| `x -l cc -- --help`                 | the options                       |
| `README.md`                         | what is built, and how            |
| `tests/specs/`                      | each feature, checked against cc  |
| `tests/contract/known-failures.txt` | each spec that fails, and why     |
| `make card`                         | runs every program on this page   |
