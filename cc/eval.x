; # x-cc -- a C compiler on x-lang
;
; ## cc/eval.x -- running a program
;
; @author [Jon Ruttan](jonruttan@gmail.com)
; @copyright 2026 Jon Ruttan
; @license MIT No Attribution (MIT-0)
;
; Memory is bytes: one buffer, and an address is a byte offset into it (0 is
; NULL and guarded).  Every read and write carries the width of the type it
; goes through -- char 1, short 2, int 4, long and pointers 8 -- and a signed
; type sign-extends what it read, since the prim answers the bytes
; zero-extended.  Sizes and offsets are therefore the ones /usr/bin/cc counts,
; padding included.  Locals live in memory (a stack growing down from the top),
; so &local works; the heap bumps up from past the globals, each allocation
; eight-aligned.

; The collector is non-moving (the reflection layer rides raw object
; pointers); the base is refreshed every run.
(def %cc-mem ())        ; the buffer string, held so it stays alive
(def %cc-memp ())       ; its ptr object, for the interpreter's words
(def %cc-memsize 131072)   ; bytes of program memory
(def %cc-raw-ref (fn (_ i w) (mem-ref-at %cc-memp i w)))
(def %cc-raw-set! (fn (_ i v w) (mem-set-at! %cc-memp i v w)))
(def %cc-sp 0)          ; stack pointer, grows down
(def %cc-hp 0)          ; heap bump, grows up
(def %cc-genv ())       ; ((name addr . kind) ...)
(def %cc-funs ())       ; ((name params . body) ...)
(def %cc-strtab ())     ; ((text . addr) ...), interned
(def %cc-exit-code ())  ; set when exit() raises its sentinel

; Function values: a function's address is an id above every memory address (so
; it is never NULL, never confused with memory), handed out the first time a
; function's name is used as a value; a call through a value maps the id back
; to the name and dispatches as a named call would (native twin first). The
; runtime's builtins take ids too.
(def %cc-fun-base 1048576)
(def %cc-fun-ids ())    ; ((name . id) ...)
(def %cc-builtins (list "putchar" "puts" "printf" "malloc" "free" "exit"))

; is the string S one of the strings in L
(def %cc-member-str?
  (fn (_ s l)
    (def go
      (fn (self es)
        (if (null? es) #f
          (if (string=? (first es) s) #t (self (rest es))))))
    (go l)))

(def %cc-fun-id
  (fn (_ name)
    (def go (fn (self es)
              (if (null? es) ()
                (if (string=? (first (first es)) name) (rest (first es)) (self (rest es))))))
    (def hit (go %cc-fun-ids))
    (if (not (null? hit)) hit
      (if (if (null? (%cc-fun name)) (not (%cc-member-str? name %cc-builtins)) #f)
        (%cc-oops (string-append "undefined: " name))
        (let ((id (+ %cc-fun-base (length %cc-fun-ids))))
          (set! %cc-fun-ids (pair (pair name id) %cc-fun-ids))
          id)))))

; The function names this program uses as VALUES rather than calling: a
; `(var N)` naming a function, which is what `f = sq`, `&sq`, `apply(sq,
; ...)` and an initializer list of them all read as.  Collected from the
; whole parsed program, gdecl initializers included, because a native
; dispatch on a function value has to know every target it might see.
(def %cc-addr-taken ())

(def %cc-scan-program!
  (fn (_ prog)
    (set! %cc-addr-taken ())
    (def named?
      (fn (_ n)
        (if (null? (%cc-fun n)) (%cc-member-str? n %cc-builtins) #t)))
    (def walk
      (fn (self node)
        (if (not (pair? node)) ()
          (do
            (if (if (pair? (first node)) #f (eq? (first node) (lit var)))
              (let ((n (first (rest node))))
                (if (if (named? n) (not (%cc-member-str? n %cc-addr-taken)) #f)
                  (set! %cc-addr-taken (pair n %cc-addr-taken))
                  ()))
              ())
            ; a call's head is a name, not a value; its arguments are
            (let ((kids
                    (if (if (pair? (first node)) #f (eq? (first node) (lit call)))
                      (first (rest (rest node)))
                      (if (pair? (first node)) node (rest node)))))
              (let ((go (fn (self2 xs)
                          (if (null? xs) ()
                            (do (self (first xs)) (self2 (rest xs)))))))
                (go kids)))))))
    ; ids are handed out in program order now, so the compiler can test
    ; against the same number the interpreter will produce
    (def ids
      (fn (self fs)
        (if (null? fs) ()
          (do (%cc-fun-id (first (first fs))) (self (rest fs))))))
    (do (walk prog) (ids (reverse %cc-funs)))))

(def %cc-fun-name
  (fn (_ id)
    (def go (fn (self es)
              (if (null? es) (%cc-oops "call through a value that is not a function")
                (if (= (rest (first es)) id) (first (first es)) (self (rest es))))))
    (go %cc-fun-ids)))

(def %cc-oops
  (fn (_ msg)
    (Err raise (lit cc) (string-append "cc: run: " msg) ())))

; How wide a value of this kind is in memory, and whether it carries a
; sign.  An aggregate never loads -- its name is its address -- so its
; width is only ever the fallback.
(def %cc-width
  (fn (_ k) (if (%cc-kind-decays? k) 8 (%cc-kind-size k))))

(def %cc-signed?
  (fn (_ k)
    (if (pair? k) #f
      (match
        ((eq? k (lit uchar)) #f)
        ((eq? k (lit ushort)) #f)
        ((eq? k (lit uint)) #f)
        ((eq? k (lit ulong)) #f)
        ((eq? k (lit fnptr)) #f)
        (#t #t)))))

; a W-byte read comes back zero-extended; a signed type takes its top bit
; as the sign
(def %cc-sext
  (fn (_ v w)
    (let ((top (<< 1 (- (* 8 w) 1))))
      (if (>= v top) (- v (* 2 top)) v))))

(def %cc-load
  (fn (_ addr kind)
    (if (<= addr 0) (%cc-oops "null or negative address read")
      (let ((w (%cc-width kind)))
        (let ((v (%cc-raw-ref addr w)))
          (if (if (%cc-signed? kind) (< w 8) #f) (%cc-sext v w) v))))))

(def %cc-store
  (fn (_ addr v kind)
    (if (<= addr 0) (%cc-oops "null or negative address write")
      (%cc-raw-set! addr v (%cc-width kind)))))

; stack bytes, zero-filled, eight-aligned; answers the base address
(def %cc-alloca
  (fn (_ n)
    (def size (%cc-round-up (if (< n 1) 1 n) 8))
    (set! %cc-sp (- %cc-sp size))
    (if (< %cc-sp %cc-sp-min) (set! %cc-sp-min %cc-sp) ())
    (if (<= %cc-sp %cc-hp) (%cc-oops "stack overflow")
      (let ((clear (fn (self i)
                     (if (>= i size) ()
                       (do (word-set! %cc-memp (+ %cc-sp i) 0)
                           (self (+ i 8)))))))
        (do (clear 0) %cc-sp)))))

; heap bytes, zero-filled like the stack's: the raw buffer behind the
; memory is space-filled at birth (0x20 bytes), and a global array's
; uninitialized tail read 0x2020202020202020 until this cleared it
(def %cc-heap
  (fn (_ n)
    (def size (%cc-round-up (if (< n 1) 1 n) 8))
    (def base %cc-hp)
    (set! %cc-hp (+ %cc-hp size))
    (if (>= %cc-hp %cc-sp) (%cc-oops "heap exhausted")
      (let ((clear (fn (self i)
                     (if (>= i size) ()
                       (do (word-set! %cc-memp (+ base i) 0) (self (+ i 8)))))))
        (do (clear 0) base)))))

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
            (if (>= i n) (%cc-raw-set! (+ base i) 0 1)
              (do (%cc-raw-set! (+ base i) (+ 0 (byte-at text i)) 1)
                  (self (+ i 1))))))
        (fill 0)
        (set! %cc-strtab (pair (pair text base) %cc-strtab))
        base))))

; a C string out of memory (bytes to the NUL)
(def %cc-cstr
  (fn (_ addr)
    (def go
      (fn (self a acc)
        (let ((b (%cc-raw-ref a 1)))
          (if (= b 0) (list->string (reverse acc))
            (self (+ a 1) (pair (integer->char b) acc))))))
    (go addr ())))

(def %cc-int->str
  (fn (_ n)
    (if (= n 0) "0"
      (let ((go (fn (self t acc)
                  (if (= t 0) acc
                    (self (/ t 10)
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
                      (self (/ t 16)
                        (pair (integer->char
                                (if (< d 10) (+ 48 d) (+ 87 d)))
                          acc)))))))
        (go n ())))))

; division and remainder, with the evaluator's own report for a zero divisor
(def %cc-div
  (fn (_ a b) (if (= b 0) (%cc-oops "division by zero") (/ a b))))
(def %cc-mod
  (fn (_ a b) (if (= b 0) (%cc-oops "division by zero") (% a b))))

(def %cc-tru (fn (_ v) (not (= v 0))))
(def %cc-b (fn (_ x) (if x 1 0)))

; --- kinds -------------------------------------------------------------------
; kind: scalar | (array N) | (array N K) | (struct S) | (ptr K)  (see
; parse.x: the parser owns the struct and typedef tables; they are
; complete before anything runs).  A struct value has no other life
; than its address: an array or struct NAME "decays" to where it lives,
; a field of struct kind answers its address, and assignment into a
; struct-kinded place copies bytes.

(def %cc-kind-decays?
  (fn (_ k)
    (if (not (pair? k)) #f
      (if (eq? (first k) (lit array)) #t (eq? (first k) (lit struct))))))

; the kind an element or pointee has: (array N K) -> K, (ptr K) -> K
(def %cc-kind-elem
  (fn (_ k)
    (if (not (pair? k)) (lit int)
      (if (eq? (first k) (lit array))
        (if (null? (rest (rest k))) (lit int) (first (rest (rest k))))
        (if (eq? (first k) (lit ptr)) (first (rest k)) (lit int))))))

; a struct's field, (off . kind), by struct name; nil when absent
(def %cc-field
  (fn (_ sname fname)
    (def e (%cc-p-struct-entry sname))
    (if (null? e) ()
      (let ((go (fn (self fs)
                  (if (null? fs) ()
                    (if (string=? (first (first fs)) fname)
                      (pair (first (rest (first fs))) (first (rest (rest (first fs)))))
                      (self (rest fs)))))))
        (go (rest (rest e)))))))

; the struct owning field FNAME, when exactly one does -- the fallback
; when a chain's kind is not known (a call's result, an untyped pointer)
(def %cc-struct-with-field
  (fn (_ fname)
    (def go (fn (self es hit)
              (if (null? es) hit
                (let ((f (%cc-field (first (first es)) fname)))
                  (if (null? f) (self (rest es) hit)
                    (if (null? hit) (self (rest es) (first (first es)))
                      (%cc-oops (string-append "ambiguous field: " fname))))))))
    (def s (go %cc-p-structs ()))
    (if (null? s) (%cc-oops (string-append "no struct has a field named " fname)) s)))

(def %cc-struct-name
  (fn (_ k fname)
    (if (if (pair? k) (eq? (first k) (lit struct)) #f)
      (first (rest k))
      (%cc-struct-with-field fname))))

(def %cc-kind-of ())

; --- names -------------------------------------------------------------------
; env: ((name addr . kind) ...) locals, then the globals table.
; kind: scalar | (array N) | (array N K) | (struct S) | (ptr K)

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

(set! %cc-kind-of
  (fn (self node env)
    (let ((t (first node)))
      (if (eq? t (lit var))
        (let ((e (%cc-find (first (rest node)) env)))
          (if (null? e) (lit int) (rest (rest e))))
      (if (eq? t (lit dot))
        (let ((f (%cc-field (%cc-struct-name (self (first (rest node)) env)
                              (first (rest (rest node))))
                   (first (rest (rest node))))))
          (if (null? f) (%cc-oops (string-append "no field: " (first (rest (rest node))))) (rest f)))
      (if (eq? t (lit arrow))
        (let ((f (%cc-field (%cc-struct-name (%cc-kind-elem (self (first (rest node)) env))
                              (first (rest (rest node))))
                   (first (rest (rest node))))))
          (if (null? f) (%cc-oops (string-append "no field: " (first (rest (rest node))))) (rest f)))
      (if (eq? t (lit idx)) (%cc-kind-elem (self (first (rest node)) env))
      (if (if (eq? t (lit un)) (string=? (first (rest node)) "*") #f)
        (%cc-kind-elem (self (first (rest (rest node))) env))
      (if (eq? t (lit call))
        ; a named call's kind is the function's declared return kind
        (let ((f (if (null? (%cc-find (first (rest node)) env)) (%cc-fun (first (rest node))) ())))
          (if (null? f) (lit int)
            (let ((r (rest (rest (rest f))))) (if (null? r) (lit int) (first r)))))
      (if (if (eq? t (lit bin)) (if (string=? (first (rest node)) "+") #t (string=? (first (rest node)) "-")) #f)
        ; pointer arithmetic keeps the pointer's kind
        (let ((ka (self (first (rest (rest node))) env)))
          (if (if (pair? ka) (eq? (first ka) (lit ptr)) #f) ka
            (if (if (pair? ka) (eq? (first ka) (lit array)) #f)
              (list (lit ptr) (%cc-kind-elem ka))
              (lit int))))
        (lit int)))))))))))

; What `+ 1` moves an expression by: a pointer or an array steps by its
; element's size, and everything else by one.  Only an address scales.
(def %cc-step-of
  (fn (_ node env)
    (let ((k (%cc-kind-of node env)))
      (if (not (pair? k)) 1
        (if (if (eq? (first k) (lit ptr)) #t (eq? (first k) (lit array)))
          (%cc-kind-size (%cc-kind-elem k))
          1)))))

; an initializer laid into memory at A by KIND: a braced list fills an
; array's elements or a struct's fields in order (nested lists recurse;
; missing trailing items stay zero); a string fills a char array with
; its bytes and a NUL; a struct value copies; a scalar stores
(def %cc-init-into! ())
(set! %cc-init-into!
  (fn (self a kind init env)
    (if (eq? (first init) (lit initlist))
      (let ((items (first (rest init))))
        (if (if (pair? kind) (eq? (first kind) (lit array)) #f)
          (let ((ek (%cc-kind-elem kind)))
            (def es (%cc-kind-size ek))
            (def go (fn (self2 is i)
                      (if (null? is) ()
                        (do (self (+ a (* i es)) ek (first is) env)
                            (self2 (rest is) (+ i 1))))))
            (go items 0))
          (if (if (pair? kind) (eq? (first kind) (lit struct)) #f)
            (let ((e (%cc-p-struct-entry (first (rest kind)))))
              (def go (fn (self2 is fs)
                        (if (null? is) ()
                          (if (null? fs) (%cc-oops "too many initializers for a struct")
                            (do (self (+ a (first (rest (first fs)))) (first (rest (rest (first fs)))) (first is) env)
                                (self2 (rest is) (rest fs)))))))
              (go items (rest (rest e))))
            (if (null? items) () (self a kind (first items) env)))))
      (if (if (eq? (first init) (lit str)) (if (pair? kind) (eq? (first kind) (lit array)) #f) #f)
        (let ((text (first (rest init))))
          (def n (byte-len text))
          (def go (fn (self2 i)
                    (if (>= i n) (%cc-raw-set! (+ a i) 0 1)
                      (do (%cc-raw-set! (+ a i) (+ 0 (byte-at text i)) 1)
                          (self2 (+ i 1))))))
          (go 0))
        (if (if (pair? kind) (eq? (first kind) (lit struct)) #f)
          (%cc-copy-bytes! a (%cc-eval init env) (%cc-kind-size kind))
          (%cc-store a (%cc-eval init env) kind))))))

(def %cc-copy-bytes!
  (fn (_ dst src n)
    (def go (fn (self i)
              (if (>= i n) ()
                (do (%cc-raw-set! (+ dst i) (%cc-raw-ref (+ src i) 1) 1)
                    (self (+ i 1))))))
    (go 0)))

; bytes out as a list, and back in: a returned struct is read before its
; frame pops -- the caller's fresh slot can be the very bytes the callee's
; first parameter held, and alloca zero-fills them (the bug: `return a;` of
; a mutated struct parameter came back all zero)
(def %cc-read-bytes
  (fn (_ src n)
    (def go (fn (self i acc)
              (if (< i 0) acc (self (- i 1) (pair (%cc-raw-ref (+ src i) 1) acc)))))
    (go (- n 1) ())))
(def %cc-write-bytes!
  (fn (_ dst vals)
    (def go (fn (self i vs)
              (if (null? vs) ()
                (do (%cc-raw-set! (+ dst i) (first vs) 1) (self (+ i 1) (rest vs))))))
    (go 0 vals)))

(def %cc-struct-kind?
  (fn (_ k) (if (pair? k) (eq? (first k) (lit struct)) #f)))

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
            (* (%cc-step-of (first (rest node)) env)
              (%cc-eval (first (rest (rest node))) env)))
          (if (eq? t (lit dot))
            (let ((f (%cc-field (%cc-struct-name (%cc-kind-of (first (rest node)) env)
                                  (first (rest (rest node))))
                       (first (rest (rest node))))))
              (if (null? f) (%cc-oops (string-append "no field: " (first (rest (rest node)))))
                (+ (%cc-lval (first (rest node)) env) (first f))))
            (if (eq? t (lit arrow))
              (let ((f (%cc-field (%cc-struct-name
                                    (%cc-kind-elem (%cc-kind-of (first (rest node)) env))
                                    (first (rest (rest node))))
                         (first (rest (rest node))))))
                (if (null? f) (%cc-oops (string-append "no field: " (first (rest (rest node)))))
                  (+ (%cc-eval (first (rest node)) env) (first f))))
              (if (if (eq? t (lit un))
                    (string=? (first (rest node)) "*") #f)
                (%cc-eval (first (rest (rest node))) env)
                ; a struct returned by value lives at the address the
                ; call answers: make(1, 2).x
                (if (if (eq? t (lit call)) #t (eq? t (lit callx)))
                  (%cc-eval node env)
                  (%cc-oops "not an lvalue"))))))))))

(def %cc-call ())

(set! %cc-eval
  (fn (_ node env)
    (let ((t (first node)))
      (if (eq? t (lit num)) (first (rest node))
      (if (eq? t (lit var))
        (let ((e (%cc-find (first (rest node)) env)))
          (if (null? e)
            ; not a variable: a function's name is its value (or undefined)
            (%cc-fun-id (first (rest node)))
            ; an array or struct NAME decays to its address; a scalar loads
            (if (%cc-kind-decays? (rest (rest e)))
              (first (rest e))
              (%cc-load (first (rest e)) (rest (rest e))))))
      (if (eq? t (lit str)) (%cc-intern (first (rest node)))
      (if (eq? t (lit bin))
        (let ((op (first (rest node))))
          (let ((a (%cc-eval (first (rest (rest node))) env)))
            (let ((b (%cc-eval (first (rest (rest (rest node)))) env)))
              (def sa (%cc-step-of (first (rest (rest node))) env))
              (def sb (%cc-step-of (first (rest (rest (rest node)))) env))
              (if (string=? op "+") (if (> sa 1) (+ a (* b sa)) (if (> sb 1) (+ (* a sb) b) (+ a b)))
              (if (string=? op "-")
                (if (> sa 1)
                  (if (> sb 1) (%cc-div (- a b) sa) (- a (* b sa)))
                  (- a b))
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
            ; *p of a pointer to a struct is the struct: its address
            (let ((a (%cc-eval (first (rest (rest node))) env)))
              (let ((ek (%cc-kind-elem (%cc-kind-of (first (rest (rest node))) env))))
                (if (%cc-kind-decays? ek) a (%cc-load a ek))))
            (if (string=? op "&")
              ; &f of a function name is the function's value
              (let ((sub (first (rest (rest node)))))
                (if (if (eq? (first sub) (lit var)) (null? (%cc-find (first (rest sub)) env)) #f)
                  (%cc-fun-id (first (rest sub)))
                  (%cc-lval sub env)))
              (let ((v (%cc-eval (first (rest (rest node))) env)))
                (if (string=? op "-") (- 0 v)
                  (if (string=? op "!") (%cc-b (= v 0))
                    (- (- 0 v) 1)))))))         ; ~v = -v-1
      (if (eq? t (lit idx))
        (let ((addr (%cc-lval node env)))
          (let ((k (%cc-kind-of node env)))
            (if (%cc-kind-decays? k) addr (%cc-load addr k))))
      (if (if (eq? t (lit dot)) #t (eq? t (lit arrow)))
        (let ((addr (%cc-lval node env)))
          (let ((k (%cc-kind-of node env)))
            (if (%cc-kind-decays? k) addr (%cc-load addr k))))
      (if (eq? t (lit assign))
        (let ((v (%cc-eval (first (rest (rest node))) env)))
          (def k (%cc-kind-of (first (rest node)) env))
          (if (if (pair? k) (eq? (first k) (lit struct)) #f)
            ; a struct-kinded place: copy the bytes from the value's address
            (let ((dst (%cc-lval (first (rest node)) env)))
              (do (%cc-copy-bytes! dst v (%cc-kind-size k)) dst))
            (do (%cc-store (%cc-lval (first (rest node)) env) v k) v)))
      (if (eq? t (lit preinc))
        (let ((a (%cc-lval (first (rest node)) env)))
          (def k (%cc-kind-of (first (rest node)) env))
          (let ((v (+ (%cc-load a k) (%cc-step-of (first (rest node)) env))))
            (do (%cc-store a v k) v)))
      (if (eq? t (lit predec))
        (let ((a (%cc-lval (first (rest node)) env)))
          (def k (%cc-kind-of (first (rest node)) env))
          (let ((v (- (%cc-load a k) (%cc-step-of (first (rest node)) env))))
            (do (%cc-store a v k) v)))
      (if (eq? t (lit postinc))
        (let ((a (%cc-lval (first (rest node)) env)))
          (def k (%cc-kind-of (first (rest node)) env))
          (let ((v (%cc-load a k)))
            (do (%cc-store a (+ v (%cc-step-of (first (rest node)) env)) k) v)))
      (if (eq? t (lit postdec))
        (let ((a (%cc-lval (first (rest node)) env)))
          (def k (%cc-kind-of (first (rest node)) env))
          (let ((v (%cc-load a k)))
            (do (%cc-store a (- v (%cc-step-of (first (rest node)) env)) k) v)))
      (if (eq? t (lit ternary))
        (if (%cc-tru (%cc-eval (first (rest node)) env))
          (%cc-eval (first (rest (rest node))) env)
          (%cc-eval (first (rest (rest (rest node)))) env))
      (if (eq? t (lit comma))
        (do (%cc-eval (first (rest node)) env)
            (%cc-eval (first (rest (rest node))) env))
      (if (eq? t (lit szof))
        (%cc-kind-size (%cc-kind-of (first (rest node)) env))
      (if (eq? t (lit call))
        ; a named call -- unless the name is a variable holding a function
        (let ((e (%cc-find (first (rest node)) env)))
          (%cc-call
            (if (null? e) (first (rest node))
              (%cc-fun-name (%cc-load (first (rest e)) (rest (rest e)))))
            (map (fn (_ a) (%cc-eval a env))
              (first (rest (rest node))))))
      (if (eq? t (lit callx))
        ; a call through an expression: (*f)(x) is f(x) -- * on a
        ; function value is the function
        (let ((strip (fn (self n)
                       (if (if (eq? (first n) (lit un)) (string=? (first (rest n)) "*") #f)
                         (self (first (rest (rest n))))
                         n))))
          (%cc-call (%cc-fun-name (%cc-eval (strip (first (rest node))) env))
            (map (fn (_ a) (%cc-eval a env))
              (first (rest (rest node))))))
        (%cc-oops "unknown expression"))))))))))))))))))))))))

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

(def %cc-call-interp
  (fn (_ name args)
    (def f (%cc-fun name))
    (if (not (null? f))
      ; a user function: params get stack space (a struct parameter its
      ; size, copied from the argument's address), the body runs, a
      ; return control carries the value; the frame frees wholesale.  A
      ; struct returned by value moves out of the popped frame into a
      ; fresh slot in the caller's, which lives until the caller returns
      (let ((saved-sp %cc-sp))
        (def bind
          (fn (self ps ks as env)
            (if (null? ps) env
              (let ((k (if (null? ks) (lit int) (first ks))))
                (def size (%cc-kind-size k))
                (def a (%cc-alloca size))
                (do (if (%cc-struct-kind? k)
                      (if (null? as) () (%cc-copy-bytes! a (first as) size))
                      (%cc-store a (if (null? as) 0 (first as)) k))
                    (self (rest ps) (if (null? ks) () (rest ks))
                      (if (null? as) () (rest as))
                      (pair (pair (first ps) (pair a k)) env)))))))
        ; f is (params body kinds ret)
        (def env (bind (first f) (first (rest (rest f))) args ()))
        (def ret (let ((r (rest (rest (rest f))))) (if (null? r) (lit int) (first r))))
        (def c (%cc-exec-block (first (rest f)) env))
        (def v (if (if (pair? c) (eq? (first c) (lit return)) #f) (first (rest c)) 0))
        (if (%cc-struct-kind? ret)
          (let ((vals (%cc-read-bytes v (%cc-kind-size ret))))
            (set! %cc-sp saved-sp)
            (let ((tmp (%cc-alloca (%cc-kind-size ret))))
              (do (%cc-write-bytes! tmp vals) tmp)))
          (do (set! %cc-sp saved-sp) v)))
      (match
        ((string=? name "putchar")
          (do (display (list->string (list (integer->char (first args)))))
              (first args)))
        ((string=? name "puts")
          (do (display (string-append (%cc-cstr (first args)) "\n")) 0))
        ((string=? name "printf") (%cc-printf args))
        ((string=? name "malloc") (%cc-heap (first args)))
        ((string=? name "free") 0)
        ((string=? name "exit")
          (do (set! %cc-exit-code (first args))
              (Err raise (lit cc-exit) "exit" ())))
        (#t (%cc-oops
              (string-append "no such function: " name)))))))

(set! %cc-call %cc-call-interp)

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
      (if (eq? t (lit switch))
        ; the matched clause and every clause after it run as one block
        ; (fallthrough); a break ends the switch, return and continue
        ; pass through to the enclosing function or loop
        (let ((v (%cc-eval (first (rest stmt)) env)))
          (def clauses (first (rest (rest stmt))))
          (def from
            (let ((go (fn (self cs)
                        (if (null? cs) ()
                          (if (if (null? (first (first cs))) #f
                                (= v (%cc-eval (first (first cs)) env)))
                            cs (self (rest cs)))))))
              (go clauses)))
          (def start
            (if (not (null? from)) from
              (let ((go (fn (self cs)
                          (if (null? cs) ()
                            (if (null? (first (first cs))) cs (self (rest cs)))))))
                (go clauses))))
          (def body
            (let ((go (fn (self cs)
                        (if (null? cs) ()
                          (append (rest (first cs)) (self (rest cs)))))))
              (go start)))
          (let ((c (%cc-exec-block (list (lit block) body) env)))
            (if (%cc-ctrl? c (lit break)) () c)))
      (if (eq? t (lit break)) (list (lit break))
      (if (eq? t (lit continue)) (list (lit continue))
        (%cc-oops "unknown statement"))))))))))))))

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
                (def size (%cc-kind-size kind))
                (def a (%cc-alloca size))
                (do (if (null? init) ()
                      (%cc-init-into! a kind init env))
                    (self (rest items)
                      (pair (pair name (pair a kind)) env))))
              (let ((c (%cc-exec item env)))
                (if (null? c) (self (rest items) env) c)))))))
    (go (first (rest blk)) env0)))

; --- the program -------------------------------------------------------------

(def %cc-sp-min 0)   ; the stack's deepest reach, for the dirty clear

(def %cc-mem-clear
  (fn (self i end)
    (if (>= i end) ()
      (do (word-set! %cc-memp i 0)
          (self (+ i 8) end)))))

(def %cc-run-core
  (fn (_ src)
    ; one vector for the process, and only the dirty ranges cleared per
    ; run (a full clear of the buffer out-allocated the buffer itself; the
    ; replaced; the dirty ranges are hundreds of bytes)
    (if (null? %cc-mem)
      (do (set! %cc-mem (mem-make %cc-memsize))
          (set! %cc-memp (mem-ptr %cc-mem))
          (%cc-mem-clear 0 %cc-memsize))
      (do (%cc-mem-clear 0 (%cc-round-up %cc-hp 8))
          (%cc-mem-clear %cc-sp-min %cc-memsize)))
    (set! %cc-memp (mem-ptr %cc-mem))
    (set! %cc-sp-min %cc-memsize)
    (set! %cc-sp %cc-memsize)
    (set! %cc-hp 16)
    (set! %cc-genv ())
    (set! %cc-funs ())
    (set! %cc-strtab ())
    (set! %cc-fun-ids ())
    (set! %cc-exit-code ())
    (def prog (cc-parse (cc-lex src)))
    (def load!
      (fn (self items)
        (if (null? items) ()
          (let ((item (first items)))
            (do (if (eq? (first item) (lit fun))
                  ; (fun NAME PARAMS BODY KINDS) -> (NAME PARAMS BODY KINDS)
                  (set! %cc-funs (pair (rest item) %cc-funs))
                  (let ((name (first (rest item))))
                    (def kind (first (rest (rest item))))
                    (def init (first (rest (rest (rest item)))))
                    (def size (%cc-kind-size kind))
                    (def a (%cc-heap size))
                    (do (if (null? init) ()
                          (%cc-init-into! a kind init ()))
                        (set! %cc-genv
                          (pair (pair name (pair a kind)) %cc-genv)))))
                (self (rest items)))))))
    (load! prog)
    (%cc-scan-program! prog)
    (guard (e
             (if (null? %cc-exit-code)
               ; a genuine failure: say it and answer 1, the loud way
               (do (display "cc: run failed: ")
                   (%cc-x-write e)
                   (newline)
                   1)
               (& %cc-exit-code 255)))
      (& (%cc-call "main" ()) 255))))

(def cc-run (fn (_ src) (%cc-run-core src)))
