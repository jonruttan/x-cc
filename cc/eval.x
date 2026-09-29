; # x-cc -- a C compiler on x-lang
;
; ## cc/eval.x -- running a program
;
; @author [Jon Ruttan](jonruttan@gmail.com)
; @copyright 2026 Jon Ruttan
; @license MIT No Attribution (MIT-0)
;
; Memory is bytes, and an address is a real one, so the C library works on
; what the program hands it.  The program's globals, string literals and
; stack are in one buffer: the literals and globals bump up from its start,
; eight-aligned, and locals live on a stack growing down from its top, so
; &local works.  Anything else -- what malloc answers, the C library's own
; data -- is wherever the library put it.  Every read and write carries the
; width of the type it goes through -- char 1, short 2, int 4, long and
; pointers 8 -- and a signed type sign-extends what it read, since the prim
; answers the bytes zero-extended.  Sizes and offsets are therefore the ones
; /usr/bin/cc counts, padding included.  An address below 4096 is a null
; pointer, and refuses rather than reaching the memory under it.
;
; A call to a function the program does not define is a call into the C
; library, found by name (%cc-libc-call).
(module cc/eval)

(import cc/prims append byte-at byte-len integer->char length list->string
  map mem-make mem-ptr mem-ref-at mem-set-at! ptr-int reverse string-append
  string-concat string=? substring word-set! x-write)
(import cc/lex cc-lex)
(import cc/parse cc-parse kind-size round-up struct-entry struct-table)
(import x/num/float libm-fn)

; The collector is non-moving (the reflection layer rides raw object
; pointers); the base is refreshed every run.
(def %cc-mem ())        ; the buffer string, held so it stays alive
(def %cc-memp ())       ; its ptr object, for the interpreter's words
(def %cc-memsize 131072)   ; bytes of program memory
(def %cc-base 0)        ; the buffer's address
; the W bytes at address A: the prim takes a pointer and an offset, and
; the buffer's pointer and A's distance from it reach A wherever it is
(def %cc-raw-ref
  (fn (_ a w)
    (if (< a 4096) (%cc-oops "a read through a null pointer"))
    (mem-ref-at %cc-memp (- a %cc-base) w)))
(def %cc-raw-set!
  (fn (_ a v w)
    (if (< a 4096) (%cc-oops "a write through a null pointer"))
    (mem-set-at! %cc-memp (- a %cc-base) v w)))
(def %cc-sp 0)          ; stack pointer, grows down
(def %cc-hp 0)          ; the bump for literals and globals, grows up
(def %cc-genv ())       ; ((name addr . kind) ...)
(def %cc-funs ())       ; ((name params . body) ...)
(def %cc-strtab ())     ; ((text . addr) ...), interned
(def %cc-exit-code ())  ; set when exit() raises its sentinel

; Function values: a function's address is an id, never NULL and below the
; memory any program or library is mapped at, handed out the first time a
; function's name is used as a value; a call through a value maps the id back
; to the name and dispatches as a named call would.  The C library's
; functions take ids too.
(def %cc-fun-base 1048576)
(def %cc-fun-ids ())    ; ((name . id) ...)

; The C library's functions on doubles, by how they take and answer them:
; (LABEL NAME ...), LABEL one of the platform's (x/num/float): "d->d" a
; double for a double, "dd->d" a double for two, "s0->d" a double for a
; string.  Each is called in a way the others are not, so run and the
; compiler take these and no other.
(def library-double-fns
  (list
    (pair "d->d"
      (list "sqrt" "cbrt" "sin" "cos" "tan" "asin" "acos" "atan" "sinh" "cosh"
            "tanh" "asinh" "acosh" "atanh" "exp" "exp2" "expm1" "log" "log2"
            "log10" "log1p" "fabs" "floor" "ceil" "round" "trunc" "rint"
            "nearbyint" "erf" "erfc" "tgamma" "lgamma"))
    (pair "dd->d"
      (list "pow" "atan2" "fmod" "hypot" "fmin" "fmax" "fdim" "copysign"
            "remainder" "nextafter"))
    (pair "s0->d" (list "atof"))))

; the LABEL of the library's function on doubles NAME, or nil
(def library-double-label
  (fn (_ name)
    (def go
      (fn (self es)
        (match
          ((null? es) ())
          ((%cc-member-str? name (rest (first es))) (first (first es)))
          (#t (self (rest es))))))
    (go library-double-fns)))

; The C type each of the library's functions answers, as its header
; declares it, for those that do not answer an int: (NAME . C-TYPE).  run
; converts what the library answers to it, and the compiler types a call
; with it.
(def library-c-types
  (let ((each (fn (_ t names) (map (fn (_ n) (pair n t)) names)))
        (cat (fn (self ls) (if (null? ls) () (append (first ls) (self (rest ls)))))))
    (cat
      (list
        (each (list (lit ptr) (lit void))
          (list "malloc" "calloc" "realloc" "memcpy" "memmove" "memset" "memchr"
                "bsearch" "fopen" "fdopen" "freopen" "tmpfile" "popen"))
        (each (list (lit ptr) (lit char))
          (list "strcpy" "strncpy" "strcat" "strncat" "strchr" "strrchr" "strstr"
                "strpbrk" "strtok" "strdup" "strndup" "strerror" "getenv" "fgets"
                "gets" "setlocale" "ctime" "asctime" "realpath" "basename"
                "dirname" "stpcpy"))
        (each (lit ulong)
          (list "strlen" "strnlen" "strspn" "strcspn" "fread" "fwrite" "strtoul"
                "strtoull" "strftime" "wcslen"))
        (each (lit long)
          (list "labs" "llabs" "atol" "atoll" "strtol" "strtoll" "ftell" "read"
                "write" "pread" "pwrite" "lseek" "time" "clock" "getline"
                "getdelim" "sysconf" "random"))
        (each (lit void)
          (list "free" "exit" "_exit" "abort" "qsort" "srand" "srandom" "perror"
                "rewind" "setbuf" "clearerr"))
        (cat (map (fn (_ e) (each (lit double) (rest e))) library-double-fns))))))

(def library-c-type
  (fn (_ name)
    (def go (fn (self es)
              (match
                ((null? es) (lit int))
                ((string=? (first (first es)) name) (rest (first es)))
                (#t (self (rest es))))))
    (go library-c-types)))

; The C library's variadic functions: (NAME V-NAME FIXED), each called
; through its v- form with a va_list after its FIXED arguments.
(def library-variadic
  (list (list "printf" "vprintf" 1) (list "fprintf" "vfprintf" 2)
        (list "sprintf" "vsprintf" 2) (list "snprintf" "vsnprintf" 3)
        (list "dprintf" "vdprintf" 2) (list "scanf" "vscanf" 1)
        (list "fscanf" "vfscanf" 2) (list "sscanf" "vsscanf" 2)))

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
      (if (if (null? (%cc-fun name)) (null? (%cc-libc-fn name)) #f)
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
        (if (null? (%cc-fun n)) (not (null? (%cc-libc-fn n))) #t)))
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

; --- doubles -----------------------------------------------------------------
; A double is its IEEE bits, an integer to everything that moves it; only
; the operations on it know it for a double.  They are the platform's
; (libm-fn): machine code made the first time a run needs each, since a
; state image cannot carry it.

(def %cc-dstubs ())     ; ((key . operation) ...)

; the operation LABEL, or the library's function NAME called as LABEL says
(def %cc-dstub
  (fn (_ label name)
    (def key (if (null? name) label (string-append label name)))
    (def go
      (fn (self es)
        (match
          ((null? es) ())
          ((string=? (first (first es)) key) (rest (first es)))
          (#t (self (rest es))))))
    (def hit (go %cc-dstubs))
    (if (not (null? hit)) hit
      (let ((f (libm-fn (lit %cc-dstub) label name)))
        (do (set! %cc-dstubs (pair (pair key f) %cc-dstubs)) f)))))

(def %cc-d (fn (_ label a b) ((%cc-dstub label ()) a b)))

(def %cc-double? (fn (_ k) (eq? k (lit double))))

(def %cc-top-bit (<< 1 63))
(def %cc-low-63 0x7FFFFFFFFFFFFFFF)   ; every bit but the sign
(def %cc-two-63 0x43E0000000000000)   ; 2^63 as a double
(def %cc-one 0x3FF0000000000000)      ; 1.0

; V of the integer C type K as a double: an unsigned long past the signed
; range converts halved, its last bit kept so it rounds as C does, and
; doubled
(def %cc-int->double
  (fn (_ v k)
    (if (if (eq? k (lit ulong)) (< v 0) #f)
      (let ((h ((%cc-dstub "i->d" ()) (| (& (>> v 1) %cc-low-63) (& v 1)))))
        (%cc-d "d+d" h h))
      ((%cc-dstub "i->d" ()) v))))

; the double V as the integer C type K, toward zero: an unsigned long at
; 2^63 or past it converts less 2^63 and takes the top bit back
(def %cc-double->int
  (fn (_ v k)
    (match
      ((if (eq? k (lit ulong)) (not (%cc-d "d<d" v %cc-two-63)) #f)
        (^ ((%cc-dstub "d->i" ()) (%cc-d "d-d" v %cc-two-63)) %cc-top-bit))
      ((%cc-bits? k) ((%cc-dstub "d->i" ()) v))
      (#t (%cc-convert ((%cc-dstub "d->i" ()) v) k)))))

; V of the C type FROM as the C type TO takes it where C converts, when
; either is a double; any other V is as it was
(def %cc-convert-from
  (fn (_ v from to)
    (match
      ((%cc-double? to) (if (%cc-double? from) v (%cc-int->double v from)))
      ((%cc-double? from) (%cc-double->int v to))
      (#t v))))

; stack bytes, zero-filled, eight-aligned; answers the base address
(def %cc-alloca
  (fn (_ n)
    (def size (round-up (if (< n 1) 1 n) 8))
    (set! %cc-sp (- %cc-sp size))
    (if (< %cc-sp %cc-sp-min) (set! %cc-sp-min %cc-sp) ())
    (if (<= %cc-sp %cc-hp) (%cc-oops "stack overflow")
      (let ((clear (fn (self i)
                     (if (>= i size) ()
                       (do (word-set! %cc-memp (+ (- %cc-sp %cc-base) i) 0)
                           (self (+ i 8)))))))
        (do (clear 0) %cc-sp)))))

; bytes for a literal or a global, zero-filled like the stack's: the raw
; buffer behind the memory is space-filled at birth (0x20 bytes), and a
; global array's uninitialized tail read 0x2020202020202020 until this
; cleared it
(def %cc-heap
  (fn (_ n)
    (def size (round-up (if (< n 1) 1 n) 8))
    (def base %cc-hp)
    (set! %cc-hp (+ %cc-hp size))
    (if (>= %cc-hp %cc-sp) (%cc-oops "program memory exhausted")
      (let ((clear (fn (self i)
                     (if (>= i size) ()
                       (do (word-set! %cc-memp (+ (- base %cc-base) i) 0)
                           (self (+ i 8)))))))
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
        (%cc-put-text! base text n)
        (set! %cc-strtab (pair (pair text base) %cc-strtab))
        base))))

; the first N bytes of TEXT at ADDR, and a NUL after them
(def %cc-put-text!
  (fn (_ addr text n)
    (def go
      (fn (self i)
        (if (>= i n) (%cc-raw-set! (+ addr i) 0 1)
          (do (%cc-raw-set! (+ addr i) (+ 0 (byte-at text i)) 1)
              (self (+ i 1))))))
    (go 0)))

; a C string out of memory (bytes to the NUL)
(def %cc-cstr
  (fn (_ addr)
    (def go
      (fn (self a acc)
        (let ((b (%cc-raw-ref a 1)))
          (if (= b 0) (list->string (reverse acc))
            (self (+ a 1) (pair (integer->char b) acc))))))
    (go addr ())))

; division and remainder, with the evaluator's own report for a zero divisor
(def %cc-div
  (fn (_ a b) (if (= b 0) (%cc-oops "division by zero") (/ a b))))
(def %cc-mod
  (fn (_ a b) (if (= b 0) (%cc-oops "division by zero") (% a b))))

(def %cc-b (fn (_ x) (if x 1 0)))

; is NODE's value true: not zero, and for a double not zero of either sign
(def %cc-test
  (fn (_ node env)
    (def v (%cc-eval node env))
    (def t (first node))
    (if (if (eq? t (lit cmp)) #f (if (eq? t (lit and)) #f (not (eq? t (lit or)))))
      (if (%cc-double? (%cc-kind-of node env))
        (not (= (& v %cc-low-63) 0))
        (not (= v 0)))
      (not (= v 0)))))

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
    (def g (if (null? l) (go %cc-genv) l))
    (if (null? g) (%cc-libc-stream name) g)))

(def %cc-fun
  (fn (_ name)
    (def go
      (fn (self es)
        (if (null? es) ()
          (if (string=? (first (first es)) name)
            (rest (first es))
            (self (rest es))))))
    (go %cc-funs)))

; --- the C library -----------------------------------------------------------
; A call to a function the program does not define goes to the C library,
; opened once for the process and searched by name.  The arguments go as the
; C calling convention passes long integers -- a pointer is a real address,
; and an integer is already in its C type -- seven at most.  A variadic
; function goes through its v- form, the arguments after its fixed ones laid
; out as a va_list: on arm64 macOS that is a pointer to eight-byte slots, and
; on Linux a record whose offsets say the registers are used up, so every
; argument is read from the slots.  The record is the architecture's: on
; x86-64 two offsets and then the slots, on arm64 the slots, the two register
; areas' ends, and then two offsets.  The answer is converted to the C type
; the function's header declares (library-c-type).

(def %cc-ptr-call (prim-ref (lit ptr) (lit call)))
(def %cc-libc ())       ; the library's handle
(def %cc-libc-syms ())  ; ((name . function) ...), looked up once each

; the C library's function or variable NAME, or nil
(def %cc-libc-fn
  (fn (_ name)
    (if (null? %cc-libc) (set! %cc-libc ((prim-ref (lit ffi) (lit dlopen)) () 1)) ())
    (def go
      (fn (self es)
        (match
          ((null? es)
            (let ((f ((prim-ref (lit ffi) (lit dlsym)) %cc-libc name)))
              (do (set! %cc-libc-syms (pair (pair name f) %cc-libc-syms)) f)))
          ((string=? (first (first es)) name) (rest (first es)))
          (#t (self (rest es))))))
    (go %cc-libc-syms)))

; ARGS as a va_list on the stack; answers its address
(def %cc-va-list
  (fn (_ args)
    (def slots (%cc-alloca (* 8 (length args))))
    (def go
      (fn (self as i)
        (if (null? as) ()
          (do (%cc-raw-set! (+ slots (* 8 i)) (first as) 8)
              (self (rest as) (+ i 1))))))
    (go args 0)
    (match
      (os-darwin? slots)
      ; an offset of zero or more says its register area is used up
      (arch-arm64?
        (let ((v (%cc-alloca 32)))
          (do (%cc-raw-set! v slots 8)
              (%cc-raw-set! (+ v 8) 0 8)
              (%cc-raw-set! (+ v 16) 0 8)
              (%cc-raw-set! (+ v 24) 0 4)
              (%cc-raw-set! (+ v 28) 0 4)
              v)))
      (#t
        (let ((v (%cc-alloca 24)))
          (do (%cc-raw-set! v 48 4)
              (%cc-raw-set! (+ v 4) 304 4)
              (%cc-raw-set! (+ v 8) slots 8)
              v))))))

; the first N of a list, and what follows them
(def %cc-take
  (fn (self n xs) (if (<= n 0) () (pair (first xs) (self (- n 1) (rest xs))))))
(def %cc-drop
  (fn (self n xs) (if (<= n 0) xs (self (- n 1) (rest xs)))))

; NAME called with ARGS in the C library
(def %cc-libc-call
  (fn (_ name args)
    (def v
      (let ((go (fn (self es)
                  (match
                    ((null? es) ())
                    ((string=? (first (first es)) name) (rest (first es)))
                    (#t (self (rest es)))))))
        (go library-variadic)))
    (def saved %cc-sp)
    (def all
      (if (null? v) args
        (let ((n (first (rest v))))
          (if (< (length args) n)
            (%cc-oops (string-append name " with too few arguments")))
          (append (%cc-take n args) (list (%cc-va-list (%cc-drop n args)))))))
    (def f (%cc-libc-fn (if (null? v) name (first v))))
    (if (null? f)
      (%cc-oops (string-append "a call to " name
                  ", which neither the program nor the C library defines")))
    (if (> (length all) 7)
      (%cc-oops (string-append "a call to " name " with more than seven arguments")))
    ; a function value is an id, which the library could not call
    (def id?
      (fn (_ x)
        (def go (fn (self es) (if (null? es) #f (if (= (rest (first es)) x) #t (self (rest es))))))
        (go %cc-fun-ids)))
    (def any-id?
      (fn (self as) (if (null? as) #f (if (id? (first as)) #t (self (rest as))))))
    (if (any-id? args)
      (%cc-oops (string-append "a pointer to a function, handed to " name)))
    (def a (fn (_ k) (%cc-drop k all)))
    (def r
      (match
        ((= (length all) 0) (%cc-ptr-call f))
        ((= (length all) 1) (%cc-ptr-call f (first all)))
        ((= (length all) 2) (%cc-ptr-call f (first all) (first (a 1))))
        ((= (length all) 3) (%cc-ptr-call f (first all) (first (a 1)) (first (a 2))))
        ((= (length all) 4)
          (%cc-ptr-call f (first all) (first (a 1)) (first (a 2)) (first (a 3))))
        ((= (length all) 5)
          (%cc-ptr-call f (first all) (first (a 1)) (first (a 2)) (first (a 3))
            (first (a 4))))
        ((= (length all) 6)
          (%cc-ptr-call f (first all) (first (a 1)) (first (a 2)) (first (a 3))
            (first (a 4)) (first (a 5))))
        (#t
          (%cc-ptr-call f (first all) (first (a 1)) (first (a 2)) (first (a 3))
            (first (a 4)) (first (a 5)) (first (a 6))))))
    (set! %cc-sp saved)
    (%cc-convert r (library-c-type name))))

; the C library writes out what its streams hold, so what the program
; printed comes before anything x prints after it
(def %cc-libc-flush!
  (fn (_) (%cc-ptr-call (%cc-libc-fn "fflush") 0)))

; stdin, stdout and stderr: the C library's own variables, each holding its
; FILE pointer -- __stdinp and the like on macOS
(def %cc-libc-stream
  (fn (_ name)
    (if (if (string=? name "stdin") #t (if (string=? name "stdout") #t (string=? name "stderr")))
      (let ((f (%cc-libc-fn
                 (if os-darwin? (string-append "__" (string-append name "p")) name))))
        (if (null? f) () (pair name (pair (ptr-int f) (list (lit ptr) (lit void))))))
      ())))

; --- expressions -------------------------------------------------------------

(def %cc-eval ())
(def %cc-exec ())
(def %cc-exec-block ())

; The C type of what NODE computes, worked out without computing it.
(set! %cc-kind-of
  (fn (self node env)
    (def t (first node))
    (match
      ((eq? t (lit var))
        (let ((e (%cc-find (first (rest node)) env)))
          (if (null? e) (%cc-function-c-type (first (rest node))) (rest (rest e)))))
      ((eq? t (lit num)) (if (null? (rest (rest node))) (lit int) (first (rest (rest node)))))
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
      ((eq? t (lit un))
        (let ((op (first (rest node))))
          (match
            ((string=? op "*") (kind-elem (self (first (rest (rest node))) env)))
            ((string=? op "&") (list (lit ptr) (self (first (rest (rest node))) env)))
            ((string=? op "!") (lit int))
            ; - and ~ answer their operand's C type, promoted
            (#t (promoted-c-type (self (first (rest (rest node))) env))))))
      ; a call through a variable answers what its pointer says the function
      ; answers
      ((if (eq? t (lit call)) (not (null? (%cc-find (first (rest node)) env))) #f)
        (%cc-called-c-type (self (list (lit var) (first (rest node))) env)))
      ((eq? t (lit call))
        ; a named call's C type is the one its function declares it returns,
        ; or the library's when the program has no function of that name
        (let ((f (%cc-fun (first (rest node)))))
          (if (null? f) (library-c-type (first (rest node)))
            (let ((r (rest (rest (rest f))))) (if (null? r) (lit int) (first r))))))
      ((eq? t (lit callx)) (%cc-called-c-type (self (first (rest node)) env)))
      ((eq? t (lit bin))
        (%cc-bin-c-type (first (rest node))
          (self (first (rest (rest node))) env)
          (self (first (rest (rest (rest node)))) env)))
      ; a comparison, && and || answer an int, 1 or 0
      ((eq? t (lit cmp)) (lit int))
      ((eq? t (lit and)) (lit int))
      ((eq? t (lit or)) (lit int))
      ; an assignment, ++ and -- answer their place's C type
      ((eq? t (lit assign)) (self (first (rest node)) env))
      ((eq? t (lit preinc)) (self (first (rest node)) env))
      ((eq? t (lit predec)) (self (first (rest node)) env))
      ((eq? t (lit postinc)) (self (first (rest node)) env))
      ((eq? t (lit postdec)) (self (first (rest node)) env))
      ((eq? t (lit comma)) (self (first (rest (rest node))) env))
      ; the arms meet as a pointer when either is an address, else in the
      ; C type their values meet in
      ((eq? t (lit ternary))
        (let ((ka (self (first (rest (rest node))) env))
              (kb (self (first (rest (rest (rest node)))) env)))
          (match
            ((%cc-address? ka) (%cc-decay ka))
            ((%cc-address? kb) (%cc-decay kb))
            ((%cc-kind-decays? ka) ka)
            (#t (common-c-type ka kb)))))
      ((eq? t (lit szof)) (lit ulong))
      ((eq? t (lit cast)) (first (rest node)))
      (#t (lit int)))))

; the C type of the function NAME's name as a value, a pointer to it,
; (fnptr RET); an int for a name nothing declares
(def %cc-function-c-type
  (fn (_ name)
    (let ((f (%cc-fun name)))
      (if (null? f) (lit int)
        (list (lit fnptr)
          (let ((r (rest (rest (rest f))))) (if (null? r) (lit int) (first r))))))))

; what a call through a value of the C type K answers: the RET of a
; pointer to a function, else an int
(def %cc-called-c-type
  (fn (_ k) (if (if (pair? k) (eq? (first k) (lit fnptr)) #f) (first (rest k)) (lit int))))

; an address: a pointer's value, or an array's, which stands for its first
; element's
(def %cc-address?
  (fn (_ k) (if (pair? k) (if (eq? (first k) (lit ptr)) #t (eq? (first k) (lit array))) #f)))

; the pointer an address K is, to what it points at
(def %cc-decay (fn (_ k) (if (eq? (first k) (lit ptr)) k (list (lit ptr) (kind-elem k)))))

; The C type a binary operator answers on operands of KA and KB: + and -
; with an address on either side of + or the left of - a pointer to what
; it points at, and two addresses subtracted the count between them, a
; long; a shift its left operand's C type, promoted; anything else the C
; type its operands meet in.
(def %cc-bin-c-type
  (fn (_ op ka kb)
    (def minus? (string=? op "-"))
    (match
      ((if minus? #t (string=? op "+"))
        (match
          ((if minus? (if (%cc-address? ka) (%cc-address? kb) #f) #f) (lit long))
          ((%cc-address? ka) (%cc-decay ka))
          ((if minus? #f (%cc-address? kb)) (%cc-decay kb))
          (#t (common-c-type ka kb))))
      ((if (string=? op "<<") #t (string=? op ">>")) (promoted-c-type ka))
      (#t (common-c-type ka kb)))))

; C's integer promotions and usual arithmetic conversions, on LP64: an
; operand narrower than an int -- a char, a short, a bit-field an int
; holds every value of -- is an int, and two operands meet in an unsigned
; long if either is one, else a long, which holds every unsigned int, else
; an unsigned int, else an int -- and in a double before any of them when
; either is one.  The compiled code works in the same C types (cc/gen.x).
(def promoted-c-type
  (fn (_ k)
    (match
      ((eq? k (lit double)) k)
      ((eq? k (lit uint)) k)
      ((eq? k (lit long)) k)
      ((eq? k (lit ulong)) k)
      ((%cc-bits? k)
        (if (if (= (first (rest (rest (rest k)))) 32) (eq? (first (rest k)) (lit uint)) #f)
          (lit uint)
          (lit int)))
      (#t (lit int)))))

(def common-c-type
  (fn (_ ka kb)
    (def a (promoted-c-type ka))
    (def b (promoted-c-type kb))
    (match
      ((if (eq? a (lit double)) #t (eq? b (lit double))) (lit double))
      ((if (eq? a (lit ulong)) #t (eq? b (lit ulong))) (lit ulong))
      ((if (eq? a (lit long)) #t (eq? b (lit long))) (lit long))
      ((if (eq? a (lit uint)) #t (eq? b (lit uint))) (lit uint))
      (#t (lit int)))))

; N / D, or N % D when REM?, both read as unsigned 64-bit values: halved,
; N is not negative, so a signed division gives all but the last bit of
; the quotient, and one comparison in unsigned order settles that
(def unsigned-divide
  (fn (_ n d rem?)
    (def top (<< 1 63))
    ; unsigned order is signed order with the top bit flipped
    (def at-least? (fn (_ a b) (>= (^ a top) (^ b top))))
    (def q
      (if (< d 0)
        (if (at-least? n d) 1 0)
        (let ((q0 (<< (/ (& (>> n 1) (- top 1)) d) 1)))
          (if (at-least? (- n (* q0 d)) d) (+ q0 1) q0))))
    (if rem? (- n (* q d)) q)))

; OP on A and B, of the C types KA and KB, as C does it: both converted to
; the C type they meet in -- a shift's count keeps its own, and the shift
; its left operand's C type -- the operation in that C type, and its
; result in it.  An unsigned long divides, and shifts right, as unsigned.
(def %cc-arith
  (fn (_ op a b ka kb)
    (def shift? (if (string=? op "<<") #t (string=? op ">>")))
    (def k (if shift? (promoted-c-type ka) (common-c-type ka kb)))
    (if (if (%cc-double? k) #t (if shift? (%cc-double? kb) #f))
      (%cc-double-arith op (%cc-convert-from a ka k) (%cc-convert-from b kb k))
      (%cc-int-arith op a b k shift?))))

; OP on the doubles X and Y
(def %cc-double-arith
  (fn (_ op x y)
    (match
      ((string=? op "+") (%cc-d "d+d" x y))
      ((string=? op "-") (%cc-d "d-d" x y))
      ((string=? op "*") (%cc-d "d*d" x y))
      ((string=? op "/") (%cc-d "d/d" x y))
      (#t (%cc-oops (string-append "the operator " op " on a double"))))))

(def %cc-int-arith
  (fn (_ op a b k shift?)
    (def x (%cc-convert a k))
    (def y (if shift? b (%cc-convert b k)))
    (def wide? (eq? k (lit ulong)))
    (%cc-convert
      (match
        ((string=? op "+") (+ x y))
        ((string=? op "-") (- x y))
        ((string=? op "*") (* x y))
        ((string=? op "/") (if wide? (%cc-udiv x y #f) (%cc-div x y)))
        ((string=? op "%") (if wide? (%cc-udiv x y #t) (%cc-mod x y)))
        ((string=? op "&") (& x y))
        ((string=? op "|") (| x y))
        ((string=? op "^") (^ x y))
        ((string=? op "<<") (<< x y))
        ((string=? op ">>")
          (if (if wide? (if (< x 0) (> y 0) #f) #f)
            (& (>> x y) (- (<< 1 (- 64 y)) 1))
            (>> x y)))
        (#t (%cc-oops "unknown operator")))
      k)))

(def %cc-udiv
  (fn (_ a b rem?) (if (= b 0) (%cc-oops "division by zero") (unsigned-divide a b rem?))))

; the comparison OP of A and B in the integer C type K; an unsigned long
; compares with its top bit flipped, which is unsigned order
(def %cc-int-cmp
  (fn (_ op a b k)
    (def flip (if (eq? k (lit ulong)) %cc-top-bit 0))
    (def x (^ (%cc-convert a k) flip))
    (def y (^ (%cc-convert b k) flip))
    (match
      ((string=? op "<") (< x y))
      ((string=? op "<=") (<= x y))
      ((string=? op ">") (> x y))
      ((string=? op ">=") (>= x y))
      ((string=? op "==") (= x y))
      (#t (not (= x y))))))

; the comparison OP of the doubles X and Y: false for a NaN on either side
; but for !=
(def %cc-double-cmp
  (fn (_ op x y)
    (match
      ((string=? op "<") (%cc-d "d<d" x y))
      ((string=? op ">") (%cc-d "d<d" y x))
      ((string=? op "<=") (if (%cc-d "d<d" x y) #t (%cc-d "d=d" x y)))
      ((string=? op ">=") (if (%cc-d "d<d" y x) #t (%cc-d "d=d" x y)))
      ((string=? op "==") (%cc-d "d=d" x y))
      (#t (not (%cc-d "d=d" x y))))))

; + and - with an address among the operands: the count beside an address
; moves it by that many of what it points at, and two addresses subtract to
; the count of those between them
(def %cc-address-arith
  (fn (_ op a b ka kb)
    (match
      ((if (string=? op "-") (if (%cc-address? ka) (%cc-address? kb) #f) #f)
        (%cc-div (- a b) (kind-size (kind-elem ka))))
      ((if (string=? op "-") (%cc-address? ka) #f) (- a (* b (kind-size (kind-elem ka)))))
      ((if (string=? op "+") (%cc-address? ka) #f) (+ a (* b (kind-size (kind-elem ka)))))
      ((string=? op "+") (+ (* a (kind-size (kind-elem kb))) b))
      (#t (%cc-oops (string-append "the operator " op " on an address"))))))

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
          (%cc-store a (%cc-convert-from (%cc-eval init env) (%cc-kind-of init env) kind)
            kind))))))

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
              (def ka (%cc-kind-of (first (rest (rest node))) env))
              (def kb (%cc-kind-of (first (rest (rest (rest node)))) env))
              (if (if (%cc-address? ka) #t (%cc-address? kb))
                (%cc-address-arith op a b ka kb)
                (%cc-arith op a b ka kb)))))
      (if (eq? t (lit cmp))
        (let ((op (first (rest node))))
          (let ((a (%cc-eval (first (rest (rest node))) env)))
            (let ((b (%cc-eval (first (rest (rest (rest node)))) env)))
              (def ka (%cc-kind-of (first (rest (rest node))) env))
              (def kb (%cc-kind-of (first (rest (rest (rest node)))) env))
              ; the operands in the C type they meet in, an address as it is
              (def k (if (if (%cc-address? ka) #t (%cc-address? kb)) (lit long) (common-c-type ka kb)))
              (%cc-b
                (if (%cc-double? k)
                  (%cc-double-cmp op (%cc-convert-from a ka k) (%cc-convert-from b kb k))
                  (%cc-int-cmp op a b k))))))
      (if (eq? t (lit and))
        (%cc-b (if (%cc-test (first (rest node)) env)
                 (%cc-test (first (rest (rest node))) env)
                 #f))
      (if (eq? t (lit or))
        (%cc-b (if (%cc-test (first (rest node)) env)
                 #t
                 (%cc-test (first (rest (rest node))) env)))
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
              ; - and ~ in the operand's C type, promoted; ~v is -v-1.  A
              ; double negates by its sign bit and is false at either zero
              (let ((v (%cc-eval (first (rest (rest node))) env)))
                (def k (promoted-c-type (%cc-kind-of (first (rest (rest node))) env)))
                (match
                  ((%cc-double? k)
                    (match
                      ((string=? op "!") (%cc-b (= (& v %cc-low-63) 0)))
                      ((string=? op "-") (^ v %cc-top-bit))
                      (#t (%cc-oops "the operator ~ on a double"))))
                  ((string=? op "!") (%cc-b (= v 0)))
                  (#t (%cc-convert (if (string=? op "-") (- 0 v) (- (- 0 v) 1)) k)))))))
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
              (do (%cc-store a (%cc-convert-from v (%cc-kind-of (first (rest (rest node))) env) k) k)
                  (%cc-load a k)))))
      (if (eq? t (lit preinc))
        (let ((a (%cc-lval (first (rest node)) env)))
          (def k (%cc-kind-of (first (rest node)) env))
          (let ((v (%cc-step (%cc-load a k) (first (rest node)) k env "+")))
            (do (%cc-store a v k) (%cc-load a k))))
      (if (eq? t (lit predec))
        (let ((a (%cc-lval (first (rest node)) env)))
          (def k (%cc-kind-of (first (rest node)) env))
          (let ((v (%cc-step (%cc-load a k) (first (rest node)) k env "-")))
            (do (%cc-store a v k) (%cc-load a k))))
      (if (eq? t (lit postinc))
        (let ((a (%cc-lval (first (rest node)) env)))
          (def k (%cc-kind-of (first (rest node)) env))
          (let ((v (%cc-load a k)))
            (do (%cc-store a (%cc-step v (first (rest node)) k env "+") k) v)))
      (if (eq? t (lit postdec))
        (let ((a (%cc-lval (first (rest node)) env)))
          (def k (%cc-kind-of (first (rest node)) env))
          (let ((v (%cc-load a k)))
            (do (%cc-store a (%cc-step v (first (rest node)) k env "-") k) v)))
      (if (eq? t (lit ternary))
        ; the arm taken, in the C type the arms meet in
        (let ((arm (if (%cc-test (first (rest node)) env)
                     (first (rest (rest node)))
                     (first (rest (rest (rest node)))))))
          (def v (%cc-eval arm env))
          (def k (%cc-kind-of node env))
          (if (%cc-double? k) (%cc-convert-from v (%cc-kind-of arm env) k) v))
      (if (eq? t (lit comma))
        (do (%cc-eval (first (rest node)) env)
            (%cc-eval (first (rest (rest node))) env))
      (if (eq? t (lit szof))
        (kind-size (%cc-kind-of (first (rest node)) env))
      (if (eq? t (lit call))
        ; a named call -- unless the name is a variable holding a function
        (let ((e (%cc-find (first (rest node)) env)))
          (def name
            (if (null? e) (first (rest node))
              (%cc-fun-name (%cc-load (first (rest e)) (rest (rest e))))))
          (%cc-call name (%cc-args name (first (rest (rest node))) env)))
      (if (eq? t (lit callx))
        ; a call through an expression: (*f)(x) is f(x) -- * on a
        ; function value is the function
        (let ((strip (fn (self n)
                       (if (if (eq? (first n) (lit un)) (string=? (first (rest n)) "*") #f)
                         (self (first (rest (rest n))))
                         n))))
          (def name (%cc-fun-name (%cc-eval (strip (first (rest node))) env)))
          (%cc-call name (%cc-args name (first (rest (rest node))) env)))
        (if (eq? t (lit cast))
          (let ((sub (first (rest (rest node)))) (to (first (rest node))))
            (%cc-convert (%cc-convert-from (%cc-eval sub env) (%cc-kind-of sub env) to) to))
          (%cc-oops "unknown expression")))))))))))))))))))))))))

; V moved one step by OP, + or -, as ++ and -- move the place NODE of C
; type K: an address by what it points at, a double by 1.0
(def %cc-step
  (fn (_ v node k env op)
    (match
      ((%cc-double? k) (%cc-double-arith op v %cc-one))
      ((string=? op "+") (+ v (%cc-step-of node env)))
      (#t (- v (%cc-step-of node env))))))

; The values of a call's argument NODES, each converted to the C type its
; parameter declares, where the function NAME declares one
(def %cc-args
  (fn (_ name nodes env)
    (def f (%cc-fun name))
    (def label (if (null? f) (library-double-label name) ()))
    (def ks
      (match
        ((not (null? f)) (first (rest (rest f))))
        ((null? label) ())
        ((string=? label "d->d") (list (lit double)))
        ((string=? label "dd->d") (list (lit double) (lit double)))
        (#t ())))
    (def go
      (fn (self ns ks)
        (if (null? ns) ()
          (let ((v (%cc-eval (first ns) env)))
            (pair (if (null? ks) v (%cc-convert-from v (%cc-kind-of (first ns) env) (first ks)))
                  (self (rest ns) (if (null? ks) () (rest ks))))))))
    (go nodes ks)))

; --- calls and builtins ------------------------------------------------------

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
        (if (%cc-ctrl? c (lit goto))
          (%cc-oops (string-append "a goto to a label the function does not have: "
                      (first (rest c)))))
        ; (return V C-TYPE): V in the C type the function answers
        (def v
          (if (%cc-ctrl? c (lit return))
            (%cc-convert-from (first (rest c)) (first (rest (rest c))) ret)
            0))
        (if (%cc-struct-kind? ret)
          (let ((vals (%cc-read-bytes v (kind-size ret))))
            (set! %cc-sp saved-sp)
            (let ((tmp (%cc-alloca (kind-size ret))))
              (do (%cc-write-bytes! tmp vals) tmp)))
          (do (set! %cc-sp saved-sp) v)))
      ; exit leaves through the interpreter, once the C library has written
      ; what it holds; everything else is the C library's
      (if (string=? name "exit")
        (do (%cc-libc-flush!)
            (set! %cc-exit-code (first args))
            (Err raise (lit cc-exit) "exit" ()))
        (let ((label (library-double-label name)))
          (if (null? label) (%cc-libc-call name args) (%cc-libm-call label name args)))))))

; NAME, one of the library's functions on doubles, called with ARGS as its
; LABEL says: a double in and out travels as the platform's float, whose
; first is its bits, and atof is strtod with no end pointer
(def %cc-libm-call
  (fn (_ label name args)
    (def n (if (string=? label "dd->d") 2 1))
    (if (not (= (length args) n))
      (%cc-oops (string-append "a call to " name " with the wrong number of arguments")))
    (match
      ((string=? label "d->d") (first ((%cc-dstub label name) (list (first args)))))
      ((string=? label "dd->d")
        (first ((%cc-dstub label name) (list (first args)) (list (first (rest args))))))
      ((< (first args) 4096) (%cc-oops (string-append "a null pointer, handed to " name)))
      (#t ((%cc-dstub label "strtod") (first args))))))

(set! %cc-call %cc-call-interp)

; --- statements --------------------------------------------------------------
; control: () | (return V) | (break) | (continue) | (goto NAME)

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
        (if (%cc-test (first (rest stmt)) env)
          (%cc-exec (first (rest (rest stmt))) env)
          (let ((e (first (rest (rest (rest stmt))))))
            (if (null? e) () (%cc-exec e env))))
      (if (eq? t (lit while))
        (if (%cc-test (first (rest stmt)) env)
          (%cc-while-on stmt env (%cc-exec (first (rest (rest stmt))) env))
          ())
      (if (eq? t (lit do))
        (%cc-do-on stmt env (%cc-exec (first (rest stmt)) env))
      (if (eq? t (lit for))
        (let ((i-n (first (rest stmt))) (c-n (first (rest (rest stmt)))))
          (do (if (null? i-n) () (%cc-eval i-n env))
              (if (if (null? c-n) #t (%cc-test c-n env))
                (%cc-for-on stmt env (%cc-exec (first (rest (rest (rest (rest stmt))))) env))
                ())))
      (if (eq? t (lit goto)) (list (lit goto) (first (rest stmt)))
      (if (eq? t (lit label)) (%cc-exec (first (rest (rest stmt))) env)
      (if (eq? t (lit return))
        (let ((e (first (rest stmt))))
          (if (null? e) (list (lit return) 0 (lit int))
            (list (lit return) (%cc-eval e env) (%cc-kind-of e env))))
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
        (%cc-oops "unknown statement"))))))))))))))))

; The rest of a loop after a pass over its body answered C: a break ends
; it, nothing or a continue goes on to the next pass, as the loop's own
; test and step say, and anything else -- a return, a goto -- leaves it.
(def %cc-while-on
  (fn (self stmt env c)
    (match
      ((%cc-ctrl? c (lit break)) ())
      ((if (null? c) #t (%cc-ctrl? c (lit continue)))
        (if (%cc-test (first (rest stmt)) env)
          (self stmt env (%cc-exec (first (rest (rest stmt))) env))
          ()))
      (#t c))))

(def %cc-do-on
  (fn (self stmt env c)
    (match
      ((%cc-ctrl? c (lit break)) ())
      ((if (null? c) #t (%cc-ctrl? c (lit continue)))
        (if (%cc-test (first (rest (rest stmt))) env)
          (self stmt env (%cc-exec (first (rest stmt)) env))
          ()))
      (#t c))))

(def %cc-for-on
  (fn (self stmt env c)
    (def c-n (first (rest (rest stmt))))
    (def u-n (first (rest (rest (rest stmt)))))
    (match
      ((%cc-ctrl? c (lit break)) ())
      ((if (null? c) #t (%cc-ctrl? c (lit continue)))
        (do (if (null? u-n) () (%cc-eval u-n env))
            (if (if (null? c-n) #t (%cc-test c-n env))
              (self stmt env (%cc-exec (first (rest (rest (rest (rest stmt))))) env))
              ())))
      (#t c))))

; --- goto ----------------------------------------------------------------------
; A goto answers (goto NAME), which passes up out of the statements it is
; in, as a return does, to the block whose statements hold the label.  That
; block goes on from the statement holding it, entered at the label: the
; statements before it in the block are passed over, their declarations
; bound but not initialized, as C leaves them.  A label behind the goto is
; gone back to with the block's names as they are.

; does NODE, a statement or a list of them, hold the label NAME at any depth
(def %cc-has-label?
  (fn (self node name)
    (if (not (pair? node)) #f
      (if (if (eq? (first node) (lit label)) (string=? (first (rest node)) name) #f) #t
        (let ((go (fn (go xs) (if (pair? xs) (if (self (first xs) name) #t (go (rest xs))) #f))))
          (go node))))))

; the tail of ITEMS whose first statement holds the label NAME
(def %cc-label-tail
  (fn (self items name) (if (%cc-has-label? (first items) name) items (self (rest items) name))))

; STMT, entered at the label NAME inside it: its statements before the
; label are passed over, and a loop goes on as its own test and step say
; once the pass that began at the label is done
(def %cc-exec-seek
  (fn (self stmt env name)
    (def t (first stmt))
    (match
      ((eq? t (lit label))
        (if (string=? (first (rest stmt)) name)
          (%cc-exec (first (rest (rest stmt))) env)
          (self (first (rest (rest stmt))) env name)))
      ((eq? t (lit block)) (%cc-exec-items (first (rest stmt)) (first (rest stmt)) env name))
      ((eq? t (lit if))
        (if (%cc-has-label? (first (rest (rest stmt))) name)
          (self (first (rest (rest stmt))) env name)
          (self (first (rest (rest (rest stmt)))) env name)))
      ((eq? t (lit while)) (%cc-while-on stmt env (self (first (rest (rest stmt))) env name)))
      ((eq? t (lit do)) (%cc-do-on stmt env (self (first (rest stmt)) env name)))
      ((eq? t (lit for))
        (%cc-for-on stmt env (self (first (rest (rest (rest (rest stmt))))) env name)))
      ; every clause's statements, as one block
      ((eq? t (lit switch))
        (let ((all (let ((go (fn (go cs) (if (null? cs) () (append (rest (first cs)) (go (rest cs)))))))
                     (go (first (rest (rest stmt)))))))
          (let ((c (%cc-exec-items all all env name)))
            (if (%cc-ctrl? c (lit break)) () c))))
      (#t (%cc-oops "a goto into a statement that holds no label")))))

; A block's statements from ITEMS on, ALL being every one of them.  SEEK,
; when not (), is a label being gone to, in ITEMS; a goto a statement
; answers goes on here when its label is one of the block's.
(def %cc-exec-items
  (fn (self all items env seek)
    (if (null? items) ()
      (let ((item (first items)))
        (match
          ((eq? (first item) (lit decl))
            (self all (rest items) (%cc-declare item env (null? seek)) seek))
          ((if (null? seek) #f (not (%cc-has-label? item seek)))
            (self all (rest items) env seek))
          (#t
            (let ((c (if (null? seek) (%cc-exec item env) (%cc-exec-seek item env seek))))
              (match
                ((null? c) (self all (rest items) env ()))
                ((not (%cc-ctrl? c (lit goto))) c)
                ((%cc-has-label? (rest items) (first (rest c)))
                  (self all (rest items) env (first (rest c))))
                ((%cc-has-label? all (first (rest c)))
                  (self all (%cc-label-tail all (first (rest c))) env (first (rest c))))
                (#t c)))))))))

; ENV with the declaration ITEM's name bound to its storage, initialized
; when INIT?.  The name is in scope in its own initializer:
; struct node *n = malloc(sizeof *n);
(def %cc-declare
  (fn (_ item env init?)
    (def name (first (rest item)))
    (def kind (first (rest (rest item))))
    (def init (first (rest (rest (rest item)))))
    (def static? (not (null? (rest (rest (rest (rest item)))))))
    (def a (if static? (%cc-static-address item kind init env) (%cc-alloca (kind-size kind))))
    (def inner (pair (pair name (pair a kind)) env))
    (do (if (if init? (if static? #f (not (null? init))) #f) (%cc-init-into! a kind init inner) ())
        inner)))

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
  (fn (_ blk env0) (%cc-exec-items (first (rest blk)) (first (rest blk)) env0 ())))

; --- the program -------------------------------------------------------------

(def %cc-sp-min 0)   ; the stack's deepest reach, for the dirty clear

(def %cc-mem-clear
  (fn (self i end)
    (if (>= i end) ()
      (do (word-set! %cc-memp i 0)
          (self (+ i 8) end)))))

(def %cc-run-core
  (fn (_ src input argv)
    ; one vector for the process, and only the dirty ranges cleared per
    ; run (a full clear of the buffer out-allocated the buffer itself; the
    ; replaced; the dirty ranges are hundreds of bytes)
    (if (null? %cc-mem)
      (do (set! %cc-mem (mem-make %cc-memsize))
          (set! %cc-memp (mem-ptr %cc-mem))
          (%cc-mem-clear 0 %cc-memsize))
      (do (%cc-mem-clear 0 (round-up (- %cc-hp %cc-base) 8))
          (%cc-mem-clear (- %cc-sp-min %cc-base) %cc-memsize)))
    (set! %cc-memp (mem-ptr %cc-mem))
    (set! %cc-base (ptr-int %cc-memp))
    (set! %cc-sp-min (+ %cc-base %cc-memsize))
    (set! %cc-sp (+ %cc-base %cc-memsize))
    (set! %cc-hp (+ %cc-base 16))
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
    (def saved (if (null? input) () (%cc-stdin-from! input)))
    (def status
      (guard (e
               (if (null? %cc-exit-code)
                 ; a genuine failure: say it, after what the program
                 ; printed, and answer 1, the loud way
                 (do (%cc-libc-flush!)
                     (display "cc: run failed: ")
                     (x-write e)
                     (newline)
                     1)
                 (& %cc-exit-code 255)))
        (& (%cc-call "main" (%cc-main-args argv)) 255)))
    (%cc-libc-flush!)
    (if (null? saved) () (%cc-stdin-back! saved))
    status))

; The C library's own call, for run's plumbing rather than the program's
(def %cc-libc-do
  (fn (_ name . args)
    (def f (%cc-libc-fn name))
    (match
      ((null? args) (%cc-ptr-call f))
      ((null? (rest args)) (%cc-ptr-call f (first args)))
      ((null? (rest (rest args))) (%cc-ptr-call f (first args) (first (rest args))))
      (#t (%cc-ptr-call f (first args) (first (rest args)) (first (rest (rest args))))))))

; the C library's standard input, cleared of what it held and of its end:
; fpurge on macOS, __fpurge on glibc
(def %cc-stdin-reset!
  (fn (_)
    (def stdin (%cc-raw-ref (first (rest (%cc-libc-stream "stdin"))) 8))
    (%cc-libc-do "clearerr" stdin)
    (%cc-libc-do (if os-darwin? "fpurge" "__fpurge") stdin)))

; TEXT as fd 0 for the program's run, from a temporary file the library
; makes; answers the fd 0 it replaced, kept on another descriptor
(def %cc-stdin-from!
  (fn (_ text)
    (def f (%cc-libc-do "tmpfile"))
    (def fd (%cc-libc-do "fileno" f))
    (%cc-libc-do "write" fd text (byte-len text))
    (%cc-libc-do "lseek" fd 0 0)
    (def saved (%cc-libc-do "dup" 0))
    (%cc-libc-do "dup2" fd 0)
    (%cc-libc-do "fclose" f)
    (%cc-stdin-reset!)
    saved))

; fd 0 back from SAVED, as it was before the run
(def %cc-stdin-back!
  (fn (_ saved)
    (%cc-libc-do "dup2" saved 0)
    (%cc-libc-do "close" saved)
    (%cc-stdin-reset!)))

; main's arguments: none when it takes none, else argc and argv, each of
; ARGV laid into memory as a C string and the pointers to them after, the
; last one null
(def %cc-main-args
  (fn (_ argv)
    (def f (%cc-fun "main"))
    (if (if (null? f) #t (null? (first f))) ()
      (let ((ptrs (map (fn (_ s)
                         (let ((a (%cc-heap (+ (byte-len s) 1))))
                           (do (%cc-put-text! a s (byte-len s)) a)))
                    argv)))
        (def table (%cc-heap (* 8 (+ (length argv) 1))))
        (def go
          (fn (self ps i)
            (if (null? ps) (%cc-raw-set! (+ table (* 8 i)) 0 8)
              (do (%cc-raw-set! (+ table (* 8 i)) (first ps) 8)
                  (self (rest ps) (+ i 1))))))
        (go ptrs 0)
        (list (length argv) table)))))

; SRC's program with INPUT as its standard input and ARGV its arguments,
; the program's name first; with INPUT nil, standard input is fd 0
(def cc-run-with (fn (_ src input argv) (%cc-run-core src input argv)))

(def cc-run (fn (_ src) (%cc-run-core src () (list "a.out"))))

; run's conversions and arithmetic on doubles, which the compiler works a
; global's initializer out with (cc/gen.x)
(def convert-double %cc-convert-from)
(def double-arith %cc-double-arith)

(provide cc/eval cc-run cc-run-with common-c-type convert-double double-arith kind-elem
  library-c-type library-double-fns library-double-label library-variadic
  promoted-c-type signed? unsigned-divide)
