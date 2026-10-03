; # x-cc -- a C compiler on x-lang
;
; ## cc/parse.x -- tokens to a program
;
; @author [Jon Ruttan](jonruttan@gmail.com)
; @copyright 2026 Jon Ruttan
; @license MIT No Attribution (MIT-0)
;
; Grammar only, functionally threaded: every function answers
; (ast . remaining-tokens).  The full C expression ladder, fifteen
; levels, each level one flat function.
;
; The AST:
;   toplevel  (fun NAME PARAMS BODY C-TYPES RET-C-TYPE) (gdecl NAME C-TYPE INIT|())
;   stmts     (block ITEMS) (if C T E|()) (while C B) (do B C)
;             (for I|() C|() U|() B) (return E|()) (break) (continue)
;             (expr E) (decl NAME C-TYPE INIT|())
;   C-TYPE      scalar | (array N)
;   exprs     (num N) (str S) (var NAME) (call NAME ARGS) (idx A I)
;             (un "op" E) (preinc LV) (predec LV) (postinc LV)
;             (postdec LV) (bin "op" A B) (cmp "op" A B) (and A B)
;             (or A B) (assign LV E) (ternary C A B) (comma A B)
;             (szof E)
;
; Structs, unions (a struct whose fields all sit at offset 0), enums
; (constants folded at parse time; the type is a scalar), typedefs
; (the types section), switch (clauses in order, fallthrough the
; evaluator's), initializer lists (INIT may be (initlist ITEMS); an
; unsized array takes its size from one) and function pointers (the
; `(*NAME)(params)` declarator is a pointer-wide value; a call whose callee is
; any expression but a bare name is (callx E ARGS)) and goto parse.
; Refused loudly: `long double`, a recorded pending.
(module cc/parse)

(import cc/prims append byte-len convert length map reverse set-first! string-append
  string=?)

; The type handle this file asks convert for, fetched by name through the
; platform's public door and private to this module.
(def %string (Type named STRING))

(def %cc-p-err
  (fn (_ msg)
    (Err raise (lit cc) (string-append "cc: parse: " msg) ())))

(def %cc-p-op?
  (fn (_ toks s)
    (if (null? toks) #f
      (if (eq? (first (first toks)) (lit op))
        (string=? (first (rest (first toks))) s)
        #f))))

(def %cc-p-kw?
  (fn (_ toks k)
    (if (null? toks) #f
      (if (eq? (first (first toks)) (lit kw))
        (eq? (first (rest (first toks))) k)
        #f))))

(def %cc-p-id?
  (fn (_ toks)
    (if (null? toks) #f (eq? (first (first toks)) (lit id)))))

(def %cc-p-eat
  (fn (_ toks s)
    (if (%cc-p-op? toks s)
      (rest toks)
      (%cc-p-err (string-append "expected " s)))))

; the keywords the parser knows and refuses by name, none at present
(def %cc-p-hard
  ())

(def %cc-p-hard?
  (fn (_ toks)
    (if (null? toks) #f
      (if (eq? (first (first toks)) (lit kw))
        (let ((k (first (rest (first toks)))))
          (let ((go (fn (self ks)
                      (if (null? ks) #f
                        (if (eq? (first ks) k) #t (self (rest ks)))))))
            (go %cc-p-hard)))
        #f))))

; a type-specifier keyword?
(def %cc-p-c-type-kw?
  (fn (_ toks)
    (if (null? toks) #f
      (if (eq? (first (first toks)) (lit kw))
        (let ((k (first (rest (first toks)))))
          (match
            ((eq? k (lit int)) #t)
            ((eq? k (lit char)) #t)
            ((eq? k (lit void)) #t)
            ((eq? k (lit double)) #t)
            ((eq? k (lit float)) #t)
            ((eq? k (lit long)) #t)
            ((eq? k (lit short)) #t)
            ((eq? k (lit unsigned)) #t)
            ((eq? k (lit signed)) #t)
            ((eq? k (lit const)) #t)
            ((eq? k (lit static)) #t)
            (#t (eq? k (lit extern)))))
        #f))))

; Plain `char`'s C type, which each platform's C ABI picks: signed on macOS
; and on x86-64, unsigned on arm64 Linux.
(def plain-char (if (if os-linux? arch-arm64? #f) (lit uchar) (lit char)))

; va_list's C type, each platform's C ABI's: a pointer to eight-byte slots
; on arm64 macOS; on Linux a record, arm64's 32 bytes and x86-64's 24
(def %cc-p-va-list
  (match
    (os-darwin? (list (lit ptr) (lit char)))
    (arch-arm64? (list (lit array) 4 (lit ulong)))
    (#t (list (lit array) 3 (lit ulong)))))

; the C type a va_list is handed on as, which a variadic function's last
; parameter, "...", holds: the caller's va_list for the arguments past the
; fixed ones
(def %cc-p-va-handed
  (if os-darwin? %cc-p-va-list (list (lit ptr) (lit ulong))))

; The scalar the specifiers name.  `unsigned`/`signed` pick the signedness and
; the width keyword picks the width; `long long` is `long`, and specifiers
; that say nothing about either (const, static, extern) are swallowed.  A
; `char` that says neither `signed` nor `unsigned` is plain-char.
(def %cc-p-scalar-of
  (fn (_ toks)
    (def go
      (fn (self ts width unsigned?)
        (if (not (%cc-p-c-type-kw? ts)) (pair (pair width unsigned?) ts)
          (let ((k (first (rest (first ts)))))
            (match
              ((eq? k (lit unsigned)) (self (rest ts) width #t))
              ((eq? k (lit signed)) (self (rest ts) width #f))
              ((eq? k (lit char)) (self (rest ts) (lit char) unsigned?))
              ((eq? k (lit short)) (self (rest ts) (lit short) unsigned?))
              ((eq? k (lit long))
                (if (eq? width (lit double))
                  (%cc-p-err "not built yet: long double")
                  (self (rest ts) (lit long) unsigned?)))
              ((eq? k (lit void)) (self (rest ts) (lit void) unsigned?))
              ((eq? k (lit float)) (self (rest ts) (lit float) unsigned?))
              ((eq? k (lit double))
                (if (eq? width (lit long))
                  (%cc-p-err "not built yet: long double")
                  (self (rest ts) (lit double) unsigned?)))
              (#t (self (rest ts) width unsigned?)))))))
    ; the signedness: #t unsigned, #f signed, plain when neither is said
    (def got (go toks () (lit plain)))
    (def width (first (first got)))
    (def sign (rest (first got)))
    (def unsigned? (eq? sign #t))
    (pair
      (match
        ((eq? width (lit void)) (lit void))
        ((eq? width (lit double)) (lit double))
        ((eq? width (lit float)) (lit float))
        ((eq? width (lit char))
          (match ((eq? sign #t) (lit uchar)) ((eq? sign #f) (lit char)) (#t plain-char)))
        ((eq? width (lit short)) (if unsigned? (lit ushort) (lit short)))
        ((eq? width (lit long)) (if unsigned? (lit ulong) (lit long)))
        (#t (if unsigned? (lit uint) (lit int))))
      (rest got))))

; --- types, as far as the memory model needs them --------------------------
; C types: a scalar's own name (char uchar short ushort int uint long ulong
; void) | (fnptr RET) | (array N K) | (struct S) | (ptr K).  Sizes are bytes, as the
; platforms this compiles for count them; a struct is its fields at aligned
; offsets, padded; an array of K is N*size(K); a pointer is 8 and keeps its
; pointee, which is what arithmetic scales by, what a read through it takes
; its width from, and where `->` finds its fields.  The parser keeps the
; struct and typedef tables (the evaluator reads them; parse always precedes
; load in a process).
(def %cc-p-structs ())     ; ((name size . ((fname off c-type) ...)) ...)
(def %cc-p-typedefs ())    ; ((name . c-type) ...)
(def %cc-p-anon 0)

(def struct-entry
  (fn (_ name)
    (def go (fn (self es)
              (if (null? es) ()
                (if (string=? (first (first es)) name) (first es)
                  (self (rest es))))))
    (go %cc-p-structs)))

; every struct the program being parsed has declared.  The table is this
; module's, and a parse replaces it, so a reader asks for it each time
; rather than keeping a copy.
(def struct-table (fn (_) %cc-p-structs))

; Sizes in bytes, as the platforms this compiles for count them (LP64):
; char 1, short 2, int 4, long 8, and every pointer 8.  An array is its
; count times its element; a struct is what its layout came to.
(def c-type-size
  (fn (self c-type)
    (if (not (pair? c-type))
      (match
        ((eq? c-type (lit char)) 1)
        ((eq? c-type (lit uchar)) 1)
        ((eq? c-type (lit short)) 2)
        ((eq? c-type (lit ushort)) 2)
        ((eq? c-type (lit int)) 4)
        ((eq? c-type (lit uint)) 4)
        ((eq? c-type (lit float)) 4)
        ((eq? c-type (lit void)) 1)
        (#t 8))
      (match
        ((eq? (first c-type) (lit array))
          (* (first (rest c-type))
            (if (null? (rest (rest c-type))) 4
              (self (first (rest (rest c-type)))))))
        ((eq? (first c-type) (lit struct))
          (let ((e (struct-entry (first (rest c-type)))))
            (if (null? e)
              (%cc-p-err (string-append "unknown struct: " (first (rest c-type))))
              (first (rest e)))))
        ; a bit-field's unit
        ((eq? (first c-type) (lit bits)) (self (first (rest c-type))))
        (#t 8)))))

; What an address of this C type must be a multiple of: a scalar its own size,
; an array its element's, a struct its widest field's.
(def c-type-align
  (fn (self c-type)
    (if (not (pair? c-type)) (c-type-size c-type)
      (match
        ((eq? (first c-type) (lit array))
          (if (null? (rest (rest c-type))) 4 (self (first (rest (rest c-type))))))
        ((eq? (first c-type) (lit struct))
          (let ((e (struct-entry (first (rest c-type)))))
            (if (null? e) 1
              (let ((go (fn (self2 fs a)
                          (if (null? fs) a
                            (let ((fa (self (first (rest (rest (first fs)))))))
                              (self2 (rest fs) (if (> fa a) fa a)))))))
                (go (rest (rest e)) 1)))))
        ((eq? (first c-type) (lit bits)) (self (first (rest c-type))))
        (#t 8)))))

(def round-up (fn (_ n a) (let ((m (+ n (- a 1)))) (- m (% m a)))))

(def %cc-p-typedef-name?
  (fn (_ toks)
    (if (null? toks) #f
      (if (eq? (first (first toks)) (lit id))
        (let ((n (first (rest (first toks)))))
          (def go (fn (self es)
                    (if (null? es) #f
                      (if (string=? (first (first es)) n) #t (self (rest es))))))
          (go %cc-p-typedefs))
        #f))))
(def %cc-p-typedef-c-type
  (fn (_ n)
    (def go (fn (self es)
              (if (null? es) (lit int)
                (if (string=? (first (first es)) n) (rest (first es)) (self (rest es))))))
    (go %cc-p-typedefs)))

; a declaration starts with a type keyword, `struct`/`union`/`enum`,
; or a typedef name
(def %cc-p-c-type-start?
  (fn (_ toks)
    (if (%cc-p-c-type-kw? toks) #t
      (if (%cc-p-kw? toks (lit struct)) #t
        (if (%cc-p-kw? toks (lit union)) #t
          (if (%cc-p-kw? toks (lit enum)) #t
            (%cc-p-typedef-name? toks)))))))

; --- enums: names for constants, folded here ----------------------------------
(def %cc-p-enums ())       ; ((name . value) ...)

(def %cc-p-enum-value
  (fn (_ name)
    (def go (fn (self es)
              (if (null? es) ()
                (if (string=? (first (first es)) name) (rest (first es)) (self (rest es))))))
    (go %cc-p-enums)))

; a constant expression's value, over numbers (enum names already folded
; to numbers by the primary level), as an enumerator and #if take one: a
; comparison, `!`, `&&` and `||` are 1 or 0, and `&&`, `||` and `?:` leave
; the side they do not take unevaluated, so 0 && 1 / 0 is 0
(def %cc-p-const
  (fn (self node)
    (def no (fn (_) (%cc-p-err "expected a constant expression")))
    (def b01 (fn (_ x) (if x 1 0)))
    (def arg (fn (_ i) (first (%cc-p-const-drop i node))))
    (let ((t (first node)))
      (match
        ((eq? t (lit num)) (first (rest node)))
        ((eq? t (lit un))
          (let ((v (self (arg 2))))
            (def op (first (rest node)))
            (match
              ((string=? op "-") (- 0 v))
              ((string=? op "!") (b01 (= v 0)))
              ((string=? op "~") (- (- 0 v) 1))
              (#t (no)))))
        ((eq? t (lit and)) (b01 (if (= (self (arg 1)) 0) #f (not (= (self (arg 2)) 0)))))
        ((eq? t (lit or)) (b01 (if (= (self (arg 1)) 0) (not (= (self (arg 2)) 0)) #t)))
        ((eq? t (lit ternary)) (if (= (self (arg 1)) 0) (self (arg 3)) (self (arg 2))))
        ((eq? t (lit cmp))
          (let ((op (first (rest node))))
            (def a (self (arg 2)))
            (def b (self (arg 3)))
            (b01
              (match
                ((string=? op "<")  (< a b))
                ((string=? op ">")  (> a b))
                ((string=? op "<=") (<= a b))
                ((string=? op ">=") (>= a b))
                ((string=? op "==") (= a b))
                (#t (not (= a b)))))))
        ((eq? t (lit bin))
          (let ((op (first (rest node))))
            (def a (self (arg 2)))
            (def b (self (arg 3)))
            (if (if (= b 0) (if (string=? op "/") #t (string=? op "%")) #f)
              (%cc-p-err "division by zero in a constant expression"))
            (match
              ((string=? op "+")  (+ a b))
              ((string=? op "-")  (- a b))
              ((string=? op "*")  (* a b))
              ((string=? op "/")  (/ a b))
              ((string=? op "%")  (% a b))
              ((string=? op "<<") (<< a b))
              ((string=? op ">>") (>> a b))
              ((string=? op "&")  (& a b))
              ((string=? op "|")  (| a b))
              ((string=? op "^")  (^ a b))
              (#t (no)))))
        (#t (no))))))

; what follows the first N of a list
(def %cc-p-const-drop
  (fn (self n xs) (if (<= n 0) xs (self (- n 1) (rest xs)))))

; { NAME [= const] (, NAME [= const])* [,] }: each registers, counting
; up from the last; answers the rest
(def %cc-p-enum-body
  (fn (_ toks)
    (def go
      (fn (self ts next)
        (if (%cc-p-op? ts "}") (rest ts)
          (if (not (%cc-p-id? ts)) (%cc-p-err "expected an enumerator")
            (let ((name (first (rest (first ts)))))
              (def vr
                (if (%cc-p-op? (rest ts) "=")
                  (let ((r (%cc-e-assign (rest (rest ts)))))
                    (pair (%cc-p-const (first r)) (rest r)))
                  (pair next (rest ts))))
              (set! %cc-p-enums (pair (pair name (first vr)) %cc-p-enums))
              (self (if (%cc-p-op? (rest vr) ",") (rest (rest vr)) (rest vr))
                (+ (first vr) 1)))))))
    (go toks 0)))

; a balanced ( ... ), skipped: the parameter list of a function-pointer
; declarator; answers the rest
(def %cc-p-skip-parens
  (fn (_ toks)
    (def go
      (fn (self ts depth)
        (if (null? ts) (%cc-p-err "unbalanced parentheses")
          (if (%cc-p-op? ts "(") (self (rest ts) (+ depth 1))
            (if (%cc-p-op? ts ")")
              (if (= depth 1) (rest ts) (self (rest ts) (- depth 1)))
              (self (rest ts) depth))))))
    (if (%cc-p-op? toks "(") (go toks 0)
      (%cc-p-err "expected a parameter list"))))

; the `(*NAME` of a function-pointer declarator?
(def %cc-p-fnptr-start?
  (fn (_ toks)
    (if (%cc-p-op? toks "(") (%cc-p-op? (rest toks) "*") #f)))

; a pointer keeps its pointee: arithmetic on it scales by the pointee's size,
; `->` needs its fields, and a read through it takes its width
(def %cc-p-pointer-to (fn (_ k) (list (lit ptr) k)))

(def %cc-p-struct-body ())

; the *s of a declarator, and the qualifiers among them, on K:
; (C-TYPE . rest)
(def %cc-p-stars
  (fn (self k ts)
    (if (%cc-p-c-type-kw? ts) (self k (rest ts))
      (if (%cc-p-op? ts "*") (self (%cc-p-pointer-to k) (rest ts))
        (pair k ts)))))

; TYPE: specifiers, then *s.  Answers (C-TYPE . rest).
(def %cc-p-c-type
  (fn (_ toks)
    (def based (%cc-p-specifiers toks))
    (%cc-p-stars (first based) (rest based))))

; The specifiers a declaration starts with, which every declarator after
; them shares: scalar keywords, `struct|union NAME [{...}]`,
; `enum [NAME] [{...}]`, or a typedef name.  The *s belong to each
; declarator, so int *a, b; makes one pointer and one int.  Answers
; (C-TYPE . rest).
(def %cc-p-specifiers
  (fn (_ toks)
    (def skip-kws (fn (self ts) (if (%cc-p-c-type-kw? ts) (self (rest ts)) ts)))
    (def ts (skip-kws toks))
    ; after `struct` or `union`: NAME [{...}] | {...}; a union is a
    ; struct whose fields overlap
    (def tagged
      (fn (_ ts2 union?)
        (if (%cc-p-id? ts2)
          (let ((name (first (rest (first ts2)))))
            (if (%cc-p-op? (rest ts2) "{")
              (pair (list (lit struct) name)
                (%cc-p-struct-body name (rest (rest ts2)) union?))
              (pair (list (lit struct) name) (rest ts2))))
          (if (%cc-p-op? ts2 "{")
            (let ((name (string-append "%anon" (convert %cc-p-anon %string))))
              (set! %cc-p-anon (+ %cc-p-anon 1))
              (pair (list (lit struct) name) (%cc-p-struct-body name (rest ts2) union?)))
            (%cc-p-err "expected a struct name or body")))))
    (if (%cc-p-kw? ts (lit struct)) (tagged (rest ts) #f)
      (if (%cc-p-kw? ts (lit union)) (tagged (rest ts) #t)
        (if (%cc-p-kw? ts (lit enum))
          ; enum [NAME] [{ enumerators }]: the constants register, the
          ; type is a scalar
          (let ((ts2 (if (%cc-p-id? (rest ts)) (rest (rest ts)) (rest ts))))
            (pair (lit int)
              (if (%cc-p-op? ts2 "{") (%cc-p-enum-body (rest ts2)) ts2)))
          (if (%cc-p-typedef-name? ts)
            (pair (%cc-p-typedef-c-type (first (rest (first ts)))) (rest ts))
            (%cc-p-scalar-of toks)))))))

; the array suffix after a declarator's name: (C-TYPE . rest).  Each [N]
; wraps the C type the dimensions after it make, so int m[2][3] is two
; arrays of three ints; [] leaves the count to an initializer.
(def %cc-p-array-suffix
  (fn (self k ts)
    (if (%cc-p-op? ts "[")
      (if (%cc-p-op? (rest ts) "]")
        (let ((inner (self k (rest (rest ts)))))
          (pair (list (lit array) () (first inner)) (rest inner)))
        ; the count is a constant expression: N + 1, sizeof x / 2, an enum
        (let ((r (%cc-e-assign (rest ts))))
          (let ((inner (self k (%cc-p-eat (rest r) "]"))))
            (pair (list (lit array) (%cc-p-const (first r)) (first inner)) (rest inner)))))
      (pair k ts))))

; a type name, as a cast or sizeof takes it: TYPE, then [N]... for an
; array, (*)[N]... for a pointer to one, or (*)(params) for a pointer to a
; function, (fnptr RET) with TYPE its RET and the parameters' types not
; kept, as a declarator's.  (C-TYPE . rest)
(def %cc-p-type-name
  (fn (_ toks)
    (def tr (%cc-p-c-type toks))
    (def ts (rest tr))
    (if (if (%cc-p-op? ts "(") (%cc-p-op? (rest ts) "*") #f)
      (let ((after (%cc-p-eat (rest (rest ts)) ")")))
        (match
          ((%cc-p-op? after "(")
            (pair (list (lit fnptr) (first tr)) (%cc-p-skip-parens after)))
          ((%cc-p-op? after "[")
            (let ((ar (%cc-p-array-suffix (first tr) after)))
              (pair (%cc-p-pointer-to (first ar)) (rest ar))))
          (#t (%cc-p-err "expected ( or [ after (*) in a type name"))))
      (%cc-p-array-suffix (first tr) ts))))

; --- the expression ladder ---------------------------------------------------

(def %cc-e-comma ())
(def %cc-e-assign ())
(def %cc-p-block ())
(def %cc-p-stmt ())

(def %cc-p-args
  (fn (_ toks)
    (if (%cc-p-op? toks ")")
      (pair () (rest toks))
      (let ((go ()))
        (set! go
          (fn (self ts acc)
            (def r (%cc-e-assign ts))
            (if (%cc-p-op? (rest r) ",")
              (self (rest (rest r)) (pair (first r) acc))
              (pair (reverse (pair (first r) acc))
                (%cc-p-eat (rest r) ")")))))
        (go toks ())))))

; <stdarg.h>'s macros, written out in the C they stand for.  The next
; argument's slot is the va_list itself on arm64 macOS, and on Linux the
; record's pointer to its slots -- arm64's first word, x86-64's second --
; whose register offsets say the registers are used up, as a caller of
; the program's own variadic function leaves them.
(def %cc-va-slot
  (fn (_ ap)
    (if os-darwin? ap
      (list (lit idx) (list (lit cast) (list (lit ptr) (list (lit ptr) (lit char))) ap)
        (list (lit num) (if arch-arm64? 0 1))))))

; the va_list TO made a copy of FROM, a va_list as it is handed on
(def %cc-va-copy
  (fn (_ to from)
    (if os-darwin? (list (lit assign) to from)
      (let ((word (fn (_ e i) (list (lit idx) (list (lit cast) (list (lit ptr) (lit ulong)) e)
                                (list (lit num) i)))))
        (def go
          (fn (self i)
            (let ((one (list (lit assign) (word to i) (word from i))))
              (if (= i 0) one (list (lit comma) (self (- i 1)) one)))))
        (go (- (first (rest %cc-p-va-list)) 1))))))

; __builtin_va_start (AP, LAST), __builtin_va_arg (AP, TYPE),
; __builtin_va_end (AP) and __builtin_va_copy (TO, FROM), with TOKS after
; the name's (: (AST . rest), or nil for another NAME.  va_arg answers the
; slot's value as TYPE and steps the slot past it.
(def %cc-e-va-builtin
  (fn (_ name toks)
    (match
      ((string=? name "__builtin_va_start")
        (let ((r (%cc-p-args toks)))
          (pair (%cc-va-copy (first (first r)) (list (lit var) "...")) (rest r))))
      ((string=? name "__builtin_va_copy")
        (let ((r (%cc-p-args toks)))
          (pair (%cc-va-copy (first (first r)) (first (rest (first r)))) (rest r))))
      ((string=? name "__builtin_va_end")
        (let ((r (%cc-p-args toks)))
          (pair (list (lit num) 0) (rest r))))
      ((string=? name "__builtin_va_arg")
        (let ((ar (%cc-e-assign toks)))
          (def tr (%cc-p-type-name (%cc-p-eat (rest ar) ",")))
          (def k (first tr))
          (if (if (pair? k) (eq? (first k) (lit struct)) #f)
            (%cc-p-err "not built yet: a struct from va_arg"))
          (def slot (%cc-va-slot (first ar)))
          (def step (list (lit num) (round-up (c-type-size k) 8)))
          (pair (list (lit un) "*"
                  (list (lit cast) (%cc-p-pointer-to k)
                    (list (lit bin) "-"
                      (list (lit assign) slot (list (lit bin) "+" slot step))
                      step)))
            (%cc-p-eat (rest tr) ")"))))
      (#t ()))))

(def %cc-e-primary
  (fn (_ toks)
    (if (null? toks) (%cc-p-err "expected an expression")
      (let ((tok (first toks)))
        (def label (first tok))
        (if (eq? label (lit num)) (pair tok (rest toks))
          (if (eq? label (lit str)) (pair tok (rest toks))
            (if (eq? label (lit id))
              (if (%cc-p-op? (rest toks) "(")
                (let ((v (%cc-e-va-builtin (first (rest tok)) (rest (rest toks)))))
                  (if (not (null? v)) v
                    (let ((r (%cc-p-args (rest (rest toks)))))
                      (pair (list (lit call) (first (rest tok)) (first r))
                        (rest r)))))
                ; an enum constant is its number, right here
                (let ((ev (%cc-p-enum-value (first (rest tok)))))
                  (pair (if (null? ev) (list (lit var) (first (rest tok))) (list (lit num) ev))
                    (rest toks))))
              (if (%cc-p-op? toks "(")
                (let ((r (%cc-e-comma (rest toks))))
                  (pair (first r) (%cc-p-eat (rest r) ")")))
                (if (%cc-p-hard? toks)
                  (%cc-p-err
                    (string-append "not built yet: "
                      (convert (first (rest tok)) %string)))
                  (%cc-p-err "unexpected token"))))))))))

(def %cc-lval?
  (fn (_ ast)
    (let ((t (first ast)))
      (if (eq? t (lit var)) #t
        (if (eq? t (lit idx)) #t
          (if (eq? t (lit dot)) #t
            (if (eq? t (lit arrow)) #t
              (if (eq? t (lit un))
                (string=? (first (rest ast)) "*")
                #f))))))))

(def %cc-e-postfix
  (fn (_ toks)
    (def r (%cc-e-primary toks))
    (def go
      (fn (self ast ts)
        (if (%cc-p-op? ts "[")
          (let ((ir (%cc-e-comma (rest ts))))
            (self (list (lit idx) ast (first ir))
              (%cc-p-eat (rest ir) "]")))
          (if (%cc-p-op? ts "++")
            (self (list (lit postinc) ast) (rest ts))
            (if (%cc-p-op? ts "--")
              (self (list (lit postdec) ast) (rest ts))
              (if (if (%cc-p-op? ts ".") (%cc-p-id? (rest ts)) #f)
                (self (list (lit dot) ast (first (rest (first (rest ts)))))
                  (rest (rest ts)))
                (if (if (%cc-p-op? ts "->") (%cc-p-id? (rest ts)) #f)
                  (self (list (lit arrow) ast (first (rest (first (rest ts)))))
                    (rest (rest ts)))
                  ; a call through any other expression: (*f)(x), ops[i](x), p->fn(x)
                  (if (%cc-p-op? ts "(")
                    (let ((ar (%cc-p-args (rest ts))))
                      (self (list (lit callx) ast (first ar)) (rest ar)))
                    (pair ast ts)))))))))
    (go (first r) (rest r))))

; a parenthesized type-name means a cast: (cast C-TYPE E)
(def %cc-cast?
  (fn (_ toks)
    (if (%cc-p-op? toks "(")
      (%cc-p-c-type-start? (rest toks))
      #f)))

(def %cc-e-unary
  (fn (self toks)
    (if (%cc-p-op? toks "-")
      (let ((r (self (rest toks))))
        (pair (list (lit un) "-" (first r)) (rest r)))
      (if (%cc-p-op? toks "!")
        (let ((r (self (rest toks))))
          (pair (list (lit un) "!" (first r)) (rest r)))
        (if (%cc-p-op? toks "~")
          (let ((r (self (rest toks))))
            (pair (list (lit un) "~" (first r)) (rest r)))
          (if (%cc-p-op? toks "*")
            (let ((r (self (rest toks))))
              (pair (list (lit un) "*" (first r)) (rest r)))
            (if (%cc-p-op? toks "&")
              (let ((r (self (rest toks))))
                (pair (list (lit un) "&" (first r)) (rest r)))
              (if (%cc-p-op? toks "+")
                (self (rest toks))
                (if (%cc-p-op? toks "++")
                  (let ((r (self (rest toks))))
                    (pair (list (lit preinc) (first r)) (rest r)))
                  (if (%cc-p-op? toks "--")
                    (let ((r (self (rest toks))))
                      (pair (list (lit predec) (first r)) (rest r)))
                    (if (%cc-p-kw? toks (lit sizeof))
                      (if (%cc-cast? (rest toks))
                        ; a size_t, which is an unsigned long here
                        (let ((tr (%cc-p-type-name (rest (rest toks)))))
                          (pair (list (lit num) (c-type-size (first tr)) (lit ulong))
                            (%cc-p-eat (rest tr) ")")))
                        (let ((r (self (rest toks))))
                          (pair (list (lit szof) (first r)) (rest r))))
                      (if (%cc-cast? toks)
                        (let ((tr (%cc-p-type-name (rest toks))))
                          (let ((r (self (%cc-p-eat (rest tr) ")"))))
                            (pair (list (lit cast) (first tr) (first r)) (rest r))))
                        (%cc-e-postfix toks)))))))))))))

; one flat driver for the left-associative binary levels: OPS is the
; level's operator list, SUB the tighter level, MK the node builder
(def %cc-binlevel
  (fn (_ toks ops sub mk)
    (def hit
      (fn (_ ts)
        (let ((go (fn (self os)
                    (if (null? os) ()
                      (if (%cc-p-op? ts (first os)) (first os)
                        (self (rest os)))))))
          (go ops))))
    (def r (sub toks))
    (def go
      (fn (self ast ts)
        (let ((op (hit ts)))
          (if (null? op)
            (pair ast ts)
            (let ((rr (sub (rest ts))))
              (self (mk op ast (first rr)) (rest rr)))))))
    (go (first r) (rest r))))

(def %cc-mk-bin (fn (_ op a b) (list (lit bin) op a b)))
(def %cc-mk-cmp (fn (_ op a b) (list (lit cmp) op a b)))

(def %cc-e-mul
  (fn (_ toks)
    (%cc-binlevel toks (list "*" "/" "%") %cc-e-unary %cc-mk-bin)))
(def %cc-e-add
  (fn (_ toks)
    (%cc-binlevel toks (list "+" "-") %cc-e-mul %cc-mk-bin)))
(def %cc-e-shift
  (fn (_ toks)
    (%cc-binlevel toks (list "<<" ">>") %cc-e-add %cc-mk-bin)))
(def %cc-e-rel
  (fn (_ toks)
    (%cc-binlevel toks (list "<=" ">=" "<" ">") %cc-e-shift %cc-mk-cmp)))
(def %cc-e-eq
  (fn (_ toks)
    (%cc-binlevel toks (list "==" "!=") %cc-e-rel %cc-mk-cmp)))
(def %cc-e-band
  (fn (_ toks)
    (%cc-binlevel toks (list "&") %cc-e-eq %cc-mk-bin)))
(def %cc-e-bxor
  (fn (_ toks)
    (%cc-binlevel toks (list "^") %cc-e-band %cc-mk-bin)))
(def %cc-e-bor
  (fn (_ toks)
    (%cc-binlevel toks (list "|") %cc-e-bxor %cc-mk-bin)))

(def %cc-e-land
  (fn (_ toks)
    (def r (%cc-e-bor toks))
    (def go
      (fn (self ast ts)
        (if (%cc-p-op? ts "&&")
          (let ((rr (%cc-e-bor (rest ts))))
            (self (list (lit and) ast (first rr)) (rest rr)))
          (pair ast ts))))
    (go (first r) (rest r))))

(def %cc-e-lor
  (fn (_ toks)
    (def r (%cc-e-land toks))
    (def go
      (fn (self ast ts)
        (if (%cc-p-op? ts "||")
          (let ((rr (%cc-e-land (rest ts))))
            (self (list (lit or) ast (first rr)) (rest rr)))
          (pair ast ts))))
    (go (first r) (rest r))))

(def %cc-e-tern
  (fn (self toks)
    (def r (%cc-e-lor toks))
    (if (%cc-p-op? (rest r) "?")
      (let ((a (%cc-e-comma (rest (rest r)))))
        (def b (self (%cc-p-eat (rest a) ":")))
        (pair (list (lit ternary) (first r) (first a) (first b))
          (rest b)))
      r)))

; compound assignment desugars; the l-value therefore evaluates twice
; in a *p++ corner, accepted and noted
(def %cc-asgn-op
  (fn (_ toks)
    (if (%cc-p-op? toks "=") ""
      (if (%cc-p-op? toks "+=") "+"
        (if (%cc-p-op? toks "-=") "-"
          (if (%cc-p-op? toks "*=") "*"
            (if (%cc-p-op? toks "/=") "/"
              (if (%cc-p-op? toks "%=") "%"
                (if (%cc-p-op? toks "&=") "&"
                  (if (%cc-p-op? toks "|=") "|"
                    (if (%cc-p-op? toks "^=") "^"
                      (if (%cc-p-op? toks "<<=") "<<"
                        (if (%cc-p-op? toks ">>=") ">>" ())))))))))))))

(set! %cc-e-assign
  (fn (self toks)
    (def r (%cc-e-tern toks))
    (def op (%cc-asgn-op (rest r)))
    (if (null? op)
      r
      (if (not (%cc-lval? (first r)))
        (%cc-p-err "assignment needs an lvalue")
        (let ((rr (self (rest (rest r)))))
          (pair
            (list (lit assign) (first r)
              (if (string=? op "")
                (first rr)
                (list (lit bin) op (first r) (first rr))))
            (rest rr)))))))

(set! %cc-e-comma
  (fn (_ toks)
    (def r (%cc-e-assign toks))
    (def go
      (fn (self ast ts)
        (if (%cc-p-op? ts ",")
          (let ((rr (%cc-e-assign (rest ts))))
            (self (list (lit comma) ast (first rr)) (rest rr)))
          (pair ast ts))))
    (go (first r) (rest r))))

; --- declarations ------------------------------------------------------------

; One declarator's name and C type, on the specifiers' BASE: *s NAME
; [N]..., the function-pointer form (*NAME [N]...)(params) -- (fnptr RET),
; RET the C type the specifiers and stars before it give, the parameters'
; types not kept -- or a pointer to an array, (*NAME)[N]....
; (NAME C-TYPE . rest)
(def %cc-p-declarator-head
  (fn (_ toks base)
    (def sr (%cc-p-stars base toks))
    (def ts (rest sr))
    (if (%cc-p-fnptr-start? ts)
      (let ((ts2 (rest (rest ts))))
        (if (not (%cc-p-id? ts2))
          (%cc-p-err "expected a name in a function-pointer declarator"))
        (let ((kr (%cc-p-array-suffix (list (lit fnptr) (first sr)) (rest ts2))))
          (def after (%cc-p-eat (rest kr) ")"))
          (match
            ((not (%cc-p-op? after "["))
              (pair (first (rest (first ts2))) (pair (first kr) (%cc-p-skip-parens after))))
            ((eq? (first (first kr)) (lit array))
              (%cc-p-err "not built yet: an array of pointers to arrays"))
            (#t
              (let ((ar (%cc-p-array-suffix (first sr) after)))
                (pair (first (rest (first ts2)))
                  (pair (%cc-p-pointer-to (first ar)) (rest ar))))))))
      (if (not (%cc-p-id? ts))
        (%cc-p-err "expected a name in declaration")
        (let ((kr (%cc-p-array-suffix (first sr) (rest ts))))
          (pair (first (rest (first ts))) (pair (first kr) (rest kr))))))))

; one declarator after the specifiers, and its initializer if it has one:
; ((decl NAME C-TYPE INIT) . rest)
(def %cc-p-declarator
  (fn (_ toks base)
    (def head (%cc-p-declarator-head toks base))
    (def name (first head))
    (def c-type (first (rest head)))
    (def ts3 (rest (rest head)))
    (if (%cc-p-op? ts3 "=")
      (let ((ir (if (%cc-p-op? (rest ts3) "{")
                  (%cc-p-initlist (rest (rest ts3)))
                  (%cc-e-assign (rest ts3)))))
        (pair (list (lit decl) name (%cc-p-size-c-type c-type (first ir)) (first ir))
          (rest ir)))
      (if (if (pair? c-type) (if (eq? (first c-type) (lit array)) (null? (first (rest c-type))) #f) #f)
        (%cc-p-err "an array without a size needs an initializer")
        (pair (list (lit decl) name c-type ()) ts3)))))

; { init (, init)* [,] } -> (initlist ITEMS), items nested lists or exprs
(def %cc-p-initlist
  (fn (self toks)
    (def go
      (fn (self2 ts acc)
        (if (%cc-p-op? ts "}")
          (pair (list (lit initlist) (reverse acc)) (rest ts))
          (let ((r (if (%cc-p-op? ts "{") (self (rest ts)) (%cc-e-assign ts))))
            (if (%cc-p-op? (rest r) ",")
              (self2 (rest (rest r)) (pair (first r) acc))
              (if (%cc-p-op? (rest r) "}")
                (pair (list (lit initlist) (reverse (pair (first r) acc))) (rest (rest r)))
                (%cc-p-err "expected , or } in an initializer")))))))
    (go toks ())))

; an unsized array takes its size from the initializer: the list's
; length, or a string's bytes plus its NUL
(def %cc-p-size-c-type
  (fn (_ c-type init)
    (if (if (pair? c-type) (if (eq? (first c-type) (lit array)) (null? (first (rest c-type))) #f) #f)
      (let ((n (if (eq? (first init) (lit initlist)) (length (first (rest init)))
                 (if (eq? (first init) (lit str)) (+ 1 (byte-len (first (rest init))))
                   (%cc-p-err "an unsized array needs a list or string initializer")))))
        (if (null? (rest (rest c-type))) (list (lit array) n) (list (lit array) n (first (rest (rest c-type))))))
      c-type)))

; do the specifiers at the front of TOKS say static?  A local that is
; static is kept once for the program, not made again per call, so its decl
; nodes carry `static` as a fifth element.
(def %cc-p-static?
  (fn (self toks)
    (if (%cc-p-c-type-kw? toks)
      (if (%cc-p-kw? toks (lit static)) #t (self (rest toks)))
      #f)))

; TYPE declarator (, declarator)* ; -- a list of decl nodes
(def %cc-p-decl-line
  (fn (_ toks)
    (def tr (%cc-p-specifiers toks))
    (def base (first tr))
    (def ts (rest tr))
    (def go
      (fn (self ts2 acc)
        (def r (%cc-p-declarator ts2 base))
        (if (%cc-p-op? (rest r) ",")
          (self (rest (rest r)) (pair (first r) acc))
          (pair (reverse (pair (first r) acc))
            (%cc-p-eat (rest r) ";")))))
    ; `struct S { ... };` declares nothing: no declarators at all
    (if (%cc-p-op? ts ";")
      (pair () (rest ts))
      (go ts ()))))

; the body of a struct: decl lines to the closing brace, fields laid
; end to end -- or, for a union, all at offset 0 with the size the
; widest field's; registers the struct and answers the rest
; One line of a struct's body: ((NAME C-TYPE WIDTH) ...), WIDTH the bits of
; a bit-field and () for any other field.  A bit-field with no name, which
; only pads, has NAME ().
(def %cc-p-field-line
  (fn (_ toks)
    (def tr (%cc-p-specifiers toks))
    (def width
      (fn (_ ts) (let ((r (%cc-e-assign ts))) (pair (%cc-p-const (first r)) (rest r)))))
    (def one
      (fn (_ ts)
        (if (%cc-p-op? ts ":")
          (let ((w (width (rest ts))))
            (pair (list () (first tr) (first w)) (rest w)))
          (let ((h (%cc-p-declarator-head ts (first tr))))
            (if (%cc-p-op? (rest (rest h)) ":")
              (let ((w (width (rest (rest (rest h))))))
                (pair (list (first h) (first (rest h)) (first w)) (rest w)))
              (pair (list (first h) (first (rest h)) ()) (rest (rest h))))))))
    (def go
      (fn (self ts acc)
        (let ((r (one ts)))
          (if (%cc-p-op? (rest r) ",")
            (self (rest (rest r)) (pair (first r) acc))
            (pair (reverse (pair (first r) acc)) (%cc-p-eat (rest r) ";"))))))
    ; `struct S { ... };` inside declares nothing
    (if (%cc-p-op? (rest tr) ";") (pair () (rest (rest tr))) (go (rest tr) ()))))

; the bit-field C type (bits C-TYPE BIT WIDTH) for WIDTH bits from bit BIT
; of a unit of C-TYPE, refusing what C or this compiler does not take
(def %cc-p-bits
  (fn (_ name k bit w)
    (match
      ((if (eq? k (lit long)) #t (eq? k (lit ulong)))
        (%cc-p-err "not built yet: a bit-field of a long"))
      ((pair? k) (%cc-p-err "a bit-field that is not an integer"))
      ((> w (* 8 (c-type-size k))) (%cc-p-err "a bit-field wider than its type"))
      ((< w 0) (%cc-p-err "a bit-field of negative width"))
      ((if (= w 0) (not (null? name)) #f) (%cc-p-err "a bit-field of width 0 with a name"))
      (#t (list (lit bits) k bit w)))))

(set! %cc-p-struct-body
  (fn (_ name toks union?)
    ; A field sits at the next offset its own alignment allows, and the
    ; struct's size rounds up to the widest field's, so an array of them
    ; keeps every field aligned.  A union's fields all sit at 0.  A
    ; bit-field takes the next WIDTH bits of a unit of its C type, the unit
    ; at a multiple of that type's size; when they would run past the
    ; unit's end it starts the next one, and width 0 starts the next one
    ; and takes none.  The layout counts in bits.
    (def bytes (fn (_ b) (/ (+ b 7) 8)))
    (def most (fn (_ a b) (if (> a b) a b)))
    (def go
      (fn (self ts bits align fields)
        (if (%cc-p-op? ts "}")
          (do (set! %cc-p-structs
                (pair (pair name (pair (round-up (bytes bits) align) (reverse fields)))
                  %cc-p-structs))
              (rest ts))
          (let ((r (%cc-p-field-line ts)))
            (def lay
              (fn (self2 ds b a fs)
                (if (null? ds) (list b a fs)
                  (let ((d (first ds)))
                    (def fname (first d))
                    (def k (first (rest d)))
                    (def w (first (rest (rest d))))
                    (def sz (c-type-size k))
                    (def unit (* 8 sz))
                    (match
                      ((null? w)
                        (let ((at (if union? 0 (round-up (bytes b) (c-type-align k)))))
                          (self2 (rest ds) (most b (* 8 (+ at sz))) (most a (c-type-align k))
                            (pair (list fname at k) fs))))
                      (#t
                        (let ((start (match
                                       (union? 0)
                                       ((= w 0) (round-up b unit))
                                       ((> (+ (% b unit) w) unit) (round-up b unit))
                                       (#t b))))
                          (def bk (%cc-p-bits fname k (% start unit) w))
                          (match
                            ((null? fname) (self2 (rest ds) (most b (+ start w)) a fs))
                            (#t (self2 (rest ds) (most b (if union? unit (+ start w)))
                                  (most a (c-type-align k))
                                  (pair (list fname (* sz (/ start unit)) bk) fs)))))))))))
            (def l (lay (first r) bits align fields))
            (self (rest r) (first l) (first (rest l)) (first (rest (rest l))))))))
    (go toks 0 1 ())))

; typedef TYPE declarator (, declarator)* ;  -- each declarator names the
; C type it would give a variable, and nothing is declared:
; typedef int vec3[3], *ints, (*row)[3];
(def %cc-p-typedef
  (fn (_ toks)
    (def tr (%cc-p-specifiers toks))
    (def go
      (fn (self ts)
        (def h (%cc-p-declarator-head ts (first tr)))
        (set! %cc-p-typedefs (pair (pair (first h) (first (rest h))) %cc-p-typedefs))
        (if (%cc-p-op? (rest (rest h)) ",")
          (self (rest (rest (rest h))))
          (%cc-p-eat (rest (rest h)) ";"))))
    (go (rest tr))))

; --- statements --------------------------------------------------------------

(set! %cc-p-stmt
  (fn (_ toks)
    (if (%cc-p-op? toks "{")
      (%cc-p-block (rest toks))
      ; goto NAME; and NAME: STATEMENT -- (goto NAME), (label NAME STMT).  A
      ; label before a declaration labels an empty statement in front of it.
      (if (%cc-p-kw? toks (lit goto))
        (if (not (%cc-p-id? (rest toks))) (%cc-p-err "expected a label after goto")
          (pair (list (lit goto) (first (rest (first (rest toks)))))
            (%cc-p-eat (rest (rest toks)) ";")))
      (if (if (%cc-p-id? toks) (%cc-p-op? (rest toks) ":") #f)
        (let ((name (first (rest (first toks)))) (s (%cc-p-stmt (rest (rest toks)))))
          (if (eq? (first (first s)) (lit decls))
            (pair (pair (lit decls) (pair (list (lit label) name (list (lit block) ())) (rest (first s))))
              (rest s))
            (pair (list (lit label) name (first s)) (rest s))))
      (if (%cc-p-kw? toks (lit if))
        (let ((c (%cc-e-comma (%cc-p-eat (rest toks) "("))))
          (def t (%cc-p-stmt (%cc-p-eat (rest c) ")")))
          (if (%cc-p-kw? (rest t) (lit else))
            (let ((e (%cc-p-stmt (rest (rest t)))))
              (pair (list (lit if) (first c) (first t) (first e))
                (rest e)))
            (pair (list (lit if) (first c) (first t) ()) (rest t))))
        (if (%cc-p-kw? toks (lit switch))
          (%cc-p-switch toks)
        (if (%cc-p-kw? toks (lit while))
          (let ((c (%cc-e-comma (%cc-p-eat (rest toks) "("))))
            (def b (%cc-p-stmt (%cc-p-eat (rest c) ")")))
            (pair (list (lit while) (first c) (first b)) (rest b)))
          (if (%cc-p-kw? toks (lit do))
            (let ((b (%cc-p-stmt (rest toks))))
              (if (not (%cc-p-kw? (rest b) (lit while)))
                (%cc-p-err "expected while after do")
                (let ((c (%cc-e-comma
                           (%cc-p-eat (rest (rest b)) "("))))
                  (pair (list (lit do) (first b) (first c))
                    (%cc-p-eat (%cc-p-eat (rest c) ")") ";")))))
            (if (%cc-p-kw? toks (lit for))
              (let ((ts (%cc-p-eat (rest toks) "(")))
                (def i-r
                  (if (%cc-p-op? ts ";") (pair () ts)
                    (%cc-e-comma ts)))
                (def ts2 (%cc-p-eat (rest i-r) ";"))
                (def c-r
                  (if (%cc-p-op? ts2 ";") (pair () ts2)
                    (%cc-e-comma ts2)))
                (def ts3 (%cc-p-eat (rest c-r) ";"))
                (def u-r
                  (if (%cc-p-op? ts3 ")") (pair () ts3)
                    (%cc-e-comma ts3)))
                (def b (%cc-p-stmt (%cc-p-eat (rest u-r) ")")))
                (pair
                  (list (lit for) (first i-r) (first c-r) (first u-r)
                    (first b))
                  (rest b)))
              (if (%cc-p-kw? toks (lit return))
                (if (%cc-p-op? (rest toks) ";")
                  (pair (list (lit return) ()) (rest (rest toks)))
                  (let ((r (%cc-e-comma (rest toks))))
                    (pair (list (lit return) (first r))
                      (%cc-p-eat (rest r) ";"))))
                (if (%cc-p-kw? toks (lit break))
                  (pair (list (lit break)) (%cc-p-eat (rest toks) ";"))
                  (if (%cc-p-kw? toks (lit continue))
                    (pair (list (lit continue))
                      (%cc-p-eat (rest toks) ";"))
                    (if (%cc-p-op? toks ";")
                      (pair (list (lit block) ()) (rest toks))
                      (if (%cc-p-hard? toks)
                        (%cc-p-err
                          (string-append "not built yet: "
                            (convert (first (rest (first toks))) %string)))
                        (if (%cc-p-kw? toks (lit typedef))
                          (pair (list (lit block) ()) (%cc-p-typedef (rest toks)))
                        (if (%cc-p-c-type-start? toks)
                          (let ((r (%cc-p-decl-line toks)))
                            (pair (pair (lit decls)
                                    (if (%cc-p-static? toks)
                                      (map (fn (_ d) (append d (list (lit static)))) (first r))
                                      (first r)))
                              (rest r)))
                          (let ((r (%cc-e-comma toks)))
                            (pair (list (lit expr) (first r))
                              (%cc-p-eat (rest r) ";"))))))))))))))))))))

; switch (E) { case V: ... default: ... } -> (switch E CLAUSES), each
; clause (VALUE stmt...) in order, VALUE () for default; fallthrough is
; the evaluator's, from the matched clause to the end
(def %cc-p-switch
  (fn (_ toks)
    (def c (%cc-e-comma (%cc-p-eat (rest toks) "(")))
    (def ts0 (%cc-p-eat (%cc-p-eat (rest c) ")") "{"))
    ; cur is (VALUE . reversed-stmts), () before the first case
    (def finish (fn (_ cur) (pair (first cur) (reverse (rest cur)))))
    (def close (fn (_ cur clauses) (if (null? cur) clauses (pair (finish cur) clauses))))
    (def go
      (fn (self ts cur clauses)
        (if (%cc-p-op? ts "}")
          (pair (list (lit switch) (first c) (reverse (close cur clauses))) (rest ts))
          (if (%cc-p-kw? ts (lit case))
            (let ((v (%cc-e-assign (rest ts))))
              (self (%cc-p-eat (rest v) ":") (pair (first v) ()) (close cur clauses)))
            (if (%cc-p-kw? ts (lit default))
              (self (%cc-p-eat (rest ts) ":") (pair () ()) (close cur clauses))
              (if (null? cur)
                (%cc-p-err "a statement before the first case")
                (let ((r (%cc-p-stmt ts)))
                  (if (eq? (first (first r)) (lit decls))
                    (self (rest r)
                      (pair (first cur) (append (reverse (rest (first r))) (rest cur)))
                      clauses)
                    (self (rest r) (pair (first cur) (pair (first r) (rest cur))) clauses)))))))))
    (go ts0 () ())))

; { ... }: statements and declarations, decls flattened in
(set! %cc-p-block
  (fn (_ toks)
    (def go
      (fn (self ts acc)
        (if (%cc-p-op? ts "}")
          (pair (list (lit block) (reverse acc)) (rest ts))
          (if (null? ts)
            (%cc-p-err "expected }")
            (let ((r (%cc-p-stmt ts)))
              (if (eq? (first (first r)) (lit decls))
                (self (rest r) (append (reverse (rest (first r))) acc))
                (self (rest r) (pair (first r) acc))))))))
    (go toks ())))

; --- top level ---------------------------------------------------------------

; parameters: (void) | (type name, ...) -- names and C types.  A `...` after
; the last is a parameter named "...", which holds a va_list for the
; arguments past the fixed ones (%cc-p-va-handed).
(def %cc-p-params
  (fn (_ toks)
    (if (%cc-p-op? toks ")")
      (pair (pair () ()) (rest toks))
      (if (if (%cc-p-kw? toks (lit void)) (%cc-p-op? (rest toks) ")") #f)
        (pair (pair () ()) (rest (rest toks)))
        (let ((go ()))
          ; one parameter, then the rest after its comma
          (def param
            (fn (_ ts names c-types)
              (def tr (%cc-p-specifiers ts))
              (def sr (%cc-p-stars (first tr) (rest tr)))
              ; (NAME C-TYPE . rest), as a declarator gives it; a
              ; prototype's parameter may have no name
              (def head
                (if (if (%cc-p-op? (rest sr) ",") #t (%cc-p-op? (rest sr) ")"))
                  (pair "" sr)
                  (%cc-p-declarator-head (rest tr) (first tr))))
              (let ((name (first head)))
                ; a parameter declared an array is a pointer to its
                ; element, as C adjusts it
                (def c-type
                  (let ((k (first (rest head))))
                    (if (if (pair? k) (eq? (first k) (lit array)) #f)
                      (%cc-p-pointer-to (first (rest (rest k))))
                      k)))
                (def ts3 (rest (rest head)))
                (if (%cc-p-op? ts3 ",")
                  (go (rest ts3) (pair name names) (pair c-type c-types))
                  (pair (pair (reverse (pair name names)) (reverse (pair c-type c-types)))
                    (%cc-p-eat ts3 ")"))))))
          (set! go
            (fn (_ ts names c-types)
              (match
                ((not (%cc-p-op? ts "...")) (param ts names c-types))
                ((null? names) (%cc-p-err "a ... with no parameter before it"))
                (#t (pair (pair (reverse (pair "..." names))
                                (reverse (pair %cc-p-va-handed c-types)))
                      (%cc-p-eat (rest ts) ")"))))))
          (go toks () ()))))))

; A function's BODY with each local scoped as C scopes it.  A name declared a
; second time in the function -- in a sibling block, or an inner block
; shadowing an outer one or a parameter among PARAMS -- takes a name of its
; own, NAME%N, which no C name can be, and each (var NAME) in its scope
; takes it too; a name declared once keeps its name.  A block and a switch's
; clauses are each a scope.
(def %cc-p-scope
  (fn (_ body params)
    (def used (pair params ()))
    (def count (pair 0 ()))
    (def member? (fn (self n l) (if (null? l) #f (if (string=? (first l) n) #t (self n (rest l))))))
    (def resolve
      (fn (self n scopes)
        (if (null? scopes) n
          (let ((hit (let ((go (fn (self2 al)
                                 (if (null? al) ()
                                   (if (string=? (first (first al)) n) (first al) (self2 (rest al)))))))
                       (go (first scopes)))))
            (if (null? hit) (self n (rest scopes)) (rest hit))))))
    (def walk ())
    ; STMTS in order, a declaration adding to the innermost scope:
    ; (STMTS' . SCOPES')
    (def seq
      (fn (self stmts scopes acc)
        (if (null? stmts) (pair (reverse acc) scopes)
          (let ((s (first stmts)))
            (if (if (pair? s) (eq? (first s) (lit decl)) #f)
              (let ((name (first (rest s))))
                (def init (walk (first (rest (rest (rest s)))) scopes))
                (def fresh
                  (if (member? name (first used))
                    (do (set-first! count (+ (first count) 1))
                        (string-append name (string-append "%" (convert (first count) %string))))
                    name))
                (set-first! used (pair name (first used)))
                (self (rest stmts)
                  (pair (pair (pair name fresh) (first scopes)) (rest scopes))
                  (pair (pair (lit decl) (pair fresh (pair (first (rest (rest s)))
                                                     (pair init (rest (rest (rest (rest s))))))))
                    acc)))
              (self (rest stmts) scopes (pair (walk s scopes) acc)))))))
    (set! walk
      (fn (self node scopes)
        (match
          ((not (pair? node)) node)
          ((eq? (first node) (lit var)) (list (lit var) (resolve (first (rest node)) scopes)))
          ; a call names its callee, which may be a local holding a pointer
          ((eq? (first node) (lit call))
            (list (lit call) (resolve (first (rest node)) scopes)
              (map (fn (_ x) (self x scopes)) (first (rest (rest node))))))
          ((eq? (first node) (lit block))
            (list (lit block) (first (seq (first (rest node)) (pair () scopes) ()))))
          ((eq? (first node) (lit switch))
            (let ((e (self (first (rest node)) scopes)))
              (def clauses
                (fn (self2 cs sc acc)
                  (if (null? cs) (reverse acc)
                    (let ((r (seq (rest (first cs)) sc ())))
                      (self2 (rest cs) (rest r)
                        (pair (pair (self (first (first cs)) sc) (first r)) acc))))))
              (list (lit switch) e (clauses (first (rest (rest node))) (pair () scopes) ()))))
          (#t (map (fn (_ x) (self x scopes)) node)))))
    (walk body ())))

(def cc-parse
  (fn (_ toks)
    (set! %cc-p-structs ())
    ; <stdarg.h>'s va_list is this one
    (set! %cc-p-typedefs (list (pair "__builtin_va_list" %cc-p-va-list)))
    (set! %cc-p-enums ())
    (set! %cc-p-anon 0)
    (def go
      (fn (self ts acc)
        (if (null? ts)
          (reverse acc)
          (if (%cc-p-hard? ts)
            (%cc-p-err
              (string-append "not built yet: "
                (convert (first (rest (first ts))) %string)))
          (if (%cc-p-kw? ts (lit typedef))
            (self (%cc-p-typedef (rest ts)) acc)
            (let ((tr (%cc-p-c-type ts)))
              (def ts2 (rest tr))
              (if (%cc-p-op? ts2 ";")
                ; `struct S { ... };` -- a definition, nothing declared
                (self (rest ts2) acc)
              (if (not (if (%cc-p-id? ts2) #t (%cc-p-fnptr-start? ts2)))
                (%cc-p-err "expected a declaration")
                (let ((name (if (%cc-p-id? ts2) (first (rest (first ts2))) ())))
                  (if (if (%cc-p-id? ts2) (%cc-p-op? (rest ts2) "(") #f)
                    ; function: definition, or a prototype to skip
                    (let ((pr (%cc-p-params (rest (rest ts2)))))
                      (if (%cc-p-op? (rest pr) ";")
                        (self (rest (rest pr)) acc)
                        (let ((b (%cc-p-block
                                   (%cc-p-eat (rest pr) "{"))))
                          ; (fun NAME PARAMS BODY C-TYPES RET-C-TYPE)
                          (self (rest b)
                            (pair (list (lit fun) name (first (first pr))
                                    (%cc-p-scope (first b) (first (first pr)))
                                    (rest (first pr)) (first tr))
                              acc)))))
                    ; globals: reuse the declarator line from ts
                    (let ((r (%cc-p-decl-line ts)))
                      (self (rest r)
                        (append
                          (reverse
                            (map (fn (_ d)
                                   (list (lit gdecl) (first (rest d))
                                     (first (rest (rest d)))
                                     (first (rest (rest (rest d))))))
                              (first r)))
                          acc)))))))))))))
    (go toks ())))

; the value of TOKS, the whole of them a constant expression, as #if
; takes one
(def cc-parse-const
  (fn (_ toks)
    (def r (%cc-e-tern toks))
    (if (not (null? (rest r))) (%cc-p-err "expected a constant expression"))
    (%cc-p-const (first r))))

(provide cc/parse cc-parse cc-parse-const c-type-size c-type-align plain-char round-up
  struct-entry struct-table)
