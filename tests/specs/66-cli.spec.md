# @weight 1

The command line, through one Opts declaration.  busybox has no cc, so the
help text is this bundle's, laid out as busybox lays its help out.
`cc --help` prints it, and 0; a line that does not run is refused -- musl
getopt's line when an option is to blame, as every bundle here refuses one,
then the usage text, on stderr, and 2.  run's files are its words up to the
first not ending in .c, and the words after them are the program's, never
parsed; build takes several files, and -o anywhere in its tail.

## the help text

### what --help prints

```cc
(display (cc-usage))
```
---
```output
Usage: cc run FILE.c... [ARG]...
or: cc build [-o OUT] FILE.c...

Run a C program, or build it into an executable

	-o OUT	Build: write the executable to OUT (default a.out)
```

## the plan

### help, run with the program's own words, build with -o before or after the file

```cc
(write (list (cc-cli-plan (list "--help")) (cc-cli-plan (list "run" "a.c" "-x" "--help")) (cc-cli-plan (list "build" "a.c" "-o" "out")) (cc-cli-plan (list "build" "-oout" "a.c")) (cc-cli-plan (list "build" "a.c"))))
```
---
    ((help) (run ("a.c") ("-x" "--help")) (build ("a.c") "out") (build ("a.c") "out") (build ("a.c") "a.out"))

### several files: run's up to the first word not ending in .c, and build's

```cc
(write (list (cc-cli-plan (list "run" "a.c" "b.c" "x.c.txt" "y.c")) (cc-cli-plan (list "run" "prog" "a.c")) (cc-cli-plan (list "build" "a.c" "-o" "p" "b.c"))))
```
---
    ((run ("a.c" "b.c") ("x.c.txt" "y.c")) (run ("prog") ("a.c")) (build ("a.c" "b.c") "p"))

### refused: no subcommand, an unknown one, no file, an option build does not take, -o with nothing after it

```cc
(write (list (cc-cli-plan ()) (cc-cli-plan (list "go" "a.c")) (cc-cli-plan (list "run")) (cc-cli-plan (list "build")) (cc-cli-plan (list "build" "-Q" "a.c")) (cc-cli-plan (list "build" "a.c" "-o"))))
```
---
    ((refuse ()) (refuse ()) (refuse ()) (refuse ()) (refuse "-Q") (refuse "-o"))

### the words

```cc
(write (list (cc-refusal "-Q") (cc-refusal "--nope") (cc-refusal "-o")))
```
---
    ("unrecognized option: Q" "unrecognized option: nope" "option requires an argument: o")
