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
; literals, + - * / % & | ^ << >> comparisons && || ! ~ the ternary,
; and calls to ITSELF (self-recursion rides the fn's first-param name,
; x-lang#583's slot-0 convention).
;
; THE LANE'S ONE ARITY RULE, measured rather than assumed: a lane
; function may take ANY number of parameters, but a SELF-CALL takes at
; most four -- and it must pass every parameter the function has, or
; the callee binds garbage and segfaults.  So a non-recursive function
; has no limit, while anything riding a self-call (every loop) fits
; four threaded variables, the rest spilling to cells.  Two body
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
;      A body that both stores and exits lowers as the ordered STREAM,
;      each exit tested in its place among the stores (%cc-stream-do).
;      SEQUENTIAL LOOPS run as phases of the one self-call: a phase
;      counter rides as one more threaded variable and each loop's
;      exit is the transition call into the next.  NESTING is any
;      depth (the state machine is recursive).  Threaded variables
;      past the lane's four arguments SPILL to scratch cells, read
;      and written as memory, their entry values stored by one
;      compiled entry function at the call boundary.  Reads under a
;      short circuit run under a cond effect on the guard.
;   3. CROSS-CALLS inline: a non-recursive callee of the if/return
;      shape lowers with its own parameters, which then substitute to
;      the lowered arguments (%cc-inline); in a loop body a cross-call
;      evaluates at its program point through a temp, so its reads
;      order against the stores.
;   3b. STRAIGHT-LINE bodies -- assignments then a return -- take the
;      same fold with no self-call at all (%cc-lower-straight).
;   4. GLOBALS are memory at a known address (%cc-globals-subst): a
;      scalar reads and writes as *(ADDR), an array is its base.
; What stays interpreted, each a recorded pending: a RECURSIVE
; function of more than four parameters (its self-call cannot pass
; them), callees with loops or recursion (a lane function calls only
; itself, so a callee must inline), calls through pointers, and struct
; kinds.
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
            (%cc-no (string-append "free variable: " n))))
      (if (eq? t (lit bin))
        (let ((op (first (rest node))))
          (def a (self (first (rest (rest node))) fname params))
          (def b (self (first (rest (rest (rest node)))) fname params))
          (if (string=? op "+") (list (lit +) a b)
            (if (string=? op "-") (list (lit -) a b)
              (if (string=? op "*") (list (lit *) a b)
                (if (string=? op "/") (list (lit /) a b)
                  (if (string=? op "%") (list (lit %) a b)
                    (if (string=? op "&") (list (lit &) a b)
                      (if (string=? op "|") (list (lit |) a b)
                        (if (string=? op "^") (list (lit ^) a b)
                          (if (string=? op "<<") (list (lit <<) a b)
                            (if (string=? op ">>") (list (lit >>) a b)
                              (%cc-no "unknown operator"))))))))))))
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
            ; another function: inline its lowered body
            (%cc-inline callee (map (fn (_ a) (self a fname params)) args))
            (if (> (length args) 4)
              (%cc-no "the lane takes at most 4 args")
              (pair (convert fname %symbol)
                (map (fn (_ a) (self a fname params)) args)))))
        (%cc-no "form stays interpreted")))))))))))))))

; --- cross-calls: inlining ---------------------------------------------------
; The lane calls only the function it is compiling, so a call to
; ANOTHER function inlines: a callee of the if/return shape lowers
; with its own parameters as the variables, then each parameter symbol
; substitutes to the lowered argument -- all at once, so a callee
; parameter named like one of the caller's cannot capture.  Mutual
; recursion is caught by the inline stack (the function being lowered
; is on it from the start); a self-recursive callee by its lowered
; body mentioning its own name.  A callee with a loop refuses in
; %cc-lower-body, as does one with struct kinds here.
(def %cc-inline-stack ())
(def %cc-fold-name "")     ; the function a loop fold is lowering

(def %cc-lane-subst
  (fn (self form al)
    (if (pair? form) (map (fn (_ x) (self x al)) form)
      (if (symbol? form)
        (let ((go (fn (self2 es)
                    (if (null? es) form
                      (if (eq? (first (first es)) form) (rest (first es))
                        (self2 (rest es)))))))
          (go al))
        form))))

(def %cc-lane-mentions?
  (fn (self form sym)
    (if (pair? form)
      (let ((go (fn (self2 xs)
                  (if (null? xs) #f
                    (if (self (first xs) sym) #t (self2 (rest xs)))))))
        (go form))
      (eq? form sym))))

(def %cc-lower-body ())

(def %cc-inline
  (fn (_ callee largs)
    (def f (%cc-fun callee))
    (if (null? f) (%cc-no "a call to no lowerable function")
      (if (%cc-member-str? callee %cc-inline-stack)
        (%cc-no "a recursive callee does not inline")
        (let ((cparams (first f)))
          (def kinds (first (rest (rest f))))
          (def ret (let ((r (rest (rest (rest f))))) (if (null? r) (lit scalar) (first r))))
          (if (not (= (length cparams) (length largs)))
            (%cc-no "a call with the wrong arity"))
          (if (if (pair? ret) #t (not (null? (filter pair? kinds))))
            (%cc-no "struct kinds stay interpreted"))
          (%cc-check-names callee cparams)
          (set! %cc-inline-stack (pair callee %cc-inline-stack))
          (def lowered
            (%cc-lower-body
              (%cc-globals-subst (first (rest (first (rest f)))) cparams)
              callee cparams))
          (set! %cc-inline-stack (rest %cc-inline-stack))
          (if (%cc-lane-mentions? lowered (convert callee %symbol))
            (%cc-no "a recursive callee does not inline"))
          (%cc-lane-subst lowered
            (let ((go (fn (self2 ps as)
                        (if (null? ps) ()
                          (pair (pair (convert (first ps) %symbol) (first as))
                            (self2 (rest ps) (rest as)))))))
              (go cparams largs))))))))

; a statement list where every path returns, as one expression
(set! %cc-lower-body
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
              ; a cross-call evaluates at its point, like a read
              (if (not (string=? (first (rest node)) %cc-fold-name)) #t
                (let ((go (fn (self2 as)
                            (if (null? as) #f
                              (if (self (first as)) #t (self2 (rest as)))))))
                  (go (first (rest (rest node))))))
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
      ; a short circuit: the guarded operand's reads (and cross-calls)
      ; run only under the guard -- a cond effect on the substituted
      ; guard, so a read the C never reaches never happens
      (if (if (eq? t (lit and)) #t (eq? t (lit or)))
        (let ((r1 (self (first (rest node)) m effs)))
          (def r2 (self (first (rest (rest node))) m ()))
          (def g (%cc-subst (first r1) m))
          (pair (list t (first r1) (first r2))
            (append (rest r1)
              (if (null? (rest r2)) ()
                (list (list (lit cond)
                        (if (eq? t (lit and)) g (list (lit un) "!" g))
                        (rest r2) ()))))))
      (if (eq? t (lit ternary))
        (let ((rc (self (first (rest node)) m effs)))
          (def ra (self (first (rest (rest node))) m ()))
          (def rb (self (first (rest (rest (rest node)))) m ()))
          (pair (list (lit ternary) (first rc) (first ra) (first rb))
            (append (rest rc)
              (if (if (null? (rest ra)) (null? (rest rb)) #f) ()
                (list (list (lit cond) (%cc-subst (first rc) m) (rest ra) (rest rb)))))))
      (if (eq? t (lit call))
        (let ((go (fn (self2 as effs2 acc)
                    (if (null? as) (pair (reverse acc) effs2)
                      (let ((r (self (first as) m effs2)))
                        (self2 (rest as) (rest r) (pair (first r) acc)))))))
          (let ((r (go (first (rest (rest node))) effs ())))
            (if (string=? (first (rest node)) %cc-fold-name)
              (pair (list (lit call) (first (rest node)) (first r)) (rest r))
              ; a cross-call: computed at its program point into a temp
              ; (calc K CALL), the expression reading (mt K)
              (let ((k (%cc-new-cells 1)))
                (pair (list (lit mt) k)
                  (append (rest r)
                    (list (list (lit calc) k
                            (%cc-subst (list (lit call) (first (rest node)) (first r)) m)))))))))
        (pair node effs))))))))))))

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
            (if (not (%cc-cellish? kind))
              (%cc-no "an array or struct local in a body"))
            (def r (if (null? init) (pair () effs) (%cc-extract init m effs)))
            (self (rest stmts)
              (%cc-st (if (null? init) m
                        (%cc-put-str name (%cc-subst (first r) m) m))
                (pair name locals) assigned exits (rest r))
              ext ctx))
        (if (eq? t (lit expr))
          ; ++/-- on a memory place (a global, a spilled variable) is
          ; the store it means
          (let ((e (let ((e0 (first (rest s))))
                     (def t0 (first e0))
                     (def inc? (if (eq? t0 (lit postinc)) #t (eq? t0 (lit preinc))))
                     (def dec? (if (eq? t0 (lit postdec)) #t (eq? t0 (lit predec))))
                     (if (if (if inc? #t dec?)
                           (not (eq? (first (first (rest e0))) (lit var))) #f)
                       (list (lit assign) (first (rest e0))
                         (list (lit bin) (if inc? "+" "-") (first (rest e0)) (list (lit num) 1)))
                       e0))))
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
                    (%cc-no (string-append "loop assigns an unknown variable: " (first a)))
                    (let ((r (%cc-extract (rest a) m effs)))
                      (self (rest stmts)
                        (%cc-st (%cc-put-str (first a) (%cc-subst (first r) m) m)
                          locals (pair (first a) assigned) exits (rest r))
                        ext ctx)))))))
        ; the three exits end their sequence: what follows is dead.
        ; Each is recorded twice: in EXITS with its guard (for the
        ; exits-only wrap) and as an (exit GUARD VALUE) marker in the
        ; effects stream at its program point (for the stream lowering
        ; when stores are among them)
        (if (eq? t (lit return))
          (if (null? (first (rest s))) (%cc-no "bare return in a loop")
            (let ((r (%cc-extract (first (rest s)) m effs)))
              (def v (%cc-subst (first r) m))
              (%cc-st m locals assigned
                (append exits (list (pair (list (lit num) 1) v)))
                (append (rest r) (list (list (lit exit) (list (lit num) 1) v))))))
        (if (eq? t (lit break))
          (if (null? (first ctx)) (%cc-no "break into a transition that stores")
            (let ((v (%cc-subst (first ctx) m)))
              (%cc-st m locals assigned
                (append exits (list (pair (list (lit num) 1) v)))
                (append effs (list (list (lit exit) (list (lit num) 1) v))))))
        (if (eq? t (lit continue))
          (let ((v (%cc-continue-call m locals ext ctx)))
            (%cc-st m locals assigned
              (append exits (list (pair (list (lit num) 1) v)))
              (append effs (list (list (lit exit) (list (lit num) 1) v)))))
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

; split { decls*; pre*; (while|for) (assign*; (while|for))*; return R }
;   -> (decls pre loops return) or nil.  PRE is the statements between
;   the decls and the first loop, in order, each (guard C . E) for a
;   pre-loop `if (C) return E;` or (init NAME . E) for a pre-loop
;   assignment -- the lowerer checks guards are loop-invariant and
;   inits target accumulators.  LOOPS is one (between-stmts . loop)
;   per loop in sequence, the between-stmts assignments only.
(def %cc-loop-split
  (fn (_ stmts)
    (def loop?
      (fn (_ s) (if (eq? (first s) (lit while)) #t (eq? (first s) (lit for)))))
    ; from the first loop on: the loops, then the lone return
    (def loops
      (fn (self ss between acc)
        (if (null? ss) ()
          (let ((s (first ss)))
            (if (loop? s)
              (self (rest ss) () (pair (pair (reverse between) s) acc))
              (if (if (eq? (first s) (lit return)) (null? (rest ss)) #f)
                (if (null? between) (list (reverse acc) s) ())
                (if (null? (%cc-stmt-assign s)) ()
                  (self (rest ss) (pair s between) acc))))))))
    (def go
      (fn (self ss decls pre)
        (if (null? ss) ()
          (let ((s (first ss)))
            (if (if (eq? (first s) (lit decl)) (null? pre) #f)
              (self (rest ss) (pair s decls) pre)
              (if (loop? s)
                (let ((r (loops ss () ())))
                  (if (null? r) ()
                    (list (reverse decls) (reverse pre) (first r)
                      (first (rest r)))))
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

; --- globals: memory at a known address ------------------------------------
; The program is loaded before anything lowers, so a global's address
; is known: a scalar global reads and writes as *(ADDR) -- the memory
; machinery (load temps, stores) takes it from there -- and an array
; global is its base address, like a local array.  A parameter or a
; body local of the same name shadows.  Struct globals stay free
; variables, and refuse.
(def %cc-decl-names
  (fn (self stmts)
    (if (null? stmts) ()
      (let ((s (first stmts)))
        (def t (first s))
        (append
          (if (eq? t (lit decl)) (list (first (rest s)))
            (if (eq? t (lit block)) (self (first (rest s)))
              (if (eq? t (lit if))
                (append (self (list (first (rest (rest s)))))
                  (if (null? (first (rest (rest (rest s))))) ()
                    (self (list (first (rest (rest (rest s))))))))
                (if (eq? t (lit while)) (self (list (first (rest (rest s)))))
                  (if (eq? t (lit for)) (self (list (first (rest (rest (rest (rest s)))))))
                    (if (eq? t (lit do)) (self (list (first (rest s))))
                      ()))))))
          (self (rest stmts)))))))

(def %cc-globals-subst
  (fn (_ stmts params)
    (def shadow (append params (%cc-decl-names stmts)))
    (def sub
      (let ((go (fn (self es acc)
                  (if (null? es) acc
                    (let ((e (first es)))
                      (def kind (rest (rest e)))
                      (if (%cc-member-str? (first e) shadow) (self (rest es) acc)
                        (if (not (pair? kind))
                          (self (rest es)
                            (pair (pair (first e)
                                    (list (lit un) "*" (list (lit num) (first (rest e)))))
                              acc))
                          (if (if (eq? (first kind) (lit array)) (null? (rest (rest kind))) #f)
                            (self (rest es)
                              (pair (pair (first e) (list (lit num) (first (rest e)))) acc))
                            (self (rest es) acc)))))))))
        (go %cc-genv ())))
    (if (null? sub) stmts (%cc-subst-stmts stmts sub))))

; effects to lane forms: a load fills its temp from the address, a
; calc fills its temp from an expression (a cross-call), a store
; writes, a cond runs one arm's effects (0 when an arm is empty)
(def %cc-effects-do ())
(def %cc-lower-eff
  (fn (_ e name ext)
    (let ((t (first e)))
      (if (eq? t (lit load))
        (list (lit %mem-set-at!) %cc-membase (first (rest e))
          (list (lit %mem-ref-at) %cc-membase
            (%cc-lower-e (first (rest (rest e))) name ext)))
        (if (eq? t (lit calc))
          (list (lit %mem-set-at!) %cc-membase (first (rest e))
            (%cc-lower-e (first (rest (rest e))) name ext))
        (if (eq? t (lit store))
          (list (lit %mem-set-at!) %cc-membase
            (%cc-lower-e (first (rest e)) name ext)
            (%cc-lower-e (first (rest (rest e))) name ext))
          (list (lit if) (%cc-lower-e (first (rest e)) name ext)
            (%cc-effects-do (first (rest (rest e))) name ext 0)
            (%cc-effects-do (first (rest (rest (rest e)))) name ext 0))))))))
(set! %cc-effects-do
  (fn (_ effs name ext tail)
    (if (null? effs) tail
      (pair (lit do)
        (append (map (fn (_ e) (%cc-lower-eff e name ext)) effs)
          (list tail))))))

; does a stream hold a real effect (a load, calc or store), or an exit?
(def %cc-real-effects?
  (fn (self effs)
    (if (null? effs) #f
      (let ((e (first effs)))
        (def t (first e))
        (if (if (eq? t (lit load)) #t (if (eq? t (lit calc)) #t (eq? t (lit store)))) #t
          (if (eq? t (lit cond))
            (if (self (first (rest (rest e)))) #t
              (if (self (first (rest (rest (rest e))))) #t (self (rest effs))))
            (self (rest effs))))))))
(def %cc-has-exit?
  (fn (self effs)
    (if (null? effs) #f
      (let ((e (first effs)))
        (if (eq? (first e) (lit exit)) #t
          (if (eq? (first e) (lit cond))
            (if (self (first (rest (rest e)))) #t
              (if (self (first (rest (rest (rest e))))) #t (self (rest effs))))
            (self (rest effs))))))))

; THE STREAM: effects and exits in program order, lowered with each
; exit tested in its place -- (if GUARD VALUE REST); an unconditional
; exit ends the stream.  A cond whose arms hold no exit is one
; statement; one that exits inside an arm carries the REST into both
; arms (the continuation is small: the stores after it and the tail).
(def %cc-stream-do
  (fn (self effs name ext tail)
    (if (null? effs) tail
      (let ((e (first effs)))
        (def t (first e))
        (if (eq? t (lit exit))
          (let ((g (first (rest e))))
            (def v (%cc-lower-e (first (rest (rest e))) name ext))
            (if (eq? (first g) (lit num)) v
              (list (lit if) (%cc-lower-e g name ext) v
                (self (rest effs) name ext tail))))
          (if (if (eq? t (lit cond)) (%cc-has-exit? (list e)) #f)
            (let ((k (self (rest effs) name ext tail)))
              (list (lit if) (%cc-lower-e (first (rest e)) name ext)
                (self (first (rest (rest e))) name ext k)
                (self (first (rest (rest (rest e)))) name ext k)))
            (list (lit do) (%cc-lower-eff e name ext)
              (self (rest effs) name ext tail))))))))

; the loop lowerer: (fn-expr . pad-inits), or a refusal
(def %cc-lower-loop
  (fn (_ name params body)
    (set! %cc-inline-stack (list name))
    (set! %cc-fold-name name)
    ; local aggregates already have their scratch blocks and their
    ; names resolved (%cc-structs-subst, which every path shares)
    (def stmts1 (first (rest body)))
    (def split (%cc-loop-split stmts1))
    (if (null? split) (%cc-no "not a decls+guards+loops+return shape")
      (let ((decls (first split)))
        (def pre (first (rest split)))
        (def guards
          (map (fn (_ p) (rest p))
            (filter (fn (_ p) (eq? (first p) (lit guard))) pre)))
        (def pre-inits
          (map (fn (_ p) (rest p))
            (filter (fn (_ p) (eq? (first p) (lit init))) pre)))
        ; the loops in sequence, each (between-stmts . loop-stmt)
        (def loops0 (first (rest (rest split))))
        (def ret (first (rest (rest (rest split)))))
        (def ret-e0 (first (rest ret)))
        (if (null? ret-e0) (%cc-no "loop fn has a bare return"))
        ; SEQUENTIAL LOOPS run as PHASES of the one self-call: a phase
        ; counter rides as one more threaded variable (%ph -- no C name
        ; can collide), each loop's exit is the transition call into
        ; the next (the statements between them, its init and its
        ; inner reset folded, the phase advanced), and the body
        ; selects on the phase.  One loop needs no counter.
        (def multi (pair? (rest loops0)))
        (def accs0 (map (fn (_ d) (first (rest d))) decls))
        ; %ph first: it must keep its slot (a transition sets it)
        (def accs-all (if multi (pair "%ph" accs0) accs0))
        ; SPILLS: every self-call passes all of the lane's four
        ; argument slots, so THREADED VARIABLES past the fourth --
        ; parameters and accumulators alike -- live in scratch cells
        ; instead: their names substitute to *(CELL) through the loops,
        ; the guards and the return, they read and write as memory from
        ; there, and their entry values store at the call boundary (the
        ; entry effects, below).  Parameters keep the slots first, then
        ; accumulators.  A spilled PARAMETER is one the lane function
        ; never takes, so the call passes fewer arguments than the C
        ; function has -- %cc-call reads the kept count from the table.
        (def take (fn (self2 l n) (if (if (null? l) #t (<= n 0)) () (pair (first l) (self2 (rest l) (- n 1))))))
        (def drop (fn (self2 l n) (if (if (null? l) #t (<= n 0)) l (self2 (rest l) (- n 1)))))
        ; the phase counter is assigned by a transition built after the
        ; substitution, so it can never be one of the spilled names:
        ; sequential loops reserve its slot, a parameter spilling to
        ; make room
        ; ONE count for both sides: keeping N parameters and spilling
        ; all but the first N are the same decision, and splitting them
        ; left the (multi) 4th parameter neither kept nor spilled -- a
        ; free variable at lowering
        (def pkeep (if multi 3 4))
        (def kept-params (take params pkeep))
        (def room (- 4 (length kept-params)))
        (if (if multi (< room 1) #f)
          (%cc-no "no lane slot for the phase counter"))
        (def accs (take accs-all room))
        (def spill-cells
          (map (fn (_ v) (pair v (%cc-new-cells 1)))
            (append (drop params pkeep) (drop accs-all room))))
        (def spill-sub
          (map (fn (_ sc) (pair (first sc) (list (lit un) "*" (list (lit num) (rest sc)))))
            spill-cells))
        (def loops
          (map (fn (_ item)
                 (pair (%cc-subst-stmts (first item) spill-sub)
                   (%cc-subst-stmt (rest item) spill-sub)))
            loops0))
        (def ret-e (%cc-subst ret-e0 spill-sub))
        (def loop1 (rest (first loops)))
        (def loop-for? (fn (_ l) (eq? (first l) (lit for))))
        (def loop-init (fn (_ l) (if (loop-for? l) (first (rest l)) ())))
        (def loop-cond
          (fn (_ l) (if (loop-for? l) (first (rest (rest l))) (first (rest l)))))
        (def loop-step
          (fn (_ l) (if (loop-for? l) (first (rest (rest (rest l)))) ())))
        (def loop-body
          (fn (_ l)
            (%cc-loop-body-stmts
              (if (loop-for? l) (first (rest (rest (rest (rest l)))))
                (first (rest (rest l)))))))
        ; the first loop's init, before any spill substitution: it folds
        ; into the init map over the parameters like the decl inits
        (def init-node (loop-init (rest (first loops0))))
        ; THE INITS: decl inits, pre-loop assignments and the first
        ; loop's for-INIT fold in order into a map over the PARAMETERS
        ; (each later init substitutes the earlier ones away), so every
        ; accumulator's entry value is an expression over params alone.
        ; A literal pads as an int; anything else pads as its own tiny
        ; lane function over the params, applied to the args at the
        ; call boundary -- once, at entry, native.
        (def set-init
          (fn (_ a imap)
            (if (not (%cc-member-str? (first a) accs-all))
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
            (go decls (if multi (list (pair "%ph" (list (lit num) 0))) ()))))
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
        (def ext (append kept-params accs))
        (def lret (%cc-lower-e ret-e name ext))
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
        (def split-inner
          (fn (self2 ss pre2)
            (if (null? ss) ()
              (if (if (eq? (first (first ss)) (lit for)) #t
                    (eq? (first (first ss)) (lit while)))
                (list (reverse pre2) (first ss) (rest ss))
                (self2 (rest ss) (pair (first ss) pre2))))))
        (def no-exits!
          (fn (_ st2 what)
            (if (null? (%cc-st-exits st2)) st2
              (%cc-no (string-append what " may not exit")))))
        ; a body's effects run in a `do` before its tail; a body that
        ; both stores and exits lowers as the ordered STREAM, each exit
        ; tested in its place among the stores (%cc-stream-do)
        (def with-effects
          (fn (_ effs exits tail)
            (if (null? exits) (%cc-effects-do effs name ext tail)
              (if (%cc-real-effects? effs) (%cc-stream-do effs name ext tail)
                (wrap-with tail exits)))))
        ; a loop's guarded reset of its inner loop, for entry and for
        ; the transition into it: (if I-cond (block PRE... J-init
        ; RESET-OF-INNER...)) -- guarded, so PRE and J-init never leak
        ; into R on the last exit; recursive, so entering a loop anew
        ; enters every loop inside it anew
        (def reset-of
          (fn (self2 loop)
            (def nest (split-inner (loop-body loop) ()))
            (if (null? nest) ()
              (let ((inner (first (rest nest))))
                (def j-init (loop-init inner))
                (def reset-stmts
                  (append (first nest)
                    (append (if (null? j-init) () (list (list (lit expr) j-init)))
                      (self2 inner))))
                (if (null? reset-stmts) ()
                  (list (list (lit if) (loop-cond loop)
                          (list (lit block) reset-stmts) ())))))))
        ; ONE LOOP, given what it answers when its condition fails --
        ; R for the last loop, the transition call into the next for
        ; the others, the enclosing loop's transition for an inner
        ; loop -- and the effects that run before that answer.  Also
        ; what a break aims at (nothing, when those effects store: a
        ; static break target cannot carry them).  Answers
        ; (expr . assigned).
        ; --- NESTED LOOPS: a state machine over the one self-call ----
        ; The body splits at its first top-level loop into PRE, the
        ; inner loop, and POST.  Each re-entry runs one step of
        ; whichever loop is active:
        ;   (if I-cond (if J-cond INNER-STEP TRANSITION) EXIT)
        ; INNER-STEP is the inner loop's own step -- this function
        ; again, so any depth -- and TRANSITION folds POST + I-step +
        ; the guarded reset.  An inner `break` is the transition call
        ; and an inner `continue` the inner self-call: folding from a
        ; map equals folding from identity then substituting, so the
        ; transition is a STATIC cexpr the fold's break already
        ; substitutes.
        (def one-loop
          (fn (self2 loop exit-c exit-effs)
            (def cond-node (loop-cond loop))
            (def step-node (loop-step loop))
            (def body-stmts (loop-body loop))
            (if (null? cond-node) (%cc-no "loop needs a condition"))
            (def lcond (%cc-lower-e cond-node name ext))
            (def lexit
              (%cc-effects-do exit-effs name ext (%cc-lower-e exit-c name ext)))
            (def outer-step-stmts
              (if (null? step-node) () (list (list (lit expr) step-node))))
            (def ctx (list (if (null? exit-effs) exit-c ()) step-node name))
            (def nest (split-inner body-stmts ()))
            (if (null? nest)
              (let ((st (%cc-fold-stmts (append body-stmts outer-step-stmts)
                          (%cc-st () () () () ()) ext ctx)))
                (pair
                  (list (lit if) lcond
                    (with-effects (%cc-st-effects st) (%cc-st-exits st)
                      (wrap-with (%cc-lower-e (call-from (first st)) name ext)
                        (%cc-st-exits st)))
                    lexit)
                  (first (rest (rest st)))))
              (let ((post-stmts (first (rest (rest nest)))))
                (def inner (first (rest nest)))
                ; the transition from identity, as a static cexpr
                (def st-t
                  (no-exits!
                    (%cc-fold-stmts
                      (append post-stmts (append outer-step-stmts (reset-of loop)))
                      (%cc-st () () () () ()) ext ctx)
                    "the outer body around the inner loop"))
                (def transition (call-from (first st-t)))
                (def r (self2 inner transition (%cc-st-effects st-t)))
                (pair
                  (list (lit if) lcond (first r) lexit)
                  (append (rest r) (first (rest (rest st-t)))))))))
        ; the transition INTO the k-th loop (phase k-1): the statements
        ; between the loops, its for-init, its inner reset, the phase
        ; advanced -- folded pure from identity into a static self-call
        (def trans-into
          (fn (_ k item)
            (def loop (rest item))
            (def init (loop-init loop))
            (def stmts
              (append (first item)
                (append (if (null? init) () (list (list (lit expr) init)))
                  (append (reset-of loop)
                    (list (list (lit expr)
                            (list (lit assign) (list (lit var) "%ph")
                              (list (lit num) (- k 1)))))))))
            (def st
              (no-exits!
                (%cc-fold-stmts stmts (%cc-st () () () () ()) ext
                  (list ret-e () name))
                "a transition between loops"))
            ; (call . effects): the next loop's init may STORE (its
            ; counter spilled to a cell), and those run before the call
            (pair (call-from (first st)) (%cc-st-effects st))))
        ; the loops from the k-th on, selecting on the phase: (expr . assigned)
        (def build-loops
          (fn (self2 items k)
            (if (null? (rest items))
              (one-loop (rest (first items)) ret-e ())
              (let ((r (let ((tr (trans-into (+ k 1) (first (rest items)))))
                         (one-loop (rest (first items)) (first tr) (rest tr)))))
                (def rr (self2 (rest items) (+ k 1)))
                (pair
                  (list (lit if)
                    (list (lit =) (convert "%ph" %symbol) (- k 1))
                    (first r) (first rr))
                  (append (rest r) (rest rr)))))))
        (def built (build-loops loops 1))
        (def loop-expr (first built))
        (def assigned (rest built))
        ; entry: the first loop's reset folded onto the init map gives
        ; the pads (the kept accumulators' entry values) and the ENTRY
        ; EFFECTS -- the spills' initial stores, then whatever the reset
        ; stores or loads -- one lane function over the parameters that
        ; %cc-call runs before the pads
        (def st-entry
          (no-exits!
            (%cc-fold-stmts (reset-of loop1) (%cc-st imap () () () ())
              ext (list ret-e () name))
            "the reset"))
        (def imap-final (first st-entry))
        (def entry-effs
          (append
            (map (fn (_ sc)
                   (list (lit store) (list (lit num) (rest sc))
                     (%cc-var-of (first sc) imap-final)))
              spill-cells)
            (%cc-st-effects st-entry)))
        (def psyms (map (fn (_ p) (convert p %symbol)) params))
        (def inits
          (map (fn (_ a)
                 (let ((e (%cc-var-of a imap-final)))
                   ; NOT `lit` -- a def in a called body binds globally
                   ; and `lit` is the quote operative
                   (def litv (%cc-int-lit e))
                   (if (not (null? litv)) litv
                     (if (not (param-only? (%cc-free-vars e)))
                       (%cc-no "an init reads a non-parameter")
                       ; fname "" so a self-call inside refuses; a call
                       ; to another function inlines
                       (list (lit fn) (pair (lit %cc-init) psyms)
                         (%cc-lower-e e "" params))))))
            accs))
        (def entry
          (if (null? entry-effs) ()
            (if (not (param-only? (%cc-effs-free-vars entry-effs)))
              (%cc-no "an entry effect reads a non-parameter")
              (list (lit fn) (pair (lit %cc-init) psyms)
                (%cc-effects-do entry-effs "" params 0)))))
        ; pre-loop guards re-run on every self-call re-entry, so each
        ; must be LOOP-INVARIANT: it may read only parameters the body
        ; never assigns (an accumulator holds its init only on first
        ; entry).  Guards wrap the loop outermost-first.
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
              (let ((g (let ((g0 (first gs)))
                         (pair (%cc-subst (first g0) spill-sub)
                           (%cc-subst (rest g0) spill-sub)))))
                (if (not (invariant?
                           (append (%cc-free-vars (first g))
                             (%cc-free-vars (rest g)))))
                  (%cc-no "a pre-loop guard is not loop-invariant")
                  ; a guard re-runs on every re-entry: memory it read
                  ; (a global) may have been stored since
                  (if (if (%cc-has-load? (first g)) #t (%cc-has-load? (rest g)))
                    (%cc-no "a pre-loop guard reads memory")
                    (list (lit if)
                      (%cc-lower-e (first g) name ext)
                      (%cc-lower-e (rest g) name ext)
                      (self2 (rest gs)))))))))
        (list
          (pair (lit fn)
            (pair (pair (convert name %symbol)
                    (map (fn (_ v) (convert v %symbol)) ext))
              (list (guarded guards))))
          inits
          entry
          (length kept-params))))))

; the variable names an effect list reads (dupes fine)
(def %cc-effs-free-vars
  (fn (self effs)
    (if (null? effs) ()
      (let ((e (first effs)))
        (def t (first e))
        (append
          (if (eq? t (lit load)) (%cc-free-vars (first (rest (rest e))))
            (if (eq? t (lit calc)) (%cc-free-vars (first (rest (rest e))))
              (if (eq? t (lit store))
                (append (%cc-free-vars (first (rest e)))
                  (%cc-free-vars (first (rest (rest e)))))
                (if (eq? t (lit cond))
                  (append (%cc-free-vars (first (rest e)))
                    (append (self (first (rest (rest e))))
                      (self (first (rest (rest (rest e)))))))
                  (list "?")))))
          (self (rest effs)))))))

; --- structs: field access as address arithmetic -----------------------------
; The lane has no notion of a field, but the cell model already says
; where one lives: a struct value IS its address, and a field is a
; fixed offset from it.  So before lowering, every `.` and `->` becomes
; explicit arithmetic over the shared memory -- `p->x` is `*(p + off)`,
; `a[i].y` is `*(a + i*size + off)` -- and the existing load/store
; machinery takes it from there.
;
; The one semantic trap is a struct passed BY VALUE: the argument is
; the caller's address, and C says the callee mutates a copy.  Reading
; through the address is right, writing through it is not, so a
; function that assigns a field of a by-value struct parameter refuses.
; Through a POINTER, writing is the point, and is allowed.
;
; Anything whose kind this cannot determine refuses rather than
; guessing: an unscaled index into an array of structs would be
; silently wrong, which is the worst thing a compiler can be.
(def %cc-kind-env
  (fn (self stmts acc)
    (if (null? stmts) acc
      (let ((s (first stmts)))
        (def t (first s))
        (self (rest stmts)
          (if (eq? t (lit decl))
            (pair (pair (first (rest s)) (first (rest (rest s)))) acc)
            (if (eq? t (lit block)) (self (first (rest s)) acc)
              (if (eq? t (lit if))
                (self (list (first (rest (rest s))))
                  (if (null? (first (rest (rest (rest s))))) acc
                    (self (list (first (rest (rest (rest s))))) acc)))
                (if (eq? t (lit while)) (self (list (first (rest (rest s)))) acc)
                  (if (eq? t (lit for))
                    (self (list (first (rest (rest (rest (rest s)))))) acc)
                    (if (eq? t (lit do)) (self (list (first (rest s))) acc)
                      acc)))))))))))

(def %cc-env-kind
  (fn (_ name env)
    (def go (fn (self es)
              (if (null? es) (lit scalar)
                (if (string=? (first (first es)) name) (rest (first es))
                  (self (rest es))))))
    (go env)))

(def %cc-struct? (fn (_ k) (if (pair? k) (eq? (first k) (lit struct)) #f)))

; one cell: a scalar, or a pointer whatever it points at.  An array or
; a struct is the one that needs storage.
(def %cc-cellish?
  (fn (_ k) (if (not (pair? k)) #t (eq? (first k) (lit ptr)))))

; the kind of an expression, statically
(def %cc-lk
  (fn (self node env)
    (let ((t (first node)))
      (if (eq? t (lit var)) (%cc-env-kind (first (rest node)) env)
      (if (eq? t (lit idx)) (%cc-kind-elem (self (first (rest node)) env))
      (if (eq? t (lit dot))
        (let ((k (self (first (rest node)) env)))
          (if (not (%cc-struct? k)) (%cc-no "a field of something not a struct")
            (let ((f (%cc-field (first (rest k)) (first (rest (rest node))))))
              (if (null? f) (%cc-no "no such field") (rest f)))))
      (if (eq? t (lit arrow))
        (let ((k (%cc-kind-elem (self (first (rest node)) env))))
          (if (not (%cc-struct? k)) (%cc-no "an arrow through something not a struct pointer")
            (let ((f (%cc-field (first (rest k)) (first (rest (rest node))))))
              (if (null? f) (%cc-no "no such field") (rest f)))))
      (if (if (eq? t (lit un)) (string=? (first (rest node)) "*") #f)
        (%cc-kind-elem (self (first (rest (rest node))) env))
      (if (if (eq? t (lit bin))
            (if (string=? (first (rest node)) "+") #t (string=? (first (rest node)) "-")) #f)
        (let ((ka (self (first (rest (rest node))) env)))
          (if (pair? ka) ka (lit scalar)))
        (lit scalar))))))))))

(def %cc-saddr ())
(def %cc-sval ())

; LOCAL AGGREGATES: an array or struct declared in a function needs
; storage, and the native scratch region above the program's memory is
; where it goes -- the name then stands for its base address, exactly
; as a struct parameter does.  One block per function, not per frame,
; so a genuinely recursive function with one refuses (its frames would
; share the storage); a loop function's self-call is the same frame and
; is fine.
(def %cc-local-bases ())
(def %cc-base-of
  (fn (_ name)
    (def go (fn (self es)
              (if (null? es) ()
                (if (string=? (first (first es)) name) (rest (first es))
                  (self (rest es))))))
    (go %cc-local-bases)))

; the VALUE of a node, once fields are arithmetic: a struct or array
; decays to its address, anything else reads
(set! %cc-sval
  (fn (_ node env)
    (let ((k (%cc-lk node env)))
      (if (%cc-kind-decays? k) (%cc-saddr node env)
        (let ((t (first node)))
          (if (if (eq? t (lit dot)) #t
                (if (eq? t (lit arrow)) #t
                  (if (eq? t (lit idx)) #t
                    (if (eq? t (lit un)) (string=? (first (rest node)) "*") #f))))
            (list (lit un) "*" (%cc-saddr node env))
            node))))))

; the ADDRESS a node names, as an expression over cells
(set! %cc-saddr
  (fn (_ node env)
    (let ((t (first node)))
      (if (eq? t (lit var))
        ; a local aggregate IS its scratch block; a struct parameter
        ; holds the caller's address
        (let ((b (%cc-base-of (first (rest node)))))
          (if (not (null? b)) (list (lit num) b)
            (if (%cc-kind-decays? (%cc-env-kind (first (rest node)) env)) node
              (%cc-no "the address of a scalar variable stays interpreted"))))
      (if (eq? t (lit dot))
        (let ((k (%cc-lk (first (rest node)) env)))
          (def f (%cc-field (first (rest k)) (first (rest (rest node)))))
          (list (lit bin) "+" (%cc-saddr (first (rest node)) env)
            (list (lit num) (first f))))
      (if (eq? t (lit arrow))
        (let ((k (%cc-kind-elem (%cc-lk (first (rest node)) env))))
          (def f (%cc-field (first (rest k)) (first (rest (rest node)))))
          (list (lit bin) "+" (%cc-sval (first (rest node)) env)
            (list (lit num) (first f))))
      (if (eq? t (lit idx))
        (let ((step (%cc-kind-size (%cc-kind-elem (%cc-lk (first (rest node)) env)))))
          (def base (%cc-sval (first (rest node)) env))
          (def i (%cc-sval (first (rest (rest node))) env))
          (list (lit bin) "+" base
            (if (= step 1) i (list (lit bin) "*" i (list (lit num) step)))))
      (if (if (eq? t (lit un)) (string=? (first (rest node)) "*") #f)
        (%cc-sval (first (rest (rest node))) env)
        (%cc-no "not an address")))))))))

; does any part of this expression mention a field?
(def %cc-has-field?
  (fn (self node)
    (if (not (pair? node)) #f
      (let ((t (first node)))
        (if (if (eq? t (lit dot)) #t (eq? t (lit arrow))) #t
          (let ((go (fn (self2 xs)
                      (if (null? xs) #f
                        (if (if (pair? (first xs)) (self (first xs)) #f) #t
                          (self2 (rest xs)))))))
            (go (rest node))))))))

; the variable a place is rooted at, stopping at any dereference (past
; one, the memory belongs to whatever the pointer names, not to us)
(def %cc-lv-root
  (fn (self node env)
    (let ((t (first node)))
      (if (eq? t (lit var)) (first (rest node))
        (if (eq? t (lit dot)) (self (first (rest node)) env)
          (if (if (eq? t (lit idx))
                (let ((k (%cc-lk (first (rest node)) env)))
                  (if (pair? k) (eq? (first k) (lit array)) #f))
                #f)
            (self (first (rest node)) env)
            ()))))))

; rewrite one expression: fields become arithmetic, everything else
; keeps its shape
(def %cc-srw
  (fn (self node env byval)
    (if (not (pair? node)) node
      (let ((t (first node)))
        (if (if (eq? t (lit dot)) #t (eq? t (lit arrow)))
          (%cc-sval node env)
        (if (eq? t (lit idx))
          ; an index into an aggregate (a local array, an array of
          ; structs) resolves to an address here, so the element size
          ; scales; a plain `int *p` keeps the existing pointer shape
          (let ((k (%cc-lk (first (rest node)) env)))
            (if (%cc-kind-decays? k)
              (%cc-sval node env)
              (list (lit idx) (self (first (rest node)) env byval)
                (self (first (rest (rest node))) env byval))))
        (if (eq? t (lit assign))
          (let ((root (%cc-lv-root (first (rest node)) env)))
            (if (if (null? root) #f (%cc-member-str? root byval))
              (%cc-no "a by-value struct parameter is assigned")
              (list (lit assign) (self (first (rest node)) env byval)
                (self (first (rest (rest node))) env byval))))
        (if (eq? t (lit call))
          (list (lit call) (first (rest node))
            (map (fn (_ a) (self a env byval)) (first (rest (rest node)))))
        (if (eq? t (lit var))
          ; an aggregate's name decays to its address
          (if (%cc-kind-decays? (%cc-lk node env)) (%cc-sval node env) node)
        (if (if (eq? t (lit num)) #t (eq? t (lit str)))
          node
          (pair t (map (fn (_ x) (if (pair? x) (self x env byval) x))
                    (rest node)))))))))))))

(def %cc-srw-stmts ())
(def %cc-srw-stmt
  (fn (self s env byval)
    (def e (fn (_ x) (if (null? x) () (%cc-srw x env byval))))
    (let ((t (first s)))
      (if (eq? t (lit expr)) (list (lit expr) (e (first (rest s))))
      (if (eq? t (lit return)) (list (lit return) (e (first (rest s))))
      (if (eq? t (lit block)) (list (lit block) (%cc-srw-stmts (first (rest s)) env byval))
      (if (eq? t (lit if))
        (list (lit if) (e (first (rest s)))
          (self (first (rest (rest s))) env byval)
          (if (null? (first (rest (rest (rest s))))) ()
            (self (first (rest (rest (rest s)))) env byval)))
      (if (eq? t (lit while))
        (list (lit while) (e (first (rest s)))
          (self (first (rest (rest s))) env byval))
      (if (eq? t (lit for))
        (list (lit for) (e (first (rest s))) (e (first (rest (rest s))))
          (e (first (rest (rest (rest s)))))
          (self (first (rest (rest (rest (rest s))))) env byval))
      (if (eq? t (lit decl))
        (list (lit decl) (first (rest s)) (first (rest (rest s)))
          (e (first (rest (rest (rest s))))))
        s))))))))))
; an aggregate that got a scratch block declares nothing any more: its
; statement goes, rather than becoming an empty one -- the loop split
; reads the leading declarations positionally
(set! %cc-srw-stmts
  (fn (_ ss env byval)
    (map (fn (_ s) (%cc-srw-stmt s env byval))
      (filter (fn (_ s)
                (if (eq? (first s) (lit decl))
                  (null? (%cc-base-of (first (rest s))))
                  #t))
        ss))))

; the whole pass: nothing to do unless a field appears somewhere
(def %cc-structs-subst
  (fn (_ stmts params kinds fname)
    (def penv
      (let ((go (fn (self ps ks)
                  (if (null? ps) ()
                    (pair (pair (first ps) (if (null? ks) (lit scalar) (first ks)))
                      (self (rest ps) (if (null? ks) () (rest ks))))))))
        (go params kinds)))
    (def env (%cc-kind-env stmts penv))
    ; storage for the local aggregates, before anything reads a name
    (set! %cc-local-bases ())
    (def aggregate?
      (fn (_ st1)
        (if (eq? (first st1) (lit decl))
          (let ((k (first (rest (rest st1)))))
            (if (pair? k) (not (eq? (first k) (lit ptr))) #f))
          #f)))
    (def recurses?
      (let ((go (fn (self n)
                  (if (not (pair? n)) #f
                    (if (if (eq? (first n) (lit call))
                          (string=? (first (rest n)) fname) #f)
                      #t
                      (let ((any (fn (self2 xs)
                                   (if (null? xs) #f
                                     (if (if (pair? (first xs)) (self (first xs)) #f) #t
                                       (self2 (rest xs)))))))
                        (any (rest n))))))))
        (go (pair (lit block) (list stmts)))))
    (map (fn (_ d)
           (if (not (null? (first (rest (rest (rest d))))))
             (%cc-no "an initialized local aggregate stays interpreted"))
           (if recurses?
             (%cc-no "a recursive function's local aggregate would share frames"))
           (set! %cc-local-bases
             (pair (pair (first (rest d))
                     (%cc-new-cells (%cc-kind-size (first (rest (rest d))))))
               %cc-local-bases)))
      (filter aggregate? stmts))
    (def byval
      (let ((go (fn (self ps ks)
                  (if (null? ps) ()
                    (if (%cc-struct? (if (null? ks) (lit scalar) (first ks)))
                      (pair (first ps) (self (rest ps) (if (null? ks) () (rest ks))))
                      (self (rest ps) (if (null? ks) () (rest ks))))))))
        (go params kinds)))
    (%cc-srw-stmts stmts env byval)))

; --- the straight-line path --------------------------------------------------
; A body of assignments and a return: no if/return ladder, no loop.
; The loop fold already models exactly this -- statements folded into
; a map over the parameters, memory reads and writes as ordered
; effects, a `return` as a guarded exit -- and without a self-call
; nothing needs a lane slot: every local is substitution-only and an
; assigned parameter just threads through the map.  A `break` or
; `continue` has no enclosing loop here, and refuses: the context
; carries no break target and no name to call.
(def %cc-lower-straight
  (fn (_ name params body)
    (set! %cc-inline-stack (list name))
    (set! %cc-fold-name name)
    (def st
      (%cc-fold-stmts (first (rest body)) (%cc-st () () () () ())
        params (list () () "")))
    (def effs (%cc-st-effects st))
    (def exits (%cc-st-exits st))
    (if (null? exits) (%cc-no "a path falls off the end"))
    ; the exits, last to first; the body ends in a return, so the
    ; unconditional one always replaces this tail
    (def wrap
      (fn (self2 es)
        (if (null? es) 0
          (let ((e (first es)))
            (if (eq? (first (first e)) (lit num))
              (%cc-lower-e (rest e) name params)
              (list (lit if) (%cc-lower-e (first e) name params)
                (%cc-lower-e (rest e) name params)
                (self2 (rest es))))))))
    (list
      (pair (lit fn)
        (pair (pair (convert name %symbol)
                (map (fn (_ p) (convert p %symbol)) params))
          (list
            (if (%cc-real-effects? effs)
              (%cc-stream-do effs name params 0)
              (wrap exits)))))
      ()
      ()
      (length params))))

; the expression-body path: fib and friends, no padding
(def %cc-lower-expr-fun
  (fn (_ name params body)
    (set! %cc-inline-stack (list name))
    (list
      (pair (lit fn)
        (pair
          (pair (convert name %symbol)
            (map (fn (_ p) (convert p %symbol)) params))
          (list
            (%cc-lower-body (first (rest body)) name params))))
      ()
      ()
      (length params))))

(def %cc-check-names
  (fn (_ name params)
    (if (%cc-unsafe-name? name) (%cc-no "name collides with the lane")
      (let ((check (fn (self ps)
                     (if (null? ps) ()
                       (if (%cc-unsafe-name? (first ps))
                         (%cc-no "parameter collides with the lane")
                         (self (rest ps)))))))
        (check params)))))

; one function to (fn-expr pad-inits entry): globals become memory
; first; then the loop transform, falling back to the expression path
(def %cc-lower-fun
  (fn (_ name params body kinds)
    (do (%cc-check-names name params)
        (let ((body2 (list (lit block)
                       (%cc-structs-subst
                         (%cc-globals-subst (first (rest body)) params)
                         params kinds name))))
          ; the loop path first; its refusal is the informative one, so
          ; keep it for the X_CC_WHY report before the expression path
          ; answers with its own
          (guard (e (do (set! %cc-loop-why e)
                        (guard (e2 (%cc-lower-straight name params body2))
                          (%cc-lower-expr-fun name params body2))))
            (%cc-lower-loop name params body2))))))

; try every function; the guard is the adoption rule -- refuse, stay
; interpreted.  Answers ((name . verdict) ...) in program order,
; verdict native | interpreted.
(def %cc-why? #f)
(def %cc-loop-why ())   ; the loop path's refusal, kept for the report

(def %cc-jit!
  (fn (_)
    (set! %cc-why? (not (null? (sys-getenv "X_CC_WHY"))))
    (set! %cc-natives ())
    (set! %cc-scratch-next %cc-memsize)
    (def go
      (fn (self fs acc)
        (if (null? fs) (reverse acc)
          (let ((name (first (first fs))))
            (def params (first (rest (first fs))))
            (def body (first (rest (rest (first fs)))))
            ; (name params body kinds ret): a struct RETURNED by value
            ; needs a frame slot in the caller, which only the
            ; interpreter has.  Struct PARAMETERS are fine -- their
            ; fields become address arithmetic (%cc-structs-subst),
            ; and assigning one refuses there.
            (def kinds (let ((tail (rest (rest (rest (first fs))))))
                         (if (null? tail) () (first tail))))
            (def structy?
              (let ((tail (rest (rest (rest (first fs))))))
                (if (null? tail) #f
                  (if (null? (rest tail)) #f
                    (let ((r (first (rest tail))))
                      (if (pair? r) (eq? (first r) (lit struct)) #f))))))
            ; X_CC_WHY=1 reports each refusal: the adoption rule is to
             ; fall back silently, which makes a function that SHOULD
             ; lower and does not very hard to see
            (def verdict
              (guard (e (do (if %cc-why?
                              (do (display "why ") (display name)
                                  (display ": ") (write e)
                                  (if (null? %cc-loop-why) ()
                                    (do (display " | loop path: ")
                                        (write %cc-loop-why)))
                                  (newline))
                              ())
                            (lit interpreted)))
                (set! %cc-loop-why ())
                (let ((lowered
                        (if structy? (%cc-no "a struct returned by value stays interpreted")
                          (%cc-lower-fun name params body kinds))))
                  (def prim (compile-asm (first lowered)))
                  ; the table entry is (name nkeep pad entry . prim);
                  ; NKEEP is how many of the C parameters the lane
                  ; function actually takes (the rest spilled to cells).
                  ; Each pad slot is an accumulator's literal init, or its init
                  ; expression compiled to a lane function over the
                  ; params (applied at the call boundary); () for a
                  ; plain function.  ENTRY is the entry effects -- the
                  ; spills' initial stores, the reset's -- as one lane
                  ; function over the params run before the pads, or ()
                  (def pad
                    (map (fn (_ p) (if (number? p) p (compile-asm p)))
                      (first (rest lowered))))
                  (def entry
                    (let ((e (first (rest (rest lowered)))))
                      (if (null? e) () (compile-asm e))))
                  (def nkeep (first (rest (rest (rest lowered)))))
                  (set! %cc-natives
                    (pair (pair name (pair nkeep (pair pad (pair entry prim))))
                      %cc-natives))
                  (lit native))))
            (self (rest fs) (pair (pair name verdict) acc))))))
    ; %cc-funs cons-loads, so program order is its reverse
    (go (reverse %cc-funs) ())))

; build: the shared core with the lane switched on -- lower what
; lowers, report each verdict, run main
(def cc-build-run
  (fn (_ src) (%cc-run-core src #t)))
