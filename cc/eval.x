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
(module cc/eval)

(import cc/prims append byte-at byte-len integer->char length list->string
  map mem-make mem-ptr mem-ref-at mem-set-at! reverse string-append
  string-concat string=? substring word-set! x-write)
(import cc/lex cc-lex)
(import cc/parse cc-parse kind-size round-up struct-entry struct-table)

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
(def %cc-builtins (list "putchar" "puts" "printf" "malloc" "free" "exit"
                    "strlen" "strcmp" "strcpy" "memcpy" "memset" "strcat" "strncmp"
                    "memcmp" "strncpy" "strchr" "atoi"
                    "isdigit" "isalpha" "isalnum" "isspace" "isupper" "islower"
                    "toupper" "tolower" "abs"))

; <ctype.h>'s classifications in the C locale, each the ranges of codes it
; takes in: (NAME (LOW . HIGH) ...).  run reads them here and the compiled
; runtime is written from them.
(def ctype-ranges
  (list (list "isdigit" (pair 48 57))
        (list "isalpha" (pair 65 90) (pair 97 122))
        (list "isalnum" (pair 48 57) (pair 65 90) (pair 97 122))
        (list "isspace" (pair 9 13) (pair 32 32))
        (list "isupper" (pair 65 90))
        (list "islower" (pair 97 122))))

; the ranges of the classification NAME, or nil
(def %cc-ctype-find
  (fn (_ name)
    (def go (fn (self es)
              (match
                ((null? es) ())
                ((string=? (first (first es)) name) (rest (first es)))
                (#t (self (rest es))))))
    (go ctype-ranges)))

; 1 when C lies in one of RANGES, else 0
(def %cc-in-ranges
  (fn (_ c ranges)
    (def go
      (fn (self rs)
        (match
          ((null? rs) 0)
          ((if (>= c (first (first rs))) (<= c (rest (first rs))) #f) 1)
          (#t (self (rest rs))))))
    (go ranges)))

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
  (fn (_ k) (if (%cc-kind-decays? k) 8 (kind-size k))))

(def signed?
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
    (match
      ((<= addr 0) (%cc-oops "null or negative address read"))
      ((%cc-bits? kind) (%cc-bits-read addr kind))
      (#t (let ((w (%cc-width kind)))
            (let ((v (%cc-raw-ref addr w)))
              (if (if (signed? kind) (< w 8) #f) (%cc-sext v w) v)))))))

(def %cc-store
  (fn (_ addr v kind)
    (match
      ((<= addr 0) (%cc-oops "null or negative address write"))
      ((%cc-bits? kind) (%cc-bits-write! addr v kind))
      (#t (%cc-raw-set! addr v (%cc-width kind))))))

; A bit-field, (bits C-TYPE BIT WIDTH): WIDTH bits from bit BIT of the unit
; of C-TYPE at the field's address.  A read takes the unit whole and its
; field with the sign of C-TYPE; a write puts V's low WIDTH bits there and
; keeps the unit's others.
(def %cc-bits? (fn (_ k) (if (pair? k) (eq? (first k) (lit bits)) #f)))

(def %cc-bits-read
  (fn (_ addr k)
    (def unit (first (rest k)))
    (def bit (first (rest (rest k))))
    (def width (first (rest (rest (rest k)))))
    (def v (& (>> (%cc-raw-ref addr (kind-size unit)) bit) (- (<< 1 width) 1)))
    (if (if (signed? unit) (>= v (<< 1 (- width 1))) #f) (- v (<< 1 width)) v)))

(def %cc-bits-write!
  (fn (_ addr v k)
    (def unit (first (rest k)))
    (def bit (first (rest (rest k))))
    (def width (first (rest (rest (rest k)))))
    (def size (kind-size unit))
    (def mask (<< (- (<< 1 width) 1) bit))
    (def old (%cc-raw-ref addr size))
    (%cc-raw-set! addr (+ (- old (& old mask)) (& (<< v bit) mask)) size)))

; V converted to KIND, as a cast does: cut to the kind's width and read
; back with its sign.  An address and the 64-bit kinds keep every bit, and
; void keeps nothing.
(def %cc-convert
  (fn (_ v kind)
    (match
      ((eq? kind (lit void)) 0)
      ((%cc-kind-decays? kind) (%cc-oops "a cast to an array or a struct"))
      (#t (let ((w (%cc-width kind)))
            (if (>= w 8) v
              (let ((low (& v (- (<< 1 (* 8 w)) 1))))
                (if (signed? kind) (%cc-sext low w) low))))))))

; stack bytes, zero-filled, eight-aligned; answers the base address
(def %cc-alloca
  (fn (_ n)
    (def size (round-up (if (< n 1) 1 n) 8))
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
    (def size (round-up (if (< n 1) 1 n) 8))
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

; N's digits in BASE, ten or sixteen, N read as unsigned: a number with
; the top bit set is the one 2^64 above it.  Each turn's quotient is taken
; with its top bit shifted out first, so it is never negative -- halved and
; divided by five for ten, shifted four for sixteen.
(def %cc-unsigned->str
  (fn (_ n base)
    (def go
      (fn (self t acc)
        (if (= t 0) acc
          (let ((q (if (= base 16)
                     (& (>> t 4) (- (<< 1 60) 1))
                     (/ (& (>> t 1) (- (<< 1 63) 1)) 5))))
            (def d (- t (* q base)))
            (self q (pair (integer->char (if (< d 10) (+ 48 d) (+ 87 d))) acc))))))
    (if (= n 0) "0" (list->string (go n ())))))

; N's digits in decimal, with its sign; the most negative long's negation
; is itself, which read as unsigned is the right number
(def %cc-int->str
  (fn (_ n)
    (if (< n 0)
      (string-append "-" (%cc-unsigned->str (- 0 n) 10))
      (%cc-unsigned->str n 10))))

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
(def kind-elem
  (fn (_ k)
    (if (not (pair? k)) (lit int)
      (if (eq? (first k) (lit array))
        (if (null? (rest (rest k))) (lit int) (first (rest (rest k))))
        (if (eq? (first k) (lit ptr)) (first (rest k)) (lit int))))))

; a struct's field, (off . kind), by struct name; nil when absent
(def %cc-field
  (fn (_ sname fname)
    (def e (struct-entry sname))
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
    (def s (go (struct-table) ()))
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
    (def t (first node))
    (def address?
      (fn (_ k) (if (pair? k) (if (eq? (first k) (lit ptr)) #t (eq? (first k) (lit array))) #f)))
    (match
      ((eq? t (lit var))
        (let ((e (%cc-find (first (rest node)) env)))
          (if (null? e) (lit int) (rest (rest e)))))
      ((eq? t (lit str)) (list (lit array) (+ (byte-len (first (rest node))) 1) (lit char)))
      ((eq? t (lit dot))
        (let ((f (%cc-field (%cc-struct-name (self (first (rest node)) env)
                              (first (rest (rest node))))
                   (first (rest (rest node))))))
          (if (null? f) (%cc-oops (string-append "no field: " (first (rest (rest node))))) (rest f))))
      ((eq? t (lit arrow))
        (let ((f (%cc-field (%cc-struct-name (kind-elem (self (first (rest node)) env))
                              (first (rest (rest node))))
                   (first (rest (rest node))))))
          (if (null? f) (%cc-oops (string-append "no field: " (first (rest (rest node))))) (rest f))))
      ; A[I] is what A + I points at
      ((eq? t (lit idx))
        (kind-elem (self (list (lit bin) "+" (first (rest node)) (first (rest (rest node)))) env)))
      ((if (eq? t (lit un)) (string=? (first (rest node)) "*") #f)
        (kind-elem (self (first (rest (rest node))) env)))
      ((if (eq? t (lit un)) (string=? (first (rest node)) "&") #f)
        (list (lit ptr) (self (first (rest (rest node))) env)))
      ((eq? t (lit call))
        ; a named call's C type is the one its function declares it returns
        (let ((f (if (null? (%cc-find (first (rest node)) env)) (%cc-fun (first (rest node))) ())))
          (if (null? f) (lit int)
            (let ((r (rest (rest (rest f))))) (if (null? r) (lit int) (first r))))))
      ; + and - with an address on either side of + or the left of -
      ; answer a pointer to what it points at; two addresses subtract to
      ; the count between them, a long
      ((if (eq? t (lit bin)) (if (string=? (first (rest node)) "+") #t (string=? (first (rest node)) "-")) #f)
        (let ((ka (self (first (rest (rest node))) env))
              (kb (self (first (rest (rest (rest node)))) env)))
          (def minus? (string=? (first (rest node)) "-"))
          (def pointer (fn (_ k) (if (eq? (first k) (lit ptr)) k (list (lit ptr) (kind-elem k)))))
          (match
            ((if minus? (if (address? ka) (address? kb) #f) #f) (lit long))
            ((address? ka) (pointer ka))
            ((if minus? #f (address? kb)) (pointer kb))
            (#t (lit int)))))
      ((eq? t (lit cast)) (first (rest node)))
      (#t (lit int)))))

; What `+ 1` moves an expression by: a pointer or an array steps by its
; element's size, and everything else by one.  Only an address scales.
(def %cc-step-of
  (fn (_ node env)
    (let ((k (%cc-kind-of node env)))
      (if (not (pair? k)) 1
        (if (if (eq? (first k) (lit ptr)) #t (eq? (first k) (lit array)))
          (kind-size (kind-elem k))
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
          (let ((ek (kind-elem kind)))
            (def es (kind-size ek))
            (def go (fn (self2 is i)
                      (if (null? is) ()
                        (do (self (+ a (* i es)) ek (first is) env)
                            (self2 (rest is) (+ i 1))))))
            (go items 0))
          (if (if (pair? kind) (eq? (first kind) (lit struct)) #f)
            (let ((e (struct-entry (first (rest kind)))))
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
          (%cc-copy-bytes! a (%cc-eval init env) (kind-size kind))
          (%cc-store a (%cc-eval init env) kind))))))

(def %cc-copy-bytes!
  (fn (_ dst src n)
    (def go (fn (self i)
              (if (>= i n) ()
                (do (%cc-raw-set! (+ dst i) (%cc-raw-ref (+ src i) 1) 1)
                    (self (+ i 1))))))
    (go 0)))

; N bytes at ADDR, each B
(def %cc-fill-bytes!
  (fn (_ addr b n)
    (def go (fn (self i)
              (if (>= i n) ()
                (do (%cc-raw-set! (+ addr i) b 1) (self (+ i 1))))))
    (go 0)))

; the bytes before the NUL at ADDR
(def %cc-strlen
  (fn (_ addr)
    (def go (fn (self i) (if (= (%cc-raw-ref (+ addr i) 1) 0) i (self (+ i 1)))))
    (go 0)))

; the first difference between the bytes at A and B, each read as an
; unsigned char, over at most N of them (all, when N is nil), stopping at
; a NUL when NUL? says; 0 when there is none -- strcmp, strncmp and memcmp
(def %cc-bytes-compare
  (fn (_ a b n nul?)
    (def go
      (fn (self i)
        (if (if (null? n) #f (>= i n)) 0
          (let ((x (%cc-raw-ref (+ a i) 1)) (y (%cc-raw-ref (+ b i) 1)))
            (match
              ((not (= x y)) (- x y))
              ((if nul? (= x 0) #f) 0)
              (#t (self (+ i 1))))))))
    (go 0)))

; N bytes to DST: the string at SRC, then NULs to the end of the N; answers
; DST
(def %cc-strncpy!
  (fn (_ dst src n)
    (def len (%cc-strlen src))
    (def go (fn (self i)
              (if (>= i n) ()
                (do (%cc-raw-set! (+ dst i) (if (< i len) (%cc-raw-ref (+ src i) 1) 0) 1)
                    (self (+ i 1))))))
    (do (go 0) dst)))

; the address of the first C, read as an unsigned char, in the string at S
; -- its NUL included -- or 0
(def %cc-strchr
  (fn (_ s c)
    (def ch (& c 255))
    (def go (fn (self i)
              (let ((b (%cc-raw-ref (+ s i) 1)))
                (match ((= b ch) (+ s i)) ((= b 0) 0) (#t (self (+ i 1)))))))
    (go 0)))

; the int the digits at S spell, after spaces and a sign
(def %cc-atoi
  (fn (_ s)
    (def space? (fn (_ b) (if (= b 32) #t (if (>= b 9) (<= b 13) #f))))
    (def skip (fn (self i) (if (space? (%cc-raw-ref (+ s i) 1)) (self (+ i 1)) i)))
    (def at (skip 0))
    (def c (%cc-raw-ref (+ s at) 1))
    (def minus? (= c 45))
    (def digits
      (fn (self i acc)
        (let ((b (%cc-raw-ref (+ s i) 1)))
          (if (if (>= b 48) (<= b 57) #f) (self (+ i 1) (+ (* acc 10) (- b 48))) acc))))
    (def v (digits (if (if minus? #t (= c 43)) (+ at 1) at) 0))
    (if minus? (- 0 v) v)))

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
        ; A[I] is at A + I, and C lets either be the address
        (if (eq? t (lit idx))
          (%cc-eval (list (lit bin) "+" (first (rest node)) (first (rest (rest node)))) env)
          (if (eq? t (lit dot))
            (let ((f (%cc-field (%cc-struct-name (%cc-kind-of (first (rest node)) env)
                                  (first (rest (rest node))))
                       (first (rest (rest node))))))
              (if (null? f) (%cc-oops (string-append "no field: " (first (rest (rest node)))))
                (+ (%cc-lval (first (rest node)) env) (first f))))
            (if (eq? t (lit arrow))
              (let ((f (%cc-field (%cc-struct-name
                                    (kind-elem (%cc-kind-of (first (rest node)) env))
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
              (let ((ek (kind-elem (%cc-kind-of (first (rest (rest node))) env))))
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
              (do (%cc-copy-bytes! dst v (kind-size k)) dst))
            ; an assignment answers what its place holds after it: the
            ; value converted to the place's C type
            (let ((a (%cc-lval (first (rest node)) env)))
              (do (%cc-store a v k) (%cc-load a k)))))
      (if (eq? t (lit preinc))
        (let ((a (%cc-lval (first (rest node)) env)))
          (def k (%cc-kind-of (first (rest node)) env))
          (let ((v (+ (%cc-load a k) (%cc-step-of (first (rest node)) env))))
            (do (%cc-store a v k) (%cc-load a k))))
      (if (eq? t (lit predec))
        (let ((a (%cc-lval (first (rest node)) env)))
          (def k (%cc-kind-of (first (rest node)) env))
          (let ((v (- (%cc-load a k) (%cc-step-of (first (rest node)) env))))
            (do (%cc-store a v k) (%cc-load a k))))
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
        (kind-size (%cc-kind-of (first (rest node)) env))
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
        (if (eq? t (lit cast))
          (%cc-convert (%cc-eval (first (rest (rest node))) env) (first (rest node)))
          (%cc-oops "unknown expression")))))))))))))))))))))))))

; --- calls and builtins ------------------------------------------------------

; The conversion specification after the % at I in FMT, as printf reads
; it: (NEXT LETTER L? LEFT? ZERO? WIDTH PRECISION), NEXT past the letter.
; The flags - and 0 come first, then a field width (0 when none), a
; precision after a . (() when none; a . alone is 0) and an l for a long.
; () when FMT ends before the letter.
(def printf-conversion
  (fn (_ fmt i)
    (def end (byte-len fmt))
    (def byte (fn (_ j) (if (< j end) (byte-at fmt j) 0)))
    ; (NEXT . VALUE) for the decimal digits from J
    (def number
      (fn (self j v)
        (if (if (>= (byte j) 48) (<= (byte j) 57) #f)
          (self (+ j 1) (+ (* v 10) (- (byte j) 48)))
          (pair j v))))
    (def flags
      (fn (self j left? zero?)
        (match
          ((= (byte j) 45) (self (+ j 1) #t zero?))
          ((= (byte j) 48) (self (+ j 1) left? #t))
          (#t (list j left? zero?)))))
    (def f (flags (+ i 1) #f #f))
    (def w (number (first f) 0))
    (def p (if (= (byte (first w)) 46) (number (+ (first w) 1) 0) (pair (first w) ())))
    (def l? (= (byte (first p)) 108))
    (def at (if l? (+ (first p) 1) (first p)))
    (if (>= at end) ()
      (list (+ at 1) (byte at) l? (first (rest f)) (first (rest (rest f))) (rest w) (rest p)))))

; N bytes of padding, zeros for ZERO? and spaces otherwise
(def printf-pad
  (fn (_ zero? n)
    (def go (fn (self k acc) (if (<= k 0) acc (self (- k 1) (pair (if zero? "0" " ") acc)))))
    (string-concat (go n ()))))

; TEXT, the conversion C's, fitted to FIELD (LEFT? ZERO? WIDTH PRECISION):
; a number's digits made up to the precision with zeros, and none for a
; zero at precision 0; a string cut to the precision; then padded to the
; field width with spaces before, or after for LEFT?, or zeros after the
; sign for ZERO? -- which a number with a precision ignores
(def printf-fit
  (fn (_ c text field)
    (def left? (first field))
    (def width (first (rest (rest field))))
    (def precision (first (rest (rest (rest field)))))
    (def number? (not (if (= c 99) #t (= c 115))))
    (def zero? (if (first (rest field)) (if number? (null? precision) #t) #f))
    (def sign (if number? (if (= (byte-at text 0) 45) "-" "") ""))
    (def digits (substring text (byte-len sign) (byte-len text)))
    (def body
      (match
        ((null? precision) digits)
        ((= c 115) (if (< precision (byte-len digits)) (substring digits 0 precision) digits))
        ((not number?) digits)
        ((if (= precision 0) (string=? digits "0") #f) "")
        (#t (string-append (printf-pad #t (- precision (byte-len digits))) digits))))
    (def pad (- width (+ (byte-len sign) (byte-len body))))
    (match
      (left? (string-append sign body (printf-pad #f pad)))
      (zero? (string-append sign (printf-pad #t pad) body))
      (#t (string-append (printf-pad #f pad) sign body)))))

; printf: %d %i %u %x %c %s and %%, and %ld %li %lu %lx, each with the
; flags - and 0, a field width and a precision; an int's conversion reads
; the argument's low 32 bits, as the compiled one does.  It answers the
; count of bytes written, as C's does.
(def %cc-printf
  (fn (_ args)
    (def fmt (%cc-cstr (first args)))
    (def end (byte-len fmt))
    (def low32 (fn (_ v) (& v 4294967295)))
    ; one conversion's text: its letter C, after an l when L?, of V
    (def convert-one
      (fn (_ c l? v)
        (match
          ((if (= c 100) #t (= c 105))                    ; d i
            (%cc-int->str (if l? v (%cc-sext (low32 v) 4))))
          ((= c 117) (%cc-unsigned->str (if l? v (low32 v)) 10))       ; u
          ((= c 120) (%cc-unsigned->str (if l? v (low32 v)) 16))       ; x
          ((if l? #f (= c 99)) (list->string (list (integer->char (& v 255)))))  ; c
          ((if l? #f (= c 115)) (%cc-cstr v))            ; s
          (#t (%cc-oops "printf: only %d %i %u %x %c %s %% and %ld %li %lu %lx")))))
    (def go
      (fn (self i as acc)
        (match
          ((>= i end)
            (let ((s (string-concat (reverse acc))))
              (do (display s) (byte-len s))))
          ((not (= (byte-at fmt i) 37)) (self (+ i 1) as (pair (substring fmt i (+ i 1)) acc)))
          ((>= (+ i 1) end) (%cc-oops "printf's % at the end of its format"))
          ((= (byte-at fmt (+ i 1)) 37) (self (+ i 2) as (pair "%" acc)))
          (#t
            (let ((spec (printf-conversion fmt i)))
              (if (null? spec) (%cc-oops "printf's % at the end of its format"))
              (if (null? as) (%cc-oops "printf with fewer arguments than conversions"))
              (def c (first (rest spec)))
              (self (first spec) (rest as)
                (pair (printf-fit c (convert-one c (first (rest (rest spec))) (first as))
                        (rest (rest (rest spec))))
                  acc)))))))
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
                (def size (kind-size k))
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
          (let ((vals (%cc-read-bytes v (kind-size ret))))
            (set! %cc-sp saved-sp)
            (let ((tmp (%cc-alloca (kind-size ret))))
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
        ((string=? name "strlen") (%cc-strlen (first args)))
        ((string=? name "strcmp") (%cc-bytes-compare (first args) (first (rest args)) () #t))
        ((string=? name "strncmp")
          (%cc-bytes-compare (first args) (first (rest args)) (first (rest (rest args))) #t))
        ((string=? name "memcmp")
          (%cc-bytes-compare (first args) (first (rest args)) (first (rest (rest args))) #f))
        ((string=? name "strcat")
          (do (%cc-copy-bytes! (+ (first args) (%cc-strlen (first args))) (first (rest args))
                (+ (%cc-strlen (first (rest args))) 1))
              (first args)))
        ((string=? name "strncpy")
          (%cc-strncpy! (first args) (first (rest args)) (first (rest (rest args)))))
        ((string=? name "strchr") (%cc-strchr (first args) (first (rest args))))
        ((string=? name "atoi") (%cc-atoi (first args)))
        ((string=? name "strcpy")
          (do (%cc-copy-bytes! (first args) (first (rest args))
                (+ (%cc-strlen (first (rest args))) 1))
              (first args)))
        ((string=? name "memcpy")
          (do (%cc-copy-bytes! (first args) (first (rest args)) (first (rest (rest args))))
              (first args)))
        ((string=? name "memset")
          (do (%cc-fill-bytes! (first args) (& (first (rest args)) 255) (first (rest (rest args))))
              (first args)))
        ((not (null? (%cc-ctype-find name))) (%cc-in-ranges (first args) (%cc-ctype-find name)))
        ((string=? name "toupper")
          (let ((c (first args))) (if (if (>= c 97) (<= c 122) #f) (- c 32) c)))
        ((string=? name "tolower")
          (let ((c (first args))) (if (if (>= c 65) (<= c 90) #f) (+ c 32) c)))
        ((string=? name "abs") (let ((v (first args))) (if (< v 0) (- 0 v) v)))
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
; A static local's storage, made the first time its declaration is reached
; and kept for the rest of the run: taken from the heap, initialized once.
; (NODE . ADDRESS), the declaration's node found again by identity.
(def %cc-statics ())
; The initializer sees the names of ENV, the block's, and its own.
(def %cc-static-address
  (fn (_ node c-type init env)
    (def go (fn (self es)
              (match
                ((null? es) ())
                ((same? (first (first es)) node) (rest (first es)))
                (#t (self (rest es))))))
    (def found (go %cc-statics))
    (if (not (null? found)) found
      (let ((a (%cc-heap (kind-size c-type))))
        (do (if (null? init) ()
              (%cc-init-into! a c-type init
                (pair (pair (first (rest node)) (pair a c-type)) env)))
            (set! %cc-statics (pair (pair node a) %cc-statics))
            a)))))

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
                (def static? (not (null? (rest (rest (rest (rest item)))))))
                (def a (if static? (%cc-static-address item kind init env)
                         (%cc-alloca (kind-size kind))))
                ; the name is in scope in its own initializer:
                ; struct node *n = malloc(sizeof *n);
                (def inner (pair (pair name (pair a kind)) env))
                (do (if (if static? #t (null? init)) ()
                      (%cc-init-into! a kind init inner))
                    (self (rest items) inner)))
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
      (do (%cc-mem-clear 0 (round-up %cc-hp 8))
          (%cc-mem-clear %cc-sp-min %cc-memsize)))
    (set! %cc-memp (mem-ptr %cc-mem))
    (set! %cc-sp-min %cc-memsize)
    (set! %cc-sp %cc-memsize)
    (set! %cc-hp 16)
    (set! %cc-genv ())
    (set! %cc-funs ())
    (set! %cc-strtab ())
    (set! %cc-statics ())
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
                    (def size (kind-size kind))
                    (def a (%cc-heap size))
                    ; in scope in its own initializer, as a local is
                    (do (set! %cc-genv (pair (pair name (pair a kind)) %cc-genv))
                        (if (null? init) ()
                          (%cc-init-into! a kind init ())))))
                (self (rest items)))))))
    (load! prog)
    (%cc-scan-program! prog)
    (guard (e
             (if (null? %cc-exit-code)
               ; a genuine failure: say it and answer 1, the loud way
               (do (display "cc: run failed: ")
                   (x-write e)
                   (newline)
                   1)
               (& %cc-exit-code 255)))
      (& (%cc-call "main" ()) 255))))

(def cc-run (fn (_ src) (%cc-run-core src)))

(provide cc/eval cc-run ctype-ranges kind-elem printf-conversion printf-fit printf-pad
  signed?)
