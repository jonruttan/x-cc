; # x-cc -- a C compiler on x-lang
;
; ## cc/parse.x -- tokens to a program
;
; @author [Jon Ruttan](jonruttan@gmail.com)
; @copyright 2026 Jon Ruttan
; @license MIT No Attribution (MIT-0)
;
; GRAMMAR ONLY, functionally threaded: every function answers
; (ast . remaining-tokens).  The full C expression ladder, fifteen
; levels, each level one flat function -- the arc's thrice-learned
; misnesting lesson applied from the start.
;
; THE AST:
;   toplevel  (fun NAME PARAMS BODY) (gdecl NAME KIND INIT|())
;   stmts     (block ITEMS) (if C T E|()) (while C B) (do B C)
;             (for I|() C|() U|() B) (return E|()) (break) (continue)
;             (expr E) (decl NAME KIND INIT|())
;   KIND      scalar | (array N)
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
; `(*NAME)(params)` declarator is one cell; a call whose callee is
; any expression but a bare name is (callx E ARGS)) parse.  Refused
; loudly: goto, floats -- each a recorded pending.

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

; the unimplemented keywords refuse by name
(def %cc-p-hard
  (list (lit goto) (lit float) (lit double)))

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
(def %cc-p-type-kw?
  (fn (_ toks)
    (if (null? toks) #f
      (if (eq? (first (first toks)) (lit kw))
        (let ((k (first (rest (first toks)))))
          (if (eq? k (lit int)) #t
            (if (eq? k (lit char)) #t
              (if (eq? k (lit void)) #t
                (if (eq? k (lit long)) #t
                  (if (eq? k (lit short)) #t
                    (if (eq? k (lit unsigned)) #t
                      (if (eq? k (lit signed)) #t
                        (if (eq? k (lit const)) #t
                          (if (eq? k (lit static)) #t
                            (eq? k (lit extern))))))))))))
        #f))))

; --- types, as far as the cell model needs them ----------------------------
; KINDS: scalar | (array N) | (array N K) | (struct S) | (ptr K).  Every
; scalar is one cell; a struct is its fields laid end to end (a field's
; offset is the cells before it); an array of K is N*size(K) cells; a
; pointer is one cell, and its K is kept ONLY when it points at a
; struct, because that is when arithmetic on it must scale and `->`
; must know its fields.  The parser keeps the struct and typedef tables
; (the evaluator reads them; parse always precedes load in a process).
(def %cc-p-structs ())     ; ((name size . ((fname off kind) ...)) ...)
(def %cc-p-typedefs ())    ; ((name . kind) ...)
(def %cc-p-anon 0)

(def %cc-p-struct-entry
  (fn (_ name)
    (def go (fn (self es)
              (if (null? es) ()
                (if (string=? (first (first es)) name) (first es)
                  (self (rest es))))))
    (go %cc-p-structs)))

(def %cc-kind-size
  (fn (self kind)
    (if (not (pair? kind)) 1
      (if (eq? (first kind) (lit array))
        (* (first (rest kind))
          (if (null? (rest (rest kind))) 1
            (self (first (rest (rest kind))))))
        (if (eq? (first kind) (lit struct))
          (let ((e (%cc-p-struct-entry (first (rest kind)))))
            (if (null? e)
              (%cc-p-err (string-append "unknown struct: " (first (rest kind))))
              (first (rest e))))
          1)))))

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
(def %cc-p-typedef-kind
  (fn (_ n)
    (def go (fn (self es)
              (if (null? es) (lit scalar)
                (if (string=? (first (first es)) n) (rest (first es)) (self (rest es))))))
    (go %cc-p-typedefs)))

; a declaration starts with a type keyword, `struct`/`union`/`enum`,
; or a typedef name
(def %cc-p-type-start?
  (fn (_ toks)
    (if (%cc-p-type-kw? toks) #t
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

; an enumerator's value: a constant expression over numbers (enum
; names already folded to numbers by the primary level)
(def %cc-p-const
  (fn (self node)
    (let ((t (first node)))
      (if (eq? t (lit num)) (first (rest node))
        (if (eq? t (lit un))
          (let ((v (self (first (rest (rest node))))))
            (def op (first (rest node)))
            (if (string=? op "-") (- 0 v)
              (if (string=? op "!") (if (= v 0) 1 0)
                (if (string=? op "~") (- (- 0 v) 1)
                  (%cc-p-err "an enumerator needs a constant expression")))))
          (if (eq? t (lit bin))
            (let ((op (first (rest node))))
              (def a (self (first (rest (rest node)))))
              (def b (self (first (rest (rest (rest node))))))
              (if (string=? op "+") (+ a b)
                (if (string=? op "-") (- a b)
                  (if (string=? op "*") (* a b)
                    (if (string=? op "/") (let ((q (/ a b))) (- q (% q 1)))
                      (if (string=? op "%") (let ((q (/ a b))) (- a (* b (- q (% q 1)))))
                        (if (string=? op "<<") (<< a b)
                          (if (string=? op ">>") (>> a b)
                            (if (string=? op "&") (& a b)
                              (if (string=? op "|") (| a b)
                                (if (string=? op "^") (^ a b)
                                  (%cc-p-err "an enumerator needs a constant expression"))))))))))))
            (%cc-p-err "an enumerator needs a constant expression")))))))

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
; declarator (types erased in the cell model); answers the rest
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

; a pointer to a struct keeps its pointee; every other pointer is a cell
(def %cc-p-pointer-to
  (fn (_ k)
    (if (if (pair? k) (eq? (first k) (lit struct)) #f) (list (lit ptr) k) (lit scalar))))

(def %cc-p-struct-body ())

; TYPE: specifiers, `struct|union NAME [{...}]`, `enum [NAME] [{...}]`,
; or a typedef name, then *s.  Answers (KIND . rest).
(def %cc-p-type
  (fn (_ toks)
    (def skip-kws (fn (self ts) (if (%cc-p-type-kw? ts) (self (rest ts)) ts)))
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
    (def based
      (if (%cc-p-kw? ts (lit struct)) (tagged (rest ts) #f)
        (if (%cc-p-kw? ts (lit union)) (tagged (rest ts) #t)
          (if (%cc-p-kw? ts (lit enum))
            ; enum [NAME] [{ enumerators }]: the constants register, the
            ; type is a scalar
            (let ((ts2 (if (%cc-p-id? (rest ts)) (rest (rest ts)) (rest ts))))
              (pair (lit scalar)
                (if (%cc-p-op? ts2 "{") (%cc-p-enum-body (rest ts2)) ts2)))
            (if (%cc-p-typedef-name? ts)
              (pair (%cc-p-typedef-kind (first (rest (first ts)))) (rest ts))
              (pair (lit scalar) ts))))))
    (def stars
      (fn (self k ts2)
        (if (%cc-p-type-kw? ts2) (self k (rest ts2))
          (if (%cc-p-op? ts2 "*") (self (%cc-p-pointer-to k) (rest ts2))
            (pair k ts2)))))
    (stars (first based) (rest based))))

; swallow a type; answers the rest (casts, and callers that erase)
(def %cc-p-skip-type
  (fn (_ toks) (rest (%cc-p-type toks))))

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

(def %cc-e-primary
  (fn (_ toks)
    (if (null? toks) (%cc-p-err "expected an expression")
      (let ((tok (first toks)))
        (def tag (first tok))
        (if (eq? tag (lit num)) (pair tok (rest toks))
          (if (eq? tag (lit str)) (pair tok (rest toks))
            (if (eq? tag (lit id))
              (if (%cc-p-op? (rest toks) "(")
                (let ((r (%cc-p-args (rest (rest toks)))))
                  (pair (list (lit call) (first (rest tok)) (first r))
                    (rest r)))
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

; a parenthesized type-name means a cast (erased in the cell model)
(def %cc-cast?
  (fn (_ toks)
    (if (%cc-p-op? toks "(")
      (%cc-p-type-start? (rest toks))
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
                        (let ((tr (%cc-p-type (rest (rest toks)))))
                          (pair (list (lit num) (%cc-kind-size (first tr)))
                            (%cc-p-eat (rest tr) ")")))
                        (let ((r (self (rest toks))))
                          (pair (list (lit szof) (first r)) (rest r))))
                      (if (%cc-cast? toks)
                        (let ((ts (%cc-p-skip-type (rest toks))))
                          (self (%cc-p-eat ts ")")))
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

; one declarator after the specifiers: *s NAME [N]? = init?, or the
; function-pointer form (*NAME [N]?)(params) -- one cell, the parameter
; types erased; answers ((decl NAME KIND INIT) . rest)
(def %cc-p-declarator
  (fn (_ toks base)
    (def stars (fn (self k ts) (if (%cc-p-op? ts "*") (self (%cc-p-pointer-to k) (rest ts)) (pair k ts))))
    (def sr (stars base toks))
    (def ts (rest sr))
    (def kind0 (first sr))
    ; the array suffix after a name: (KIND . rest)
    (def suffix
      (fn (_ k ts2)
        (if (%cc-p-op? ts2 "[")
          (if (%cc-p-op? (rest ts2) "]")
            ; int a[] = ...: the initializer sizes it
            (pair (if (pair? k) (list (lit array) () k) (list (lit array) ()))
              (rest (rest ts2)))
            (let ((n (first (rest (first (rest ts2))))))
              (pair (if (pair? k) (list (lit array) n k) (list (lit array) n))
                (%cc-p-eat (rest (rest ts2)) "]"))))
          (pair k ts2))))
    ; (NAME KIND . rest)
    (def head
      (if (%cc-p-fnptr-start? ts)
        (let ((ts2 (rest (rest ts))))
          (if (not (%cc-p-id? ts2))
            (%cc-p-err "expected a name in a function-pointer declarator")
            (let ((kr (suffix (lit scalar) (rest ts2))))
              (pair (first (rest (first ts2)))
                (pair (first kr) (%cc-p-skip-parens (%cc-p-eat (rest kr) ")")))))))
        (if (not (%cc-p-id? ts))
          (%cc-p-err "expected a name in declaration")
          (let ((kr (suffix kind0 (rest ts))))
            (pair (first (rest (first ts))) (pair (first kr) (rest kr)))))))
    (def name (first head))
    (def kind (first (rest head)))
    (def ts3 (rest (rest head)))
    (if (%cc-p-op? ts3 "=")
      (let ((ir (if (%cc-p-op? (rest ts3) "{")
                  (%cc-p-initlist (rest (rest ts3)))
                  (%cc-e-assign (rest ts3)))))
        (pair (list (lit decl) name (%cc-p-size-kind kind (first ir)) (first ir))
          (rest ir)))
      (if (if (pair? kind) (if (eq? (first kind) (lit array)) (null? (first (rest kind))) #f) #f)
        (%cc-p-err "an array without a size needs an initializer")
        (pair (list (lit decl) name kind ()) ts3)))))

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
(def %cc-p-size-kind
  (fn (_ kind init)
    (if (if (pair? kind) (if (eq? (first kind) (lit array)) (null? (first (rest kind))) #f) #f)
      (let ((n (if (eq? (first init) (lit initlist)) (length (first (rest init)))
                 (if (eq? (first init) (lit str)) (+ 1 (byte-len (first (rest init))))
                   (%cc-p-err "an unsized array needs a list or string initializer")))))
        (if (null? (rest (rest kind))) (list (lit array) n) (list (lit array) n (first (rest (rest kind))))))
      kind)))

; TYPE declarator (, declarator)* ; -- a list of decl nodes
(def %cc-p-decl-line
  (fn (_ toks)
    (def tr (%cc-p-type toks))
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
(set! %cc-p-struct-body
  (fn (_ name toks union?)
    (def go
      (fn (self ts off fields)
        (if (%cc-p-op? ts "}")
          (do (set! %cc-p-structs
                (pair (pair name (pair off (reverse fields))) %cc-p-structs))
              (rest ts))
          (let ((r (%cc-p-decl-line ts)))
            (def lay
              (fn (self2 ds o fs)
                (if (null? ds) (pair o fs)
                  (let ((d (first ds)))
                    (def k (first (rest (rest d))))
                    (def sz (%cc-kind-size k))
                    (if union?
                      (self2 (rest ds) (if (> sz o) sz o)
                        (pair (list (first (rest d)) 0 k) fs))
                      (self2 (rest ds) (+ o sz)
                        (pair (list (first (rest d)) o k) fs)))))))
            (def l (lay (first r) off fields))
            (self (rest r) (first l) (rest l))))))
    (go toks 0 ())))

; typedef TYPE declarator ;  -- a name for a kind, nothing declared;
; `typedef int (*NAME)(params);` names the one-cell function pointer
(def %cc-p-typedef
  (fn (_ toks)
    (def tr (%cc-p-type toks))
    (def stars (fn (self k ts) (if (%cc-p-op? ts "*") (self (%cc-p-pointer-to k) (rest ts)) (pair k ts))))
    (def sr (stars (first tr) (rest tr)))
    (if (%cc-p-fnptr-start? (rest sr))
      (let ((ts2 (rest (rest (rest sr)))))
        (if (not (%cc-p-id? ts2)) (%cc-p-err "expected a typedef name")
          (let ((name (first (rest (first ts2)))))
            (set! %cc-p-typedefs (pair (pair name (lit scalar)) %cc-p-typedefs))
            (%cc-p-eat (%cc-p-skip-parens (%cc-p-eat (rest ts2) ")")) ";"))))
      (if (not (%cc-p-id? (rest sr))) (%cc-p-err "expected a typedef name")
        (let ((name (first (rest (first (rest sr))))))
          (set! %cc-p-typedefs (pair (pair name (first sr)) %cc-p-typedefs))
          (%cc-p-eat (rest (rest sr)) ";"))))))

; --- statements --------------------------------------------------------------

(set! %cc-p-stmt
  (fn (_ toks)
    (if (%cc-p-op? toks "{")
      (%cc-p-block (rest toks))
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
                        (if (%cc-p-type-start? toks)
                          (let ((r (%cc-p-decl-line toks)))
                            (pair (pair (lit decls) (first r)) (rest r)))
                          (let ((r (%cc-e-comma toks)))
                            (pair (list (lit expr) (first r))
                              (%cc-p-eat (rest r) ";"))))))))))))))))))

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

; parameters: (void) | (type name, ...) -- names only in the cell model
(def %cc-p-params
  (fn (_ toks)
    (if (%cc-p-op? toks ")")
      (pair (pair () ()) (rest toks))
      (if (if (%cc-p-kw? toks (lit void)) (%cc-p-op? (rest toks) ")") #f)
        (pair (pair () ()) (rest (rest toks)))
        (let ((go ()))
          (set! go
            (fn (self ts names kinds)
              (def tr (%cc-p-type ts))
              (def ts2 (rest tr))
              ; (NAME KIND . rest): a plain parameter, an array one
              ; (a pointer), or a function pointer (one cell)
              (def head
                (if (%cc-p-fnptr-start? ts2)
                  (let ((ts3 (rest (rest ts2))))
                    (if (not (%cc-p-id? ts3)) (%cc-p-err "expected a parameter name")
                      (pair (first (rest (first ts3)))
                        (pair (lit scalar)
                          (%cc-p-skip-parens (%cc-p-eat (rest ts3) ")"))))))
                  (if (not (%cc-p-id? ts2))
                    (%cc-p-err "expected a parameter name")
                    (let ((arr? (%cc-p-op? (rest ts2) "[")))
                      (pair (first (rest (first ts2)))
                        (pair (if arr? (%cc-p-pointer-to (first tr)) (first tr))
                          (if arr? (%cc-p-eat (rest (rest ts2)) "]") (rest ts2))))))))
              (let ((name (first head)))
                (def kind (first (rest head)))
                (def ts3 (rest (rest head)))
                (if (%cc-p-op? ts3 ",")
                  (self (rest ts3) (pair name names) (pair kind kinds))
                  (pair (pair (reverse (pair name names)) (reverse (pair kind kinds)))
                    (%cc-p-eat ts3 ")"))))))
          (go toks () ()))))))

(def cc-parse
  (fn (_ toks)
    (set! %cc-p-structs ())
    (set! %cc-p-typedefs ())
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
            (let ((ts2 (%cc-p-skip-type ts)))
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
                          (self (rest b)
                            (pair (list (lit fun) name (first (first pr))
                                    (first b) (rest (first pr)))
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
