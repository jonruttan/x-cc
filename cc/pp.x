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
;   #include <H>    a standard header's lines of C (%cc-headers) take the
;                   #include's place; any other header is dropped
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

(import cc/prims append byte-at byte-len char->integer convert file-exists? file-read-all filter
  fx& fx* fx+ fx- fx< heap-collect length map
  reverse string-append string-concat string=? substring vec-make vec-ref vec-set!)
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

; does LINE, a line's tokens so far, last first, end in a lone backslash
(def %cc-splice?
  (fn (_ line)
    (def l (%cc-skip-sp line))
    (if (null? l) #f
      (if (%cc-tag? (first l) (lit bad)) (string=? (%cc-text (first l)) "\\") #f))))

; the raw tokens split at the newlines: ((N . TOKENS) ...), N the number of
; the line a line starts on.  A block comment is a blank, its newlines
; counted, so the line after it has its own number.
(def %cc-lines
  (fn (_ ts)
    ; the newlines in S, found by Str8's byte search: a comment's every
    ; byte read here was most of a header's cost
    (def nls
      (fn (_ s)
        (def go
          (fn (self i k)
            (def at (Str8 %find-bytes "\n" i s))
            (if (null? at) k (self (+ at 1) (+ k 1)))))
        (go 0 0)))
    (def go
      (fn (self ts n start line acc)
        (match
          ((null? ts) (reverse (if (null? line) acc (pair (pair start (reverse line)) acc))))
          ; a backslash right before the newline joins the next line to this
          ; one, as C splices them before it reads tokens; the backslash
          ; goes, a blank in its place
          ((if (%cc-tag? (first ts) (lit nl)) (%cc-splice? line) #f)
            (self (rest ts) (+ n 1) start
              (pair (list (lit sp) " ") (rest (%cc-skip-sp line))) acc))
          ((%cc-tag? (first ts) (lit nl))
            (self (rest ts) (+ n 1) (+ n 1) () (pair (pair start (reverse line)) acc)))
          ((%cc-tag? (first ts) (lit cmt))
            (self (rest ts) (+ n (nls (%cc-text (first ts)))) start
              (pair (list (lit sp) " ") line) acc))
          (#t (self (rest ts) n start (pair (first ts) line) acc)))))
    (go ts 1 1 () ())))

; the line each token of the walk's output came from, the last first
(def %cc-pp-lines ())

; The name __FILE__ spells: the path the next cc-lex reads from, or
; "<stdin>", as /usr/bin/cc names text that came from no file.  It holds
; for one cc-lex.
(def %cc-pp-file "<stdin>")
(def cc-source-name!
  (fn (_ path) (set! %cc-pp-file path)))

; --- macros ------------------------------------------------------------------
; The macros, (EXTRA . BUCKETS): EXTRA a short list of entries looked at
; first -- __LINE__ and __FILE__, which change from line to line -- and
; BUCKETS a vector of lists of entries, (NAME KIND . BODY), a name's bucket
; picked by its length and its first and last bytes.  A walk of every macro
; for every name was most of a header's cost.  A file's walk goes one way,
; so #define and #undef change the buckets in place, a newer entry in front.

(def %cc-nbuckets 128)
(def %cc-macros-new (fn (_) (pair () (vec-make %cc-nbuckets ()))))
(def %cc-bucket
  (fn (_ name)
    (def len (byte-len name))
    (if (fx< len 1) 0
      (fx& (fx+ (fx* len 31)
             (fx+ (fx* (char->integer (byte-at name 0)) 7) (char->integer (byte-at name (fx- len 1)))))
        (fx- %cc-nbuckets 1)))))

; the entry NAME in ES, or nil
(def %cc-macro-in
  (fn (self es name)
    (if (null? es) ()
      (if (string=? (first (first es)) name) (first es) (self (rest es) name)))))

; the macro NAME, or nil
(def %cc-macro
  (fn (_ macros name)
    (def e (%cc-macro-in (first macros) name))
    (if (null? e) (%cc-macro-in (vec-ref (rest macros) (%cc-bucket name)) name) e)))

; MACROS with the entry E defined, in place
(def %cc-macro-define!
  (fn (_ macros e)
    (def i (%cc-bucket (first e)))
    (vec-set! (rest macros) i (pair e (vec-ref (rest macros) i)))
    macros))

; MACROS without NAME, in place
(def %cc-macro-undef!
  (fn (_ macros name)
    (def i (%cc-bucket name))
    (vec-set! (rest macros) i (filter (fn (_ e) (not (string=? (first e) name))) (vec-ref (rest macros) i)))
    macros))

(def %cc-member-s?
  (fn (_ s l)
    (def go (fn (self es) (if (null? es) #f (if (string=? (first es) s) #t (self (rest es))))))
    (go l)))

; From TS, just past a function-like macro's name: ((ARG ...) . the tokens
; after its `)`), each ARG a token list split at a top-level comma, with the
; blanks around it, or nil when no `(` follows -- then the name is an
; ordinary identifier
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
                (pair (reverse (pair (reverse arg) args)) (rest ts)))
              ((%cc-op-is? t ")") (self (rest ts) (- depth 1) (pair t arg) args))
              ((if (%cc-op-is? t ",") (= depth 1) #f)
                (self (rest ts) depth () (pair (reverse arg) args)))
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

; The body with each parameter replaced by its argument's tokens: the
; argument macro-expanded first, from EXPANDED, as C does before it
; substitutes; the argument as written, from ARGS, beside # and ##.  #
; PARAM is the argument spelled as a string literal, and A ## B pastes:
; the last token before it and the first after it are one token, read
; again from their joined text.  No parentheses are added: SQ(a+b) with
; x*x is a+b*a+b, as in C.
(def %cc-subst
  (fn (_ body params args expanded)
    ; (TOKENS) for a parameter T in AS, else nil
    (def arg-in
      (fn (_ t as)
        (if (not (%cc-name? t)) ()
          (let ((go (fn (self ps as)
                      (if (null? ps) ()
                        (if (string=? (first ps) (%cc-text t)) (list (first as))
                          (self (rest ps) (rest as)))))))
            (go params as)))))
    (def arg-of (fn (_ t) (arg-in t args)))
    ; the tokens T stands for: its argument's, as written or expanded, or
    ; itself
    (def tokens-in
      (fn (_ t as) (let ((a (arg-in t as))) (if (null? a) (list t) (first a)))))
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
                    (self (rest after) (paste acc (tokens-in (first after) args))))))
              ((%cc-op-is? t "#")
                (let ((after (%cc-skip-sp (rest ts))))
                  (def a (if (null? after) () (arg-of (first after))))
                  (if (null? a) (self (rest ts) (pair t acc))
                    (self (rest after) (pair (%cc-stringize (first a)) acc)))))
              ; a parameter before ## is pasted as written
              (#t
                (let ((after (%cc-skip-sp (rest ts))))
                  (def raw? (if (null? after) #f (%cc-op-is? (first after) "##")))
                  (self (rest ts) (append (reverse (tokens-in t (if raw? args expanded))) acc)))))))))
    (go body ())))

; A variadic macro's ARGS, as read with their blanks, each trimmed: its N
; named parameters' first, and then the rest as one, __VA_ARGS__'s -- their
; tokens with a comma between each and the blanks the call had, as #
; spells them, or none when there are none; ARGS as they are when there
; are fewer than N
(def %cc-va-args
  (fn (_ args n)
    (def go
      (fn (self as i acc)
        (match
          ((null? as) (if (< i n) () (reverse (pair () acc))))
          ((< i n) (self (rest as) (+ i 1) (pair (%cc-trim-sp (first as)) acc)))
          (#t (reverse (pair (%cc-trim-sp (join as ())) acc))))))
    (def join
      (fn (self as out)
        (if (null? (rest as)) (append (reverse out) (first as))
          (self (rest as) (pair (list (lit op) ",") (append (reverse (first as)) out))))))
    (def r (go args 0 ()))
    (if (null? r) (map %cc-trim-sp args) r)))

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
              ((eq? (first (rest m)) (lit line))
                (go (rest ts) (pair (list (lit num) (convert (first (rest (rest m))) %string) 1) acc)))
              ((eq? (first (rest m)) (lit obj))
                (go (rest ts)
                  (append (reverse (self (rest (rest m)) macros (pair (first m) open))) acc)))
              (#t
                (let ((ar (%cc-macro-args (rest ts))))
                  (if (null? ar) (go (rest ts) (pair t acc))
                    (let ((params (first (rest (rest m)))))
                      ; F() is no arguments, when F takes none
                      (def args
                        (if (if (null? params) (if (null? (rest (first ar))) (null? (%cc-trim-sp (first (first ar)))) #f) #f)
                          () (first ar)))
                      (def variadic? (if (null? params) #f (string=? (first (reverse params)) "__VA_ARGS__")))
                      (def given (if variadic? (%cc-va-args args (- (length params) 1)) (map %cc-trim-sp args)))
                      (if (not (= (length params) (length given)))
                        (Err raise (lit cc) (string-append "cc: wrong argument count for macro " (first m)) ()))
                      (go (rest ar)
                        (append
                          (reverse (self (%cc-subst (rest (rest (rest m))) params given
                                           (map (fn (_ a) (self a macros open)) given))
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
                    ; ... takes the arguments past the named ones, as __VA_ARGS__
                    ((%cc-op-is? (first ts) "...") (self (rest ts) (pair "__VA_ARGS__" acc)))
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

; The standard headers: (HEADER LINE ...), each LINE a line of C that an
; #include of HEADER puts in place of its own line.  A header gives the
; macros, types and declarations programs use with the C library's
; functions, which are the library's own; its C types are macros, as
; size_t is an unsigned long.  A header that declares anything guards it,
; so a second #include declares nothing.
(def %cc-null "#define NULL ((void *)0)")
(def %cc-size-t "#define size_t unsigned long")

; inttypes.h's printf conversions, PRId8 through PRIXMAX: a long is 64
; bits, an int 32, and a narrower argument goes as an int
(def %cc-pri-lines
  (let ((width (list (pair "8" "") (pair "16" "") (pair "32" "") (pair "64" "l")
                     (pair "PTR" "l") (pair "MAX" "l")))
        (conv (list "d" "i" "o" "u" "x" "X")))
    (def go
      (fn (self ws acc)
        (if (null? ws) (reverse acc)
          (self (rest ws)
            (append (reverse
                      (map (fn (_ c) (string-append "#define PRI" c (first (first ws)) " \""
                                       (rest (first ws)) c "\""))
                        conv))
              acc)))))
    (go width ())))

(def %cc-headers
  (list (list "stdio.h" "#define EOF (-1)" %cc-null "#define FILE void" %cc-size-t
          (if os-darwin? "#define BUFSIZ 1024" "#define BUFSIZ 8192")
          "#define _IOFBF 0" "#define _IOLBF 1" "#define _IONBF 2"
          "#define SEEK_SET 0" "#define SEEK_CUR 1" "#define SEEK_END 2"
          (if os-darwin? "#define L_tmpnam 1024" "#define L_tmpnam 20"))
        (list "stdlib.h" %cc-null %cc-size-t "#define EXIT_SUCCESS 0" "#define EXIT_FAILURE 1")
        (list "string.h" %cc-null %cc-size-t)
        (list "stddef.h" %cc-null %cc-size-t "#define ptrdiff_t long"
          "#define offsetof(t, m) ((size_t)&((t *)0)->m)")
        (list "stdarg.h" "#define va_list __builtin_va_list"
          "#define va_start __builtin_va_start" "#define va_arg __builtin_va_arg"
          "#define va_end __builtin_va_end" "#define va_copy __builtin_va_copy")
        (list "stdbool.h" "#define bool _Bool" "#define true 1" "#define false 0"
          "#define __bool_true_false_are_defined 1")
        (list "stdint.h"
          "#define int8_t signed char" "#define uint8_t unsigned char"
          "#define int16_t short" "#define uint16_t unsigned short"
          "#define int32_t int" "#define uint32_t unsigned int"
          "#define int64_t long" "#define uint64_t unsigned long"
          "#define int_least8_t signed char" "#define uint_least8_t unsigned char"
          "#define int_least16_t short" "#define uint_least16_t unsigned short"
          "#define int_least32_t int" "#define uint_least32_t unsigned int"
          "#define int_least64_t long" "#define uint_least64_t unsigned long"
          "#define int_fast8_t signed char" "#define uint_fast8_t unsigned char"
          "#define int_fast16_t short" "#define uint_fast16_t unsigned short"
          "#define int_fast32_t int" "#define uint_fast32_t unsigned int"
          "#define int_fast64_t long" "#define uint_fast64_t unsigned long"
          "#define intptr_t long" "#define uintptr_t unsigned long"
          "#define intmax_t long" "#define uintmax_t unsigned long"
          "#define INT8_MIN (-128)" "#define INT8_MAX 127" "#define UINT8_MAX 255"
          "#define INT16_MIN (-32768)" "#define INT16_MAX 32767" "#define UINT16_MAX 65535"
          "#define INT32_MIN (-2147483647-1)" "#define INT32_MAX 2147483647"
          "#define UINT32_MAX 4294967295U"
          "#define INT64_MIN (-9223372036854775807L-1)" "#define INT64_MAX 9223372036854775807L"
          "#define UINT64_MAX 18446744073709551615UL"
          "#define INTPTR_MIN (-9223372036854775807L-1)" "#define INTPTR_MAX 9223372036854775807L"
          "#define UINTPTR_MAX 18446744073709551615UL"
          "#define INTMAX_MIN (-9223372036854775807L-1)" "#define INTMAX_MAX 9223372036854775807L"
          "#define UINTMAX_MAX 18446744073709551615UL"
          "#define PTRDIFF_MIN (-9223372036854775807L-1)" "#define PTRDIFF_MAX 9223372036854775807L"
          "#define SIZE_MAX 18446744073709551615UL"
          "#define INT8_C(c) c" "#define INT16_C(c) c" "#define INT32_C(c) c"
          "#define UINT8_C(c) c" "#define UINT16_C(c) c" "#define UINT32_C(c) c ## U"
          "#define INT64_C(c) c ## L" "#define UINT64_C(c) c ## UL"
          "#define INTMAX_C(c) c ## L" "#define UINTMAX_C(c) c ## UL")
        (pair "inttypes.h" (pair "#include <stdint.h>" %cc-pri-lines))
        (list "sys/types.h" %cc-size-t "#define ssize_t long" "#define off_t long"
          "#define pid_t int" "#define uid_t unsigned int" "#define gid_t unsigned int"
          "#define time_t long")
        ; struct lconv as both platforms' C libraries lay it out, and each
        ; one's numbers for the categories
        (pair "locale.h"
          (append
            (list %cc-null
              "#ifndef __XCC_STRUCT_LCONV"
              "#define __XCC_STRUCT_LCONV"
              "struct lconv {"
              "  char *decimal_point; char *thousands_sep; char *grouping;"
              "  char *int_curr_symbol; char *currency_symbol; char *mon_decimal_point;"
              "  char *mon_thousands_sep; char *mon_grouping; char *positive_sign;"
              "  char *negative_sign; char int_frac_digits; char frac_digits;"
              "  char p_cs_precedes; char p_sep_by_space; char n_cs_precedes;"
              "  char n_sep_by_space; char p_sign_posn; char n_sign_posn;"
              "  char int_p_cs_precedes; char int_n_cs_precedes; char int_p_sep_by_space;"
              "  char int_n_sep_by_space; char int_p_sign_posn; char int_n_sign_posn;"
              "};"
              "#endif")
            (if os-darwin?
              (list "#define LC_ALL 0" "#define LC_COLLATE 1" "#define LC_CTYPE 2"
                "#define LC_MONETARY 3" "#define LC_NUMERIC 4" "#define LC_TIME 5"
                "#define LC_MESSAGES 6")
              (list "#define LC_CTYPE 0" "#define LC_NUMERIC 1" "#define LC_TIME 2"
                "#define LC_COLLATE 3" "#define LC_MONETARY 4" "#define LC_MESSAGES 5"
                "#define LC_ALL 6"))))
        ; struct tm as both platforms' C libraries lay it out
        (list "time.h" %cc-null %cc-size-t "#define time_t long"
          (if os-darwin? "#define clock_t unsigned long" "#define clock_t long")
          "#define CLOCKS_PER_SEC 1000000"
          "#ifndef __XCC_STRUCT_TM"
          "#define __XCC_STRUCT_TM"
          "struct tm {"
          "  int tm_sec; int tm_min; int tm_hour; int tm_mday; int tm_mon; int tm_year;"
          "  int tm_wday; int tm_yday; int tm_isdst; long tm_gmtoff; char *tm_zone;"
          "};"
          "#endif"
          "#ifndef __XCC_STRUCT_TIMESPEC"
          "#define __XCC_STRUCT_TIMESPEC"
          "struct timespec { long tv_sec; long tv_nsec; };"
          "#endif")
        ; struct stat as each platform's C library lays it out, and its
        ; st_atime and the rest as the seconds of its times; time.h gives
        ; its struct timespec
        (pair "sys/stat.h"
          (append
            (list "#include <sys/types.h>" "#include <time.h>"
              (if os-darwin? "#define mode_t unsigned short" "#define mode_t unsigned int")
              "#define S_IFMT 0170000" "#define S_IFDIR 0040000" "#define S_IFREG 0100000"
              "#define S_IFLNK 0120000" "#define S_IFIFO 0010000" "#define S_IFCHR 0020000"
              "#define S_IFBLK 0060000" "#define S_IFSOCK 0140000"
              "#define S_ISDIR(m) (((m) & 0170000) == 0040000)"
              "#define S_ISREG(m) (((m) & 0170000) == 0100000)"
              "#define S_ISLNK(m) (((m) & 0170000) == 0120000)"
              "#define S_ISFIFO(m) (((m) & 0170000) == 0010000)"
              "#define S_ISCHR(m) (((m) & 0170000) == 0020000)"
              "#define S_ISBLK(m) (((m) & 0170000) == 0060000)"
              "#define S_IRWXU 0700" "#define S_IRUSR 0400" "#define S_IWUSR 0200"
              "#define S_IXUSR 0100" "#define S_IRWXG 070" "#define S_IRGRP 040"
              "#define S_IWGRP 020" "#define S_IXGRP 010" "#define S_IRWXO 07"
              "#define S_IROTH 04" "#define S_IWOTH 02" "#define S_IXOTH 01"
              "#ifndef __XCC_STRUCT_STAT"
              "#define __XCC_STRUCT_STAT")
            (append (match
              (os-darwin?
                (list "struct stat {"
                  "  int st_dev; unsigned short st_mode; unsigned short st_nlink;"
                  "  unsigned long st_ino; unsigned int st_uid; unsigned int st_gid; int st_rdev;"
                  "  struct timespec st_atimespec; struct timespec st_mtimespec;"
                  "  struct timespec st_ctimespec; struct timespec st_birthtimespec;"
                  "  long st_size; long st_blocks; int st_blksize; unsigned int st_flags;"
                  "  unsigned int st_gen; int st_lspare; long st_qspare[2];"
                  "};"
                  "#define st_atime st_atimespec.tv_sec" "#define st_mtime st_mtimespec.tv_sec"
                  "#define st_ctime st_ctimespec.tv_sec"))
              (arch-arm64?
                (list "struct stat {"
                  "  unsigned long st_dev; unsigned long st_ino; unsigned int st_mode;"
                  "  unsigned int st_nlink; unsigned int st_uid; unsigned int st_gid;"
                  "  unsigned long st_rdev; unsigned long __pad1; long st_size; int st_blksize;"
                  "  int __pad2; long st_blocks;"
                  "  struct timespec st_atim; struct timespec st_mtim; struct timespec st_ctim;"
                  "  int __unused[2];"
                  "};"
                  "#define st_atime st_atim.tv_sec" "#define st_mtime st_mtim.tv_sec"
                  "#define st_ctime st_ctim.tv_sec"))
              (#t
                (list "struct stat {"
                  "  unsigned long st_dev; unsigned long st_ino; unsigned long st_nlink;"
                  "  unsigned int st_mode; unsigned int st_uid; unsigned int st_gid; int __pad0;"
                  "  unsigned long st_rdev; long st_size; long st_blksize; long st_blocks;"
                  "  struct timespec st_atim; struct timespec st_mtim; struct timespec st_ctim;"
                  "  long __unused[3];"
                  "};"
                  "#define st_atime st_atim.tv_sec" "#define st_mtime st_mtim.tv_sec"
                  "#define st_ctime st_ctim.tv_sec")))
              (list "#endif"))))
        ; DIR is the C library's, reached only through its pointer
        (list "dirent.h" "#define DIR void"
          "#define DT_UNKNOWN 0" "#define DT_FIFO 1" "#define DT_CHR 2" "#define DT_DIR 4"
          "#define DT_BLK 6" "#define DT_REG 8" "#define DT_LNK 10" "#define DT_SOCK 12"
          "#ifndef __XCC_STRUCT_DIRENT"
          "#define __XCC_STRUCT_DIRENT"
          (if os-darwin?
            "struct dirent { unsigned long d_ino; unsigned long d_seekoff; unsigned short d_reclen; unsigned short d_namlen; unsigned char d_type; char d_name[1024]; };"
            "struct dirent { unsigned long d_ino; long d_off; unsigned short d_reclen; unsigned char d_type; char d_name[256]; };")
          "#endif")
        (list "unistd.h" %cc-null "#include <sys/types.h>"
          "#define STDIN_FILENO 0" "#define STDOUT_FILENO 1" "#define STDERR_FILENO 2"
          "#define F_OK 0" "#define X_OK 1" "#define W_OK 2" "#define R_OK 4"
          "#define SEEK_SET 0" "#define SEEK_CUR 1" "#define SEEK_END 2")
        ; setjmp and longjmp are the compiler's own and run's (cc/gen,
        ; cc/eval); a jmp_buf holds what they keep, four words, with room
        (list "setjmp.h" "typedef long jmp_buf[8];")
        ; a handler is a function pointer; the numbers past SIGTERM differ
        (list "signal.h" "#define sig_atomic_t int"
          "#define SIG_DFL ((void (*)(int))0)" "#define SIG_IGN ((void (*)(int))1)"
          "#define SIG_ERR ((void (*)(int))-1)"
          "#define SIGHUP 1" "#define SIGINT 2" "#define SIGQUIT 3" "#define SIGILL 4"
          "#define SIGTRAP 5" "#define SIGABRT 6" "#define SIGFPE 8" "#define SIGKILL 9"
          "#define SIGSEGV 11" "#define SIGPIPE 13" "#define SIGALRM 14" "#define SIGTERM 15"
          (if os-darwin? "#define SIGUSR1 30" "#define SIGUSR1 10")
          (if os-darwin? "#define SIGUSR2 31" "#define SIGUSR2 12")
          (if os-darwin? "#define SIGCHLD 20" "#define SIGCHLD 17")
          (if os-darwin? "#define SIGCONT 19" "#define SIGCONT 18")
          (if os-darwin? "#define SIGSTOP 17" "#define SIGSTOP 19")
          (if os-darwin? "#define SIGTSTP 18" "#define SIGTSTP 20"))
        ; errno is the C library's, through the function that answers its
        ; address; the numbers through ERANGE are the same on both platforms
        (list "errno.h"
          (if os-darwin? "#define errno (*__error())" "#define errno (*__errno_location())")
          "#define EPERM 1" "#define ENOENT 2" "#define ESRCH 3" "#define EINTR 4"
          "#define EIO 5" "#define ENXIO 6" "#define E2BIG 7" "#define ENOEXEC 8"
          "#define EBADF 9" "#define ECHILD 10" "#define ENOMEM 12" "#define EACCES 13"
          "#define EFAULT 14" "#define EBUSY 16" "#define EEXIST 17" "#define EXDEV 18"
          "#define ENODEV 19" "#define ENOTDIR 20" "#define EISDIR 21" "#define EINVAL 22"
          "#define ENFILE 23" "#define EMFILE 24" "#define ENOTTY 25" "#define EFBIG 27"
          "#define ENOSPC 28" "#define ESPIPE 29" "#define EROFS 30" "#define EMLINK 31"
          "#define EPIPE 32" "#define EDOM 33" "#define ERANGE 34"
          (if os-darwin? "#define EAGAIN 35" "#define EAGAIN 11"))
        ; assert.h reads NDEBUG at each #include; a failed assertion is the
        ; C library's report and abort
        (list "assert.h"
          "#undef assert"
          "#ifdef NDEBUG"
          "#define assert(e) ((void)0)"
          "#else"
          (if os-darwin?
            "#define assert(e) ((e) ? (void)0 : __assert_rtn((char *)0, __FILE__, __LINE__, #e))"
            "#define assert(e) ((e) ? (void)0 : __assert_fail(#e, __FILE__, __LINE__, (char *)0))")
          "#endif"
          "#define static_assert _Static_assert")
        (list "math.h"
          "#define M_E 2.71828182845904523536028747135266250"
          "#define M_LOG2E 1.44269504088896340735992468100189214"
          "#define M_LOG10E 0.434294481903251827651128918916605082"
          "#define M_LN2 0.693147180559945309417232121458176568"
          "#define M_LN10 2.30258509299404568401799145468436421"
          "#define M_PI 3.14159265358979323846264338327950288"
          "#define M_PI_2 1.57079632679489661923132169163975144"
          "#define M_PI_4 0.785398163397448309615660845819875721"
          "#define M_1_PI 0.318309886183790671537767526745028724"
          "#define M_2_PI 0.636619772367581343075535053490057448"
          "#define M_2_SQRTPI 1.12837916709551257389615890312154517"
          "#define M_SQRT2 1.41421356237309504880168872420969808"
          "#define M_SQRT1_2 0.707106781186547524400844362104849039"
          ; past the largest double, a literal reads as infinity
          "#define HUGE_VAL 1e999")
        ; IEEE 754's single and double, as both platforms have them
        (list "float.h"
          "#define FLT_RADIX 2"
          "#define FLT_MANT_DIG 24" "#define FLT_DIG 6" "#define FLT_EPSILON 1.19209290e-7F"
          "#define FLT_MIN_EXP (-125)" "#define FLT_MAX_EXP 128"
          "#define FLT_MIN_10_EXP (-37)" "#define FLT_MAX_10_EXP 38"
          "#define FLT_MIN 1.17549435e-38F" "#define FLT_MAX 3.40282347e+38F"
          "#define DBL_MANT_DIG 53" "#define DBL_DIG 15" "#define DBL_EPSILON 2.2204460492503131e-16"
          "#define DBL_MIN_EXP (-1021)" "#define DBL_MAX_EXP 1024"
          "#define DBL_MIN_10_EXP (-307)" "#define DBL_MAX_10_EXP 308"
          "#define DBL_MIN 2.2250738585072014e-308" "#define DBL_MAX 1.7976931348623157e+308")
        ; the platforms' C types: long 64 bits, plain char as plain-char says
        (list "limits.h"
          "#define CHAR_BIT 8"
          "#define SCHAR_MIN (-128)" "#define SCHAR_MAX 127" "#define UCHAR_MAX 255"
          (if (eq? plain-char (lit uchar)) "#define CHAR_MIN 0" "#define CHAR_MIN (-128)")
          (if (eq? plain-char (lit uchar)) "#define CHAR_MAX 255" "#define CHAR_MAX 127")
          "#define SHRT_MIN (-32768)" "#define SHRT_MAX 32767" "#define USHRT_MAX 65535"
          "#define INT_MIN (-2147483647-1)" "#define INT_MAX 2147483647"
          "#define UINT_MAX 4294967295U"
          "#define LONG_MIN (-9223372036854775807L-1)" "#define LONG_MAX 9223372036854775807L"
          "#define ULONG_MAX 18446744073709551615UL"
          "#define LLONG_MIN (-9223372036854775807L-1)" "#define LLONG_MAX 9223372036854775807L"
          "#define ULLONG_MAX 18446744073709551615UL")))

; PATH's directory, up to and with its last /, or "" for a path with none
(def %cc-dir
  (fn (_ path)
    (def go (fn (self i) (match ((< i 0) "") ((= (byte-at path i) #\/) (substring path 0 (+ i 1)))
                           (#t (self (- i 1))))))
    (go (- (byte-len path) 1))))

; the directory of the file being read, where #include "..." looks
(def %cc-pp-dir "")

; The lines #include ARG puts in place of its own, numbered N: those of the
; standard header it names in <...>, none for any other; those of the file
; it names in "...", from the directory of the file being read
(def %cc-header-lines
  (fn (_ arg n)
    (def len (byte-len arg))
    (def quoted? (if (> len 1) (if (= (byte-at arg 0) #\") (= (byte-at arg (- len 1)) #\") #f) #f))
    (if quoted? (%cc-local-lines (substring arg 1 (- len 1)) n)
      (%cc-standard-lines arg n))))

; the lines of the file NAME, numbered N: NAME is as an #include names it,
; from the directory of the file being read unless it starts with /.  An
; #include "..." among them names its file from NAME's own directory, so
; it is put as from the file being read.
(def %cc-local-lines
  (fn (_ name n)
    (def absolute? (if (> (byte-len name) 0) (= (byte-at name 0) #\/) #f))
    (def path (if absolute? name (string-append %cc-pp-dir name)))
    (if (not (file-exists? path)) (%cc-oops (string-append "#include \"" path "\": no such file")))
    (def dir (%cc-dir name))
    ; a line's tokens, an #include "..." among them put from DIR
    (def from-dir
      (fn (_ ts)
        (def a (%cc-skip-sp ts))
        (def b (if (if (null? a) #f (%cc-op-is? (first a) "#")) (%cc-skip-sp (rest a)) ()))
        (def c (if (if (null? b) #f (if (%cc-name? (first b)) (string=? (%cc-text (first b)) "include") #f))
                 (%cc-skip-sp (rest b)) ()))
        (def s (if (if (null? c) #f (%cc-tag? (first c) (lit str))) (%cc-text (first c)) ""))
        (if (if (> (byte-len s) 2) (not (= (byte-at s 1) #\/)) #f)
          (append (list (first a) (first b) (list (lit sp) " ")
                    (list (lit str) (string-append "\"" dir (substring s 1 (byte-len s)))))
            (rest c))
          ts)))
    (map (fn (_ l) (pair n (if (string=? dir "") (rest l) (from-dir (rest l)))))
      (%cc-lines (cc-raw-tokens (file-read-all path))))))

(def %cc-standard-lines
  (fn (_ arg n)
    (def len (byte-len arg))
    (def name
      (if (if (> len 1) (if (= (byte-at arg 0) 60) (= (byte-at arg (- len 1)) 62) #f) #f)
        (substring arg 1 (- len 1))
        ""))
    (def go
      (fn (self hs)
        (match
          ((null? hs) ())
          ((string=? (first (first hs)) name)
            (map (fn (_ l) (pair n (rest l)))
              (%cc-lines (cc-raw-tokens (string-concat (map (fn (_ s) (string-append s "\n"))
                                                             (rest (first hs))))))))
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
; Collecting: nothing collects on its own, and what a line makes is far
; more than it leaves, so the walk collects every few thousand tokens out
; (a line counts as eight).
(def %cc-pp-walked 0)
(def %cc-pp-collect!
  (fn (_ n)
    (set! %cc-pp-walked (fx+ %cc-pp-walked n))
    (if (fx< %cc-pp-walked 4096) ()
      (do (set! %cc-pp-walked 0)
          (heap-collect)))))

(def %cc-preprocess
  (fn (_ src)
    (set! %cc-pp-lines ())
    (def file-macro
      (list "__FILE__" (lit obj) (%cc-stringize (list (list (lit id) %cc-pp-file)))))
    (set! %cc-pp-dir (if (string=? %cc-pp-file "<stdin>") "" (%cc-dir %cc-pp-file)))
    (set! %cc-pp-file "<stdin>")
    (def live?
      (fn (self st) (if (null? st) #t (if (first (first st)) (self (rest st)) #f))))
    ; a conditional's opening entry: off-and-taken under a dead parent
    (def open (fn (_ on v) (if on (pair v v) (pair #f #t))))
    ; WAIT expanded onto OUT, __LINE__ the number of the line N, spelled
    ; only where it is met: a conversion to text costs more than a line
    (def flush
      (fn (_ wait n macros out)
        (if (null? wait) out
          (let ((e (%cc-expand (reverse wait)
                     (pair (list (list "__LINE__" (lit line) n) file-macro) (rest macros))
                     ())))
            (def mark (fn (self ts) (if (null? ts) () (do (set! %cc-pp-lines (pair n %cc-pp-lines))
                                                         (%cc-pp-collect! 1)
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
            (%cc-pp-collect! 8)
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
                    (self (append (%cc-header-lines (%cc-spell (%cc-no-sp args)) n) (rest ls))
                      n macros stack () out2))
                  ((string=? word "define")
                    (self (rest ls) n (%cc-macro-define! macros (%cc-define args)) stack () out2))
                  ((string=? word "undef")
                    (self (rest ls) n (%cc-macro-undef! macros (%cc-directive-name "#undef" args)) stack () out2))
                  (#t (%cc-oops (string-append "unsupported directive #" word))))))))))
    (go (%cc-lines (cc-raw-tokens src)) 1 (%cc-macros-new) () () ())))

; --- several files -------------------------------------------------------------
; A program of several files is one stream of tokens, each file preprocessed
; on its own -- its own macros, its own include guards -- and its names with
; internal linkage, those declared static at file scope, renamed NAME.N for
; its place N among the files, so two files' static helpers of one name are
; two functions.  Every identifier of that name in the file is renamed, but
; a field: one named after . or ->, or declared in a struct's or a union's
; body, which a header the files share lays out alike for all of them.

(def %cc-kw-text? (fn (_ t s) (if (%cc-tag? t (lit kw)) (string=? (%cc-text t) s) #f)))

; the names TS, a file's raw tokens, declares static at file scope: each
; declarator's name -- the identifier before its =, its , or ; or [, or a
; function's ( -- of a declaration that starts with static outside any brace
(def %cc-file-statics
  (fn (_ ts)
    ; DEPTH the braces open outside a declaration; in one, P the parentheses
    ; and brackets open, Q the nesting of an initializer being passed over
    ; (-1 when none is), NAME the last identifier, FN? whether a function's
    ; name was taken, and B the braces of a struct's body open in it
    (def outside
      (fn (self ts depth acc)
        (match
          ((null? ts) acc)
          ((%cc-op-is? (first ts) "{") (self (rest ts) (+ depth 1) acc))
          ((%cc-op-is? (first ts) "}") (self (rest ts) (- depth 1) acc))
          ((if (= depth 0) (%cc-kw-text? (first ts) "static") #f)
            (inside (rest ts) 0 -1 () #f 0 acc))
          (#t (self (rest ts) depth acc)))))
    (def take (fn (_ name acc) (if (null? name) acc (pair name acc))))
    (def inside
      (fn (self ts p q name fn? b acc)
        (if (null? ts) acc
          (let ((t (first ts)))
            (match
              ((%cc-tag? t (lit sp)) (self (rest ts) p q name fn? b acc))
              ; an initializer, to its , or ; at its own level
              ((>= q 0)
                (match
                  ((if (%cc-op-is? t "(") #t (%cc-op-is? t "{")) (self (rest ts) p (+ q 1) () fn? b acc))
                  ((if (%cc-op-is? t ")") #t (%cc-op-is? t "}")) (self (rest ts) p (- q 1) () fn? b acc))
                  ((if (= q 0) (%cc-op-is? t ",") #f) (self (rest ts) p -1 () fn? b acc))
                  ((if (= q 0) (%cc-op-is? t ";") #f) (outside (rest ts) 0 acc))
                  (#t (self (rest ts) p q () fn? b acc))))
              ; a struct's body among the specifiers
              ((> b 0)
                (match
                  ((%cc-op-is? t "{") (self (rest ts) p q () fn? (+ b 1) acc))
                  ((%cc-op-is? t "}") (self (rest ts) p q () fn? (- b 1) acc))
                  (#t (self (rest ts) p q () fn? b acc))))
              ((%cc-tag? t (lit id)) (self (rest ts) p q (%cc-text t) fn? b acc))
              ((%cc-op-is? t "(")
                (if (if (= p 0) (not (null? name)) #f)
                  (self (rest ts) 1 q () #t b (pair name acc))
                  (self (rest ts) (+ p 1) q () fn? b acc)))
              ((%cc-op-is? t "[")
                (self (rest ts) (+ p 1) q () fn? b (if (= p 0) (take name acc) acc)))
              ((if (%cc-op-is? t ")") #t (%cc-op-is? t "]")) (self (rest ts) (- p 1) q () fn? b acc))
              ((> p 0) (self (rest ts) p q () fn? b acc))
              ((%cc-op-is? t "=") (self (rest ts) p 0 () fn? b (take name acc)))
              ((%cc-op-is? t ",") (self (rest ts) p q () fn? b (take name acc)))
              ((%cc-op-is? t ";") (outside (rest ts) 0 (take name acc)))
              ; a function's body, or a struct's
              ((%cc-op-is? t "{") (if fn? (outside (rest ts) 1 acc) (self (rest ts) p q () fn? 1 acc)))
              (#t (self (rest ts) p q () fn? b acc)))))))
    (outside ts 0 ())))

; TS, a file's raw tokens, with each of NAMES renamed NAME.N, but a field
(def %cc-rename-statics
  (fn (_ ts names n)
    (def suffix (string-append "." (convert n %string)))
    (def static? (fn (_ s) (%cc-member-s? s names)))
    ; PREV the last token not a blank; TAG 1 just after a struct or union
    ; keyword and 2 just after its tag, where a { opens its body, else 0; B
    ; the braces of the struct's body open.  A tag is never renamed.
    (def go
      (fn (self ts prev tag b acc)
        (if (null? ts) (reverse acc)
          (let ((t (first ts)))
            (match
              ((%cc-tag? t (lit sp)) (self (rest ts) prev tag b (pair t acc)))
              ((%cc-op-is? t "{")
                (self (rest ts) t 0 (if (if (> tag 0) #t (> b 0)) (+ b 1) 0) (pair t acc)))
              ((%cc-op-is? t "}") (self (rest ts) t 0 (if (> b 0) (- b 1) 0) (pair t acc)))
              ((if (%cc-kw-text? t "struct") #t (%cc-kw-text? t "union")) (self (rest ts) t 1 b (pair t acc)))
              ((if (= tag 1) (%cc-tag? t (lit id)) #f) (self (rest ts) t 2 b (pair t acc)))
              ((if (%cc-tag? t (lit id))
                 (if (static? (%cc-text t))
                   (if (= b 0)
                     (if (null? prev) #t
                       (not (if (%cc-op-is? prev ".") #t (%cc-op-is? prev "->"))))
                     #f)
                   #f)
                 #f)
                (self (rest ts) t 0 b
                  (pair (pair (first t) (pair (string-append (%cc-text t) suffix) (rest (rest t)))) acc)))
              (#t (self (rest ts) t 0 b (pair t acc))))))))
    (if (null? names) ts (go ts () 0 0 ()))))

; The parser's tokens for SRC: a program's text, or a list of its files,
; each (PATH . TEXT), in order.  Each is preprocessed, the blanks out, each
; token made the parser's, and a string literal right after another joined
; to it.
(def cc-lex
  (fn (_ src)
    (def units (if (str? src) (list (pair %cc-pp-file src)) src))
    (def many? (not (null? (rest units))))
    ; the raw tokens and their lines of every file, each list reversed
    (def read
      (fn (self us n ts ns)
        (if (null? us) (pair ts ns)
          (do (set! %cc-pp-file (first (first us)))
              (let ((raw (%cc-preprocess (rest (first us)))))
                (def lines (reverse %cc-pp-lines))
                (def raw2 (if many? (%cc-rename-statics raw (%cc-file-statics raw) n) raw))
                (self (rest us) (+ n 1) (append (reverse raw2) ts) (append (reverse lines) ns)))))))
    (def all (read units 1 () ()))
    ; TS and NS, each token's line, walked together: (TOKENS . LINES)
    (def go
      (fn (self ts ns acc lacc)
        (def n (if (null? ns) 0 (first ns)))
        (def ns2 (if (null? ns) ns (rest ns)))
        (%cc-pp-collect! 1)
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
    (def r (go (reverse (first all)) (reverse (rest all)) () ()))
    ; the parser reports an error at its token's line
    (cc-token-lines! (first r) (rest r))
    (first r)))

(provide cc/pp cc-lex cc-source-name!)
