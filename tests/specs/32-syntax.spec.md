# @weight 1

## cc/syntax -- the C highlighting grammar

The bundle's lang.xon declares a grammar, `c`, that x/tool/syntax colours C
files with. Its module, `cc/syntax`, imports x-lang libraries and cc/words
only, and registers the grammar as it loads.

The cases share one process, and a registered grammar stays registered, so
the catalogue's case comes first: it finds the grammar through lang.xon,
before anything has imported the module.

### the catalogue finds c by suffix and by modeline

The langs directory holds this bundle, linked as `cc`. The row comes from
lang.xon, its module not loaded until a file asks for the grammar, and the
grammar takes lang.xon's suffixes.

```cc
(do (import x/sys/posix) (import x/sys/file) (import x/tool/syntax)
    (def root (Str8 replace "/cc/syntax.x" "" (%module-resolve-file "cc/syntax.x")))
    (def tmp (File temp "/tmp/x-cc-spec-langs-"))
    (File close (first tmp))
    (def d (rest tmp))
    (File unlink d)
    (File mkdir d)
    (File symlink root (Str8 append d "/cc"))
    (def was (Sys getenv "X_LANG_DIR"))
    (Sys setenv "X_LANG_DIR" d)
    (Syntax forget!)
    (def row (List find (fn (_ r) (eq? (first r) (lit c))) (Syntax catalogue)))
    (def name (fn (_ path . text)
      (let ((g (apply Syntax (pair (lit for-file) (pair path text))))) (if (null? g) () (g name)))))
    (def seen
      (list (List ref 1 row)
            (name "x.c") (name "include/x.h")
            (name "x" "int x;\n/* vi: set ft=c: */\n")
            (name "x.txt")
            ((Syntax named (lit c)) files)))
    (File unlink (Str8 append d "/cc"))
    (File rmdir d)
    (Sys setenv "X_LANG_DIR" (if (null? was) "" was))
    (Syntax forget!)
    (write seen))
```
---
    (cc/syntax c c c () (".c" ".h"))

### a file's spans: directives, comments, types, keywords, constants

An #include's header is a string.  A type's keyword is a class, any other
keyword a keyword, any other name plain.  Brackets, commas and semicolons
are punctuation, the other punctuators operators.

```cc
(do (import x/tool/syntax) (import cc/syntax)
    (write ((Syntax named (lit c)) spans
      "#include <stdio.h>\n/* c */ int main(void) { return 'a' + 0x1fU; } // x\n")))
```
---
    ((0 8 keyword) (9 9 string) (19 7 comment) (27 3 class) (35 1 punct) (36 4 class) (40 1 punct) (42 1 punct) (44 6 keyword) (51 3 char) (55 1 operator) (57 5 number) (62 1 punct) (64 1 punct) (66 4 comment))

### a # with no directive after it, and prefixed literals

A directive may have blanks after its #.  A # before a name the
preprocessor does not know is an operator, the name plain.

```cc
(do (import x/tool/syntax) (import cc/syntax)
    (write ((Syntax named (lit c)) spans
      "#define S(x) #x ## y\n# if L'a' > u8\"s\"\n#warning w\n")))
```
---
    ((0 7 keyword) (9 1 punct) (11 1 punct) (13 1 operator) (16 2 operator) (21 4 keyword) (26 4 char) (31 1 operator) (33 5 string) (39 1 operator))

### a comment and a string left open run to the end

```cc
(do (import x/tool/syntax) (import cc/syntax)
    (write (List map (fn (_ s) ((Syntax named (lit c)) spans s))
      (list "x = /* open" "s = \"open"))))
```
---
    (((2 1 operator) (4 7 comment)) ((2 1 operator) (4 5 string)))

### the grammar's types are compiler keywords

The keywords are cc/words', the ones cc/tokens reads; the types the grammar
classes apart are among them.

```cc
(do (import cc/syntax cc-syntax-types) (import cc/words cc-keywords)
    (write (List filter (fn (_ w) (not (List includes? w cc-keywords))) cc-syntax-types)))
```
---
    ()

### a window reads from the line above it at the first column

Spans walk back from a window's first line to one starting with a name, a #
or a brace, so a block comment opened on a line above colours the window's
start.

```cc
(do (import x/tool/syntax) (import cc/syntax)
    (write ((Syntax named (lit c)) spans "int f;\n/* a\n  b */ x\n" 12 8)))
```
---
    ((12 6 comment))
