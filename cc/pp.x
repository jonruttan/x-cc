; # x-cc -- a C compiler on x-lang
;
; ## cc/pp.x -- the preprocessor, on tokens
;
; @author [Jon Ruttan](jonruttan@gmail.com)
; @copyright 2026 Jon Ruttan
; @license MIT No Attribution (MIT-0)
;
; The source is read into raw tokens once (cc/tokens), then walked a line at
; a time, a line ending at a newline token.  A line whose first token is #
; is a directive:
;
;   #include <H>    a standard header defines the few macros programs use
;                   with it (%cc-headers); the header itself is dropped
;   #define         an object-like macro (NAME obj . TOKENS), or, when a (
;                   follows the name with no blank between, a function-like
;                   one (NAME fn PARAMS . TOKENS)
;   #undef #ifdef #ifndef #if #elif #else #endif
;
; and any other refuses by name.  Another line expands under the macros
; defined so far once its parentheses close -- a call to a function-like
; macro may run over lines -- with __LINE__ its number.  An #if's condition is
; a constant expression: defined NAME and defined (NAME) are 1 or 0, the
; macros expand, a name left over is 0, and the parser folds the rest.
; cc-lex answers the parser's tokens: blanks out, side-by-side string
; literals joined, as C's translation joins them.
(module cc/pp)

(import cc/prims append byte-at byte-len convert filter length map reverse string-append
  string-concat string=? substring)
(import cc/tokens cc-raw-tokens cc-token)
(import cc/parse cc-parse-const cc-token-lines! plain-char)

; The type handle this file asks convert for, fetched by name through the
; platform's public door and private to this module.
(def %string (Type named STRING))

(def %cc-text (fn (_ t) (first (rest t))))
(def %cc-tag? (fn (_ t tag) (eq? (first t) tag)))
(def %cc-op-is? (fn (_ t s) (if (eq? (first t) (lit op)) (string=? (first (rest t)) s) #f)))
; an identifier or a keyword, which a macro may also be named
(def %cc-name? (fn (_ t) (if (eq? (first t) (lit id)) #t (eq? (first t) (lit kw)))))

(def %cc-skip-sp
  (fn (self ts) (if (null? ts) ts (if (%cc-tag? (first ts) (lit sp)) (self (rest ts)) ts))))

; TS without the blanks at either end
(def %cc-trim-sp
  (fn (_ ts) (reverse (%cc-skip-sp (reverse (%cc-skip-sp ts))))))

(def %cc-no-sp (fn (_ ts) (filter (fn (_ t) (not (%cc-tag? t (lit sp)))) ts)))

; TS's text, a run of blanks spelled as one space
(def %cc-spell
  (fn (_ ts)
    (string-concat
      (map (fn (_ t) (if (%cc-tag? t (lit sp)) " " (%cc-text t))) (%cc-trim-sp ts)))))

; TEXT's raw tokens without the newline the lexer ends them with, and the
; blanks at either end
(def %cc-body-tokens
  (fn (_ text)
    (%cc-trim-sp (filter (fn (_ t) (not (%cc-tag? t (lit nl)))) (cc-raw-tokens text)))))

; the raw tokens split at the newlines: ((N . TOKENS) ...), N the number of
; the line a line starts on.  A block comment is a blank, its newlines
; counted, so the line after it has its own number.
(def %cc-lines
  (fn (_ ts)
    (def nls
      (fn (_ s)
        (def end (byte-len s))
        (def go (fn (self i k) (if (>= i end) k (self (+ i 1) (if (= (byte-at s i) 10) (+ k 1) k)))))
        (go 0 0)))
    (def go
      (fn (self ts n start line acc)
        (match
          ((null? ts) (reverse (if (null? line) acc (pair (pair start (reverse line)) acc))))
          ((%cc-tag? (first ts) (lit nl))
            (self (rest ts) (+ n 1) (+ n 1) () (pair (pair start (reverse line)) acc)))
          ((%cc-tag? (first ts) (lit cmt))
            (self (rest ts) (+ n (nls (%cc-text (first ts)))) start
              (pair (list (lit sp) " ") line) acc))
          (#t (self (rest ts) n start (pair (first ts) line) acc)))))
    (go ts 1 1 () ())))

; the line each token of the walk's output came from, the last first
(def %cc-pp-lines ())

; --- macros ------------------------------------------------------------------

; the macro NAME, or nil
(def %cc-macro
  (fn (_ macros name)
    (def go
      (fn (self es)
        (if (null? es) ()
          (if (string=? (first (first es)) name) (first es) (self (rest es))))))
    (go macros)))

(def %cc-member-s?
  (fn (_ s l)
    (def go (fn (self es) (if (null? es) #f (if (string=? (first es) s) #t (self (rest es))))))
    (go l)))

; From TS, just past a function-like macro's name: ((ARG ...) . the tokens
; after its `)`), each ARG a token list split at a top-level comma, or nil
; when no `(` follows -- then the name is an ordinary identifier
(def %cc-macro-args
  (fn (_ ts)
    (def ts0 (%cc-skip-sp ts))
    (def go
      (fn (self ts depth arg args)
        (if (null? ts) (Err raise (lit cc) "cc: unterminated macro call" ())
          (let ((t (first ts)))
            (match
              ((%cc-op-is? t "(") (self (rest ts) (+ depth 1) (pair t arg) args))
              ((if (%cc-op-is? t ")") (= depth 1) #f)
                (pair (reverse (pair (%cc-trim-sp (reverse arg)) args)) (rest ts)))
              ((%cc-op-is? t ")") (self (rest ts) (- depth 1) (pair t arg) args))
              ((if (%cc-op-is? t ",") (= depth 1) #f)
                (self (rest ts) depth () (pair (%cc-trim-sp (reverse arg)) args)))
              (#t (self (rest ts) depth (pair t arg) args)))))))
    (if (if (null? ts0) #t (not (%cc-op-is? (first ts0) "("))) ()
      (go (rest ts0) 1 () ()))))

; ARG as a string literal's raw token: its text, quotes and backslashes
; escaped
(def %cc-stringize
  (fn (_ arg)
    (def s (%cc-spell arg))
    (def n (byte-len s))
    (def go (fn (self i acc)
              (if (>= i n) (string-concat (reverse (pair "\"" acc)))
                (let ((c (byte-at s i)))
                  (self (+ i 1)
                    (pair (substring s i (+ i 1))
                      (if (if (= c 34) #t (= c 92)) (pair "\\" acc) acc)))))))
    (list (lit str) (go 0 (list "\"")))))

; The body with each parameter replaced by its argument's tokens.  # PARAM is
; the argument spelled as a string literal, and A ## B pastes: the last
; token before it and the first after it are one token, read again from
; their joined text.  No parentheses are added: SQ(a+b) with x*x is
; a+b*a+b, as in C.
(def %cc-subst
  (fn (_ body params args)
    ; (TOKENS) for a parameter T, else nil
    (def arg-of
      (fn (_ t)
        (if (not (%cc-name? t)) ()
          (let ((go (fn (self ps as)
                      (if (null? ps) ()
                        (if (string=? (first ps) (%cc-text t)) (list (first as))
                          (self (rest ps) (rest as)))))))
            (go params args)))))
    ; the tokens T stands for: its argument's, or itself
    (def tokens-of
      (fn (_ t) (let ((a (arg-of t))) (if (null? a) (list t) (first a)))))
    ; ACC (reversed) with its last token pasted to the first of NEXT
    (def paste
      (fn (_ acc next)
        (def left (%cc-skip-sp acc))
        (match
          ((null? left) (append (reverse next) acc))
          ((null? next) left)
          (#t (append (reverse (rest next))
                (append (reverse (%cc-body-tokens
                                   (string-append (%cc-text (first left)) (%cc-text (first next)))))
                  (rest left)))))))
    (def go
      (fn (self ts acc)
        (if (null? ts) (reverse acc)
          (let ((t (first ts)))
            (match
              ((%cc-op-is? t "##")
                (let ((after (%cc-skip-sp (rest ts))))
                  (if (null? after) (self after acc)
                    (self (rest after) (paste acc (tokens-of (first after)))))))
              ((%cc-op-is? t "#")
                (let ((after (%cc-skip-sp (rest ts))))
                  (def a (if (null? after) () (arg-of (first after))))
                  (if (null? a) (self (rest ts) (pair t acc))
                    (self (rest after) (pair (%cc-stringize (first a)) acc)))))
              (#t (self (rest ts) (append (reverse (tokens-of t)) acc))))))))
    (go body ())))

; TS with the macros expanded.  OPEN holds the names whose expansion this
; is, which do not expand again inside it, so a macro that names itself
; ends.  An expansion is read again for macros with its own name open.
(def %cc-expand
  (fn (self ts macros open)
    (def go
      (fn (go ts acc)
        (if (null? ts) (reverse acc)
          (let ((t (first ts)))
            (def m
              (if (%cc-name? t)
                (if (%cc-member-s? (%cc-text t) open) () (%cc-macro macros (%cc-text t)))
                ()))
            (match
              ((null? m) (go (rest ts) (pair t acc)))
              ((eq? (first (rest m)) (lit obj))
                (go (rest ts)
                  (append (reverse (self (rest (rest m)) macros (pair (first m) open))) acc)))
              (#t
                (let ((ar (%cc-macro-args (rest ts))))
                  (if (null? ar) (go (rest ts) (pair t acc))
                    (let ((params (first (rest (rest m)))))
                      ; F() is no arguments, when F takes none
                      (def args
                        (if (if (null? params) (if (null? (rest (first ar))) (null? (first (first ar))) #f) #f)
                          () (first ar)))
                      (if (not (= (length params) (length args)))
                        (Err raise (lit cc) (string-append "cc: wrong argument count for macro " (first m)) ()))
                      (go (rest ar)
                        (append
                          (reverse (self (%cc-subst (rest (rest (rest m))) params args)
                                     macros (pair (first m) open)))
                          acc)))))))))))
    (go ts ())))

; --- directives --------------------------------------------------------------

(def %cc-oops (fn (_ msg) (Err raise (lit cc) (string-append "cc: " msg) ())))

; the name a directive's ARGS begin with
(def %cc-directive-name
  (fn (_ what args)
    (if (if (null? args) #t (not (%cc-name? (first args))))
      (%cc-oops (string-append what " needs a name"))
      (%cc-text (first args)))))

; #define's tokens after the word: the macro
(def %cc-define
  (fn (_ ts)
    (def name (%cc-directive-name "#define" ts))
    (def after (rest ts))
    (if (if (null? after) #f (%cc-op-is? (first after) "("))
      ; function-like: the parameters' names up to the `)`
      (let ((go (fn (self ts acc)
                  (match
                    ((null? ts) (%cc-oops "unterminated macro parameter list"))
                    ((%cc-op-is? (first ts) ")") (pair (reverse acc) (rest ts)))
                    ((%cc-name? (first ts)) (self (rest ts) (pair (%cc-text (first ts)) acc)))
                    (#t (self (rest ts) acc))))))
        (let ((pr (go (rest after) ())))
          (pair name (pair (lit fn) (pair (first pr) (%cc-trim-sp (rest pr)))))))
      (pair name (pair (lit obj) (%cc-trim-sp after))))))

; whether an #if's condition, TS, holds under MACROS
(def %cc-if-true?
  (fn (_ ts macros)
    (def defined
      (fn (self ts acc)
        (if (null? ts) (reverse acc)
          (if (if (%cc-name? (first ts)) (string=? (%cc-text (first ts)) "defined") #f)
            (let ((a (%cc-skip-sp (rest ts))))
              (def paren? (if (null? a) #f (%cc-op-is? (first a) "(")))
              (def b (if paren? (%cc-skip-sp (rest a)) a))
              (if (if (null? b) #t (not (%cc-name? (first b))))
                (%cc-oops "#if: defined without a name"))
              (def c (if paren? (%cc-skip-sp (rest b)) (rest b)))
              (if (if paren? (if (null? c) #t (not (%cc-op-is? (first c) ")"))) #f)
                (%cc-oops "#if: defined ( without its )"))
              (self (if paren? (rest c) c)
                (pair (list (lit num) (if (null? (%cc-macro macros (%cc-text (first b)))) "0" "1") 1)
                  acc)))
            (self (rest ts) (pair (first ts) acc))))))
    (def toks (%cc-no-sp (%cc-expand (defined ts ()) macros ())))
    (if (null? toks) (%cc-oops "#if with no condition"))
    ; a name left over is 0
    (not (= 0 (cc-parse-const
                (map (fn (_ t) (if (%cc-name? t) (list (lit num) 0) (cc-token t))) toks))))))

; The macros a standard header gives that programs use with the runtime's
; functions: (HEADER (NAME . BODY) ...).  The header itself is dropped, and
; an #include of one defines these.
(def %cc-headers
  (list (list "stdio.h" (pair "EOF" "(-1)") (pair "NULL" "((void *)0)") (pair "FILE" "void")
          (pair "size_t" "unsigned long"))
        (list "stdlib.h" (pair "NULL" "((void *)0)") (pair "size_t" "unsigned long")
          (pair "EXIT_SUCCESS" "0") (pair "EXIT_FAILURE" "1"))
        (list "string.h" (pair "NULL" "((void *)0)") (pair "size_t" "unsigned long"))
        (list "stddef.h" (pair "NULL" "((void *)0)") (pair "size_t" "unsigned long")
          (pair "ptrdiff_t" "long"))
        (list "stdarg.h" (pair "va_list" "__builtin_va_list")
          (pair "va_start" "__builtin_va_start") (pair "va_arg" "__builtin_va_arg")
          (pair "va_end" "__builtin_va_end") (pair "va_copy" "__builtin_va_copy"))
        (list "math.h"
          (pair "M_E" "2.71828182845904523536028747135266250")
          (pair "M_LOG2E" "1.44269504088896340735992468100189214")
          (pair "M_LOG10E" "0.434294481903251827651128918916605082")
          (pair "M_LN2" "0.693147180559945309417232121458176568")
          (pair "M_LN10" "2.30258509299404568401799145468436421")
          (pair "M_PI" "3.14159265358979323846264338327950288")
          (pair "M_PI_2" "1.57079632679489661923132169163975144")
          (pair "M_PI_4" "0.785398163397448309615660845819875721")
          (pair "M_1_PI" "0.318309886183790671537767526745028724")
          (pair "M_2_PI" "0.636619772367581343075535053490057448")
          (pair "M_2_SQRTPI" "1.12837916709551257389615890312154517")
          (pair "M_SQRT2" "1.41421356237309504880168872420969808")
          (pair "M_SQRT1_2" "0.707106781186547524400844362104849039"))
        ; the platforms' C types: long 64 bits, plain char as plain-char says
        (list "limits.h"
          (pair "CHAR_BIT" "8")
          (pair "SCHAR_MIN" "(-128)") (pair "SCHAR_MAX" "127") (pair "UCHAR_MAX" "255")
          (pair "CHAR_MIN" (if (eq? plain-char (lit uchar)) "0" "(-128)"))
          (pair "CHAR_MAX" (if (eq? plain-char (lit uchar)) "255" "127"))
          (pair "SHRT_MIN" "(-32768)") (pair "SHRT_MAX" "32767") (pair "USHRT_MAX" "65535")
          (pair "INT_MIN" "(-2147483647-1)") (pair "INT_MAX" "2147483647")
          (pair "UINT_MAX" "4294967295U")
          (pair "LONG_MIN" "(-9223372036854775807L-1)") (pair "LONG_MAX" "9223372036854775807L")
          (pair "ULONG_MAX" "18446744073709551615UL")
          (pair "LLONG_MIN" "(-9223372036854775807L-1)") (pair "LLONG_MAX" "9223372036854775807L")
          (pair "ULLONG_MAX" "18446744073709551615UL"))))

; the macros #include ARG defines: those of the standard header it names in
; <...>, none for any other
(def %cc-header-macros
  (fn (_ arg)
    (def n (byte-len arg))
    (def name
      (if (if (> n 1) (if (= (byte-at arg 0) 60) (= (byte-at arg (- n 1)) 62) #f) #f)
        (substring arg 1 (- n 1))
        ""))
    (def go
      (fn (self hs)
        (match
          ((null? hs) ())
          ((string=? (first (first hs)) name)
            (map (fn (_ e) (pair (first e) (pair (lit obj) (%cc-body-tokens (rest e)))))
              (rest (first hs))))
          (#t (self (rest hs))))))
    (go %cc-headers)))

; --- the walk ----------------------------------------------------------------

; The source's raw tokens, preprocessed and expanded.  The walk carries a
; stack of conditional entries, (ACTIVE . TAKEN): a line lives when every
; open conditional is active; TAKEN says a branch of this conditional
; already ran, so #elif and #else stay off.  An inactive region still
; tracks its own nesting, so its #endif pairs; its other directives are
; not read.  WAIT holds the live lines' tokens, reversed, until the next
; directive expands them under the macros as they stand.
(def %cc-preprocess
  (fn (_ src)
    (set! %cc-pp-lines ())
    (def live?
      (fn (self st) (if (null? st) #t (if (first (first st)) (self (rest st)) #f))))
    (def undef
      (fn (_ name macros) (filter (fn (_ e) (not (string=? (first e) name))) macros)))
    ; a conditional's opening entry: off-and-taken under a dead parent
    (def open (fn (_ on v) (if on (pair v v) (pair #f #t))))
    ; WAIT expanded onto OUT, __LINE__ the number of the line N
    (def flush
      (fn (_ wait n macros out)
        (if (null? wait) out
          (let ((e (%cc-expand (reverse wait)
                     (pair (list "__LINE__" (lit obj) (list (lit num) (convert n %string) 1))
                       macros)
                     ())))
            (def mark (fn (self ts) (if (null? ts) () (do (set! %cc-pp-lines (pair n %cc-pp-lines))
                                                         (self (rest ts))))))
            (mark e)
            (append (reverse e) out)))))
    ; does WAIT close every ( it opens: a call to a function-like macro may
    ; run on to the next line
    (def closed?
      (fn (self ts depth)
        (match
          ((null? ts) (<= depth 0))
          ((%cc-op-is? (first ts) "(") (self (rest ts) (+ depth 1)))
          ((%cc-op-is? (first ts) ")") (self (rest ts) (- depth 1)))
          (#t (self (rest ts) depth)))))
    (def go
      (fn (self ls prev macros stack wait out)
        (if (null? ls)
          (if (not (null? stack))
            (%cc-oops "unterminated #if")
            (reverse (flush wait prev macros out)))
          (let ((line (%cc-skip-sp (rest (first ls)))) (n (first (first ls))))
            (def on (live? stack))
            (if (if (null? line) #t (not (%cc-op-is? (first line) "#")))
              ; a line break is a blank between the lines' tokens; a line
              ; whose parentheses close expands now, under its own number
              (let ((w (if on (append (reverse line) (pair (list (lit sp) " ") wait)) wait)))
                (if (closed? w 0)
                  (self (rest ls) n macros stack () (flush w n macros out))
                  (self (rest ls) n macros stack w out)))
              (let ((ts (%cc-skip-sp (rest line))))
                (def out2 (flush wait n macros out))
                (def word (if (if (null? ts) #f (%cc-name? (first ts))) (%cc-text (first ts)) ""))
                (def args (%cc-skip-sp (if (null? ts) ts (rest ts))))
                (match
                  ((string=? word "ifdef")
                    (self (rest ls) n macros
                      (pair (open on (if on (not (null? (%cc-macro macros (%cc-directive-name "#ifdef" args)))) #f))
                        stack) () out2))
                  ((string=? word "ifndef")
                    (self (rest ls) n macros
                      (pair (open on (if on (null? (%cc-macro macros (%cc-directive-name "#ifndef" args))) #f))
                        stack) () out2))
                  ((string=? word "if")
                    (self (rest ls) n macros
                      (pair (open on (if on (%cc-if-true? args macros) #f)) stack) () out2))
                  ((string=? word "elif")
                    (if (null? stack) (%cc-oops "#elif without #if")
                      (self (rest ls) n macros
                        (pair (if (rest (first stack)) (pair #f #t)
                                (let ((v (%cc-if-true? args macros))) (pair v v)))
                          (rest stack))
                        () out2)))
                  ((string=? word "else")
                    (if (null? stack) (%cc-oops "#else without #if")
                      (self (rest ls) n macros
                        (pair (pair (not (rest (first stack))) #t) (rest stack)) () out2)))
                  ((string=? word "endif")
                    (if (null? stack) (%cc-oops "#endif without #if")
                      (self (rest ls) n macros (rest stack) () out2)))
                  ((not on) (self (rest ls) n macros stack () out2))
                  ((string=? word "include")
                    (self (rest ls) n (append (%cc-header-macros (%cc-spell (%cc-no-sp args))) macros)
                      stack () out2))
                  ((string=? word "define")
                    (self (rest ls) n (pair (%cc-define args) macros) stack () out2))
                  ((string=? word "undef")
                    (self (rest ls) n (undef (%cc-directive-name "#undef" args) macros) stack () out2))
                  (#t (%cc-oops (string-append "unsupported directive #" word))))))))))
    (go (%cc-lines (cc-raw-tokens src)) 1 () () () ())))

; The parser's tokens for SRC: preprocessed, the blanks out, each token
; made the parser's, and a string literal right after another joined to it
(def cc-lex
  (fn (_ src)
    (def raw (%cc-preprocess src))
    ; TS and NS, each token's line, walked together: (TOKENS . LINES)
    (def go
      (fn (self ts ns acc lacc)
        (def n (if (null? ns) 0 (first ns)))
        (def ns2 (if (null? ns) ns (rest ns)))
        (match
          ((null? ts) (pair (reverse acc) (reverse lacc)))
          ((%cc-tag? (first ts) (lit sp)) (self (rest ts) ns2 acc lacc))
          (#t
            (let ((t (cc-token (first ts))))
              (if (if (eq? (first t) (lit str))
                    (if (null? acc) #f (eq? (first (first acc)) (lit str)))
                    #f)
                (self (rest ts) ns2
                  (pair (list (lit str) (string-append (first (rest (first acc))) (first (rest t))))
                    (rest acc))
                  lacc)
                (self (rest ts) ns2 (pair t acc) (pair n lacc))))))))
    (def r (go raw (reverse %cc-pp-lines) () ()))
    ; the parser reports an error at its token's line
    (cc-token-lines! (first r) (rest r))
    (first r)))

(provide cc/pp cc-lex)
