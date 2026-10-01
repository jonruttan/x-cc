# @weight 2
# @timeout-scale 3

C's escapes and adjacent string literals, under `run` and compiled.  An
escape is one of C's simple ones, up to three octal digits, or `x` and
hex digits; its code keeps its low eight bits.  String literals side by
side, across lines too, are one, as C's translation joins them.  Each
case runs the program under `run`, then compiled, and shows both outputs
and both statuses; every expectation is what the same source prints
through /usr/bin/cc.

## escapes and joined literals

### octal and hex escapes, in strings and character constants

```cc
(def src "#include <stdio.h>\nint main(void) { puts(\"\\x48\\151\\041 \\x7e\\60\"); return '\\x41' + '\\101' + '\\0' + '\\12'; }\n")
(display (list (cc-run src) (cc-exe-run src)))
```
---
```output
Hi! ~0
Hi! ~0
(140 140)
```

### a character constant is the value its byte has as a plain char

```cc
(def src "int main(void) { char c = '\\xff'; return ('\\xe9' == (char)0xe9) + 2 * (c == '\\xff') + 4 * ('\\377' == (char)255); }\n")
(display (list (cc-run src) (cc-exe-run src)))
```
---
    (7 7)

### string literals side by side are one

```cc
(def src "#include <stdio.h>\nint main(void) { char *s = \"ab\" \"cd\"\n  \"ef\"; puts(s); puts(\"x\" \"\" \"y\"); return sizeof(\"ab\" \"c\"); }\n")
(display (list (cc-run src) (cc-exe-run src)))
```
---
```output
abcdef
xy
abcdef
xy
(4 4)
```
