# @weight 1

The preprocessor and lexer: C text to tokens.

## the lexer

### the shape of a tiny program

```cc
(write (cc-lex "int main() { return 42; }"))
```
---
    ((kw int) (id "main") (op "(") (op ")") (op "{") (kw return) (num 42) (op ";") (op "}"))

### numbers: decimal, hex, octal, char constants

```cc
(write (cc-lex "255 0xff 0377 'A' '\\n'"))
```
---
    ((num 255) (num 255) (num 255) (num 65) (num 10))

### strings with escapes

```cc
(write (cc-lex "\"hi\\n\""))
```
---
    ((str "hi\n"))

### operators fold longest-first

```cc
(write (cc-lex "a>>=b<<c->d++ != e"))
```
---
    ((id "a") (op ">>=") (id "b") (op "<<") (id "c") (op "->") (id "d") (op "++") (op "!=") (id "e"))

### comments vanish, strings survive them

```cc
(write (cc-lex "a /* x */ b // y\nc \"/*not*/\""))
```
---
    ((id "a") (id "b") (id "c") (str "/*not*/"))

## the preprocessor

### include drops, define splices

```cc
(write (cc-lex "#include <stdio.h>\n#define N 3\nint x = N;"))
```
---
    ((kw int) (id "x") (op "=") (num 3) (op ";"))

### a macro body can reference another macro

```cc
(write (cc-lex "#define A B\n#define B 7\nA"))
```
---
    ((num 7))

### a function-like macro substitutes its argument text

```cc
(cc-lex "#define F(x) x\nF(1)")
```
---
    ((num 1))

### substitution adds no parentheses, as in C

`x*x` with the argument `2+1` is `2+1*2+1`.

```cc
(cc-lex "#define SQ(x) x*x\nSQ(2+1)")
```
---
    ((num 2) (op "+") (num 1) (op "*") (num 2) (op "+") (num 1))
