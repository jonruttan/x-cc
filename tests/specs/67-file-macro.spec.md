# @weight 1
# @timeout-scale 2

`__FILE__` is the path the source was read from, as the command line gives
it -- `cc-source-name!` sets it for the next read, as `x -l cc -- run` and
`build` do -- or `<stdin>` for text from no file, as /usr/bin/cc names
source read from standard input.  A quote or backslash in the path is
escaped.  Every expectation is what the same source prints through
/usr/bin/cc given the same path.

## run

### __FILE__ for text from no file, directly and through a macro

```cc
(display (cc-run "#include <stdio.h>\n#define WHERE __FILE__\nint main(void) {\n  printf(\"%s %s\\n\", __FILE__, WHERE);\n  return 0;\n}\n"))
```
---
```output
<stdin> <stdin>
0
```

### __FILE__ is the path the source was read from, for that read only

```cc
(cc-source-name! "dir/prog.c")
(display (cc-run "#include <stdio.h>\nint main(void) {\n  printf(\"%s:%d\\n\", __FILE__, __LINE__);\n  return 0;\n}\n"))
(display (cc-run "#include <stdio.h>\nint main(void) {\n  printf(\"%s\\n\", __FILE__);\n  return 0;\n}\n"))
```
---
```output
dir/prog.c:3
0<stdin>
0
```

### a quote and a backslash in the path are escaped

```cc
(cc-source-name! "a\"b\\c.c")
(display (cc-run "#include <stdio.h>\nint main(void) {\n  puts(__FILE__);\n  return sizeof __FILE__;\n}\n"))
```
---
```output
a"b\c.c
8
```

## compiled

### __FILE__ is the path the source was read from

```cc
(cc-source-name! "dir/prog.c")
(display (cc-exe-run "#include <stdio.h>\nint main(void) {\n  printf(\"%s:%d\\n\", __FILE__, __LINE__);\n  return 0;\n}\n"))
```
---
```output
dir/prog.c:3
0
```
