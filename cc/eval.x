; # x-cc -- a C compiler on x-lang
;
; ## cc/eval.x -- running a program
;
; @author [Jon Ruttan](jonruttan@gmail.com)
; @copyright 2026 Jon Ruttan
; @license MIT No Attribution (MIT-0)
;
; THE CELL MODEL: memory is one Vector of cells; every scalar occupies
; ONE cell, sizeof any scalar is 1, pointer arithmetic counts cells.
; Addresses are plain ints (0 is NULL and guarded), so pointers, &, *,
; arrays and malloc all mean what they mean in C -- only the SIZES
; diverge from a byte machine, and byte-accurate sizes are the recorded
; pending.  Locals live in memory (a stack growing DOWN from the top),
; so &local works; the heap bumps UP from past the globals.
;
; C division truncates toward zero -- the tower's / answers rationals,
; so the evaluator owns its own div and mod.

(def %cc-mem ())
; 16K cells: ample for the tool-scale programs this tier runs, and
; small enough to live inside the spec runner's allocation ceiling
; (a 256K vector alone tripped it).  Grows the day a program needs it.
(def %cc-memsize 16384)
(def %cc-sp 0)          ; stack pointer, grows down
(def %cc-hp 0)          ; heap bump, grows up
(def %cc-genv ())       ; ((name addr . kind) ...)
(def %cc-funs ())       ; ((name params . body) ...)
(def %cc-strtab ())     ; ((text . addr) ...), interned
(def %cc-exit-code ())  ; set when exit() raises its sentinel

(def %cc-oops
  (fn (_ msg)
    (Err raise (lit cc) (string-append "cc: run: " msg) ())))

(def %cc-load
  (fn (_ addr)
    (if (<= addr 0) (%cc-oops "null or negative address read")
      (vec-ref %cc-mem addr))))

(def %cc-store
  (fn (_ addr v)
    (if (<= addr 0) (%cc-oops "null or negative address write")
      (vec-set! %cc-mem addr v))))

; stack cells, zero-filled; answers the base address
(def %cc-alloca
  (fn (_ n)
    (set! %cc-sp (- %cc-sp n))
    (if (< %cc-sp %cc-sp-min) (set! %cc-sp-min %cc-sp) ())
    (if (<= %cc-sp %cc-hp) (%cc-oops "stack overflow (cell memory)")
      (let ((clear (fn (self i)
                     (if (>= i n) ()
                       (do (vec-set! %cc-mem (+ %cc-sp i) 0)
                           (self (+ i 1)))))))
        (do (clear 0) %cc-sp)))))

(def %cc-heap
  (fn (_ n)
    (def base %cc-hp)
    (set! %cc-hp (+ %cc-hp n))
    (if (>= %cc-hp %cc-sp) (%cc-oops "heap exhausted (cell memory)")
      base)))

; a C string into memory, interned; answers its address
(def %cc-intern
  (fn (_ text)
    (def hit
      (let ((go (fn (self es)
                  (if (null? es) ()
                    (if (string=? (first (first es)) text)
                      (rest (first es))
                      (self (rest es)))))))
        (go %cc-strtab)))
    (if (not (null? hit)) hit
      (let ((n (byte-len text)))
        (def base (%cc-heap (+ n 1)))
        (def fill
          (fn (self i)
            (if (>= i n) (vec-set! %cc-mem (+ base i) 0)
              (do (vec-set! %cc-mem (+ base i) (+ 0 (byte-at text i)))
                  (self (+ i 1))))))
        (fill 0)
        (set! %cc-strtab (pair (pair text base) %cc-strtab))
        base))))

; a C string OUT of memory (cells to the NUL)
(def %cc-cstr
  (fn (_ addr)
    (def go
      (fn (self a acc)
        (let ((b (%cc-load a)))
          (if (= b 0) (list->string (reverse acc))
            (self (+ a 1) (pair (integer->char b) acc))))))
    (go addr ())))

(def %cc-int->str
  (fn (_ n)
    (if (= n 0) "0"
      (let ((go (fn (self t acc)
                  (if (= t 0) acc
                    (self (/ (- t (% t 10)) 10)
                      (pair (integer->char (+ 48 (% t 10))) acc))))))
        (if (< n 0)
          (string-append "-" (list->string (go (- 0 n) ())))
          (list->string (go n ())))))))

(def %cc-hex->str
  (fn (_ n)
    (if (= n 0) "0"
      (let ((go (fn (self t acc)
                  (if (= t 0) (list->string acc)
                    (let ((d (% t 16)))
                      (self (/ (- t d) 16)
                        (pair (integer->char
                                (if (< d 10) (+ 48 d) (+ 87 d)))
                          acc)))))))
        (go n ())))))

; C's truncating division and its matching remainder
(def %cc-div
  (fn (_ a b)
    (if (= b 0) (%cc-oops "division by zero")
      (let ((q (/ a b)))
        (- q (% q 1))))))
(def %cc-mod
  (fn (_ a b) (- a (* b (%cc-div a b)))))

(def %cc-tru (fn (_ v) (not (= v 0))))
(def %cc-b (fn (_ x) (if x 1 0)))

; --- names -------------------------------------------------------------------
; env: ((name addr . kind) ...) locals, then the globals table.
; kind: scalar | (array N)

(def %cc-find
  (fn (_ name env)
    (def go
      (fn (self es)
        (if (null? es) ()
          (if (string=? (first (first es)) name)
            (first es)
            (self (rest es))))))
    (def l (go env))
    (if (null? l) (go %cc-genv) l)))

(def %cc-fun
  (fn (_ name)
    (def go
      (fn (self es)
        (if (null? es) ()
          (if (string=? (first (first es)) name)
            (rest (first es))
            (self (rest es))))))
    (go %cc-funs)))

; --- expressions -------------------------------------------------------------

(def %cc-eval ())
(def %cc-exec ())
(def %cc-exec-block ())

(def %cc-lval
  (fn (_ node env)
    (let ((t (first node)))
      (if (eq? t (lit var))
        (let ((e (%cc-find (first (rest node)) env)))
          (if (null? e)
            (%cc-oops (string-append "undefined: " (first (rest node))))
            (first (rest e))))
        (if (eq? t (lit idx))
          (+ (%cc-eval (first (rest node)) env)
            (%cc-eval (first (rest (rest node))) env))
          (if (if (eq? t (lit un))
                (string=? (first (rest node)) "*") #f)
            (%cc-eval (first (rest (rest node))) env)
            (%cc-oops "not an lvalue")))))))

(def %cc-call ())

(set! %cc-eval
  (fn (_ node env)
    (let ((t (first node)))
      (if (eq? t (lit num)) (first (rest node))
      (if (eq? t (lit var))
        (let ((e (%cc-find (first (rest node)) env)))
          (if (null? e)
            (%cc-oops (string-append "undefined: " (first (rest node))))
            ; an array NAME decays to its address; a scalar loads
            (if (pair? (rest (rest e)))
              (first (rest e))
              (%cc-load (first (rest e))))))
      (if (eq? t (lit str)) (%cc-intern (first (rest node)))
      (if (eq? t (lit bin))
        (let ((op (first (rest node))))
          (let ((a (%cc-eval (first (rest (rest node))) env)))
            (let ((b (%cc-eval (first (rest (rest (rest node)))) env)))
              (if (string=? op "+") (+ a b)
              (if (string=? op "-") (- a b)
              (if (string=? op "*") (* a b)
              (if (string=? op "/") (%cc-div a b)
              (if (string=? op "%") (%cc-mod a b)
              (if (string=? op "&") (& a b)
              (if (string=? op "|") (| a b)
              (if (string=? op "^") (^ a b)
              (if (string=? op "<<") (<< a b)
              (if (string=? op ">>") (>> a b)
                (%cc-oops "unknown operator"))))))))))))))
      (if (eq? t (lit cmp))
        (let ((op (first (rest node))))
          (let ((a (%cc-eval (first (rest (rest node))) env)))
            (let ((b (%cc-eval (first (rest (rest (rest node)))) env)))
              (%cc-b
                (if (string=? op "<") (< a b)
                  (if (string=? op "<=") (<= a b)
                    (if (string=? op ">") (> a b)
                      (if (string=? op ">=") (>= a b)
                        (if (string=? op "==") (= a b)
                          (not (= a b)))))))))))
      (if (eq? t (lit and))
        (%cc-b (if (%cc-tru (%cc-eval (first (rest node)) env))
                 (%cc-tru (%cc-eval (first (rest (rest node))) env))
                 #f))
      (if (eq? t (lit or))
        (%cc-b (if (%cc-tru (%cc-eval (first (rest node)) env))
                 #t
                 (%cc-tru (%cc-eval (first (rest (rest node))) env))))
      (if (eq? t (lit un))
        (let ((op (first (rest node))))
          (if (string=? op "*")
            (%cc-load (%cc-eval (first (rest (rest node))) env))
            (if (string=? op "&")
              (%cc-lval (first (rest (rest node))) env)
              (let ((v (%cc-eval (first (rest (rest node))) env)))
                (if (string=? op "-") (- 0 v)
                  (if (string=? op "!") (%cc-b (= v 0))
                    (- (- 0 v) 1)))))))         ; ~v = -v-1
      (if (eq? t (lit idx))
        (%cc-load
          (+ (%cc-eval (first (rest node)) env)
            (%cc-eval (first (rest (rest node))) env)))
      (if (eq? t (lit assign))
        (let ((v (%cc-eval (first (rest (rest node))) env)))
          (do (%cc-store (%cc-lval (first (rest node)) env) v) v))
      (if (eq? t (lit preinc))
        (let ((a (%cc-lval (first (rest node)) env)))
          (let ((v (+ (%cc-load a) 1))) (do (%cc-store a v) v)))
      (if (eq? t (lit predec))
        (let ((a (%cc-lval (first (rest node)) env)))
          (let ((v (- (%cc-load a) 1))) (do (%cc-store a v) v)))
      (if (eq? t (lit postinc))
        (let ((a (%cc-lval (first (rest node)) env)))
          (let ((v (%cc-load a))) (do (%cc-store a (+ v 1)) v)))
      (if (eq? t (lit postdec))
        (let ((a (%cc-lval (first (rest node)) env)))
          (let ((v (%cc-load a))) (do (%cc-store a (- v 1)) v)))
      (if (eq? t (lit ternary))
        (if (%cc-tru (%cc-eval (first (rest node)) env))
          (%cc-eval (first (rest (rest node))) env)
          (%cc-eval (first (rest (rest (rest node)))) env))
      (if (eq? t (lit comma))
        (do (%cc-eval (first (rest node)) env)
            (%cc-eval (first (rest (rest node))) env))
      (if (eq? t (lit szof))
        (let ((e (if (eq? (first (first (rest node))) (lit var))
                   (%cc-find (first (rest (first (rest node)))) env)
                   ())))
          (if (if (null? e) #f (pair? (rest (rest e))))
            (first (rest (rest (rest e))))
            1))
      (if (eq? t (lit call))
        (%cc-call (first (rest node))
          (map (fn (_ a) (%cc-eval a env))
            (first (rest (rest node)))))
        (%cc-oops "unknown expression"))))))))))))))))))))))

; --- calls and builtins ------------------------------------------------------

(def %cc-printf
  (fn (_ args)
    (def fmt (%cc-cstr (first args)))
    (def end (byte-len fmt))
    (def go
      (fn (self i as acc)
        (if (>= i end)
          (do (display (string-concat (reverse acc))) 0)
          (let ((b (byte-at fmt i)))
            (if (not (= b 37))                             ; %
              (self (+ i 1) as
                (pair (substring fmt i (+ i 1)) acc))
              (let ((c (byte-at fmt (+ i 1))))
                (if (= c 37)
                  (self (+ i 2) as (pair "%" acc))
                  (if (= c 100)                            ; d
                    (self (+ i 2) (rest as)
                      (pair (%cc-int->str (first as)) acc))
                    (if (= c 99)                           ; c
                      (self (+ i 2) (rest as)
                        (pair (list->string
                                (list (integer->char (first as))))
                          acc))
                      (if (= c 115)                        ; s
                        (self (+ i 2) (rest as)
                          (pair (%cc-cstr (first as)) acc))
                        (if (= c 120)                      ; x
                          (self (+ i 2) (rest as)
                            (pair (%cc-hex->str (first as)) acc))
                          (%cc-oops
                            "printf: only %d %c %s %x %% so far"))))))))))))
    (go 0 (rest args) ())))

(set! %cc-call
  (fn (_ name args)
    (def f (%cc-fun name))
    (if (not (null? f))
      ; a user function: params get stack cells, the body runs, a
      ; return control carries the value; the frame frees wholesale
      (let ((saved-sp %cc-sp))
        (def bind
          (fn (self ps as env)
            (if (null? ps) env
              (let ((a (%cc-alloca 1)))
                (do (%cc-store a (if (null? as) 0 (first as)))
                    (self (rest ps) (if (null? as) () (rest as))
                      (pair (pair (first ps) (pair a (lit scalar)))
                        env)))))))
        (def env (bind (first f) args ()))
        ; f is (params . BLOCK-NODE); exec-block wants the node itself
        (def c (%cc-exec-block (rest f) env))
        (do (set! %cc-sp saved-sp)
            (if (if (pair? c) (eq? (first c) (lit return)) #f)
              (first (rest c))
              0)))
      (if (string=? name "putchar")
        (do (display (list->string (list (integer->char (first args)))))
            (first args))
        (if (string=? name "puts")
          (do (display (string-append (%cc-cstr (first args)) "\n")) 0)
          (if (string=? name "printf")
            (%cc-printf args)
            (if (string=? name "malloc")
              (%cc-heap (first args))
              (if (string=? name "free")
                0
                (if (string=? name "exit")
                  (do (set! %cc-exit-code (first args))
                      (Err raise (lit cc-exit) "exit" ()))
                  (%cc-oops
                    (string-append "no such function: " name)))))))))))

; --- statements --------------------------------------------------------------
; control: () | (return V) | (break) | (continue)

(def %cc-ctrl?
  (fn (_ c k) (if (pair? c) (eq? (first c) k) #f)))

(set! %cc-exec
  (fn (_ stmt env)
    (let ((t (first stmt)))
      (if (eq? t (lit expr))
        (do (%cc-eval (first (rest stmt)) env) ())
      (if (eq? t (lit block))
        (%cc-exec-block stmt env)
      (if (eq? t (lit if))
        (if (%cc-tru (%cc-eval (first (rest stmt)) env))
          (%cc-exec (first (rest (rest stmt))) env)
          (let ((e (first (rest (rest (rest stmt))))))
            (if (null? e) () (%cc-exec e env))))
      (if (eq? t (lit while))
        (let ((loop (fn (self)
                      (if (%cc-tru (%cc-eval (first (rest stmt)) env))
                        (let ((c (%cc-exec (first (rest (rest stmt))) env)))
                          (if (null? c) (self)
                            (if (%cc-ctrl? c (lit break)) ()
                              (if (%cc-ctrl? c (lit continue)) (self)
                                c))))
                        ()))))
          (loop))
      (if (eq? t (lit do))
        (let ((loop (fn (self)
                      (let ((c (%cc-exec (first (rest stmt)) env)))
                        (if (%cc-ctrl? c (lit break)) ()
                          (if (if (null? c) #t (%cc-ctrl? c (lit continue)))
                            (if (%cc-tru
                                  (%cc-eval (first (rest (rest stmt))) env))
                              (self) ())
                            c))))))
          (loop))
      (if (eq? t (lit for))
        (let ((i-n (first (rest stmt))))
          (def c-n (first (rest (rest stmt))))
          (def u-n (first (rest (rest (rest stmt)))))
          (def body (first (rest (rest (rest (rest stmt))))))
          (def loop
            (fn (self)
              (if (if (null? c-n) #t (%cc-tru (%cc-eval c-n env)))
                (let ((c (%cc-exec body env)))
                  (if (%cc-ctrl? c (lit break)) ()
                    (if (if (null? c) #t (%cc-ctrl? c (lit continue)))
                      (do (if (null? u-n) () (%cc-eval u-n env))
                          (self))
                      c)))
                ())))
          (do (if (null? i-n) () (%cc-eval i-n env))
              (loop)))
      (if (eq? t (lit return))
        (list (lit return)
          (if (null? (first (rest stmt))) 0
            (%cc-eval (first (rest stmt)) env)))
      (if (eq? t (lit break)) (list (lit break))
      (if (eq? t (lit continue)) (list (lit continue))
        (%cc-oops "unknown statement")))))))))))))

; a block: declarations extend the env as they pass
(set! %cc-exec-block
  (fn (_ blk env0)
    (def go
      (fn (self items env)
        (if (null? items) ()
          (let ((item (first items)))
            (if (eq? (first item) (lit decl))
              (let ((name (first (rest item))))
                (def kind (first (rest (rest item))))
                (def init (first (rest (rest (rest item)))))
                (def size (if (pair? kind) (first (rest kind)) 1))
                (def a (%cc-alloca size))
                (do (if (null? init) ()
                      (%cc-store a (%cc-eval init env)))
                    (self (rest items)
                      (pair
                        (pair name
                          (pair a (if (pair? kind)
                                    (list (lit array)
                                      (first (rest kind)))
                                    (lit scalar))))
                        env))))
              (let ((c (%cc-exec item env)))
                (if (null? c) (self (rest items) env) c)))))))
    (go (first (rest blk)) env0)))

; --- the program -------------------------------------------------------------

(def %cc-sp-min 0)   ; the stack's deepest reach, for the dirty clear

(def %cc-mem-clear
  (fn (self i end)
    (if (>= i end) ()
      (do (vec-set! %cc-mem i 0)
          (self (+ i 1) end)))))

(def cc-run
  (fn (_ src)
    ; ONE vector for the process, and only the DIRTY ranges cleared per
    ; run (an interpreted 16K full clear out-allocated the vector it
    ; replaced; the dirty ranges are hundreds of cells)
    (if (null? %cc-mem)
      (set! %cc-mem (vec-make %cc-memsize 0))
      (do (%cc-mem-clear 0 %cc-hp)
          (%cc-mem-clear %cc-sp-min %cc-memsize)))
    (set! %cc-sp-min %cc-memsize)
    (set! %cc-sp %cc-memsize)
    (set! %cc-hp 16)
    (set! %cc-genv ())
    (set! %cc-funs ())
    (set! %cc-strtab ())
    (set! %cc-exit-code ())
    (def prog (cc-parse (cc-lex src)))
    (def load!
      (fn (self items)
        (if (null? items) ()
          (let ((item (first items)))
            (do (if (eq? (first item) (lit fun))
                  (set! %cc-funs
                    (pair (pair (first (rest item))
                            (pair (first (rest (rest item)))
                              (first (rest (rest (rest item))))))
                      %cc-funs))
                  (let ((name (first (rest item))))
                    (def kind (first (rest (rest item))))
                    (def init (first (rest (rest (rest item)))))
                    (def size (if (pair? kind) (first (rest kind)) 1))
                    (def a (%cc-heap size))
                    (do (if (null? init) ()
                          (%cc-store a (%cc-eval init ())))
                        (set! %cc-genv
                          (pair
                            (pair name
                              (pair a (if (pair? kind)
                                        (list (lit array)
                                          (first (rest kind)))
                                        (lit scalar))))
                            %cc-genv)))))
                (self (rest items)))))))
    (load! prog)
    (guard (e
             (if (null? %cc-exit-code)
               ; a genuine failure: say it and answer 1, the loud way
               (do (display "cc: run failed: ")
                   (%cc-x-write e)
                   (newline)
                   1)
               (& %cc-exit-code 255)))
      (& (%cc-call "main" ()) 255))))
