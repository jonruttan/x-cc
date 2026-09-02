; # x-cc -- a C compiler on x-lang
;
; ## cc/build.x -- the compile-asm backend, slice one
;
; @author [Jon Ruttan](jonruttan@gmail.com)
; @copyright 2026 Jon Ruttan
; @license MIT No Attribution (MIT-0)
;
; THE ELIGIBLE CLASS: a C function lowers to the engine's JIT when it
; is integers all the way -- int parameters, every path a return, the
; body only if/return/blocks, expressions over params, literals,
; + - * / % comparisons && || ! ~ the ternary, and calls to ITSELF
; (max 4 args -- the lane's own trampoline rule; self-recursion rides
; the fn's first-param name, x-lang#583's slot-0 convention).  Pointers,
; assignments, loops, globals and cross-calls stay interpreted --
; recorded pendings, each a lane feature away.
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

; one function to a lane expression, or a refusal
(def %cc-lower-fun
  (fn (_ name params body)
    (if (%cc-unsafe-name? name) (%cc-no "name collides with the lane")
      (let ((check (fn (self ps)
                     (if (null? ps) ()
                       (if (%cc-unsafe-name? (first ps))
                         (%cc-no "parameter collides with the lane")
                         (self (rest ps)))))))
        (do (check params)
            (pair (lit fn)
              (pair
                (pair (convert name %symbol)
                  (map (fn (_ p) (convert p %symbol)) params))
                (list
                  (%cc-lower-body (first (rest body)) name params)))))))))

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
                (let ((expr (%cc-lower-fun name params body)))
                  (def prim (compile-asm expr))
                  (set! %cc-natives
                    (pair (pair name prim) %cc-natives))
                  (lit native))))
            (self (rest fs) (pair (pair name verdict) acc))))))
    ; %cc-funs cons-loads, so program order is its reverse
    (go (reverse %cc-funs) ())))

; build: the shared core with the lane switched on -- lower what
; lowers, report each verdict, run main
(def cc-build-run
  (fn (_ src) (%cc-run-core src #t)))
