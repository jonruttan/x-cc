# @weight 1

A parse error names the line it is on: the line of the token the parser was
looking at, or, for a missing token, the line of the token it should have
followed.  The lines are the source's, counted through the preprocessor --
a directive's line, and each line of a block comment, count as /usr/bin/cc
counts them.

## lines

### a missing ; is reported at the line it belongs on

```cc
(display (guard (e (do (display "refused: ") (write e) ""))
  (cc-run "int main(void) {\n  int x = 1\n  return x;\n}\n")))
```
---
    refused: #<err:cc cc: parse: line 2: expected ;>

### a block comment's lines count

```cc
(display (guard (e (do (display "refused: ") (write e) ""))
  (cc-run "/* one\n   two\n   three */\nint main(void) {\n  return );\n}\n")))
```
---
    refused: #<err:cc cc: parse: line 5: unexpected token>

### an #include's and a #define's lines count, and a macro's tokens are its use's

```cc
(display (guard (e (do (display "refused: ") (write e) ""))
  (cc-run "#include <stdio.h>\n#define N 3\nint a[N;\nint main(void) { return 0; }\n")))
```
---
    refused: #<err:cc cc: parse: line 3: expected ]>
