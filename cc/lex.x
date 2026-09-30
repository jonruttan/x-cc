; # x-cc -- a C compiler on x-lang
;
; ## cc/lex.x -- C text to tokens
;
; @author [Jon Ruttan](jonruttan@gmail.com)
; @copyright 2026 Jon Ruttan
; @license MIT No Attribution (MIT-0)
;
; Tokens: (num N) (str S) (id S) (kw SYM) (op S).  Character constants
; arrive as (num CODE) -- they are ints in C -- and string literals side
; by side as one (str S), as C's translation joins them.  Every C89 keyword is
; recognized (so the parser refuses the unimplemented ones loudly,
; never misreads them as identifiers).  Object-like macros splice here,
; token-wise: an id in the macro table lexes its body and continues --
; one level, self-reference guarded by the in-expansion name list.
(module cc/lex)

(import cc/prims byte-at byte-len convert integer->char length list->string
  map reverse string-append string-concat string=? substring)
(import cc/pp cc-preprocess)
(import x/num/float Float)

; The type handle this file asks convert for, fetched by name through the
; platform's public door and private to this module.
(def %symbol (Type named SYMBOL))

(def %cc-keywords
  (list "auto" "break" "case" "char" "const" "continue" "default" "do"
        "double" "else" "enum" "extern" "float" "for" "goto" "if" "int"
        "long" "register" "return" "short" "signed" "sizeof" "static"
        "struct" "switch" "typedef" "union" "unsigned" "void" "volatile"
        "while"))

(def %cc-kw?
  (fn (_ s)
    (def go
      (fn (self ks)
        (if (null? ks) #f
          (if (string=? s (first ks)) #t (self (rest ks))))))
    (go %cc-keywords)))

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
(def %cc-id-start?
  (fn (_ b)
    (if (if (>= b 97) (<= b 122) #f) #t
      (if (if (>= b 65) (<= b 90) #f) #t (= b 95)))))
(def %cc-id-char?
  (fn (_ b) (if (%cc-id-start? b) #t (%cc-digit? b))))

(def %cc-b->s
  (fn (_ b) (list->string (list (integer->char b)))))

; an escape at i (past the backslash): (code . next-i) -- one of C's
; simple escapes, up to three octal digits, or x and hex digits; the code
; is the byte's, so what is past 255 keeps its low eight bits
(def %cc-escape
  (fn (_ src end i)
    (def b (byte-at src i))
    (def octal? (fn (_ c) (if (>= c 48) (<= c 55) #f)))
    ; a hex digit's value, or nil
    (def hex
      (fn (_ c)
        (match
          ((if (>= c 48) (<= c 57) #f) (- c 48))
          ((if (>= c 97) (<= c 102) #f) (- c 87))
          ((if (>= c 65) (<= c 70) #f) (- c 55))
          (#t ()))))
    (def octal
      (fn (self j v n)
        (if (if (< n 3) (if (< j end) (octal? (byte-at src j)) #f) #f)
          (self (+ j 1) (+ (* v 8) (- (byte-at src j) 48)) (+ n 1))
          (pair (& v 255) j))))
    (def hexes
      (fn (self j v)
        (if (if (< j end) (not (null? (hex (byte-at src j)))) #f)
          (self (+ j 1) (+ (* v 16) (hex (byte-at src j))))
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

; the end of a decimal floating constant at I, or nil when the number there
; is an integer's: digits, then a . and digits, an exponent, or both --
; 1.5, .5, 2., 1e3, 1.5e-3 -- then l or L, which leave it a double
(def %cc-lex-float-end
  (fn (_ src end i)
    (def digits
      (fn (self j) (if (if (< j end) (%cc-digit? (byte-at src j)) #f) (self (+ j 1)) j)))
    (def at (fn (_ j) (if (< j end) (byte-at src j) 0)))
    (def a (digits i))
    (def dot? (= (at a) 46))
    (def b (if dot? (digits (+ a 1)) a))
    (def e? (if (= (at b) 101) #t (= (at b) 69)))
    (def c
      (if e?
        (let ((s (if (if (= (at (+ b 1)) 43) #t (= (at (+ b 1)) 45)) (+ b 2) (+ b 1))))
          (if (%cc-digit? (at s)) (digits s) ()))
        b))
    (match
      ((if (= (at i) 48) (if (= (at (+ i 1)) 120) #t (= (at (+ i 1)) 88)) #f) ())
      ((null? c) ())
      ((not (if dot? #t e?)) ())
      ((if (= (at c) 102) #t (= (at c) 70))
        (Err raise (lit cc) "cc: not built yet: a float constant" ()))
      ((if (= (at c) 108) #t (= (at c) 76)) (+ c 1))
      (#t c))))

; number: decimal, 0x hex, 0 octal, as (VALUE C-TYPE . NEXT); the suffixes
; u U l L, with the base and the value, give the literal its C type
(def %cc-lex-num
  (fn (_ src end i)
    (def hexp
      (if (if (= (byte-at src i) 48) (< (+ i 1) end) #f)
        (let ((b1 (byte-at src (+ i 1))))
          (if (= b1 120) #t (= b1 88)))
        #f))
    (def dec
      (fn (self j acc base)
        (if (>= j end) (pair acc j)
          (let ((b (byte-at src j)))
            (if (if (= base 16) (%cc-hex-digit? b) (%cc-digit? b))
              (self (+ j 1) (+ (* acc base) (%cc-hex-val b)) base)
              (pair acc j))))))
    (def r
      (if hexp
        (dec (+ i 2) 0 16)
        (if (if (= (byte-at src i) 48)
              (if (< (+ i 1) end) (%cc-digit? (byte-at src (+ i 1))) #f)
              #f)
          (dec (+ i 1) 0 8)
          (dec i 0 10))))
    ; integer suffixes: u U l L, in any pile, read as (U? . L?)
    (def suf
      (fn (self j u l)
        (if (>= j end) (pair (pair u l) j)
          (let ((b (byte-at src j)))
            (match
              ((if (= b 117) #t (= b 85)) (self (+ j 1) #t l))
              ((if (= b 108) #t (= b 76)) (self (+ j 1) u #t))
              (#t (pair (pair u l) j)))))))
    (def s (suf (rest r) #f #f))
    (pair (first r)
      (pair (%cc-lit-c-type (first r) (not (if hexp #t (= (byte-at src i) 48)))
              (first (first s)) (rest (first s)))
        (rest s)))))

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

(def %cc-lex-str
  (fn (_ src end i)
    (def go
      (fn (self j acc)
        (if (>= j end)
          (Err raise (lit cc) "cc: unterminated string literal" ())
          (let ((b (byte-at src j)))
            (if (= b 34)                                   ; "
              (pair (list->string (reverse acc)) (+ j 1))
              (if (= b 92)
                (let ((e (%cc-escape src end (+ j 1))))
                  (self (rest e) (pair (integer->char (first e)) acc)))
                (self (+ j 1) (pair (integer->char b) acc))))))))
    (go i ())))

; the three-char, two-char, one-char operator ladders
(def %cc-ops3 (list "<<=" ">>=" "..."))
(def %cc-ops2
  (list "==" "!=" "<=" ">=" "&&" "||" "++" "--" "+=" "-=" "*=" "/="
        "%=" "&=" "|=" "^=" "<<" ">>" "->"))

(def %cc-op-at
  (fn (_ src end i)
    (def try
      (fn (_ n table)
        (if (> (+ i n) end) ()
          (let ((s (substring src i (+ i n))))
            (let ((go (fn (self ts)
                        (if (null? ts) ()
                          (if (string=? s (first ts)) s
                            (self (rest ts)))))))
              (go table))))))
    (def m3 (try 3 %cc-ops3))
    (if (not (null? m3)) (pair m3 (+ i 3))
      (let ((m2 (try 2 %cc-ops2)))
        (if (not (null? m2)) (pair m2 (+ i 2))
          (pair (substring src i (+ i 1)) (+ i 1)))))))

(def %cc-macro-body
  (fn (_ macros name)
    (def go
      (fn (self es)
        (if (null? es) ()
          (if (string=? (first (first es)) name)
            (first es)
            (self (rest es))))))
    (go macros)))

(def %cc-member-s?
  (fn (_ s l)
    (def go
      (fn (self es)
        (if (null? es) #f
          (if (string=? (first es) s) #t (self (rest es))))))
    (go l)))

; --- function-like macros ---------------------------------------------------
; The arguments are collected as text from the source (balanced parens,
; split at top-level commas, string and char literals opaque); the body
; text has each parameter identifier replaced by its argument text --
; identifier boundaries respected, string literals untouched -- and the
; result is lexed with the macro open, which is the rescan (so a macro
; may use a macro, and an argument's own macros expand there).  No
; parentheses are added: SQ(a+b) with x*x is a+b*a+b, as in C.

; from I (at or before the `(`): ((arg-text ...) . index-after-paren),
; or () when no `(` follows -- then the name is just an identifier
(def %cc-macro-args
  (fn (_ src end i)
    (def skip (fn (self j) (if (>= j end) j
                            (let ((c (byte-at src j)))
                              (if (if (= c 32) #t (if (= c 9) #t (= c 10))) (self (+ j 1)) j)))))
    (def j0 (skip i))
    (if (not (if (< j0 end) (= (byte-at src j0) 40) #f)) ()
      (let ((go ()))
        (set! go
          (fn (self j depth start acc)
            (if (>= j end) (Err raise (lit cc) "cc: unterminated macro call" ())
              (let ((c (byte-at src j)))
                (match
                  ((= c 34)                                   ; a string: skip it whole
                    (let ((skipstr (fn (self2 k)
                                     (if (>= k end) k
                                       (if (= (byte-at src k) 92) (self2 (+ k 2))
                                         (if (= (byte-at src k) 34) (+ k 1) (self2 (+ k 1))))))))
                      (self (skipstr (+ j 1)) depth start acc)))
                  ((= c 39)                                   ; a char constant
                    (let ((k (if (= (byte-at src (+ j 1)) 92) (+ j 4) (+ j 3))))
                      (self k depth start acc)))
                  ((= c 40) (self (+ j 1) (+ depth 1) start acc))
                  ((= c 41)
                    (if (= depth 1)
                      (pair (reverse (pair (substring src start j) acc)) (+ j 1))
                      (self (+ j 1) (- depth 1) start acc)))
                  ((if (= c 44) (= depth 1) #f)
                    (self (+ j 1) depth (+ j 1) (pair (substring src start j) acc)))
                  (#t (self (+ j 1) depth start acc)))))))
        (go (+ j0 1) 1 (+ j0 1) ())))))

(def %cc-trim
  (fn (_ s)
    (def end (byte-len s))
    (def ws? (fn (_ c) (if (= c 32) #t (if (= c 9) #t (= c 10)))))
    (def a (let ((go (fn (self i) (if (>= i end) i (if (ws? (byte-at s i)) (self (+ i 1)) i))))) (go 0)))
    (def z (let ((go (fn (self i) (if (<= i a) i (if (ws? (byte-at s (- i 1))) (self (- i 1)) i))))) (go end)))
    (substring s a z)))

; the body with each parameter identifier replaced by its argument text;
; #PARAM becomes the argument's text as a string literal (quotes and
; backslashes escaped), and A ## B pastes: the operator and the
; whitespace either side drop out, so the neighbours' text joins and
; the rescan lexes the joined token
(def %cc-macro-subst
  (fn (_ body params args)
    (def end (byte-len body))
    (def arg-of
      (fn (_ name)
        (def go (fn (self ps as)
                  (if (null? ps) ()
                    (if (string=? (first ps) name) (first as) (self (rest ps) (rest as))))))
        (go params args)))
    (def ws? (fn (_ c) (if (= c 32) #t (if (= c 9) #t (= c 10)))))
    (def skip-ws (fn (self j) (if (>= j end) j (if (ws? (byte-at body j)) (self (+ j 1)) j))))
    (def id-end (fn (self j) (if (>= j end) j (if (%cc-id-char? (byte-at body j)) (self (+ j 1)) j))))
    (def trim-right
      (fn (_ s)
        (def go (fn (self k) (if (<= k 0) 0 (if (ws? (byte-at s (- k 1))) (self (- k 1)) k))))
        (substring s 0 (go (byte-len s)))))
    (def stringize
      (fn (_ s)
        (def n (byte-len s))
        (def go (fn (self i acc)
                  (if (>= i n) (string-concat (reverse (pair "\"" acc)))
                    (let ((c (byte-at s i)))
                      (self (+ i 1)
                        (pair (substring s i (+ i 1))
                          (if (if (= c 34) #t (= c 92)) (pair "\\" acc) acc)))))))
        (go 0 (list "\""))))
    (def go
      (fn (self i start acc)
        (if (>= i end) (string-concat (reverse (pair (substring body start end) acc)))
          (let ((c (byte-at body i)))
            (if (= c 34)
              (let ((skipstr (fn (self2 k)
                               (if (>= k end) k
                                 (if (= (byte-at body k) 92) (self2 (+ k 2))
                                   (if (= (byte-at body k) 34) (+ k 1) (self2 (+ k 1))))))))
                (self (skipstr (+ i 1)) start acc))
              (if (= c 35)                                            ; #
                (if (if (< (+ i 1) end) (= (byte-at body (+ i 1)) 35) #f)
                  ; ##: paste
                  (let ((j (skip-ws (+ i 2))))
                    (self j j (pair (trim-right (substring body start i)) acc)))
                  ; #PARAM: stringize; a # before anything else passes through
                  (let ((j (skip-ws (+ i 1))))
                    (def idr (if (if (< j end) (%cc-id-start? (byte-at body j)) #f) (id-end j) j))
                    (def a (if (> idr j) (arg-of (substring body j idr)) ()))
                    (if (null? a)
                      (self (+ i 1) start acc)
                      (self idr idr (pair (stringize (%cc-trim a)) (pair (substring body start i) acc))))))
              (if (%cc-id-start? c)
                (let ((idr (let ((g (fn (self2 j)
                                     (if (>= j end) j
                                       (if (%cc-id-char? (byte-at body j)) (self2 (+ j 1)) j)))))
                             (g i))))
                  (def a (arg-of (substring body i idr)))
                  (if (null? a)
                    (self idr start acc)
                    (self idr idr (pair a (pair (substring body start i) acc)))))
                (self (+ i 1) start acc))))))))
    (go 0 0 ())))

; the driver: text + macros to a token list; `expanding` carries the
; macro names currently open, so a self-referential define terminates
(def %cc-lex-go
  (fn (self src end i macros expanding acc)
    (if (>= i end) acc
      (let ((b (byte-at src i)))
        (if (if (= b 32) #t (if (= b 9) #t (if (= b 10) #t (= b 13))))
          (self src end (+ i 1) macros expanding acc)
          (if (if (%cc-digit? b) #t
                (if (= b 46) (if (< (+ i 1) end) (%cc-digit? (byte-at src (+ i 1))) #f) #f))
            ; (num VALUE), or (num VALUE C-TYPE) when the literal is not an
            ; int; a double's VALUE is its IEEE bits, read by the C library
            (let ((fe (%cc-lex-float-end src end i)))
              (if (not (null? fe))
                (self src end fe macros expanding
                  (pair (list (lit num) (Float str->bits (substring src i fe)) (lit double))
                    acc))
                (let ((r (%cc-lex-num src end i)))
                  (self src end (rest (rest r)) macros expanding
                    (pair (if (eq? (first (rest r)) (lit int))
                            (list (lit num) (first r))
                            (list (lit num) (first r) (first (rest r))))
                      acc)))))
            (if (= b 34)                                   ; "
              (let ((r (%cc-lex-str src end (+ i 1))))
                (self src end (rest r) macros expanding
                  ; a string literal right after another joins it, as C's
                  ; translation joins adjacent ones
                  (if (if (pair? acc) (eq? (first (first acc)) (lit str)) #f)
                    (pair (list (lit str) (string-append (first (rest (first acc))) (first r)))
                      (rest acc))
                    (pair (list (lit str) (first r)) acc))))
              (if (= b 39)                                 ; '
                ; (+ 0 ...): byte-at's value only becomes a plain int
                ; through arithmetic; raw pass-through keeps a char
                (let ((e (if (= (byte-at src (+ i 1)) 92)
                           (%cc-escape src end (+ i 2))
                           (pair (+ 0 (byte-at src (+ i 1))) (+ i 2)))))
                  (if (not (= (byte-at src (rest e)) 39))
                    (Err raise (lit cc) "cc: bad character constant" ())
                    (self src end (+ (rest e) 1) macros expanding
                      (pair (list (lit num) (first e)) acc))))
                (if (%cc-id-start? b)
                  (let ((idr (let ((go (fn (self2 j)
                                         (if (>= j end) j
                                           (if (%cc-id-char? (byte-at src j))
                                             (self2 (+ j 1))
                                             j)))))
                               (go i))))
                    (def word (substring src i idr))
                    (def m (%cc-macro-body macros word))
                    (if (if (null? m) #f
                          (not (%cc-member-s? word expanding)))
                      (if (pair? (rest m))
                        ; function-like: needs its `(`; without one the
                        ; name is an ordinary identifier
                        (let ((ar (%cc-macro-args src end idr)))
                          (if (null? ar)
                            (self src end idr macros expanding
                              (pair (list (lit id) word) acc))
                            (let ((params (first (rest (rest m)))))
                              (def args (map (fn (_ a) (%cc-trim a)) (first ar)))
                              (def args2
                                (if (if (null? params) (if (pair? args) (if (null? (rest args)) (string=? (first args) "") #f) #f) #f)
                                  () args))
                              (if (not (= (length params) (length args2)))
                                (Err raise (lit cc) (string-append "cc: wrong argument count for macro " word) ()))
                              (def text (%cc-macro-subst (rest (rest (rest m))) params args2))
                              (let ((spliced
                                      (%cc-lex-go text (byte-len text) 0
                                        macros (pair word expanding) acc)))
                                (self src end (rest ar) macros expanding spliced)))))
                        ; object-like: splice the body's tokens, then continue
                        (let ((spliced
                                (%cc-lex-go (rest m) (byte-len (rest m)) 0
                                  macros (pair word expanding) acc)))
                          (self src end idr macros expanding spliced)))
                      (self src end idr macros expanding
                        (pair
                          (if (%cc-kw? word)
                            (list (lit kw) (convert word %symbol))
                            (list (lit id) word))
                          acc))))
                  (let ((r (%cc-op-at src end i)))
                    (self src end (rest r) macros expanding
                      (pair (list (lit op) (first r)) acc))))))))))))

(def cc-tokenize
  (fn (_ src macros)
    (reverse (%cc-lex-go src (byte-len src) 0 macros () ()))))

; the whole front door: source text to tokens
(def cc-lex
  (fn (_ src)
    (def pp (cc-preprocess src))
    (cc-tokenize (first pp) (rest pp))))

(provide cc/lex cc-lex)
