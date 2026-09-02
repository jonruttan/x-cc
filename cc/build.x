; # x-cc -- a C compiler on x-lang
;
; ## cc/build.x -- the compile-asm backend, slice one
;
; @author [Jon Ruttan](jonruttan@gmail.com)
; @copyright 2026 Jon Ruttan
; @license MIT No Attribution (MIT-0)
;
; THE ELIGIBLE CLASS: a C function lowers to the engine's JIT when it
; is integers all the way -- int parameters, expressions over params,
; literals, + - * / % comparisons && || ! ~ the ternary, and calls to
; ITSELF (max 4 lane args -- the trampoline rule; self-recursion rides
; the fn's first-param name, x-lang#583's slot-0 convention).  Two body
; shapes lower:
;   1. if/return/blocks -- fib and friends (%cc-lower-expr-fun)
;   2. { decls; while|for; return } -- LOOPS, transformed to tail
;      self-recursion with the accumulators as extra params, literal
;      inits supplied by arg-padding at the call boundary
;      (%cc-lower-loop).  Slice one: a flat assignment body,
;      literal inits, params+accs <= 4.
; Pointers, param mutation, nested loop control, non-literal inits,
; globals and cross-calls stay interpreted -- recorded pendings.
;
; Adoption is sha256.x's pattern: the whole attempt sits in a guard;
; a function that will not lower or will not compile simply stays
; interpreted.  `build` reports which twin each function got, then
; runs -- same output as `run`, faster where it counts.

(import x/tool/compile)

; C identifiers that would collide with the lane's own operators
(def %cc-unsafe-name?
  (fn (_ s)
    (if (string=? s "if") #t
      (if (string=? s "and") #t
        (if (string=? s "or") #t
          (if (string=? s "not") #t
            (if (string=? s "do") #t
              (if (string=? s "fn") #t (string=? s "self")))))))))

(def %cc-no
  (fn (_ why) (Err raise (lit cc-lower) why ())))

(def %cc-member-str?
  (fn (_ s l)
    (def go
      (fn (self es)
        (if (null? es) #f
          (if (string=? (first es) s) #t (self (rest es))))))
    (go l)))

; C expression AST to lane expression; FNAME is the self-call name,
; PARAMS the only legal variables
(def %cc-lower-e
  (fn (self node fname params)
    (let ((t (first node)))
      (if (eq? t (lit num)) (first (rest node))
      (if (eq? t (lit var))
        (let ((n (first (rest node))))
          (if (%cc-member-str? n params)
            (convert n %symbol)
            (%cc-no "free variable")))
      (if (eq? t (lit bin))
        (let ((op (first (rest node))))
          (def a (self (first (rest (rest node))) fname params))
          (def b (self (first (rest (rest (rest node)))) fname params))
          (if (string=? op "+") (list (lit +) a b)
            (if (string=? op "-") (list (lit -) a b)
              (if (string=? op "*") (list (lit *) a b)
                (if (string=? op "/") (list (lit /) a b)
                  (if (string=? op "%") (list (lit %) a b)
                    (%cc-no "bitwise is not in the lane yet")))))))
      (if (eq? t (lit cmp))
        (let ((op (first (rest node))))
          (def a (self (first (rest (rest node))) fname params))
          (def b (self (first (rest (rest (rest node)))) fname params))
          (if (string=? op "<") (list (lit <) a b)
            (if (string=? op "<=") (list (lit <=) a b)
              (if (string=? op ">") (list (lit >) a b)
                (if (string=? op ">=") (list (lit >=) a b)
                  (if (string=? op "==") (list (lit =) a b)
                    ; != as an if: the lane's not() wants one arm
                    (list (lit if) (list (lit =) a b) 0 1)))))))
      (if (eq? t (lit and))
        ; C's && yields exactly 1 or 0
        (list (lit if)
          (list (lit =) (self (first (rest node)) fname params) 0)
          0
          (list (lit if)
            (list (lit =)
              (self (first (rest (rest node))) fname params) 0)
            0 1))
      (if (eq? t (lit or))
        (list (lit if)
          (list (lit =) (self (first (rest node)) fname params) 0)
          (list (lit if)
            (list (lit =)
              (self (first (rest (rest node))) fname params) 0)
            0 1)
          1)
      (if (eq? t (lit un))
        (let ((op (first (rest node))))
          (def v (self (first (rest (rest node))) fname params))
          (if (string=? op "-") (list (lit -) 0 v)
            (if (string=? op "!") (list (lit if) (list (lit =) v 0) 1 0)
              (if (string=? op "~") (list (lit ~) v)
                (%cc-no "pointers stay interpreted")))))
      (if (eq? t (lit ternary))
        (list (lit if)
          (self (first (rest node)) fname params)
          (self (first (rest (rest node))) fname params)
          (self (first (rest (rest (rest node)))) fname params))
      (if (eq? t (lit call))
        (let ((callee (first (rest node))))
          (def args (first (rest (rest node))))
          (if (not (string=? callee fname))
            (%cc-no "only self-calls lower")
            (if (> (length args) 4)
              (%cc-no "the lane takes at most 4 args")
              (pair (convert fname %symbol)
                (map (fn (_ a) (self a fname params)) args)))))
        (%cc-no "form stays interpreted")))))))))))))

; a statement list where every path returns, as one expression
(def %cc-lower-body
  (fn (self stmts fname params)
    (if (null? stmts)
      (%cc-no "a path falls off the end")
      (let ((s (first stmts)))
        (let ((t (first s)))
          (if (eq? t (lit return))
            (if (null? (first (rest s)))
              (%cc-no "a bare return has no value to lower")
              (%cc-lower-e (first (rest s)) fname params))
            (if (eq? t (lit block))
              (self (append (first (rest s)) (rest stmts)) fname params)
              (if (eq? t (lit if))
                (let ((c (%cc-lower-e (first (rest s)) fname params)))
                  (def then-b
                    (%cc-lower-body (list (first (rest (rest s))))
                      fname params))
                  (def else-n (first (rest (rest (rest s)))))
                  (def else-b
                    (if (null? else-n)
                      (self (rest stmts) fname params)
                      (%cc-lower-body
                        (pair else-n (rest stmts)) fname params)))
                  (list (lit if) c then-b else-b))
                (%cc-no "only if/return lower")))))))))

; --- loops: the tail-recursion transform -----------------------------------
; The lane has no loop -- only whole-function self-recursion.  So a C
; function shaped { decls; while|for; return R } becomes a tail-
; recursive function whose accumulator and loop variables ride as EXTRA
; parameters after the real ones: init in the arg-padding at the call
; boundary, updated in the self-call.  The whole thing is ONE lane
; function whose body IS the loop:
;   (fn (name p... a...) (if COND (name p... new-a...) R))
; Slice one: a flat body of assignments/++/-- to the accumulators,
; literal inits, params+accs <= 4.  Nested control in the body, non-
; literal inits, and param mutation stay interpreted.

; string-keyed alist helpers (accname -> cexpr)
(def %cc-assoc-str
  (fn (_ k al)
    (def go (fn (self es)
              (if (null? es) ()
                (if (string=? (first (first es)) k) (first es)
                  (self (rest es))))))
    (go al)))
(def %cc-del-str
  (fn (_ k al)
    (def go (fn (self es)
              (if (null? es) ()
                (if (string=? (first (first es)) k) (rest es)
                  (pair (first es) (self (rest es)))))))
    (go al)))
(def %cc-put-str
  (fn (_ k v al) (pair (pair k v) (%cc-del-str k al))))

; an int literal (or its unary minus), else nil
(def %cc-int-lit
  (fn (_ node)
    (if (eq? (first node) (lit num)) (first (rest node))
      (if (if (eq? (first node) (lit un))
            (string=? (first (rest node)) "-") #f)
        (let ((inner (first (rest (rest node)))))
          (if (eq? (first inner) (lit num))
            (- 0 (first (rest inner)))
            ()))
        ()))))

; substitute (var X) -> map[X] (a cexpr) through a cexpr, so an update
; that reads an already-updated accumulator this iteration sees the new
; value -- C's sequential semantics, at the AST level
(def %cc-subst
  (fn (self node sub)
    (let ((t (first node)))
      (if (eq? t (lit var))
        (let ((r (%cc-assoc-str (first (rest node)) sub)))
          (if (null? r) node (rest r)))
      (if (eq? t (lit bin))
        (list (lit bin) (first (rest node))
          (self (first (rest (rest node))) sub)
          (self (first (rest (rest (rest node)))) sub))
      (if (eq? t (lit cmp))
        (list (lit cmp) (first (rest node))
          (self (first (rest (rest node))) sub)
          (self (first (rest (rest (rest node)))) sub))
      (if (eq? t (lit un))
        (list (lit un) (first (rest node))
          (self (first (rest (rest node))) sub))
      (if (eq? t (lit and))
        (list (lit and) (self (first (rest node)) sub)
          (self (first (rest (rest node))) sub))
      (if (eq? t (lit or))
        (list (lit or) (self (first (rest node)) sub)
          (self (first (rest (rest node))) sub))
      (if (eq? t (lit ternary))
        (list (lit ternary) (self (first (rest node)) sub)
          (self (first (rest (rest node))) sub)
          (self (first (rest (rest (rest node)))) sub))
        node))))))))))

; a raw expression that is an assignment/inc to a variable, as
; (varname . new-value-cexpr), else nil
(def %cc-expr-assign
  (fn (_ e)
    (let ((t (first e)))
      (if (eq? t (lit assign))
        (let ((lv (first (rest e))))
          (if (eq? (first lv) (lit var))
            (pair (first (rest lv)) (first (rest (rest e))))
            ()))
      (if (if (eq? t (lit postinc)) #t (eq? t (lit preinc)))
        (let ((lv (first (rest e))))
          (if (eq? (first lv) (lit var))
            (pair (first (rest lv))
              (list (lit bin) "+" lv (list (lit num) 1)))
            ()))
      (if (if (eq? t (lit postdec)) #t (eq? t (lit predec)))
        (let ((lv (first (rest e))))
          (if (eq? (first lv) (lit var))
            (pair (first (rest lv))
              (list (lit bin) "-" lv (list (lit num) 1)))
            ()))
        ()))))))

(def %cc-stmt-assign
  (fn (_ s)
    (if (eq? (first s) (lit expr))
      (%cc-expr-assign (first (rest s)))
      ())))

; fold the loop body (and step) into an updates alist, sequentially
(def %cc-loop-updates
  (fn (_ stmts accs)
    (def go
      (fn (self ss upd)
        (if (null? ss) upd
          (let ((a-rhs (%cc-stmt-assign (first ss))))
            (if (null? a-rhs) (%cc-no "loop body: only assignments")
              (if (not (%cc-member-str? (first a-rhs) accs))
                (%cc-no "loop assigns a non-accumulator")
                (self (rest ss)
                  (%cc-put-str (first a-rhs)
                    (%cc-subst (rest a-rhs) upd) upd))))))))
    (go stmts ())))

; body-stmt to a statement list (a block flattens)
(def %cc-loop-body-stmts
  (fn (_ body-stmt)
    (if (eq? (first body-stmt) (lit block))
      (first (rest body-stmt))
      (list body-stmt))))

; split { decls*; (while|for); return R } -> (decls loop return) or nil
(def %cc-loop-split
  (fn (_ stmts)
    (def go
      (fn (self ss decls)
        (if (null? ss) ()
          (let ((s (first ss)))
            (if (eq? (first s) (lit decl))
              (self (rest ss) (pair s decls))
              (if (if (eq? (first s) (lit while)) #t
                    (eq? (first s) (lit for)))
                (if (if (pair? (rest ss))
                      (if (null? (rest (rest ss)))
                        (eq? (first (first (rest ss))) (lit return)) #f)
                      #f)
                  (list (reverse decls) s (first (rest ss)))
                  ())
                ()))))))
    (go stmts ())))

; set accs[name]'s init in the parallel inits list
(def %cc-set-init
  (fn (self inits accs name v)
    (if (null? accs) inits
      (if (string=? (first accs) name)
        (pair v (rest inits))
        (pair (first inits)
          (self (rest inits) (rest accs) name v))))))

; the loop lowerer: (fn-expr . pad-inits), or a refusal
(def %cc-lower-loop
  (fn (_ name params body)
    (def split (%cc-loop-split (first (rest body))))
    (if (null? split) (%cc-no "not a decls+loop+return shape")
      (let ((decls (first split)))
        (def loop (first (rest split)))
        (def ret (first (rest (rest split))))
        (def ret-e (first (rest ret)))
        (if (null? ret-e) (%cc-no "loop fn has a bare return"))
        (def accs (map (fn (_ d) (first (rest d))) decls))
        (def inits0
          (map (fn (_ d)
                 (let ((iv (first (rest (rest (rest d))))))
                   (if (null? iv) 0
                     (let ((n (%cc-int-lit iv)))
                       (if (null? n) (%cc-no "decl init not a literal") n)))))
            decls))
        (def is-for (eq? (first loop) (lit for)))
        (def init-node (if is-for (first (rest loop)) ()))
        (def cond-node (if is-for (first (rest (rest loop)))
                         (first (rest loop))))
        (def step-node (if is-for (first (rest (rest (rest loop)))) ()))
        (def body-stmt (if is-for
                         (first (rest (rest (rest (rest loop)))))
                         (first (rest (rest loop)))))
        (if (null? cond-node) (%cc-no "loop needs a condition"))
        (if (> (+ (length params) (length accs)) 4)
          (%cc-no "loop needs more than 4 lane args"))
        ; for-INIT overrides an accumulator's literal init
        (def inits
          (if (null? init-node) inits0
            (let ((ia (%cc-expr-assign init-node)))
              (if (null? ia) (%cc-no "for init not a simple assignment")
                (let ((iv (%cc-int-lit (rest ia))))
                  (if (null? iv) (%cc-no "for init not a literal")
                    (if (not (%cc-member-str? (first ia) accs))
                      (%cc-no "for init sets a non-accumulator")
                      (%cc-set-init inits0 accs (first ia) iv))))))))
        ; per-iteration updates: body then step
        (def upd0 (%cc-loop-updates
                    (%cc-loop-body-stmts body-stmt) accs))
        (def upd
          (if (null? step-node) upd0
            (let ((sa (%cc-expr-assign step-node)))
              (if (null? sa) (%cc-no "for step not an assignment")
                (if (not (%cc-member-str? (first sa) accs))
                  (%cc-no "for step touches a non-accumulator")
                  (%cc-put-str (first sa)
                    (%cc-subst (rest sa) upd0) upd0))))))
        (def ext (append params accs))
        (def lcond (%cc-lower-e cond-node name ext))
        (def lret (%cc-lower-e ret-e name ext))
        (def self-call
          (pair (convert name %symbol)
            (append
              (map (fn (_ p) (convert p %symbol)) params)
              (map (fn (_ a)
                     (let ((u (%cc-assoc-str a upd)))
                       (if (null? u) (convert a %symbol)
                         (%cc-lower-e (rest u) name ext))))
                accs))))
        (pair
          (pair (lit fn)
            (pair (pair (convert name %symbol)
                    (map (fn (_ v) (convert v %symbol)) ext))
              (list (list (lit if) lcond self-call lret))))
          inits)))))

; the expression-body path: fib and friends, no padding
(def %cc-lower-expr-fun
  (fn (_ name params body)
    (pair
      (pair (lit fn)
        (pair
          (pair (convert name %symbol)
            (map (fn (_ p) (convert p %symbol)) params))
          (list
            (%cc-lower-body (first (rest body)) name params))))
      ())))

(def %cc-check-names
  (fn (_ name params)
    (if (%cc-unsafe-name? name) (%cc-no "name collides with the lane")
      (let ((check (fn (self ps)
                     (if (null? ps) ()
                       (if (%cc-unsafe-name? (first ps))
                         (%cc-no "parameter collides with the lane")
                         (self (rest ps)))))))
        (check params)))))

; one function to (fn-expr . pad-inits): try the loop transform first,
; fall back to the expression path
(def %cc-lower-fun
  (fn (_ name params body)
    (do (%cc-check-names name params)
        (guard (e (%cc-lower-expr-fun name params body))
          (%cc-lower-loop name params body)))))

; try every function; the guard is the adoption rule -- refuse, stay
; interpreted.  Answers ((name . verdict) ...) in program order,
; verdict native | interpreted.
(def %cc-jit!
  (fn (_)
    (set! %cc-natives ())
    (def go
      (fn (self fs acc)
        (if (null? fs) (reverse acc)
          (let ((name (first (first fs))))
            (def params (first (rest (first fs))))
            (def body (rest (rest (first fs))))
            (def verdict
              (guard (e (lit interpreted))
                (let ((lowered (%cc-lower-fun name params body)))
                  (def prim (compile-asm (first lowered)))
                  ; the table entry is (name pad . prim); pad is the
                  ; accumulators' literal inits, () for a plain function
                  (set! %cc-natives
                    (pair (pair name (pair (rest lowered) prim))
                      %cc-natives))
                  (lit native))))
            (self (rest fs) (pair (pair name verdict) acc))))))
    ; %cc-funs cons-loads, so program order is its reverse
    (go (reverse %cc-funs) ())))

; build: the shared core with the lane switched on -- lower what
; lowers, report each verdict, run main
(def cc-build-run
  (fn (_ src) (%cc-run-core src #t)))
