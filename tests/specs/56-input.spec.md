# @weight 2
# @timeout-scale 3

A program's input, the same under `run` and compiled: main takes argc
and argv, `getchar` answers the next byte of standard input or `EOF`,
and `read` and `write` move bytes through a descriptor.  An `#include`
of a standard header defines what programs use with these: `EOF`,
`NULL`, `EXIT_SUCCESS` and `EXIT_FAILURE`.  Each case runs the program
under `run`, then compiled, with the same standard input and arguments,
and shows both outputs and both statuses; every expectation is what the
same source prints through /usr/bin/cc, its input through a pipe.

## arguments

### argc, each argument, an empty one, and the null pointer after the last

```cc
(def src "#include <stdio.h>\nint main(int argc, char **argv) {\n  int i;\n  printf(\"%d\\n\", argc);\n  for (i = 1; i < argc; i++) printf(\"[%s]\\n\", argv[i]);\n  return argv[argc] == NULL ? argc : 99;\n}\n")
(def prog-in "")
(def prog-argv (list "prog" "one" "two words" ""))
(display (list (cc-run-with src prog-in prog-argv) (cc-exe-run-with src prog-in prog-argv)))
```
---
```output
4
[one]
[two words]
[]
4
[one]
[two words]
[]
(4 4)
```

## standard input

### words, lines and bytes, a byte at a time to EOF

```cc
(def src "#include <stdio.h>\nint main(void) {\n  int c;\n  int lines = 0, words = 0, chars = 0, in = 0;\n  while ((c = getchar()) != EOF) {\n    chars++;\n    if (c == '\\n') lines++;\n    if (c == ' ' || c == '\\n' || c == '\\t') in = 0;\n    else if (!in) { in = 1; words++; }\n  }\n  printf(\"%d %d %d\\n\", lines, words, chars);\n  return lines;\n}\n")
(def prog-in "hello world\nthis is\n  a\ttest\n")
(def prog-argv (list "prog"))
(display (list (cc-run-with src prog-in prog-argv) (cc-exe-run-with src prog-in prog-argv)))
```
---
```output
3 6 29
3 6 29
(3 3)
```

### lines gathered into a buffer, the last one unterminated, argv's strings written to

```cc
(def src "#include <stdio.h>\n#include <stdlib.h>\nint main(int argc, char **argv) {\n  char line[80];\n  int n = 0, c, len = 0;\n  int width = argc > 1 ? atoi(argv[1]) : 1;\n  argv[0][0] = 'X';\n  while ((c = getchar()) != EOF) {\n    if (c == '\\n') {\n      line[len] = 0;\n      n++;\n      printf(\"%3d: %s\\n\", n * width, line);\n      len = 0;\n    } else if (len < 79) line[len++] = c;\n  }\n  if (len > 0) {\n    line[len] = 0;\n    n++;\n    printf(\"%3d: %s\\n\", n * width, line);\n  }\n  return n;\n}\n")
(def prog-in "first\nsecond\n\nlast")
(def prog-argv (list "prog" "10"))
(display (list (cc-run-with src prog-in prog-argv) (cc-exe-run-with src prog-in prog-argv)))
```
---
```output
 10: first
 20: second
 30: 
 40: last
 10: first
 20: second
 30: 
 40: last
(4 4)
```

### bytes past 127 come back unsigned, EOF stays EOF, and NULL starts a global

```cc
(def src "#include <stdio.h>\n#include <stdlib.h>\nchar *nothing = NULL;\nint main(void) {\n  int c, sum = 0, count = 0;\n  while ((c = getchar()) != EOF) {\n    sum += c;\n    count++;\n  }\n  printf(\"%d %d %d %d\\n\", count, sum, getchar(), getchar());\n  return nothing == NULL ? EXIT_SUCCESS : EXIT_FAILURE;\n}\n")
(def prog-in "café über\n")
(def prog-argv (list "prog"))
(display (list (cc-run-with src prog-in prog-argv) (cc-exe-run-with src prog-in prog-argv)))
```
---
```output
12 1400 -1 -1
12 1400 -1 -1
(0 0)
```

### read and write, a buffer reversed in between

```cc
(def src "#include <stdio.h>\n#include <unistd.h>\nint main(int argc, char *argv[]) {\n  char buf[64];\n  long n = read(0, buf, sizeof buf);\n  long i;\n  long w;\n  for (i = 0; i < n / 2; i++) {\n    char t = buf[i];\n    buf[i] = buf[n - 1 - i];\n    buf[n - 1 - i] = t;\n  }\n  w = write(1, buf, n);\n  write(1, \"\\n\", 1);\n  printf(\"%ld %ld %d\\n\", n, w, argc);\n  return (int)n;\n}\n")
(def prog-in "abcdef")
(def prog-argv (list "prog" "x"))
(display (list (cc-run-with src prog-in prog-argv) (cc-exe-run-with src prog-in prog-argv)))
```
---
```output
fedcba
6 6 2
fedcba
6 6 2
(6 6)
```

### stdin, stdout and stderr, the C library's streams

```cc
(def src "#include <stdio.h>\nint main(void) {\n  char line[64];\n  int n = 0;\n  FILE *out = stdout;\n  while (fgets(line, sizeof line, stdin)) { n++; fprintf(out, \"%d: %s\", n, line); }\n  fputs(\"done\\n\", stdout);\n  fprintf(stderr, \"%s\", \"\");\n  return n + (stdin != stdout) * 10;\n}\n")
(def prog-in "a\nbb\n")
(def prog-argv (list "prog"))
(display (list (cc-run-with src prog-in prog-argv) (cc-exe-run-with src prog-in prog-argv)))
```
---
```output
1: a
2: bb
done
1: a
2: bb
done
(12 12)
```

## refused

### main with one parameter

```cc
(display (guard (e (do (display "refused: ") (write e) ""))
  (cc-exe-run "int main(int argc) { return argc; }")))
```
---
    refused: #<err:cc cc: compile: not built yet: main with parameters other than argc and argv>

