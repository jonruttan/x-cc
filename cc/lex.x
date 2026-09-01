; # x-cc -- a C compiler on x-lang
;
; ## cc/lex.x -- C text to tokens
;
; @author [Jon Ruttan](jonruttan@gmail.com)
; @copyright 2026 Jon Ruttan
; @license MIT No Attribution (MIT-0)
;
; TOKENS: (num N) (str S) (id S) (kw SYM) (op S).  Character constants
; arrive as (num CODE) -- they are ints in C.  Every C89 keyword is
; recognized (so the parser refuses the unimplemented ones LOUDLY,
; never misreads them as identifiers).  Object-like macros splice here,
; token-wise: an id in the macro table lexes its body and continues --
; one level, self-reference guarded by the in-expansion name list.

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

; an escape at i (past the backslash): (code . next-i)
(def %cc-escape
  (fn (_ src end i)
    (def b (byte-at src i))
    (if (= b 110) (pair 10 (+ i 1))                       ; n
      (if (= b 116) (pair 9 (+ i 1))                      ; t
        (if (= b 114) (pair 13 (+ i 1))                   ; r
          (if (= b 48) (pair 0 (+ i 1))                   ; 0
            (if (= b 97) (pair 7 (+ i 1))                 ; a
              (if (= b 98) (pair 8 (+ i 1))               ; b
                (if (= b 102) (pair 12 (+ i 1))           ; f
                  (if (= b 118) (pair 11 (+ i 1))         ; v
                    (pair (+ 0 b) (+ i 1))))))))))))      ; \\ \' \" ...

; number: decimal, 0x hex, 0 octal; suffixes uUlL skipped
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
    ; integer suffixes: u U l L, in any pile
    (def skip-suf
      (fn (self j)
        (if (>= j end) j
          (let ((b (byte-at src j)))
            (if (if (= b 117) #t (if (= b 85) #t (if (= b 108) #t (= b 76))))
              (self (+ j 1))
              j)))))
    (pair (first r) (skip-suf (rest r)))))

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

; the driver: text + macros to a token list; EXPANDING carries the
; macro names currently open, so a self-referential define terminates
(def %cc-lex-go
  (fn (self src end i macros expanding acc)
    (if (>= i end) acc
      (let ((b (byte-at src i)))
        (if (if (= b 32) #t (if (= b 9) #t (if (= b 10) #t (= b 13))))
          (self src end (+ i 1) macros expanding acc)
          (if (%cc-digit? b)
            (let ((r (%cc-lex-num src end i)))
              (self src end (rest r) macros expanding
                (pair (list (lit num) (first r)) acc)))
            (if (= b 34)                                   ; "
              (let ((r (%cc-lex-str src end (+ i 1))))
                (self src end (rest r) macros expanding
                  (pair (list (lit str) (first r)) acc)))
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
                      ; splice the macro body's tokens, then continue
                      (let ((spliced
                              (%cc-lex-go (rest m) (byte-len (rest m)) 0
                                macros (pair word expanding) acc)))
                        (self src end idr macros expanding spliced))
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
