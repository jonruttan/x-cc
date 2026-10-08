; # x-cc -- a C compiler on x-lang
;
; ## cc/tokens.x -- C text to raw tokens, and a raw token's value
;
; @author [Jon Ruttan](jonruttan@gmail.com)
; @copyright 2026 Jon Ruttan
; @license MIT No Attribution (MIT-0)
;
; The text is read by a Lexer (x/reader/lexer): a tokenizer base whose types
; are the rules below, its states compiled where the assembler lane is open.
; A raw token is (TAG TEXT), or (TAG TEXT LABEL) for a number:
;
;   sp   a run of blanks, kept: a function-like #define's ( follows its
;        name with none between, and # spells an argument with them
;   nl   a newline, which ends a # line
;   kw   one of C89's keywords        id   an identifier
;   num  a number, LABEL 1 an integer, 2 a fraction or exponent, 3 hex
;   str  a string literal and chr a character constant, as written
;   op   an operator or punctuator, the longest that matches
;   bad  a byte no other rule reads
;   cmt  a block comment, whose newlines the preprocessor counts
;
; A line comment drops up to its newline.
; cc-token makes a raw token the parser's: (num N [C-TYPE]) (str S) (id S)
; (kw SYM) (op S), a number its value and C type, a literal its bytes.
(module cc/tokens)

(import cc/prims byte-at byte-len convert length reverse set-first! string-append string=?
  substring)
(import x/reader/lexer)
(import x/num/float Float)
(import cc/real single)
(import cc/parse plain-char)

; The type handle this file asks convert for, fetched by name through the
; platform's public door and private to this module.
(def %symbol (Type named SYMBOL))

; Every C89 keyword, so the parser refuses the unimplemented ones by name
; rather than reading them as identifiers.
(def %cc-keywords
  (list "auto" "break" "case" "char" "const" "continue" "default" "do"
        "double" "else" "enum" "extern" "float" "for" "goto" "if" "int"
        "long" "register" "return" "short" "signed" "sizeof" "static"
        "struct" "switch" "typedef" "union" "unsigned" "void" "volatile"
        "while"))

; C's punctuators, the longest that matches
(def %cc-ops
  (list "[" "]" "(" ")" "{" "}" "." "->" "++" "--" "&" "*" "+" "-" "~" "!"
        "/" "%" "<<" ">>" "<" ">" "<=" ">=" "==" "!=" "^" "|" "&&" "||"
        "?" ":" ";" "..." "=" "*=" "/=" "%=" "+=" "-=" "<<=" ">>=" "&="
        "^=" "|=" "," "#" "##"))

(def %cc-name-start (list (pair 97 122) (pair 65 90) 95))
(def %cc-name-rest (list (pair 97 122) (pair 65 90) (pair 48 57) 95))

; The lexer, made the first time text is read: making it compiles its
; states, which a program that reads no C should not pay for.  The keyword
; table comes before the identifier run, so a keyword wins the tie; a
; longer identifier wins over it.  A byte no rule reads is a bad token of
; its own, last, which cc-token refuses.  The end text is a newline, which
; ends a last line comment.
(def %cc-lexer (pair () ()))
(def %cc-lexer!
  (fn (_)
    (if (null? (first %cc-lexer))
      (let ((l (Lexer make
                 (list (Lexer run (lit sp) (list 32 9 13 12 11) (list 32 9 13 12 11))
                       (Lexer until (lit cmt) "/*" "*/")
                       (Lexer until () "//" "\n")
                       (Lexer table (lit nl) (list "\n"))
                       (Lexer table (lit kw) %cc-keywords)
                       (Lexer run (lit id) %cc-name-start %cc-name-rest)
                       (Lexer number (lit num) "uUlLfF")
                       (Lexer quoted (lit str) 34 34 92)
                       (Lexer quoted (lit chr) 39 39 92)
                       (Lexer table (lit op) %cc-ops)
                       (Lexer any (lit bad)))
                 "\n")))
        (set-first! %cc-lexer l)
        l)
      (first %cc-lexer))))

; TEXT's raw tokens
(def cc-raw-tokens
  (fn (_ text) ((%cc-lexer!) read-str text)))

; --- a token's value ---------------------------------------------------------

(def %cc-digit? (fn (_ b) (if (>= b 48) (<= b 57) #f)))
(def %cc-hex-digit?
  (fn (_ b)
    (if (%cc-digit? b) #t
      (if (if (>= b 97) (<= b 102) #f) #t
        (if (>= b 65) (<= b 70) #f)))))
(def %cc-hex-val
  (fn (_ b)
    (if (%cc-digit? b) (- b 48)
      (if (>= b 97) (- b 87) (- b 55)))))

; an escape at i (past the backslash): (code . next-i) -- one of C's
; simple escapes, up to three octal digits, or x and hex digits; the code
; is the byte's, so what is past 255 keeps its low eight bits
(def %cc-escape
  (fn (_ src end i)
    (def b (byte-at src i))
    (def octal? (fn (_ c) (if (>= c 48) (<= c 55) #f)))
    (def octal
      (fn (self j v n)
        (if (if (< n 3) (if (< j end) (octal? (byte-at src j)) #f) #f)
          (self (+ j 1) (+ (* v 8) (- (byte-at src j) 48)) (+ n 1))
          (pair (& v 255) j))))
    (def hexes
      (fn (self j v)
        (if (if (< j end) (%cc-hex-digit? (byte-at src j)) #f)
          (self (+ j 1) (+ (* v 16) (%cc-hex-val (byte-at src j))))
          (pair (& v 255) j))))
    (match
      ((octal? b) (octal i 0 0))                          ; \0 \12 \101
      ((= b 120) (hexes (+ i 1) 0))                       ; x
      ((= b 110) (pair 10 (+ i 1)))                       ; n
      ((= b 116) (pair 9 (+ i 1)))                        ; t
      ((= b 114) (pair 13 (+ i 1)))                       ; r
      ((= b 97)  (pair 7 (+ i 1)))                        ; a
      ((= b 98)  (pair 8 (+ i 1)))                        ; b
      ((= b 102) (pair 12 (+ i 1)))                       ; f
      ((= b 118) (pair 11 (+ i 1)))                       ; v
      (#t (pair (+ 0 b) (+ i 1))))))                      ; \\ \' \" \?

; The C type of an integer literal -- C11's integer constant (6.4.4.1) -- as C
; gives it, long long being long: the first of a list that holds the value, the
; list set by the suffix and by whether the literal is decimal.  A value past a
; long's reach wrapped negative as it was read, and only an unsigned long holds
; it.
(def %cc-lit-c-type
  (fn (_ v decimal? u? l?)
    (def int? (if (>= v 0) (<= v 2147483647) #f))
    (def uint? (if (>= v 0) (<= v 4294967295) #f))
    (def long? (>= v 0))
    (match
      ((if u? l? #f) (lit ulong))
      (u? (if uint? (lit uint) (lit ulong)))
      (l? (if long? (lit long) (lit ulong)))
      (decimal? (match (int? (lit int)) (long? (lit long)) (#t (lit ulong))))
      (#t (match (int? (lit int)) (uint? (lit uint)) (long? (lit long)) (#t (lit ulong)))))))

; an integer literal's token: decimal, 0x hex or 0 octal, then the
; suffixes u U l L, which with the base and the value give its C type
(def %cc-int-token
  (fn (_ text)
    (def end (byte-len text))
    (def hex? (if (> end 1) (if (= (byte-at text 0) 48)
                              (let ((b (byte-at text 1))) (if (= b 120) #t (= b 88))) #f) #f))
    (def octal? (if (not hex?) (if (> end 1) (= (byte-at text 0) 48) #f) #f))
    (def digits
      (fn (self j acc base)
        (if (>= j end) (pair acc j)
          (let ((b (byte-at text j)))
            (if (if (= base 16) (%cc-hex-digit? b) (if (%cc-digit? b) (< (- b 48) base) #f))
              (self (+ j 1) (+ (* acc base) (%cc-hex-val b)) base)
              (pair acc j))))))
    (def r (match (hex? (digits 2 0 16)) (octal? (digits 1 0 8)) (#t (digits 0 0 10))))
    ; the suffixes, in any pile, read as (U? . L?)
    (def suf
      (fn (self j u l)
        (if (>= j end) (pair u l)
          (let ((b (byte-at text j)))
            (match
              ((if (= b 117) #t (= b 85)) (self (+ j 1) #t l))
              ((if (= b 108) #t (= b 76)) (self (+ j 1) u #t))
              (#t (Err raise (lit cc) (string-append "cc: bad number " text) ())))))))
    (def s (suf (rest r) #f #f))
    (def k (%cc-lit-c-type (first r) (not (if hex? #t octal?)) (first s) (rest s)))
    (if (eq? k (lit int)) (list (lit num) (first r)) (list (lit num) (first r) k))))

; a floating literal's token: a double's value is its IEEE bits, read by
; the C library, and a float's -- an f or F suffix -- its single's,
; rounded from them
(def %cc-real-token
  (fn (_ text)
    (def last (byte-at text (- (byte-len text) 1)))
    (def bits (Float str->bits text))
    (if (if (= last 102) #t (= last 70))
      (list (lit num) (single bits) (lit float))
      (list (lit num) bits (lit double)))))

; A string literal's bytes, from I to its closing quote.  Each byte stays as
; it is -- the source's own, or an escape's code -- so a byte past 127 stays
; one byte rather than becoming the character with that code, which a
; string would hold in two.
(def %cc-str-bytes
  (fn (_ src i)
    (def end (byte-len src))
    (def go
      (fn (self j acc)
        (if (>= j end)
          (Err raise (lit cc) "cc: unterminated string literal" ())
          (let ((b (+ 0 (byte-at src j))))
            (if (= b 34)
              (bytes->str (reverse acc))
              (if (= b 92)
                (let ((e (%cc-escape src end (+ j 1))))
                  (self (rest e) (pair (first e) acc)))
                (self (+ j 1) (pair b acc))))))))
    (go i ())))

; a character constant's token: an int, of the value its byte has as a
; plain char
(def %cc-char-token
  (fn (_ text)
    (def end (byte-len text))
    ; (+ 0 ...): byte-at's value only becomes a plain int through
    ; arithmetic; raw pass-through keeps a char
    (def e (if (= (byte-at text 1) 92)
             (%cc-escape text end 2)
             (pair (+ 0 (byte-at text 1)) 2)))
    (if (not (= (rest e) (- end 1)))
      (Err raise (lit cc) "cc: bad character constant" ()))
    (list (lit num)
      (if (if (eq? plain-char (lit char)) (>= (first e) 128) #f)
        (- (first e) 256)
        (first e)))))

; the parser's token for a raw one
(def cc-token
  (fn (_ t)
    (def tag (first t))
    (def text (first (rest t)))
    (match
      ((eq? tag (lit id)) t)
      ((eq? tag (lit op)) t)
      ((eq? tag (lit kw)) (list (lit kw) (convert text %symbol)))
      ((eq? tag (lit num))
        (if (= (first (rest (rest t))) 2) (%cc-real-token text) (%cc-int-token text)))
      ((eq? tag (lit str)) (list (lit str) (%cc-str-bytes text 1)))
      ((eq? tag (lit chr)) (%cc-char-token text))
      (#t (Err raise (lit cc) (string-append "cc: a character no C token begins with: " text) ())))))

(provide cc/tokens cc-raw-tokens cc-token)
