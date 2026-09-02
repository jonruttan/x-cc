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
;      self-recursion: params AND accumulators ride the self-call
;      with their folded new values, accumulators' literal inits
;      supplied by arg-padding at the call boundary (%cc-lower-loop).
;      The body fold (%cc-fold-stmts) takes assignments/++/-- to any
;      threadable variable (a mutated param is fine), body-local
;      temps (substitution-only, no slot), if/else (each written
;      variable merges as a ternary), and EXITS -- return/break/
;      continue as guarded exits, plus loop-invariant pre-loop
;      `if (C) return E;` guards.  params+accs <= 4.
; Pointers, nested loops, non-literal inits, pre-loop assignments,
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
      (if (eq? t (lit call))
        (list (lit call) (first (rest node))
          (map (fn (_ a) (self a sub)) (first (rest (rest node)))))
        node)))))))))))

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

; the update fold: loop-body statements to an updates alist, in order.
; State is (map locals assigned): MAP is var -> cexpr in terms of the
; iteration's ENTRY values; LOCALS are names declared in the body --
; substitution-only, they never need a parameter slot (a `t = a % b`
; temp folds straight into whoever reads it); ASSIGNED is the names
; written, for the if-merge.  Any variable in EXT (params AND
; accumulators -- a mutated param just rides the self-call like an
; accumulator) or in LOCALS may be assigned.  An `if` folds each branch
; from the current map and merges every variable either branch wrote
; as a ternary on the (substituted) condition -- SSA's phi, as a
; select.  Branch-declared locals die at the merge.  Anything else --
; break, continue, return, a nested loop, a call statement -- refuses.
(def %cc-var-of
  (fn (_ v m)
    (let ((r (%cc-assoc-str v m)))
      (if (null? r) (list (lit var) v) (rest r)))))

; EXITS: return/break/continue inside the body are GUARDED EXITS --
; (guard-cexpr . value-cexpr) in appearance order, the guard the
; conjunction of the path conditions above it ((num 1) = unconditional,
; and the rest of that sequence is dead).  `return E` exits with E;
; `break` exits with the function's R evaluated at the break-point
; map; `continue` exits with a SELF-CALL whose args come from the
; continue-point map with the for-step applied.  The lowered body is
; the exits as nested ifs ending in the ordinary self-call.  CTX is
; (ret-e step-node name).
(def %cc-st (fn (_ m locals assigned exits) (list m locals assigned exits)))
(def %cc-st-exits (fn (_ st) (first (rest (rest (rest st))))))

; the self-call as a cexpr, args from map M with the step applied
(def %cc-continue-call
  (fn (_ m locals ext ctx)
    (def step-node (first (rest ctx)))
    (def m2
      (if (null? step-node) m
        (first (%cc-fold-stmts
                 (list (list (lit expr) step-node))
                 (%cc-st m locals () ()) ext ctx))))
    (list (lit call) (first (rest (rest ctx)))
      (map (fn (_ v) (%cc-var-of v m2)) ext))))

(def %cc-fold-stmts
  (fn (self stmts st ext ctx)
    (if (null? stmts) st
      (let ((s (first stmts)))
        (def t (first s))
        (def m (first st))
        (def locals (first (rest st)))
        (def assigned (first (rest (rest st))))
        (def exits (%cc-st-exits st))
        (if (eq? t (lit block))
          (self (append (first (rest s)) (rest stmts)) st ext ctx)
        (if (eq? t (lit decl))
          (let ((name (first (rest s))))
            (def kind (first (rest (rest s))))
            (def init (first (rest (rest (rest s)))))
            (if (pair? kind) (%cc-no "array local in a loop body"))
            (self (rest stmts)
              (%cc-st (if (null? init) m
                        (%cc-put-str name (%cc-subst init m) m))
                (pair name locals) assigned exits)
              ext ctx))
        (if (eq? t (lit expr))
          (let ((a (%cc-expr-assign (first (rest s)))))
            (if (null? a) (%cc-no "loop body: a statement that is not an assignment")
              (if (not (if (%cc-member-str? (first a) ext) #t
                         (%cc-member-str? (first a) locals)))
                (%cc-no "loop assigns an unknown variable")
                (self (rest stmts)
                  (%cc-st (%cc-put-str (first a) (%cc-subst (rest a) m) m)
                    locals (pair (first a) assigned) exits)
                  ext ctx))))
        ; the three exits end their sequence: what follows is dead
        (if (eq? t (lit return))
          (if (null? (first (rest s))) (%cc-no "bare return in a loop")
            (%cc-st m locals assigned
              (append exits
                (list (pair (list (lit num) 1)
                        (%cc-subst (first (rest s)) m))))))
        (if (eq? t (lit break))
          (%cc-st m locals assigned
            (append exits
              (list (pair (list (lit num) 1)
                      (%cc-subst (first ctx) m)))))
        (if (eq? t (lit continue))
          (%cc-st m locals assigned
            (append exits
              (list (pair (list (lit num) 1)
                      (%cc-continue-call m locals ext ctx)))))
        (if (eq? t (lit if))
          (let ((c (%cc-subst (first (rest s)) m)))
            (def then-s (first (rest (rest s))))
            (def else-s (first (rest (rest (rest s)))))
            (def st-then
              (self (list then-s) (%cc-st m locals () ()) ext ctx))
            (def st-else
              (if (null? else-s) (%cc-st m locals () ())
                (self (list else-s) (%cc-st m locals () ()) ext ctx)))
            ; only variables that outlive the if get merged
            (def touched
              (filter (fn (_ v)
                        (if (%cc-member-str? v ext) #t
                          (%cc-member-str? v locals)))
                (append (first (rest (rest st-then)))
                  (first (rest (rest st-else))))))
            (def merge
              (fn (self2 vs mm)
                (if (null? vs) mm
                  (let ((v (first vs)))
                    (self2 (rest vs)
                      (%cc-put-str v
                        (list (lit ternary) c
                          (%cc-var-of v (first st-then))
                          (%cc-var-of v (first st-else)))
                        mm))))))
            ; a branch's exits take the branch condition as a guard;
            ; an unconditional exit's guard is just the condition
            (def guard-with
              (fn (_ g e)
                (if (eq? (first (first e)) (lit num))
                  (pair g (rest e))
                  (pair (list (lit and) g (first e)) (rest e)))))
            (def then-exits
              (map (fn (_ e) (guard-with c e)) (%cc-st-exits st-then)))
            (def else-exits
              (map (fn (_ e) (guard-with (list (lit un) "!" c) e))
                (%cc-st-exits st-else)))
            (self (rest stmts)
              (%cc-st (merge touched m) locals (append touched assigned)
                (append exits (append then-exits else-exits)))
              ext ctx))
          (%cc-no "loop body: only assignments, locals, if and exits lower"))))))))))))

; body-stmt to a statement list (a block flattens)
(def %cc-loop-body-stmts
  (fn (_ body-stmt)
    (if (eq? (first body-stmt) (lit block))
      (first (rest body-stmt))
      (list body-stmt))))

; the variable names a cexpr reads (dupes fine)
(def %cc-free-vars
  (fn (self node)
    (let ((t (first node)))
      (if (eq? t (lit var)) (list (first (rest node)))
      (if (eq? t (lit num)) ()
      (if (if (eq? t (lit bin)) #t (eq? t (lit cmp)))
        (append (self (first (rest (rest node))))
          (self (first (rest (rest (rest node))))))
      (if (eq? t (lit un)) (self (first (rest (rest node))))
      (if (if (eq? t (lit and)) #t (eq? t (lit or)))
        (append (self (first (rest node)))
          (self (first (rest (rest node)))))
      (if (eq? t (lit ternary))
        (append (self (first (rest node)))
          (append (self (first (rest (rest node))))
            (self (first (rest (rest (rest node)))))))
      (if (eq? t (lit call))
        (let ((go (fn (self2 as)
                    (if (null? as) ()
                      (append (self (first as)) (self2 (rest as)))))))
          (go (first (rest (rest node)))))
        (list "?")))))))))))

; a pre-loop guard: (if C (return E)) with no else, as (C . E), else nil
(def %cc-guard-of
  (fn (_ s)
    (if (not (eq? (first s) (lit if))) ()
      (let ((then-s (first (rest (rest s)))))
        (def else-s (first (rest (rest (rest s)))))
        (def ret
          (if (eq? (first then-s) (lit return)) then-s
            (if (if (eq? (first then-s) (lit block))
                  (if (pair? (first (rest then-s)))
                    (null? (rest (first (rest then-s)))) #f)
                  #f)
              (let ((inner (first (first (rest then-s)))))
                (if (eq? (first inner) (lit return)) inner ()))
              ())))
        (if (null? else-s)
          (if (null? ret) ()
            (if (null? (first (rest ret))) ()
              (pair (first (rest s)) (first (rest ret)))))
          ())))))

; split { decls*; guards*; (while|for); return R }
;   -> (decls guards loop return) or nil.  A guard is a pre-loop
;   `if (C) return E;` -- the lowerer checks it is loop-invariant.
(def %cc-loop-split
  (fn (_ stmts)
    (def go
      (fn (self ss decls guards)
        (if (null? ss) ()
          (let ((s (first ss)))
            (if (if (eq? (first s) (lit decl)) (null? guards) #f)
              (self (rest ss) (pair s decls) guards)
              (if (if (eq? (first s) (lit while)) #t
                    (eq? (first s) (lit for)))
                (if (if (pair? (rest ss))
                      (if (null? (rest (rest ss)))
                        (eq? (first (first (rest ss))) (lit return)) #f)
                      #f)
                  (list (reverse decls) (reverse guards) s
                    (first (rest ss)))
                  ())
                (let ((g (%cc-guard-of s)))
                  (if (null? g) ()
                    (self (rest ss) decls (pair g guards))))))))))
    (go stmts () ())))

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
    (if (null? split) (%cc-no "not a decls+guards+loop+return shape")
      (let ((decls (first split)))
        (def guards (first (rest split)))
        (def loop (first (rest (rest split))))
        (def ret (first (rest (rest (rest split)))))
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
        (def ext (append params accs))
        ; per-iteration updates: the body, then the for-step (wrapped
        ; as the statement it is), through one fold
        (def stmts
          (append (%cc-loop-body-stmts body-stmt)
            (if (null? step-node) ()
              (list (list (lit expr) step-node)))))
        (def ctx (list ret-e step-node name))
        (def st (%cc-fold-stmts stmts (%cc-st () () () ()) ext ctx))
        (def upd (first st))
        (def lcond (%cc-lower-e cond-node name ext))
        (def lret (%cc-lower-e ret-e name ext))
        ; every threadable variable -- params included -- takes its
        ; folded value into the self-call, or rides through unchanged
        (def plain-call
          (pair (convert name %symbol)
            (map (fn (_ v)
                   (let ((u (%cc-assoc-str v upd)))
                     (if (null? u) (convert v %symbol)
                       (%cc-lower-e (rest u) name ext))))
              ext)))
        ; the exits, last to first, wrap the plain self-call in ifs;
        ; an unconditional exit replaces everything after it
        (def wrap
          (fn (self2 es)
            (if (null? es) plain-call
              (let ((e (first es)))
                (if (eq? (first (first e)) (lit num))
                  (%cc-lower-e (rest e) name ext)
                  (list (lit if)
                    (%cc-lower-e (first e) name ext)
                    (%cc-lower-e (rest e) name ext)
                    (self2 (rest es))))))))
        (def self-call (wrap (%cc-st-exits st)))
        (def loop-expr (list (lit if) lcond self-call lret))
        ; pre-loop guards re-run on every self-call re-entry, so each
        ; must be LOOP-INVARIANT: it may read only parameters the body
        ; never assigns (an accumulator holds its init only on first
        ; entry).  Guards wrap the loop outermost-first.
        (def assigned (first (rest (rest st))))
        (def invariant?
          (fn (self2 vs)
            (if (null? vs) #t
              (if (if (%cc-member-str? (first vs) params)
                    (not (%cc-member-str? (first vs) assigned)) #f)
                (self2 (rest vs))
                #f))))
        (def guarded
          (fn (self2 gs)
            (if (null? gs) loop-expr
              (let ((g (first gs)))
                (if (not (invariant?
                           (append (%cc-free-vars (first g))
                             (%cc-free-vars (rest g)))))
                  (%cc-no "a pre-loop guard is not loop-invariant")
                  (list (lit if)
                    (%cc-lower-e (first g) name ext)
                    (%cc-lower-e (rest g) name ext)
                    (self2 (rest gs))))))))
        (pair
          (pair (lit fn)
            (pair (pair (convert name %symbol)
                    (map (fn (_ v) (convert v %symbol)) ext))
              (list (guarded guards))))
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
