# @weight 2
# @timeout-scale 3

`#if` and `#elif` take a constant expression: `defined NAME` and
`defined (NAME)` are 1 or 0, then the macros expand, function-like ones
too, a name left over is 0, and the expression is evaluated, true when it
is not 0.  `&&`, `||` and `?:` leave the side they do not take
unevaluated.  Every expectation is what the same source prints through
/usr/bin/cc, then its status.

## run

### defined, &&, ||, !, ?:, comparisons, arithmetic, a function-like macro, a name left over, #undef

```cc
(def src "#include <stdio.h>\n#define VERSION 3\n#define FEATURE\n#define MAX(a, b) ((a) > (b) ? (a) : (b))\n#if VERSION >= 2 && defined(FEATURE)\nint a = 1;\n#else\nint a = 0;\n#endif\n#if defined FEATURE && !defined(MISSING) || 0\nint b = 2;\n#endif\n#if MAX(VERSION, 5) == 5 && (1 << 4) == 16 && 7 / 2 == 3 && -1 < 0\nint c = 3;\n#endif\n#if UNDEFINED_NAME\nint d = 9;\n#elif VERSION * 2 == 6 ? 1 : 0\nint d = 4;\n#endif\n#if 0 && 1 / 0\nint e = 9;\n#else\nint e = 5;\n#endif\n#if 0x10 == 16 && 'A' == 65 && 10UL > 2\nint f = 6;\n#endif\n#undef VERSION\n#if VERSION == 0\nint g = 7;\n#endif\nint main(void) {\n  printf(\"%d %d %d %d %d %d %d\\n\", a, b, c, d, e, f, g);\n  return a + b + c + d + e + f + g;\n}\n")
(display (cc-run src))
```
---
```output
1 2 3 4 5 6 7
28
```

## compiled

### defined, &&, ||, !, ?:, comparisons, arithmetic, a function-like macro, a name left over, #undef

```cc
(def src "#include <stdio.h>\n#define VERSION 3\n#define FEATURE\n#define MAX(a, b) ((a) > (b) ? (a) : (b))\n#if VERSION >= 2 && defined(FEATURE)\nint a = 1;\n#else\nint a = 0;\n#endif\n#if defined FEATURE && !defined(MISSING) || 0\nint b = 2;\n#endif\n#if MAX(VERSION, 5) == 5 && (1 << 4) == 16 && 7 / 2 == 3 && -1 < 0\nint c = 3;\n#endif\n#if UNDEFINED_NAME\nint d = 9;\n#elif VERSION * 2 == 6 ? 1 : 0\nint d = 4;\n#endif\n#if 0 && 1 / 0\nint e = 9;\n#else\nint e = 5;\n#endif\n#if 0x10 == 16 && 'A' == 65 && 10UL > 2\nint f = 6;\n#endif\n#undef VERSION\n#if VERSION == 0\nint g = 7;\n#endif\nint main(void) {\n  printf(\"%d %d %d %d %d %d %d\\n\", a, b, c, d, e, f, g);\n  return a + b + c + d + e + f + g;\n}\n")
(display (cc-exe-run src))
```
---
```output
1 2 3 4 5 6 7
28
```

## refused

### division by zero

```cc
(display (guard (e (do (display "refused: ") (write e) ""))
  (cc-run "#if 1 / 0\n#endif\nint main(void) { return 0; }\n")))
```
---
    refused: #<err:cc cc: parse: division by zero in a constant expression>

### defined without a name

```cc
(display (guard (e (do (display "refused: ") (write e) ""))
  (cc-run "#if defined()\n#endif\nint main(void) { return 0; }\n")))
```
---
    refused: #<err:cc cc: #if: defined without a name>

### a condition that is not an expression

```cc
(display (guard (e (do (display "refused: ") (write e) ""))
  (cc-run "#if 1 +\n#endif\nint main(void) { return 0; }\n")))
```
---
    refused: #<err:cc cc: parse: expected an expression>
