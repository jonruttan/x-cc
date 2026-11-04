# @weight 2
# @timeout-scale 3

An executable exports what the link line asks, for dlsym to find: the
names an -exported_symbols_list FILE lists (ld64's, a name a line, each
with Mach-O's leading _), or with -export_dynamic, --export-dynamic, -E or
-rdynamic every function and global.  A function's address is the one the
program's own pointer to it holds, the C library's way in; a global's is
its place in the data.  A name the program does not define is refused.
The program's output is what /usr/bin/cc prints for the same source and
list, but with nothing asked: GNU ld exports nothing then, and x-cc does
the same on every target, where ld64 would export every global.

## the plan

### -Wl, words: a list, -export_dynamic, -rdynamic; the rest ignored

```cc
(write (list (cc-cli-plan (list "a.o" "-Wl,-exported_symbols_list,exports.sym" "-Wl,-dead_strip" "-o" "x-bin")) (cc-cli-plan (list "a.o" "-Wl,-exported_symbols_list" "-Wl,more.sym" "-Wl,--gc-sections")) (cc-cli-plan (list "-rdynamic" "a.c" "-Wl,-export_dynamic")) (cc-cli-plan (list "a.c" "-Wl,-exported_symbols_list"))))
```
---
    ((build ("a.o") "x-bin" () () ("exports.sym")) (build ("a.o") "a.out" () () ("more.sym")) (build ("a.c") "a.out" () () (all)) (refuse ()))

## compiled

### a function and a global through dlsym, exported by name

```cc
(def src "#include <dlfcn.h>\n#include <stdio.h>\nint twice(int x) { return 2 * x; }\nlong counter = 41;\nint main(void) {\n  void *h = dlopen(0, RTLD_LAZY);\n  int (*f)(int) = (int (*)(int))dlsym(h, \"twice\");\n  long *c = (long *)dlsym(h, \"counter\");\n  printf(\"%d %ld %d %d %d\\n\", f(21), *c + 1, f == twice, c == &counter, dlsym(h, \"main\") == 0);\n  return 0;\n}\n")
(display (cc-exe-run-with src () (list "a.out") (list "twice" "counter")))
```
---
```output
42 42 1 1 1
0
```

### every function and global, main among them

```cc
(def src "#include <dlfcn.h>\n#include <stdio.h>\nint thrice(int x) { return 3 * x; }\nchar tag[] = \"all\";\nint main(void) {\n  void *h = dlopen(0, RTLD_LAZY);\n  int (*f)(int) = (int (*)(int))dlsym(h, \"thrice\");\n  printf(\"%d %s %d\\n\", f(14), (char *)dlsym(h, \"tag\"), dlsym(h, \"main\") != 0);\n  return 0;\n}\n")
(display (cc-exe-run-with src () (list "a.out") (lit all)))
```
---
```output
42 all 1
0
```

### nothing exported when nothing is asked, as GNU ld

```cc
(def src "#include <dlfcn.h>\n#include <stdio.h>\nint quad(int x) { return 4 * x; }\nint main(void) {\n  void *h = dlopen(0, RTLD_LAZY);\n  printf(\"%d %d\\n\", dlsym(h, \"quad\") == 0, quad(2));\n  return 0;\n}\n")
(display (cc-exe-run src))
```
---
```output
1 8
0
```

### a name the program does not define

```cc
(display (guard (e (e msg)) (cc-compile-image "int main(void) { return 0; }\n" (lit macho-arm64) (list "nowhere"))))
```
---
```output
cc: compile: exported symbol not defined: nowhere
```
