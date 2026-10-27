# @weight 1

The command line's help text, through one Opts declaration, and its plan.
busybox has no cc, so the help text is this bundle's, laid out as busybox
lays its help out.  `cc --help` prints it, and 0; a line that does not run
is refused -- musl getopt's line when an option is to blame, as every
bundle here refuses one, then the usage text, on stderr, and 2.  run's
files are its words up to the first not ending in .c, and the words after
them are the program's, never parsed; a build takes several files, and -o
anywhere among them.  cc's own options are 81-cc-arguments' cases.

## the help text

### what --help prints

```cc
(display (cc-usage))
```
---
```output
Usage: cc [-c] [-o OUT] [-D NAME[=VALUE]] [-I DIR] FILE...
or: cc run FILE.c... [ARG]...

Build a C program into an executable, or run it

	-c		Preprocess each FILE.c into FILE.o, to build from
	-o OUT		Write the executable, or the one -c makes, to OUT
	-D NAME[=VALUE]	Define NAME as VALUE, or as 1
	-U NAME		Undefine NAME
	-I DIR		Look for #include files in DIR too
	-fsyntax-only	Read the files and stop
```

## the plan

### help, run with the program's own words, build with -o before or after the file

```cc
(write (list (cc-cli-plan (list "--help")) (cc-cli-plan (list "run" "a.c" "-x" "--help")) (cc-cli-plan (list "build" "a.c" "-o" "out")) (cc-cli-plan (list "build" "-oout" "a.c")) (cc-cli-plan (list "build" "a.c"))))
```
---
    ((help) (run ("a.c") ("-x" "--help")) (build ("a.c") "out" () ()) (build ("a.c") "out" () ()) (build ("a.c") "a.out" () ()))

### several files: run's up to the first word not ending in .c, and build's

```cc
(write (list (cc-cli-plan (list "run" "a.c" "b.c" "x.c.txt" "y.c")) (cc-cli-plan (list "run" "prog" "a.c")) (cc-cli-plan (list "build" "a.c" "-o" "p" "b.c"))))
```
---
    ((run ("a.c" "b.c") ("x.c.txt" "y.c")) (run ("prog") ("a.c")) (build ("a.c" "b.c") "p" () ()))

### refused: nothing, no file, an option cc does not take, -o with nothing after it

```cc
(write (list (cc-cli-plan ()) (cc-cli-plan (list "run")) (cc-cli-plan (list "build")) (cc-cli-plan (list "build" "-Q" "a.c")) (cc-cli-plan (list "build" "a.c" "-o"))))
```
---
    ((refuse ()) (refuse ()) (refuse ()) (refuse "-Q") (refuse "-o"))

### the words

```cc
(write (list (cc-refusal "-Q") (cc-refusal "--nope") (cc-refusal "-o")))
```
---
    ("unrecognized option: Q" "unrecognized option: nope" "option requires an argument: o")
