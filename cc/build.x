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
;      variable merges as a ternary), EXITS -- return/break/continue
;      as guarded exits, plus loop-invariant pre-loop `if (C) return
;      E;` guards -- and INITS over the parameters: decl inits,
;      pre-loop assignments and the for-INIT fold in order, and a
;      non-literal init pads as its own lane function over the params
;      applied at the call boundary -- NESTED LOOPS, two deep, as a
;      state machine over the one self-call (see the nested section
;      in %cc-lower-loop) -- and POINTERS: the program's memory is one
;      raw buffer both sides address, so a pointer is a cell index on
;      both and arrays cross the boundary; in a body, reads become
;      load temps and stores become effects, emitted in program order
;      before the tail (%cc-extract, %cc-effects-do); a top-level
;      local array takes scratch cells and its name substitutes away.
;      params+accs <= 4.
; Stores with early exits, reads under a short circuit, two sequential
; top-level loops, three-deep loops, a fifth threaded variable, inits
; that call, globals and cross-calls stay interpreted -- recorded
; pendings.
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
                (if (string=? op "*")
                  (list (lit %mem-ref-at) %cc-membase v)
                  (%cc-no "address-of stays interpreted"))))))
      (if (eq? t (lit ternary))
        (list (lit if)
          (self (first (rest node)) fname params)
          (self (first (rest (rest node))) fname params)
          (self (first (rest (rest (rest node)))) fname params))
      ; memory: a load temp, an indexed read -- words in the shared
      ; buffer, its data address baked in as a literal
      (if (eq? t (lit mt))
        (list (lit %mem-ref-at) %cc-membase (first (rest node)))
      (if (eq? t (lit idx))
        (list (lit %mem-ref-at) %cc-membase
          (list (lit +) (self (first (rest node)) fname params)
            (self (first (rest (rest node))) fname params)))
      (if (eq? t (lit call))
        (let ((callee (first (rest node))))
          (def args (first (rest (rest node))))
          (if (not (string=? callee fname))
            (%cc-no "only self-calls lower")
            (if (> (length args) 4)
              (%cc-no "the lane takes at most 4 args")
              (pair (convert fname %symbol)
                (map (fn (_ a) (self a fname params)) args)))))
        (%cc-no "form stays interpreted")))))))))))))))

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
      ; memory forms: a subscript's base and index, an assignment's
      ; target and value, an increment's target -- a local array's
      ; name lives inside these
      (if (eq? t (lit idx))
        (list (lit idx) (self (first (rest node)) sub)
          (self (first (rest (rest node))) sub))
      (if (eq? t (lit assign))
        (list (lit assign) (self (first (rest node)) sub)
          (self (first (rest (rest node))) sub))
      (if (if (eq? t (lit postinc)) #t
            (if (eq? t (lit preinc)) #t
              (if (eq? t (lit postdec)) #t (eq? t (lit predec)))))
        (list t (self (first (rest node)) sub))
        node))))))))))))))

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
; EFFECTS: memory is the one thing substitution cannot model, so the
; fold carries an ORDERED effects list beside the map.  A memory read
; inside an expression is pulled out at its evaluation point into a
; (load K ADDR) effect -- K a temp cell in the native scratch region --
; and the expression reads (mt K) instead; a store to memory is a
; (store ADDR VALUE) effect; an if whose branches have effects yields
; one (cond C THEN-EFFECTS ELSE-EFFECTS) item.  Emitted in order as a
; `do` before the tail, every read sees exactly the stores that C's
; program order puts before it (the bubble-sort swap included).
; Reads under a short circuit would hoist past their guard, so they
; refuse; a body with both effects and exits refuses at the lowerer.
(def %cc-st
  (fn (_ m locals assigned exits effects)
    (list m locals assigned exits effects)))
(def %cc-st-exits (fn (_ st) (first (rest (rest (rest st))))))
(def %cc-st-effects (fn (_ st) (first (rest (rest (rest (rest st)))))))

; the native scratch region: local arrays and load temps, allocated
; per build from the cells above the program's memory
(def %cc-scratch-next 0)
(def %cc-new-cells
  (fn (_ n)
    (def k %cc-scratch-next)
    (set! %cc-scratch-next (+ k n))
    (if (> %cc-scratch-next (+ %cc-memsize %cc-scratch-cells))
      (%cc-no "native scratch exhausted")
      k)))

(def %cc-has-load?
  (fn (self node)
    (let ((t (first node)))
      (if (eq? t (lit idx)) #t
        (if (if (eq? t (lit un)) (string=? (first (rest node)) "*") #f) #t
          (if (if (eq? t (lit var)) #t (if (eq? t (lit num)) #t (eq? t (lit mt))))
            #f
            (if (eq? t (lit call))
              (let ((go (fn (self2 as)
                          (if (null? as) #f
                            (if (self (first as)) #t (self2 (rest as)))))))
                (go (first (rest (rest node)))))
              ; bin cmp un and or ternary: any child
              (let ((go (fn (self2 kids)
                          (if (null? kids) #f
                            (if (if (pair? (first kids)) (self (first kids)) #f)
                              #t (self2 (rest kids)))))))
                (go (rest node))))))))))

; pull memory reads out of a cexpr in evaluation order; answers
; (node' . effects') with the loads APPENDED.  Addresses substitute
; the current map here, so they read this point's values.
(def %cc-extract
  (fn (self node m effs)
    (let ((t (first node)))
      (if (eq? t (lit idx))
        (let ((r1 (self (first (rest node)) m effs)))
          (def r2 (self (first (rest (rest node))) m (rest r1)))
          (def k (%cc-new-cells 1))
          (pair (list (lit mt) k)
            (append (rest r2)
              (list (list (lit load) k
                      (%cc-subst (list (lit bin) "+" (first r1) (first r2)) m))))))
      (if (if (eq? t (lit un)) (string=? (first (rest node)) "*") #f)
        (let ((r1 (self (first (rest (rest node))) m effs)))
          (def k (%cc-new-cells 1))
          (pair (list (lit mt) k)
            (append (rest r1)
              (list (list (lit load) k (%cc-subst (first r1) m))))))
      (if (if (eq? t (lit un)) (string=? (first (rest node)) "&") #f)
        (%cc-no "address-of stays interpreted")
      (if (if (eq? t (lit bin)) #t (eq? t (lit cmp)))
        (let ((r1 (self (first (rest (rest node))) m effs)))
          (def r2 (self (first (rest (rest (rest node)))) m (rest r1)))
          (pair (list t (first (rest node)) (first r1) (first r2)) (rest r2)))
      (if (eq? t (lit un))
        (let ((r1 (self (first (rest (rest node))) m effs)))
          (pair (list (lit un) (first (rest node)) (first r1)) (rest r1)))
      (if (if (eq? t (lit and)) #t (if (eq? t (lit or)) #t (eq? t (lit ternary))))
        (if (%cc-has-load? node)
          (%cc-no "a memory read under a short circuit")
          (pair node effs))
      (if (eq? t (lit call))
        (let ((go (fn (self2 as effs2 acc)
                    (if (null? as) (pair (reverse acc) effs2)
                      (let ((r (self (first as) m effs2)))
                        (self2 (rest as) (rest r) (pair (first r) acc)))))))
          (let ((r (go (first (rest (rest node))) effs ())))
            (pair (list (lit call) (first (rest node)) (first r)) (rest r))))
        (pair node effs)))))))))))

; the address a memory lvalue names, with its own reads extracted
(def %cc-lval-addr
  (fn (_ lv m effs)
    (if (eq? (first lv) (lit idx))
      (let ((r1 (%cc-extract (first (rest lv)) m effs)))
        (def r2 (%cc-extract (first (rest (rest lv))) m (rest r1)))
        (pair (%cc-subst (list (lit bin) "+" (first r1) (first r2)) m)
          (rest r2)))
      (if (if (eq? (first lv) (lit un)) (string=? (first (rest lv)) "*") #f)
        (let ((r1 (%cc-extract (first (rest (rest lv))) m effs)))
          (pair (%cc-subst (first r1) m) (rest r1)))
        (%cc-no "not a memory lvalue")))))

; the self-call as a cexpr, args from map M with the step applied
(def %cc-continue-call
  (fn (_ m locals ext ctx)
    (def step-node (first (rest ctx)))
    (def st2
      (if (null? step-node) (%cc-st m locals () () ())
        (%cc-fold-stmts
          (list (list (lit expr) step-node))
          (%cc-st m locals () () ()) ext ctx)))
    (if (not (null? (%cc-st-effects st2)))
      (%cc-no "continue past a step that stores"))
    (list (lit call) (first (rest (rest ctx)))
      (map (fn (_ v) (%cc-var-of v (first st2))) ext))))

(def %cc-fold-stmts
  (fn (self stmts st ext ctx)
    (if (null? stmts) st
      (let ((s (first stmts)))
        (def t (first s))
        (def m (first st))
        (def locals (first (rest st)))
        (def assigned (first (rest (rest st))))
        (def exits (%cc-st-exits st))
        (def effs (%cc-st-effects st))
        (if (eq? t (lit block))
          (self (append (first (rest s)) (rest stmts)) st ext ctx)
        (if (eq? t (lit decl))
          (let ((name (first (rest s))))
            (def kind (first (rest (rest s))))
            (def init (first (rest (rest (rest s)))))
            (if (pair? kind) (%cc-no "array local in a loop body"))
            (def r (if (null? init) (pair () effs) (%cc-extract init m effs)))
            (self (rest stmts)
              (%cc-st (if (null? init) m
                        (%cc-put-str name (%cc-subst (first r) m) m))
                (pair name locals) assigned exits (rest r))
              ext ctx))
        (if (eq? t (lit expr))
          (let ((e (first (rest s))))
            (if (if (eq? (first e) (lit assign))
                  (not (eq? (first (first (rest e))) (lit var))) #f)
              ; a store: the value's reads, the address's reads, then it
              (let ((rv (%cc-extract (first (rest (rest e))) m effs)))
                (def ra (%cc-lval-addr (first (rest e)) m (rest rv)))
                (self (rest stmts)
                  (%cc-st m locals assigned exits
                    (append (rest ra)
                      (list (list (lit store) (first ra)
                              (%cc-subst (first rv) m)))))
                  ext ctx))
              (let ((a (%cc-expr-assign e)))
                (if (null? a) (%cc-no "loop body: a statement that is not an assignment")
                  (if (not (if (%cc-member-str? (first a) ext) #t
                             (%cc-member-str? (first a) locals)))
                    (%cc-no "loop assigns an unknown variable")
                    (let ((r (%cc-extract (rest a) m effs)))
                      (self (rest stmts)
                        (%cc-st (%cc-put-str (first a) (%cc-subst (first r) m) m)
                          locals (pair (first a) assigned) exits (rest r))
                        ext ctx)))))))
        ; the three exits end their sequence: what follows is dead
        (if (eq? t (lit return))
          (if (null? (first (rest s))) (%cc-no "bare return in a loop")
            (let ((r (%cc-extract (first (rest s)) m effs)))
              (%cc-st m locals assigned
                (append exits
                  (list (pair (list (lit num) 1) (%cc-subst (first r) m))))
                (rest r))))
        (if (eq? t (lit break))
          (if (null? (first ctx)) (%cc-no "break into a transition that stores")
            (%cc-st m locals assigned
              (append exits
                (list (pair (list (lit num) 1) (%cc-subst (first ctx) m))))
              effs))
        (if (eq? t (lit continue))
          (%cc-st m locals assigned
            (append exits
              (list (pair (list (lit num) 1)
                      (%cc-continue-call m locals ext ctx))))
            effs)
        (if (eq? t (lit if))
          (let ((rc (%cc-extract (first (rest s)) m effs)))
            (def c (%cc-subst (first rc) m))
            (def then-s (first (rest (rest s))))
            (def else-s (first (rest (rest (rest s)))))
            (def st-then
              (self (list then-s) (%cc-st m locals () () ()) ext ctx))
            (def st-else
              (if (null? else-s) (%cc-st m locals () () ())
                (self (list else-s) (%cc-st m locals () () ()) ext ctx)))
            (def branch-effs
              (if (if (null? (%cc-st-effects st-then))
                    (null? (%cc-st-effects st-else)) #f)
                ()
                (list (list (lit cond) c
                        (%cc-st-effects st-then)
                        (%cc-st-effects st-else)))))
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
                (append exits (append then-exits else-exits))
                (append (rest rc) branch-effs))
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
      (if (eq? t (lit idx))
        (append (self (first (rest node)))
          (self (first (rest (rest node)))))
      (if (eq? t (lit mt)) ()
      (if (eq? t (lit call))
        (let ((go (fn (self2 as)
                    (if (null? as) ()
                      (append (self (first as)) (self2 (rest as)))))))
          (go (first (rest (rest node)))))
        (list "?")))))))))))))

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

; split { decls*; pre*; (while|for); return R }
;   -> (decls pre loop return) or nil.  PRE is the statements between
;   the decls and the loop, in order, each (guard C . E) for a pre-loop
;   `if (C) return E;` or (init NAME . E) for a pre-loop assignment --
;   the lowerer checks guards are loop-invariant and inits target
;   accumulators.
(def %cc-loop-split
  (fn (_ stmts)
    (def go
      (fn (self ss decls pre)
        (if (null? ss) ()
          (let ((s (first ss)))
            (if (if (eq? (first s) (lit decl)) (null? pre) #f)
              (self (rest ss) (pair s decls) pre)
              (if (if (eq? (first s) (lit while)) #t
                    (eq? (first s) (lit for)))
                (if (if (pair? (rest ss))
                      (if (null? (rest (rest ss)))
                        (eq? (first (first (rest ss))) (lit return)) #f)
                      #f)
                  (list (reverse decls) (reverse pre) s
                    (first (rest ss)))
                  ())
                (let ((g (%cc-guard-of s)))
                  (if (not (null? g))
                    (self (rest ss) decls (pair (pair (lit guard) g) pre))
                    (let ((a (%cc-stmt-assign s)))
                      (if (null? a) ()
                        (self (rest ss) decls
                          (pair (pair (lit init) a) pre))))))))))))
    (go stmts () ())))

; set accs[name]'s init in the parallel inits list
(def %cc-set-init
  (fn (self inits accs name v)
    (if (null? accs) inits
      (if (string=? (first accs) name)
        (pair v (rest inits))
        (pair (first inits)
          (self (rest inits) (rest accs) name v))))))

; substitute through STATEMENTS (local arrays become literal bases)
(def %cc-subst-stmts ())
(def %cc-subst-stmt
  (fn (self s sub)
    (def sub-e (fn (_ e) (if (null? e) () (%cc-subst e sub))))
    (let ((t (first s)))
      (if (eq? t (lit expr)) (list (lit expr) (sub-e (first (rest s))))
      (if (eq? t (lit return)) (list (lit return) (sub-e (first (rest s))))
      (if (eq? t (lit block))
        (list (lit block) (%cc-subst-stmts (first (rest s)) sub))
      (if (eq? t (lit if))
        (list (lit if) (sub-e (first (rest s)))
          (self (first (rest (rest s))) sub)
          (if (null? (first (rest (rest (rest s))))) ()
            (self (first (rest (rest (rest s)))) sub)))
      (if (eq? t (lit while))
        (list (lit while) (sub-e (first (rest s)))
          (self (first (rest (rest s))) sub))
      (if (eq? t (lit for))
        (list (lit for) (sub-e (first (rest s)))
          (sub-e (first (rest (rest s))))
          (sub-e (first (rest (rest (rest s)))))
          (self (first (rest (rest (rest (rest s))))) sub))
      (if (eq? t (lit decl))
        (list (lit decl) (first (rest s)) (first (rest (rest s)))
          (sub-e (first (rest (rest (rest s))))))
        s))))))))))
(set! %cc-subst-stmts
  (fn (_ ss sub) (map (fn (_ s) (%cc-subst-stmt s sub)) ss)))

; effects to lane forms: a load fills its temp from the address, a
; store writes, a cond runs one arm's effects (0 when an arm is empty)
(def %cc-effects-do ())
(def %cc-lower-eff
  (fn (_ e name ext)
    (let ((t (first e)))
      (if (eq? t (lit load))
        (list (lit %mem-set-at!) %cc-membase (first (rest e))
          (list (lit %mem-ref-at) %cc-membase
            (%cc-lower-e (first (rest (rest e))) name ext)))
        (if (eq? t (lit store))
          (list (lit %mem-set-at!) %cc-membase
            (%cc-lower-e (first (rest e)) name ext)
            (%cc-lower-e (first (rest (rest e))) name ext))
          (list (lit if) (%cc-lower-e (first (rest e)) name ext)
            (%cc-effects-do (first (rest (rest e))) name ext 0)
            (%cc-effects-do (first (rest (rest (rest e)))) name ext 0)))))))
(set! %cc-effects-do
  (fn (_ effs name ext tail)
    (if (null? effs) tail
      (pair (lit do)
        (append (map (fn (_ e) (%cc-lower-eff e name ext)) effs)
          (list tail))))))

; the loop lowerer: (fn-expr . pad-inits), or a refusal
(def %cc-lower-loop
  (fn (_ name params body)
    ; local ARRAYS: cells in the native scratch region, their names
    ; substituted away as literal bases before anything else looks
    (def stmts0 (first (rest body)))
    (def array-decl?
      (fn (_ st1)
        (if (eq? (first st1) (lit decl)) (pair? (first (rest (rest st1)))) #f)))
    ; a struct-kinded or struct-element local stays interpreted
    (def check-kinds
      (fn (self ss)
        (if (null? ss) ()
          (let ((st1 (first ss)))
            (if (if (eq? (first st1) (lit decl)) (pair? (first (rest (rest st1)))) #f)
              (let ((k (first (rest (rest st1)))))
                (if (if (eq? (first k) (lit array)) (null? (rest (rest k))) #f)
                  (self (rest ss))
                  (%cc-no "struct kinds stay interpreted")))
              (self (rest ss)))))))
    (check-kinds stmts0)
    (def arr-sub
      (map (fn (_ d)
             ; the array's name substitutes away and its decl is dropped,
             ; so an initializer would be lost: refuse, stay interpreted
             (if (not (null? (first (rest (rest (rest d))))))
               (%cc-no "an initialized local array stays interpreted"))
             (pair (first (rest d))
               (list (lit num)
                 (%cc-new-cells (first (rest (first (rest (rest d)))))))))
        (filter array-decl? stmts0)))
    (def stmts1
      (%cc-subst-stmts (filter (fn (_ st1) (not (array-decl? st1))) stmts0)
        arr-sub))
    (def split (%cc-loop-split stmts1))
    (if (null? split) (%cc-no "not a decls+guards+loop+return shape")
      (let ((decls (first split)))
        (def pre (first (rest split)))
        (def guards
          (map (fn (_ p) (rest p))
            (filter (fn (_ p) (eq? (first p) (lit guard))) pre)))
        (def pre-inits
          (map (fn (_ p) (rest p))
            (filter (fn (_ p) (eq? (first p) (lit init))) pre)))
        (def loop (first (rest (rest split))))
        (def ret (first (rest (rest (rest split)))))
        (def ret-e (first (rest ret)))
        (if (null? ret-e) (%cc-no "loop fn has a bare return"))
        (def accs (map (fn (_ d) (first (rest d))) decls))
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
        ; THE INITS: decl inits, pre-loop assignments and the for-INIT
        ; fold in order into a map over the PARAMETERS (each later init
        ; substitutes the earlier ones away), so every accumulator's
        ; entry value is an expression over params alone.  A literal
        ; pads as an int; anything else pads as its own tiny lane
        ; function over the params, applied to the args at the call
        ; boundary -- once, at entry, native.
        (def set-init
          (fn (_ a imap)
            (if (not (%cc-member-str? (first a) accs))
              (%cc-no "a pre-loop assignment to a non-accumulator")
              (%cc-put-str (first a) (%cc-subst (rest a) imap) imap))))
        (def imap0
          (let ((go (fn (self2 ds imap)
                      (if (null? ds) imap
                        (let ((d (first ds)))
                          (def iv (first (rest (rest (rest d)))))
                          (self2 (rest ds)
                            (%cc-put-str (first (rest d))
                              (if (null? iv) (list (lit num) 0)
                                (%cc-subst iv imap))
                              imap)))))))
            (go decls ())))
        (def imap1
          (let ((go (fn (self2 as imap)
                      (if (null? as) imap
                        (self2 (rest as) (set-init (first as) imap))))))
            (go pre-inits imap0)))
        (def imap
          (if (null? init-node) imap1
            (let ((ia (%cc-expr-assign init-node)))
              (if (null? ia) (%cc-no "for init not a simple assignment")
                (set-init ia imap1)))))
        (def param-only?
          (fn (self2 vs)
            (if (null? vs) #t
              (if (%cc-member-str? (first vs) params)
                (self2 (rest vs)) #f))))
        (def ext (append params accs))
        (def lcond (%cc-lower-e cond-node name ext))
        (def lret (%cc-lower-e ret-e name ext))
        (def body-stmts (%cc-loop-body-stmts body-stmt))
        ; a self-call cexpr from map M: every threadable variable takes
        ; its folded value, or rides through unchanged
        (def call-from
          (fn (_ m)
            (list (lit call) name (map (fn (_ v) (%cc-var-of v m)) ext))))
        ; the exits, last to first, wrap a plain self-call in ifs; an
        ; unconditional exit replaces everything after it
        (def wrap-with
          (fn (self2 plain es)
            (if (null? es) plain
              (let ((e (first es)))
                (if (eq? (first (first e)) (lit num))
                  (%cc-lower-e (rest e) name ext)
                  (list (lit if)
                    (%cc-lower-e (first e) name ext)
                    (%cc-lower-e (rest e) name ext)
                    (self2 plain (rest es))))))))
        ; --- NESTED LOOPS: a state machine over the one self-call ----
        ; The outer body splits at its first top-level loop into PRE,
        ; the inner loop, and POST.  Each re-entry runs one step of
        ; whichever loop is active:
        ;   (if I-cond (if J-cond INNER-STEP TRANSITION) R)
        ; INNER-STEP folds the inner body + J-step; TRANSITION folds
        ; POST + I-step + (if I-cond' { PRE; J-init }) -- guarded, so
        ; PRE and J-init never leak into R on the last exit.  The same
        ; guarded reset, folded onto the init map, gives the entry
        ; pads (J-init may read i).  An inner `break` is the transition
        ; call and an inner `continue` the inner self-call: folding
        ; from a map equals folding from identity then substituting,
        ; so the transition is a STATIC cexpr the fold's break already
        ; substitutes.  Two levels deep; a third refuses in the fold.
        (def split-inner
          (fn (self2 ss pre)
            (if (null? ss) ()
              (if (if (eq? (first (first ss)) (lit for)) #t
                    (eq? (first (first ss)) (lit while)))
                (list (reverse pre) (first ss) (rest ss))
                (self2 (rest ss) (pair (first ss) pre))))))
        (def nest (split-inner body-stmts ()))
        (def no-exits!
          (fn (_ st2 what)
            (if (null? (%cc-st-exits st2)) st2
              (%cc-no (string-append what " may not exit")))))
        (def no-effects!
          (fn (_ st2 what)
            (if (null? (%cc-st-effects st2)) st2
              (%cc-no (string-append what " may not store")))))
        ; a body's effects run in a `do` before its tail; a body that
        ; both stores and exits early is the recorded refusal
        (def with-effects
          (fn (_ effs exits tail)
            (if (if (pair? effs) (pair? exits) #f)
              (%cc-no "stores with early exits")
              (%cc-effects-do effs name ext tail))))
        (def outer-step-stmts
          (if (null? step-node) () (list (list (lit expr) step-node))))
        ; the two paths meet at (upd . st): the outer-level fold state
        ; that shapes the self-call, plus imap-final and body-expr
        (def nested
          (if (null? nest) ()
            (let ((pre-stmts (first nest)))
              (def inner (first (rest nest)))
              (def post-stmts (first (rest (rest nest))))
              (def j-for (eq? (first inner) (lit for)))
              (def j-init (if j-for (first (rest inner)) ()))
              (def j-cond (if j-for (first (rest (rest inner)))
                            (first (rest inner))))
              (def j-step (if j-for (first (rest (rest (rest inner)))) ()))
              (def j-body (%cc-loop-body-stmts
                            (if j-for
                              (first (rest (rest (rest (rest inner)))))
                              (first (rest (rest inner))))))
              (if (null? j-cond) (%cc-no "inner loop needs a condition"))
              ; the guarded reset: (if I-cond (block PRE... J-init))
              (def reset-stmts
                (append pre-stmts
                  (if (null? j-init) ()
                    (list (list (lit expr) j-init)))))
              (def reset
                (if (null? reset-stmts) ()
                  (list (list (lit if) cond-node
                          (list (lit block) reset-stmts) ()))))
              ; the transition from identity, as a static cexpr
              (def st-t
                (no-exits!
                  (%cc-fold-stmts (append post-stmts
                                    (append outer-step-stmts reset))
                    (%cc-st () () () () ()) ext (list ret-e step-node name))
                  "the outer body around the inner loop"))
              (def transition (call-from (first st-t)))
              (def t-effs (%cc-st-effects st-t))
              ; the inner step, its break aimed at the transition -- unless
              ; the transition stores, which a static break target cannot
              (def st-in
                (%cc-fold-stmts
                  (append j-body
                    (if (null? j-step) () (list (list (lit expr) j-step))))
                  (%cc-st () () () () ()) ext
                  (list (if (null? t-effs) transition ()) j-step name)))
              (def inner-expr
                (with-effects (%cc-st-effects st-in) (%cc-st-exits st-in)
                  (wrap-with (%cc-lower-e (call-from (first st-in)) name ext)
                    (%cc-st-exits st-in))))
              ; entry pads: the reset folded onto the init map, pure
              (def imap-final
                (first (no-effects!
                         (no-exits!
                           (%cc-fold-stmts reset (%cc-st imap () () () ())
                             ext (list ret-e step-node name))
                           "the reset")
                         "the reset")))
              (list imap-final
                (list (lit if) lcond
                  (list (lit if) (%cc-lower-e j-cond name ext)
                    inner-expr
                    (%cc-effects-do t-effs name ext
                      (%cc-lower-e transition name ext)))
                  lret)
                (append (first (rest (rest st-in)))
                  (first (rest (rest st-t))))))))
        ; --- the single-loop path ------------------------------------
        (def st
          (if (null? nested)
            (%cc-fold-stmts (append body-stmts outer-step-stmts)
              (%cc-st () () () () ()) ext (list ret-e step-node name))
            ()))
        (def imap-final (if (null? nested) imap (first nested)))
        (def loop-expr
          (if (null? nested)
            (list (lit if) lcond
              (with-effects (%cc-st-effects st) (%cc-st-exits st)
                (wrap-with (%cc-lower-e (call-from (first st)) name ext)
                  (%cc-st-exits st)))
              lret)
            (first (rest nested))))
        (def inits
          (map (fn (_ a)
                 (let ((e (%cc-var-of a imap-final)))
                   ; NOT `lit` -- a def in a called body binds globally
                   ; and `lit` is the quote operative
                   (def litv (%cc-int-lit e))
                   (if (not (null? litv)) litv
                     (if (not (param-only? (%cc-free-vars e)))
                       (%cc-no "an init reads a non-parameter")
                       ; fname "" so any call inside refuses
                       (list (lit fn)
                         (pair (lit %cc-init)
                           (map (fn (_ p) (convert p %symbol)) params))
                         (%cc-lower-e e "" params))))))
            accs))
        ; pre-loop guards re-run on every self-call re-entry, so each
        ; must be LOOP-INVARIANT: it may read only parameters the body
        ; never assigns (an accumulator holds its init only on first
        ; entry).  Guards wrap the loop outermost-first.
        (def assigned
          (if (null? nested) (first (rest (rest st)))
            (first (rest (rest nested)))))
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
    (set! %cc-scratch-next %cc-memsize)
    (def go
      (fn (self fs acc)
        (if (null? fs) (reverse acc)
          (let ((name (first (first fs))))
            (def params (first (rest (first fs))))
            (def body (first (rest (rest (first fs)))))
            (def verdict
              (guard (e (lit interpreted))
                (let ((lowered (%cc-lower-fun name params body)))
                  (def prim (compile-asm (first lowered)))
                  ; the table entry is (name pad . prim); each pad slot
                  ; is an accumulator's literal init, or its init
                  ; expression compiled to a lane function over the
                  ; params (applied at the call boundary); () for a
                  ; plain function
                  (def pad
                    (map (fn (_ p) (if (number? p) p (compile-asm p)))
                      (rest lowered)))
                  (set! %cc-natives
                    (pair (pair name (pair pad prim)) %cc-natives))
                  (lit native))))
            (self (rest fs) (pair (pair name verdict) acc))))))
    ; %cc-funs cons-loads, so program order is its reverse
    (go (reverse %cc-funs) ())))

; build: the shared core with the lane switched on -- lower what
; lowers, report each verdict, run main
(def cc-build-run
  (fn (_ src) (%cc-run-core src #t)))
