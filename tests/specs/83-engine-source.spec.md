# @weight 1
# @timeout-scale 2

What x-engine-c's own source asks of x-cc, in the shapes its
files spell: `#pragma GCC diagnostic` around a call (src/x-cli.c), which
is ignored, as C says a pragma a compiler does not know is; `#warning`
under a guard -D leaves off (ext/x-expr/include/x-heap.h), and `#error`,
which refuses with its text; `__attribute__((unused))` on a static
function (include/x-prim.h) and `__attribute__((no_sanitize_address))`
behind a macro (src/x-prim/callcc.c), read as nothing; and a header found
through -I that includes another by a name from the -I directory, not
from its own (include/x-type/err.h's "x-type.h"); and a union initialized
by a designator, which takes the member it names (src/x-env.c's
`{ .i = 0 }` for an x_obj_t); and offsetof in a static table, a constant
(src/x-prim/type.c); and a function's address cast to a data pointer in
a global's initializer (src/x-type.c's `(x_obj_t *)&x_type_save_default`),
and a call through a conditional of a pointer and a function's name
(include/x-eval-slots.h's x_eval_call_or); and sigaction's record
(opt/x-prim/signal.c).  The program's output is what /usr/bin/cc prints
for the same source.

## directives and attributes

### a pragma around a call, an attribute on a static function and one behind a macro

```cc
(def src "#include <stdio.h>\n#define X_CALLCC_NO_ASAN __attribute__((no_sanitize_address))\n__attribute__((unused)) static int spare(void) { return 1; }\nX_CALLCC_NO_ASAN static int copy(int n) { return n * 2; }\nint main(void) {\n  int r;\n#pragma GCC diagnostic push\n#pragma GCC diagnostic ignored \"-Wdeprecated-declarations\"\n  r = copy(21);\n#pragma GCC diagnostic pop\n  printf(\"%d\\n\", r);\n  return 0;\n}\n")
(display (list (cc-run src) (cc-exe-run src)))
```
---
```output
42
42
(0 0)
```

### #warning under a guard -D leaves off reads as a directive; #error refuses with its text

```cc
(cc-pp-options! () (list "X_HEAP 1"))
(def quiet (List length (cc-lex "#ifndef X_HEAP\n#warning X_HEAP is required\n#endif\nint x;\n")))
(cc-pp-options! () ())
(def said (guard (e (if (Err err? e) (e msg) e)) (cc-lex "#ifndef X_HEAP\n#error X_HEAP is required\n#endif\nint x;\n")))
(write (list quiet said))
```
---
    (3 "cc: #error X_HEAP is required")

## includes

### a header found through -I includes another by a name from the -I directory

```cc
(def put
  (fn (_ path text)
    (def fd (File open path (list 'wronly 'creat 'trunc) 420))
    (File write fd text (Str8 length text))
    (File close fd)))
(Proc capture (list "mkdir" "-p" "/tmp/xcc-spec83/include/x-type" "/tmp/xcc-spec83/src"))
(put "/tmp/xcc-spec83/include/x-type.h" "#ifndef X_TYPE_H\n#define X_TYPE_H\n#define X_TYPE_ERR 7\n#endif\n")
(put "/tmp/xcc-spec83/include/x-type/err.h" "#ifndef X_TYPE_ERR_H\n#define X_TYPE_ERR_H\n#include \"x-type.h\"\nstatic int err_code(void) { return X_TYPE_ERR; }\n#endif\n")
(put "/tmp/xcc-spec83/src/main.c" "#include <stdio.h>\n#include \"x-type/err.h\"\n#include \"x-type.h\"\nint main(void) { printf(\"%d\\n\", err_code()); return 0; }\n")
(cc-pp-options! (list "/tmp/xcc-spec83/include/") ())
(def units (list (pair "/tmp/xcc-spec83/src/main.c" (File read-all "/tmp/xcc-spec83/src/main.c"))))
(def r (list (cc-run units) (cc-exe-run units)))
(cc-pp-options! () ())
(display r)
```
---
```output
7
7
(0 0)
```

## unions

### a designator names the member a union takes, in a global, a local array and a scalar

```cc
(def src "#include <stdio.h>\ntypedef union u { void *p; long i; char c; } u_t;\nstatic u_t g[2] = { { .p = 0 }, { .i = 7 } };\nint main(void) {\n  u_t a[2] = { { .p = 0 }, { .i = 9 } };\n  u_t b = { .c = 'A' };\n  printf(\"%ld %ld %c\\n\", g[1].i, a[1].i, b.c);\n  return 0;\n}\n")
(display (list (cc-run src) (cc-exe-run src)))
```
---
```output
7 9 A
7 9 A
(0 0)
```

## offsetof

### a static table of names and offsetof, as a constant

```cc
(def src "#include <stdio.h>\n#include <stddef.h>\nstruct t { long a; char b; void *c; struct { int x; int y; } in; };\nint main(void) {\n  static const struct { char *name; size_t offset; } fields[] = {\n    { \"a\", offsetof(struct t, a) },\n    { \"c\", offsetof(struct t, c) },\n    { \"y\", offsetof(struct t, in.y) }\n  };\n  int i;\n  for (i = 0; i < 3; i++) printf(\"%s %d\\n\", fields[i].name, (int)fields[i].offset);\n  return 0;\n}\n")
(display (list (cc-run src) (cc-exe-run src)))
```
---
```output
a 0
c 16
y 28
a 0
c 16
y 28
(0 0)
```

## a function's address in the data

### a global's pointer starts at a function's address through a cast

```cc
(def src "#include <stdio.h>\nstatic int twice(int n) { return n * 2; }\ntypedef union u { void *p; long i; } u_t;\nu_t g = { (void *)&twice };\nint main(void) {\n  int (*f)(int) = (int (*)(int))g.p;\n  printf(\"%d\\n\", f(21));\n  return 0;\n}\n")
(display (list (cc-run src) (cc-exe-run src)))
```
---
```output
42
42
(0 0)
```

### a call through a conditional of a pointer and a function's name

```cc
(def src "#include <stdio.h>\ntypedef int (*fn_t)(int);\nstatic int twice(int n) { return n * 2; }\nstatic int thrice(int n) { return n * 3; }\nint main(void) {\n  fn_t slot = 0;\n  printf(\"%d\\n\", (slot ? slot : twice)(21));\n  slot = thrice;\n  printf(\"%d\\n\", (slot ? slot : twice)(21));\n  return 0;\n}\n")
(display (list (cc-run src) (cc-exe-run src)))
```
---
```output
42
63
42
63
(0 0)
```

## signals

### a handler set through sigaction's record, raised, and read back

The program is built and run, not interpreted: a function stored in a
record that the C library reads later does not become a callback under run.

```cc
(def src "#include <stdio.h>\n#include <signal.h>\n#include <signal.h>\nstatic volatile sig_atomic_t hit;\nstatic void handler(int s) { (void)s; hit = 1; }\nint main(void) {\n  struct sigaction sa, old;\n  sa.sa_handler = handler;\n  sa.sa_flags = 0;\n  sigemptyset(&sa.sa_mask);\n  printf(\"%d\\n\", sigaction(SIGINT, &sa, NULL));\n  raise(SIGINT);\n  sigaction(SIGINT, NULL, &old);\n  printf(\"%d %d %d\\n\", (int)hit, old.sa_handler == handler, (old.sa_flags & SA_RESTART) == 0);\n  return 0;\n}\n")
(display (cc-exe-run src))
```
---
```output
0
1 1 1
0
```
