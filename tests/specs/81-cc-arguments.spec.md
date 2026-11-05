# @weight 1
# @timeout-scale 2

cc's own command line, so x-cc stands in for cc where a Makefile calls it:
bare files build, -o names the output, -c makes an object, -D and -U
define and undefine before a file's first line, -I adds a directory an
#include looks in, and the options that ask for nothing x-cc does
differently are taken and ignored.  The lines are the ones x-engine-c's
Makefile writes.  An object is its file compiled under the -D and -I
before it, an object file of x/tool/link's -- its code and data, its
functions and globals as symbols, and the names it takes of other units
as relocations -- and a later line links it without them.  The program's
output is what /usr/bin/cc prints for the same files.

## the plan

### a compile line from x-engine-c's Makefile

```cc
(write (cc-cli-plan (list "-c" "-O2" "-Wall" "-Wextra" "-Wno-unused-parameter" "-DX_HEAP" "-ffunction-sections" "-fdiagnostics-color=always" "-ansi" "-Iext/x-expr/include" "-I./include" "-DX_MACHINE=\"arm64\"" "-MMD" "-MP" "-o" "src/x-alist.o" "src/x-alist.c")))
```
---
    (compile ("src/x-alist.c") "src/x-alist.o" ("ext/x-expr/include/" "./include/") ("X_HEAP 1" "X_MACHINE \"arm64\"") ())

### a link line, bare files, build before them, -c with no -o, -fsyntax-only, -dumpmachine

```cc
(write (list (cc-cli-plan (list "-O2" "-Wall" "a.o" "b.o" "-ldl" "-lm" "-L" "/usr/lib" "-Wl,-dead_strip" "-o" "x-bin")) (cc-cli-plan (list "hello.c" "-o" "hello")) (cc-cli-plan (list "build" "a.c")) (cc-cli-plan (list "-c" "x/a.c" "b.c")) (cc-cli-plan (list "-fsyntax-only" "-I" "inc" "a.c")) (cc-cli-plan (list "-dumpmachine"))))
```
---
    ((build ("a.o" "b.o") "x-bin" () () ()) (build ("hello.c") "hello" () () ()) (build ("a.c") "a.out" () () ()) (compile ("x/a.c" "b.c") () () () ()) (check ("a.c") () ("inc/") () ()) (machine))

### -D with a value, without one, function-like and empty; -U drops the ones before it

```cc
(write (cc-cli-plan (list "-D" "A" "-DB=2" "-DF(x)=((x)+1)" "-DA=3" "-UA" "-D" "C=" "-DA=4" "a.c")))
```
---
    (build ("a.c") "a.out" () ("B 2" "F(x) ((x)+1)" "C " "A 4") ())

### refused: an option x-cc does not take, one with no value, a -D with no name, one -o for several objects, no files

```cc
(write (list (cc-cli-plan (list "-E" "a.c")) (cc-cli-plan (list "-shared" "a.c")) (cc-cli-plan (list "--nope" "a.c")) (cc-cli-plan (list "a.c" "-D")) (cc-cli-plan (list "-D=1" "a.c")) (cc-cli-plan (list "a.c" "-I")) (cc-cli-plan (list "-c" "-o" "x.o" "a.c" "b.c")) (cc-cli-plan (list "-O2"))))
```
---
    ((refuse "-E") (refuse "-shared") (refuse "--nope") (refuse "-D") (refuse "-D") (refuse "-I") (refuse ()) (refuse ()))

### the words

```cc
(write (list (cc-refusal "-E") (cc-refusal "-shared") (cc-refusal "-D") (cc-refusal "-I") (cc-refusal "-MF")))
```
---
    ("unrecognized option: E" "unrecognized option: shared" "option requires an argument: D" "option requires an argument: I" "option requires an argument: MF")

## objects

### a unit's object: its sections, its symbols, the names it takes

A global is a symbol in the data, a function one in the text; a static is
the unit's own, and a static function has a second name, with the unit's
appended, that the linker's thunk for it can take; a function another
unit defines, called through its prototype, and the C library's function
a call names are relocations.

```cc
(cc-pp-options! () (list "N 7"))
(def o (cc-compile-unit "#include <stdio.h>\nint a = N;\nstatic int b;\nint twice(int);\nstatic int helper(void) { return b; }\nint main(void) { puts(\"hi\"); return twice(a) + helper(); }\n" (cc-target)))
(cc-pp-options! () ())
(write (list (List map (fn (_ s) (list (first s) (first (rest s)))) (first o))
             (List map (fn (_ s) (list (first s) (first (rest s)) (first (rest (rest (rest s))))))
                  (List filter (fn (_ s) (not (Str8 %find-bytes "@" 0 (first s)))) (first (rest o))))
             (List uniq (List sort (fn (_ a b) (Str8 <? a b))
                          (List map (fn (_ r) (first (rest (rest (rest r))))) (first (rest (rest o))))))))
```
---
    (((text 16) (data 16)) ((".data" data local) ("a" data global) ("b" data local) ("helper" text local) ("main" text global)) (".data" "a" "b" "puts@slot" "twice"))

### an object file written and read back

```cc
(def o (cc-compile-unit "int n = 3;\nint main(void) { return n; }\n" (cc-target)))
(import x/tool/link link-write! link-read)
(link-write! "/tmp/xcc-spec81.o" o)
(def back (link-read "/tmp/xcc-spec81.o"))
(write (list (List map first (first back))
             (first (rest back))
             (Str8 sub 0 9 (File read-all "/tmp/xcc-spec81.o"))))
```
---
    ((text data) ((".data" data 0 local) ("n" data 0 global) ("main" text 0 global)) "x-object ")

### two files and a header under -I, -D before each, linked from the objects with other -D at the link

```cc
(def put
  (fn (_ path text)
    (def fd (File open path (list 'wronly 'creat 'trunc) 420))
    (File write fd text (Str8 length text))
    (File close fd)))
(Proc capture (list "mkdir" "-p" "/tmp/xcc-spec81/inc" "/tmp/xcc-spec81/src"))
(put "/tmp/xcc-spec81/inc/greet.h" "#ifndef GREET_H\n#define GREET_H\n#define TIMES 2\nint greet(const char *who);\n#endif\n")
(put "/tmp/xcc-spec81/src/main.c" "#include <stdio.h>\n#include \"greet.h\"\nint main(void) {\n#ifdef LOUD\n  printf(\"%s!\\n\", WHO);\n#else\n  printf(\"quiet\\n\");\n#endif\n  return greet(WHO) * TIMES;\n}\n")
(put "/tmp/xcc-spec81/src/greet.c" "#include <stdio.h>\n#include <greet.h>\nstatic int count = 1;\nint greet(const char *who) { printf(\"hello, %s\\n\", who); return count + SCALE(2); }\n")
(cc-pp-options! (list "/tmp/xcc-spec81/inc/") (list "LOUD 1" "WHO \"world\""))
(def om (cc-compile-unit (list (pair "/tmp/xcc-spec81/src/main.c" (File read-all "/tmp/xcc-spec81/src/main.c"))) (cc-target)))
(cc-pp-options! (list "/tmp/xcc-spec81/inc/") (list "SCALE(x) ((x)*3)"))
(def og (cc-compile-unit (list (pair "/tmp/xcc-spec81/src/greet.c" (File read-all "/tmp/xcc-spec81/src/greet.c"))) (cc-target)))
; the link's own -D does not reach into the objects
(cc-pp-options! () (list "TIMES 5" "LOUD 0"))
(cc-link (list om og) (cc-target) "/tmp/xcc-spec81/a.out" ())
(cc-pp-options! () ())
(def r (Proc capture (list "/tmp/xcc-spec81/a.out")))
(display (rest r))
(write (first r))
```
---
```output
world!
hello, world
14
```

### without the -D, the #else; without the -I, the quoted header is not found

```cc
(cc-pp-options! (list "/tmp/xcc-spec81/inc/") (list "WHO \"x\""))
(def om (cc-compile-unit (list (pair "/tmp/xcc-spec81/src/main.c" (File read-all "/tmp/xcc-spec81/src/main.c"))) (cc-target)))
(cc-pp-options! (list "/tmp/xcc-spec81/inc/") (list "SCALE(x) ((x)*3)"))
(def og (cc-compile-unit (list (pair "/tmp/xcc-spec81/src/greet.c" (File read-all "/tmp/xcc-spec81/src/greet.c"))) (cc-target)))
(cc-pp-options! () ())
(cc-link (list om og) (cc-target) "/tmp/xcc-spec81/quiet" ())
(def missing
  (guard (e (if (Err err? e) (e msg) e))
    (cc-compile-unit (list (pair "/tmp/xcc-spec81/src/main.c" (File read-all "/tmp/xcc-spec81/src/main.c"))) (cc-target))))
(def r (Proc capture (list "/tmp/xcc-spec81/quiet")))
(write (list (rest r) (first r) missing))
```
---
    ("quiet\nhello, x\n" 14 "cc: #include \"/tmp/xcc-spec81/src/greet.h\": no such file")
