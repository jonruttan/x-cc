# @weight 1
# @timeout-scale 2

cc's own command line, so x-cc stands in for cc where a Makefile calls it:
bare files build, -o names the output, -c makes an object, -D and -U
define and undefine before a file's first line, -I adds a directory an
#include looks in, and the options that ask for nothing x-cc does
differently are taken and ignored.  The lines are the ones x-engine-c's
Makefile writes.  An object is its file preprocessed under the -D and -I
before it, spelled back as C on the lines it came from, and a later line
builds from it without them.  The program's output is what /usr/bin/cc
prints for the same files.

## the plan

### a compile line from x-engine-c's Makefile

```cc
(write (cc-cli-plan (list "-c" "-O2" "-Wall" "-Wextra" "-Wno-unused-parameter" "-DX_HEAP" "-ffunction-sections" "-fdiagnostics-color=always" "-ansi" "-Iext/x-expr/include" "-I./include" "-DX_MACHINE=\"arm64\"" "-MMD" "-MP" "-o" "src/x-alist.o" "src/x-alist.c")))
```
---
    (compile ("src/x-alist.c") "src/x-alist.o" ("ext/x-expr/include/" "./include/") ("X_HEAP 1" "X_MACHINE \"arm64\""))

### a link line, bare files, build before them, -c with no -o, -fsyntax-only, -dumpmachine

```cc
(write (list (cc-cli-plan (list "-O2" "-Wall" "a.o" "b.o" "-ldl" "-lm" "-L" "/usr/lib" "-Wl,-dead_strip" "-o" "x-bin")) (cc-cli-plan (list "hello.c" "-o" "hello")) (cc-cli-plan (list "build" "a.c")) (cc-cli-plan (list "-c" "x/a.c" "b.c")) (cc-cli-plan (list "-fsyntax-only" "-I" "inc" "a.c")) (cc-cli-plan (list "-dumpmachine"))))
```
---
    ((build ("a.o" "b.o") "x-bin" () ()) (build ("hello.c") "hello" () ()) (build ("a.c") "a.out" () ()) (compile ("x/a.c" "b.c") () () ()) (check ("a.c") () ("inc/") ()) (machine))

### -D with a value, without one, function-like and empty; -U drops the ones before it

```cc
(write (cc-cli-plan (list "-D" "A" "-DB=2" "-DF(x)=((x)+1)" "-DA=3" "-UA" "-D" "C=" "-DA=4" "a.c")))
```
---
    (build ("a.c") "a.out" () ("B 2" "F(x) ((x)+1)" "C " "A 4"))

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

### the file preprocessed, each token on the line it came from

```cc
(cc-pp-options! () (list "N 7"))
(def o (cc-pp-object "t.c" "int a;\n\n/* two */\nint b = N + __LINE__;\n"))
(cc-pp-options! () ())
(write (list o (cc-pp-object-path o) (cc-pp-object-path "int a;\n")))
```
---
    ("/* x-cc object: t.c */int a ; \n\n\nint b = 7 + 4 ; \n" "t.c" ())

### two files and a header under -I, -D before each, built from the objects with other -D at the link

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
(def om (cc-pp-object "/tmp/xcc-spec81/src/main.c" (File read-all "/tmp/xcc-spec81/src/main.c")))
(cc-pp-options! (list "/tmp/xcc-spec81/inc/") (list "SCALE(x) ((x)*3)"))
(def og (cc-pp-object "/tmp/xcc-spec81/src/greet.c" (File read-all "/tmp/xcc-spec81/src/greet.c")))
; the link's own -D does not reach into the objects
(cc-pp-options! () (list "TIMES 5" "LOUD 0"))
(def units (list (pair (cc-pp-object-path om) om) (pair (cc-pp-object-path og) og)))
(def r (list (cc-run units) (cc-exe-run units)))
(cc-pp-options! () ())
(display r)
```
---
```output
world!
hello, world
world!
hello, world
(14 14)
```

### without the -D, the #else; without the -I, the quoted header is not found

```cc
(cc-pp-options! (list "/tmp/xcc-spec81/inc/") (list "WHO \"x\""))
(def om (cc-pp-object "/tmp/xcc-spec81/src/main.c" (File read-all "/tmp/xcc-spec81/src/main.c")))
(cc-pp-options! () ())
(def missing
  (guard (e (if (Err err? e) (e msg) e))
    (cc-pp-object "/tmp/xcc-spec81/src/main.c" (File read-all "/tmp/xcc-spec81/src/main.c"))))
(write (list (if (Str8 %find-bytes "quiet" 0 om) #t #f) (if (Str8 %find-bytes "x!" 0 om) #t #f) missing))
```
---
    (#t #f "cc: #include \"/tmp/xcc-spec81/src/greet.h\": no such file")
