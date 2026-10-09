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
; library, found by name (%cc-libc-call).  One of the program's own is
; translated into closures the first time it is called (the run, below).
(module cc/eval)

(import cc/prims append byte-at byte-len length
  map mem-make mem-ptr mem-ref-at mem-set-at! ptr-int reverse string-append
  string-concat string=? substring word-set! x-write fx+ fx- fx* fx< fx<< fx>>)
(import cc/pp cc-lex)
(import cc/parse cc-parse c-type-size plain-char round-up struct-entry struct-table)
(import cc/real convert-real real-arith real-compare real-negate real-step real-stub
  real-zero? real?)
(import x/sys/callback)

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
    (if (fx< a 4096) (%cc-oops "a read through a null pointer"))
    (mem-ref-at %cc-memp (fx- a %cc-base) w)))
(def %cc-raw-set!
  (fn (_ a v w)
    (if (fx< a 4096) (%cc-oops "a write through a null pointer"))
    (mem-set-at! %cc-memp (fx- a %cc-base) v w)))
(def %cc-sp 0)          ; stack pointer, grows down
(def %cc-hp 0)          ; the bump for literals and globals, grows up
(def %cc-genv ())       ; ((name addr . c-type) ...)
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
; string, "ii->d" a double for two integers or pointers.  Each is called in
; a way the others are not, so run and the compiler take these and no other.
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
    (pair "s0->d" (list "atof"))
    (pair "ii->d" (list "strtod"))))

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
        (each (list (lit ptr) plain-char)
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

; How wide a value of this C type is in memory, and whether it carries a
; sign.  An aggregate never loads -- its name is its address -- so its
; width is only ever the fallback.
(def %cc-width
  (fn (_ k) (if (%cc-c-type-decays? k) 8 (c-type-size k))))

(def signed?
  (fn (_ k)
    (if (pair? k) #f
      (match
        ((eq? k (lit uchar)) #f)
        ((eq? k (lit ushort)) #f)
        ((eq? k (lit uint)) #f)
        ((eq? k (lit ulong)) #f)
        ; a float's 32 bits read back as they are
        ((eq? k (lit float)) #f)
        (#t #t)))))

; a W-byte read comes back zero-extended; a signed type takes its top bit
; as the sign
(def %cc-sext
  (fn (_ v w)
    (def top (fx<< 1 (fx- (fx* 8 w) 1)))
    (if (fx< v top) v (fx- v (fx<< top 1)))))

(def %cc-load
  (fn (_ addr c-type)
    (match
      ((<= addr 0) (%cc-oops "null or negative address read"))
      ((%cc-bits? c-type) (%cc-bits-read addr c-type))
      (#t (let ((w (%cc-width c-type)))
            (let ((v (%cc-raw-ref addr w)))
              (if (if (signed? c-type) (< w 8) #f) (%cc-sext v w) v)))))))

(def %cc-store
  (fn (_ addr v c-type)
    (match
      ((<= addr 0) (%cc-oops "null or negative address write"))
      ((%cc-bits? c-type) (%cc-bits-write! addr v c-type))
      (#t (%cc-raw-set! addr v (%cc-width c-type))))))

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
    (def v (& (>> (%cc-raw-ref addr (c-type-size unit)) bit) (- (<< 1 width) 1)))
    (if (if (signed? unit) (>= v (<< 1 (- width 1))) #f) (- v (<< 1 width)) v)))

(def %cc-bits-write!
  (fn (_ addr v k)
    (def unit (first (rest k)))
    (def bit (first (rest (rest k))))
    (def width (first (rest (rest (rest k)))))
    (def size (c-type-size unit))
    (def mask (<< (- (<< 1 width) 1) bit))
    (def old (%cc-raw-ref addr size))
    (%cc-raw-set! addr (+ (- old (& old mask)) (& (<< v bit) mask)) size)))

; V converted to C-TYPE, as a cast does: cut to the C type's width and read
; back with its sign.  An address and the 64-bit C types keep every bit, and
; void keeps nothing.
(def %cc-convert
  (fn (_ v c-type)
    (match
      ((eq? c-type (lit void)) 0)
      ((%cc-c-type-decays? c-type) (%cc-oops "a cast to an array or a struct"))
      (#t (let ((w (%cc-width c-type)))
            (if (>= w 8) v
              (let ((low (& v (- (<< 1 (* 8 w)) 1))))
                (if (signed? c-type) (%cc-sext low w) low))))))))

; --- the real types ------------------------------------------------------------
; V of the C type FROM as the C type TO takes it where C converts, when
; either is real (cc/real.x), an integer TO's answer cut to its width; any
; other V is as it was
(def %cc-convert-from
  (fn (_ v from to)
    (if (if (real? from) #t (real? to))
      (let ((r (convert-real v from to)))
        (if (if (real? to) #t (%cc-bits? to)) r (%cc-convert r to)))
      v)))

; stack bytes, zero-filled, eight-aligned; answers the base address
(def %cc-alloca
  (fn (_ n)
    ; at least one byte, a whole number of words
    (def size (if (fx< n 1) 8 (fx<< (fx>> (fx+ n 7) 3) 3)))
    (set! %cc-sp (fx- %cc-sp size))
    (if (fx< %cc-sp %cc-sp-min) (set! %cc-sp-min %cc-sp) ())
    (if (not (fx< %cc-hp %cc-sp)) (%cc-oops "stack overflow"))
    (def at (fx- %cc-sp %cc-base))
    (def clear (fn (self i)
                 (if (fx< i size)
                   (do (word-set! %cc-memp (fx+ at i) 0)
                       (self (fx+ i 8)))
                   ())))
    (clear 0)
    %cc-sp))

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

; division and remainder, with the evaluator's own report for a zero divisor
(def %cc-div
  (fn (_ a b) (if (= b 0) (%cc-oops "division by zero") (/ a b))))
(def %cc-mod
  (fn (_ a b) (if (= b 0) (%cc-oops "division by zero") (% a b))))

(def %cc-b (fn (_ x) (if x 1 0)))

; --- C types -------------------------------------------------------------------
; C type: scalar | (array N) | (array N K) | (struct S) | (ptr K)  (see
; parse.x: the parser owns the struct and typedef tables; they are
; complete before anything runs).  A struct value has no other life
; than its address: an array or struct NAME "decays" to where it lives,
; a field of struct C type answers its address, and assignment into a
; struct-kinded place copies bytes.

(def %cc-c-type-decays?
  (fn (_ k)
    (if (not (pair? k)) #f
      (if (eq? (first k) (lit array)) #t (eq? (first k) (lit struct))))))

; the C type an element or pointee has: (array N K) -> K, (ptr K) -> K
(def c-type-elem
  (fn (_ k)
    (if (not (pair? k)) (lit int)
      (if (eq? (first k) (lit array))
        (if (null? (rest (rest k))) (lit int) (first (rest (rest k))))
        (if (eq? (first k) (lit ptr)) (first (rest k)) (lit int))))))

; a struct's field, (off . c-type), by struct name; nil when absent
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
; when a chain's C type is not known (a call's result, an untyped pointer)
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

; --- names -------------------------------------------------------------------
; env: ((name addr . c-type) ...) locals, then the globals table.
; C type: scalar | (array N) | (array N K) | (struct S) | (ptr K)

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

; how many fixed parameters a variadic function with PARAMS has, the ones
; before its "...", else nil
(def %cc-fixed
  (fn (_ params)
    (def go
      (fn (self ps n)
        (match
          ((null? ps) ())
          ((null? (rest ps)) (if (string=? (first ps) "...") n ()))
          (#t (self (rest ps) (+ n 1))))))
    (go params 0)))

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

; A function of the program's, handed to the C library -- qsort's comparator
; -- goes as a callback (x/sys/callback): a native function the library calls
; with the arguments in the C calling convention, each converted to its
; parameter's C type, which runs the function here and answers its integer
; value.  One callback a function, made the first time it is handed over and
; kept until the next run.
(def %cc-callbacks ())   ; ((name . callback) ...)

(def %cc-callbacks-free!
  (fn (_)
    (def go (fn (self es) (if (null? es) () (do ((rest (first es)) free!) (self (rest es))))))
    (go %cc-callbacks)
    (set! %cc-callbacks ())))

; the address of a callback calling the program's function NAME, which is
; handed to the library's function TO
(def %cc-callback-address
  (fn (_ name to)
    (def go (fn (self es)
              (match
                ((null? es) ())
                ((string=? (first (first es)) name) (rest (first es)))
                (#t (self (rest es))))))
    (def hit (go %cc-callbacks))
    (if (not (null? hit)) (hit address)
      (let ((f (%cc-fun name)))
        ; f is (params body c-types ret)
        (def ks (first (rest (rest f))))
        (def ret (let ((r (rest (rest (rest f))))) (if (null? r) (lit int) (first r))))
        (def no (fn (_ what) (%cc-oops (string-append what ", handed to " to))))
        (if (not (null? (%cc-fixed (first f)))) (no (string-append "the variadic function " name)))
        (if (> (length ks) 4) (no (string-append name ", which takes more than four arguments")))
        (def plain? (fn (_ k) (if (real? k) #f (not (%cc-struct-c-type? k)))))
        (def all-plain? (fn (self l) (if (null? l) #t (if (plain? (first l)) (self (rest l)) #f))))
        (if (not (if (all-plain? ks) (if (eq? ret (lit void)) #t (plain? ret)) #f))
          (no (string-append name ", which takes or answers a double, a float or a struct")))
        (def cb
          (Callback make
            (fn (_ . as)
              (%cc-call name (map (fn (_ p) (%cc-convert (first p) (rest p))) (%cc-zip as ks))))
            (length ks)))
        (set! %cc-callbacks (pair (pair name cb) %cc-callbacks))
        (cb address)))))

; the pairs (A . B) of two lists, as far as the shorter goes
(def %cc-zip
  (fn (self as bs)
    (if (if (null? as) #t (null? bs)) ()
      (pair (pair (first as) (first bs)) (self (rest as) (rest bs))))))

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
    (def given
      (if (null? v) args
        (let ((n (first (rest v))))
          (if (< (length args) n)
            (%cc-oops (string-append name " with too few arguments")))
          (append (%cc-take n args) (list (%cc-va-list (%cc-drop n args)))))))
    (def f (%cc-libc-fn (if (null? v) name (first v))))
    (if (null? f)
      (%cc-oops (string-append "a call to " name
                  ", which neither the program nor the C library defines")))
    (if (> (length given) 7)
      (%cc-oops (string-append "a call to " name " with more than seven arguments")))
    ; a function value is an id, which the library is handed as a callback's
    ; address instead (%cc-callback-address)
    (def id-name
      (fn (_ x)
        (def go (fn (self es)
                  (match
                    ((null? es) ())
                    ((= (rest (first es)) x) (first (first es)))
                    (#t (self (rest es))))))
        (go %cc-fun-ids)))
    (def all
      (map (fn (_ x)
             (let ((n (id-name x)))
               (if (null? n) x (%cc-callback-address n name))))
        given))
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

; --- C types of expressions ---------------------------------------------------

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
(def %cc-decay (fn (_ k) (if (eq? (first k) (lit ptr)) k (list (lit ptr) (c-type-elem k)))))

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
; either is one, else in a float when either is one.  The compiled code works
; in the same C types (cc/gen.x).
(def promoted-c-type
  (fn (_ k)
    (match
      ((eq? k (lit double)) k)
      ((eq? k (lit float)) k)
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
      ((if (eq? a (lit float)) #t (eq? b (lit float))) (lit float))
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


(def %cc-udiv
  (fn (_ a b rem?) (if (= b 0) (%cc-oops "division by zero") (unsigned-divide a b rem?))))


(def %cc-copy-bytes!
  (fn (_ dst src n)
    (def go (fn (self i)
              (if (fx< i n)
                (do (%cc-raw-set! (fx+ dst i) (%cc-raw-ref (fx+ src i) 1) 1)
                    (self (fx+ i 1)))
                ())))
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

(def %cc-struct-c-type?
  (fn (_ k) (if (pair? k) (eq? (first k) (lit struct)) #f)))


; NAME, one of the library's functions on doubles, called with ARGS as its
; LABEL says: a double in and out travels as the platform's float, whose
; first is its bits, and atof is strtod with no end pointer
(def %cc-libm-call
  (fn (_ label name args)
    (def n (if (if (string=? label "dd->d") #t (string=? label "ii->d")) 2 1))
    (if (not (= (length args) n))
      (%cc-oops (string-append "a call to " name " with the wrong number of arguments")))
    (match
      ((string=? label "d->d") (first ((real-stub label name) (list (first args)))))
      ((string=? label "dd->d")
        (first ((real-stub label name) (list (first args)) (list (first (rest args))))))
      ((< (first args) 4096) (%cc-oops (string-append "a null pointer, handed to " name)))
      ; strtod with its end pointer, which may be null
      ((string=? label "ii->d") ((real-stub label name) (first args) (first (rest args))))
      (#t ((real-stub label "strtod") (first args))))))


; --- the run: each function translated into closures ----------------------------
; A function is translated the first time it is called, and the translation
; kept for the run: each expression becomes a closure of the frame's address
; that answers its value, each statement one that answers how control leaves
; it, with every C type, conversion, width and place settled in the
; translating, not each time it runs.  A function's locals each have a slot
; at a fixed offset in one frame, made when it is called; the parser gave
; every local of a function a name of its own (%cc-p-scope), so one table
; of slots a function holds them all.  A name is looked up as the
; translation reaches it: a local in scope, else a global, a stream of the C
; library, or a function.
;
; Control: () | (break) | (continue) | (return V C-TYPE) | (goto NAME).

(def %cc-brk (list (lit break)))
(def %cc-cnt (list (lit continue)))
(def %cc-ret0 (list (lit return) 0 (lit int)))

(def %cc-ctrl?
  (fn (_ c k) (if (pair? c) (eq? (first c) k) #f)))

(def %cc-id (fn (_ v) v))

; the function being translated: its names in scope, ((NAME . PLACE) ...),
; a PLACE (local OFF . C-TYPE) or (global ADDRESS . C-TYPE), and its frame's
; size so far
(def %cc-k-locals ())
(def %cc-k-size 0)

; a slot in the frame for NAME of C type K, in scope from here: its offset
(def %cc-k-slot!
  (fn (_ name k)
    (def off (round-up %cc-k-size 8))
    (set! %cc-k-size (+ off (round-up (c-type-size k) 8)))
    (set! %cc-k-locals (pair (pair name (pair (lit local) (pair off k))) %cc-k-locals))
    off))

; NAME's place: a local in scope, a global, a stream of the C library, or nil
(def %cc-k-place
  (fn (_ name)
    (def go (fn (self es)
              (match
                ((null? es) ())
                ((string=? (first (first es)) name) (rest (first es)))
                (#t (self (rest es))))))
    (def l (go %cc-k-locals))
    (if (not (null? l)) l
      (let ((g (%cc-find name ())))
        (if (null? g) () (pair (lit global) (rest g)))))))

; --- loads, stores and conversions, settled by C type --------------------------

; a read of a K at an address
(def %cc-k-load
  (fn (_ k)
    (if (%cc-bits? k) (fn (_ a) (%cc-bits-read a k))
      (let ((w (%cc-width k)))
        (if (if (signed? k) (< w 8) #f)
          (fn (_ a) (%cc-sext (%cc-raw-ref a w) w))
          (fn (_ a) (%cc-raw-ref a w)))))))

; a write of a K at an address
(def %cc-k-store
  (fn (_ k)
    (if (%cc-bits? k) (fn (_ a v) (%cc-bits-write! a v k))
      (let ((w (%cc-width k)))
        (fn (_ a v) (%cc-raw-set! a v w))))))

; V converted to K as a cast does (%cc-convert)
(def %cc-k-conv
  (fn (_ k)
    (match
      ((eq? k (lit void)) (fn (_ v) 0))
      ((%cc-c-type-decays? k) (fn (_ v) (%cc-oops "a cast to an array or a struct")))
      (#t (let ((w (%cc-width k)))
            (if (>= w 8) %cc-id
              (let ((m (- (<< 1 (* 8 w)) 1)))
                (if (signed? k)
                  (fn (_ v) (%cc-sext (& v m) w))
                  (fn (_ v) (& v m))))))))))

; V of the C type FROM as TO takes it (%cc-convert-from)
(def %cc-k-from
  (fn (_ from to)
    (if (if (real? from) #t (real? to))
      (if (if (real? to) #t (%cc-bits? to))
        (fn (_ v) (convert-real v from to))
        (let ((c (%cc-k-conv to))) (fn (_ v) (c (convert-real v from to)))))
      %cc-id)))

; --- expressions ---------------------------------------------------------------
; (%cc-k-expr NODE): (C-TYPE . VALUE), VALUE a closure of the frame's address

(def %cc-k-expr ())
(def %cc-k-lval ())
(def %cc-k-call ())

(def %cc-k-a (fn (_ node) (first (rest node))))
(def %cc-k-b (fn (_ node) (first (rest (rest node)))))
(def %cc-k-c (fn (_ node) (first (rest (rest (rest node))))))

; is NODE's value true: not zero, and for a real value not zero of either sign
(def %cc-k-test
  (fn (_ node)
    (def e (%cc-k-expr node))
    (def f (rest e))
    (def t (first node))
    (if (if (eq? t (lit cmp)) #f (if (eq? t (lit and)) #f (not (eq? t (lit or)))))
      (let ((k (first e)))
        (if (real? k) (fn (_ fp) (not (real-zero? (f fp) k))) (fn (_ fp) (not (= (f fp) 0)))))
      (fn (_ fp) (not (= (f fp) 0))))))

; a name: a scalar loads, an array or a struct is its address, and a
; function's name is its value
(def %cc-k-var
  (fn (_ name)
    (def p (%cc-k-place name))
    (if (null? p)
      (let ((id (%cc-fun-id name))) (pair (%cc-function-c-type name) (fn (_ fp) id)))
      (let ((k (rest (rest p))) (at (first (rest p))))
        (def ld (%cc-k-load k))
        (pair k
          (match
            ((eq? (first p) (lit local))
              (if (%cc-c-type-decays? k) (fn (_ fp) (+ fp at)) (fn (_ fp) (ld (+ fp at)))))
            ((%cc-c-type-decays? k) (fn (_ fp) at))
            (#t (fn (_ fp) (ld at)))))))))

; + and - with an address among the operands: the count moves it by what it
; points at, and two addresses subtract to the count between them
(def %cc-k-addr-arith
  (fn (_ op fa fb ka kb)
    (match
      ((if (string=? op "-") (if (%cc-address? ka) (%cc-address? kb) #f) #f)
        (let ((es (c-type-size (c-type-elem ka))))
          (fn (_ fp) (def x (fa fp)) (%cc-div (fx- x (fb fp)) es))))
      ((if (string=? op "-") (%cc-address? ka) #f)
        (let ((es (c-type-size (c-type-elem ka))))
          (fn (_ fp) (def x (fa fp)) (fx- x (fx* (fb fp) es)))))
      ((if (string=? op "+") (%cc-address? ka) #f)
        (let ((es (c-type-size (c-type-elem ka))))
          (fn (_ fp) (def x (fa fp)) (fx+ x (fx* (fb fp) es)))))
      ((string=? op "+")
        (let ((es (c-type-size (c-type-elem kb))))
          (fn (_ fp) (def x (fa fp)) (fx+ (fx* x es) (fb fp)))))
      (#t (fn (_ fp) (%cc-oops (string-append "the operator " op " on an address")))))))

; OP on two integers converted to K: a closure of the two
(def %cc-k-int-op
  (fn (_ op k)
    (def wide? (eq? k (lit ulong)))
    (match
      ; a long's sum, difference and product wrap at 64 bits, as C's do;
      ; a narrower type is cut to its width after
      ((string=? op "+") fx+)
      ((string=? op "-") fx-)
      ((string=? op "*") fx*)
      ((string=? op "/") (if wide? (fn (_ x y) (%cc-udiv x y #f)) (fn (_ x y) (%cc-div x y))))
      ((string=? op "%") (if wide? (fn (_ x y) (%cc-udiv x y #t)) (fn (_ x y) (%cc-mod x y))))
      ((string=? op "&") (fn (_ x y) (& x y)))
      ((string=? op "|") (fn (_ x y) (| x y)))
      ((string=? op "^") (fn (_ x y) (^ x y)))
      ((string=? op "<<") (fn (_ x y) (<< x y)))
      ((string=? op ">>")
        (if wide?
          (fn (_ x y) (if (if (< x 0) (> y 0) #f) (& (>> x y) (- (<< 1 (- 64 y)) 1)) (>> x y)))
          (fn (_ x y) (>> x y))))
      (#t (fn (_ x y) (%cc-oops "unknown operator"))))))

; OP on the values of FA and FB, of the C types KA and KB, as C does it: both
; in the C type they meet in -- a shift's count keeps its own -- and the
; result in it
(def %cc-k-arith
  (fn (_ op fa fb ka kb)
    (def shift? (if (string=? op "<<") #t (string=? op ">>")))
    (def k (if shift? (promoted-c-type ka) (common-c-type ka kb)))
    (match
      ((real? k)
        (let ((ca (%cc-k-from ka k)) (cb (%cc-k-from kb k)))
          (fn (_ fp) (def x (ca (fa fp))) (real-arith op x (cb (fb fp)) k))))
      ((if shift? (real? kb) #f)
        (fn (_ fp) (%cc-oops (string-append "the operator " op " by a floating value"))))
      (#t
        (let ((c (%cc-k-conv k)) (g (%cc-k-int-op op k)))
          (if shift?
            (fn (_ fp) (def x (c (fa fp))) (c (g x (fb fp))))
            (fn (_ fp) (def x (c (fa fp))) (c (g x (c (fb fp)))))))))))

; a comparison OP in the integer C type K: an unsigned long compares with its
; top bit flipped, which is unsigned order
(def %cc-k-cmp-op
  (fn (_ op)
    (match
      ((string=? op "<") fx<)
      ((string=? op "<=") (fn (_ x y) (not (fx< y x))))
      ((string=? op ">") (fn (_ x y) (fx< y x)))
      ((string=? op ">=") (fn (_ x y) (not (fx< x y))))
      ((string=? op "==") (fn (_ x y) (= x y)))
      (#t (fn (_ x y) (not (= x y)))))))

(def %cc-k-cmp
  (fn (_ op fa fb ka kb)
    (def k (if (if (%cc-address? ka) #t (%cc-address? kb)) (lit long) (common-c-type ka kb)))
    (if (real? k)
      (let ((ca (%cc-k-from ka k)) (cb (%cc-k-from kb k)))
        (fn (_ fp) (def x (ca (fa fp))) (%cc-b (real-compare op x (cb (fb fp)) k))))
      (let ((c (%cc-k-conv k)) (flip (if (eq? k (lit ulong)) (<< 1 63) 0)) (t (%cc-k-cmp-op op)))
        (fn (_ fp) (def x (^ (c (fa fp)) flip)) (%cc-b (t x (^ (c (fb fp)) flip))))))))

; a unary operator: * reads, & is the place's address, and - ~ ! in the
; operand's C type, promoted
(def %cc-k-unary
  (fn (_ node)
    (def op (%cc-k-a node))
    (def sub (%cc-k-b node))
    (match
      ((string=? op "*")
        (let ((e (%cc-k-expr sub)))
          (def ek (c-type-elem (first e)))
          (def f (rest e))
          (pair ek
            (if (%cc-c-type-decays? ek) f
              (let ((ld (%cc-k-load ek))) (fn (_ fp) (ld (f fp))))))))
      ((string=? op "&")
        ; &f of a function's name is the function's value
        (if (if (eq? (first sub) (lit var)) (null? (%cc-k-place (first (rest sub)))) #f)
          (let ((e (%cc-k-expr sub))) (pair (list (lit ptr) (first e)) (rest e)))
          (let ((l (%cc-k-lval sub))) (pair (list (lit ptr) (first l)) (rest l)))))
      (#t
        (let ((e (%cc-k-expr sub)))
          (def f (rest e))
          (def k (promoted-c-type (first e)))
          (pair (if (string=? op "!") (lit int) k)
            (match
              ((real? k)
                (match
                  ((string=? op "!") (fn (_ fp) (%cc-b (real-zero? (f fp) k))))
                  ((string=? op "-") (fn (_ fp) (real-negate (f fp) k)))
                  (#t (fn (_ fp) (%cc-oops (string-append "the operator ~ on a "
                                              (if (eq? k (lit float)) "float" "double")))))))
              ((string=? op "!") (fn (_ fp) (%cc-b (= (f fp) 0))))
              ((string=? op "-") (let ((c (%cc-k-conv k))) (fn (_ fp) (c (fx- 0 (f fp))))))
              (#t (let ((c (%cc-k-conv k))) (fn (_ fp) (c (fx- (fx- 0 (f fp)) 1))))))))))))

; ++ and --, before or after: a place of C type K moves by what `+ 1` moves
; it by -- an address by what it points at, a real value by 1.0
(def %cc-k-step
  (fn (_ node up? after?)
    (def l (%cc-k-lval (%cc-k-a node)))
    (def k (first l))
    (def fa (rest l))
    (def ld (%cc-k-load k))
    (def st (%cc-k-store k))
    (def by (if (%cc-address? k) (c-type-size (c-type-elem k)) 1))
    (def step
      (match
        ((real? k) (let ((op (if up? "+" "-"))) (fn (_ v) (real-step v k op))))
        (up? (fn (_ v) (fx+ v by)))
        (#t (fn (_ v) (fx- v by)))))
    (pair k
      (if after?
        (fn (_ fp) (def a (fa fp)) (def v (ld a)) (st a (step v)) v)
        (fn (_ fp) (def a (fa fp)) (st a (step (ld a))) (ld a))))))

(def %cc-k-assign
  (fn (_ node)
    (def l (%cc-k-lval (%cc-k-a node)))
    (def r (%cc-k-expr (%cc-k-b node)))
    (def k (first l))
    (def fa (rest l))
    (def fr (rest r))
    (pair k
      (if (%cc-struct-c-type? k)
        ; a struct-kinded place: the bytes copied from the value's address
        (let ((n (c-type-size k)))
          (fn (_ fp) (def v (fr fp)) (def d (fa fp)) (%cc-copy-bytes! d v n) d))
        ; an assignment answers what its place holds after it
        (let ((cf (%cc-k-from (first r) k)) (st (%cc-k-store k)) (ld (%cc-k-load k)))
          (fn (_ fp) (def v (fr fp)) (def a (fa fp)) (st a (cf v)) (ld a)))))))

(def %cc-k-ternary
  (fn (_ node)
    (def t (%cc-k-test (%cc-k-a node)))
    (def ea (%cc-k-expr (%cc-k-b node)))
    (def eb (%cc-k-expr (%cc-k-c node)))
    (def ka (first ea))
    (def kb (first eb))
    ; the arms meet as a pointer when either is an address, else in the C
    ; type their values meet in
    (def k
      (match
        ((%cc-address? ka) (%cc-decay ka))
        ((%cc-address? kb) (%cc-decay kb))
        ((%cc-c-type-decays? ka) ka)
        (#t (common-c-type ka kb))))
    (def fa (rest ea))
    (def fb (rest eb))
    (pair k
      (if (real? k)
        (let ((ca (%cc-k-from ka k)) (cb (%cc-k-from kb k)))
          (fn (_ fp) (if (t fp) (ca (fa fp)) (cb (fb fp)))))
        (fn (_ fp) (if (t fp) (fa fp) (fb fp)))))))

; a field's place, (OFF . C-TYPE), in the struct of C type K
(def %cc-k-field
  (fn (_ k fname)
    (def f (%cc-field (%cc-struct-name k fname) fname))
    (if (null? f) (%cc-oops (string-append "no field: " fname)) f)))

; a place's value: an array or a struct is its address, anything else loads
(def %cc-k-read
  (fn (_ l)
    (def k (first l))
    (def fa (rest l))
    (pair k
      (if (%cc-c-type-decays? k) fa
        (let ((ld (%cc-k-load k))) (fn (_ fp) (ld (fa fp))))))))

(set! %cc-k-expr
  (fn (_ node)
    (def t (first node))
    (match
      ((eq? t (lit num))
        (let ((v (%cc-k-a node)))
          (pair (if (null? (rest (rest node))) (lit int) (%cc-k-b node)) (fn (_ fp) v))))
      ((eq? t (lit var)) (%cc-k-var (%cc-k-a node)))
      ((eq? t (lit str))
        (let ((text (%cc-k-a node)))
          (def a (%cc-intern text))
          (pair (list (lit array) (+ (byte-len text) 1) plain-char) (fn (_ fp) a))))
      ((eq? t (lit bin))
        (let ((ea (%cc-k-expr (%cc-k-b node))) (eb (%cc-k-expr (%cc-k-c node))))
          (def op (%cc-k-a node))
          (def ka (first ea))
          (def kb (first eb))
          (pair (%cc-bin-c-type op ka kb)
            (if (if (%cc-address? ka) #t (%cc-address? kb))
              (%cc-k-addr-arith op (rest ea) (rest eb) ka kb)
              (%cc-k-arith op (rest ea) (rest eb) ka kb)))))
      ((eq? t (lit cmp))
        (let ((ea (%cc-k-expr (%cc-k-b node))) (eb (%cc-k-expr (%cc-k-c node))))
          (pair (lit int) (%cc-k-cmp (%cc-k-a node) (rest ea) (rest eb) (first ea) (first eb)))))
      ((eq? t (lit and))
        (let ((ta (%cc-k-test (%cc-k-a node))) (tb (%cc-k-test (%cc-k-b node))))
          (pair (lit int) (fn (_ fp) (if (ta fp) (if (tb fp) 1 0) 0)))))
      ((eq? t (lit or))
        (let ((ta (%cc-k-test (%cc-k-a node))) (tb (%cc-k-test (%cc-k-b node))))
          (pair (lit int) (fn (_ fp) (if (ta fp) 1 (if (tb fp) 1 0))))))
      ((eq? t (lit un)) (%cc-k-unary node))
      ((eq? t (lit idx)) (%cc-k-read (%cc-k-lval node)))
      ((eq? t (lit dot)) (%cc-k-read (%cc-k-lval node)))
      ((eq? t (lit arrow)) (%cc-k-read (%cc-k-lval node)))
      ((eq? t (lit assign)) (%cc-k-assign node))
      ((eq? t (lit preinc)) (%cc-k-step node #t #f))
      ((eq? t (lit predec)) (%cc-k-step node #f #f))
      ((eq? t (lit postinc)) (%cc-k-step node #t #t))
      ((eq? t (lit postdec)) (%cc-k-step node #f #t))
      ((eq? t (lit ternary)) (%cc-k-ternary node))
      ((eq? t (lit comma))
        (let ((ea (%cc-k-expr (%cc-k-a node))) (eb (%cc-k-expr (%cc-k-b node))))
          (def fa (rest ea))
          (def fb (rest eb))
          (pair (first eb) (fn (_ fp) (do (fa fp) (fb fp))))))
      ((eq? t (lit szof))
        (let ((n (c-type-size (first (%cc-k-expr (%cc-k-a node))))))
          (pair (lit ulong) (fn (_ fp) n))))
      ((eq? t (lit call)) (%cc-k-call node))
      ((eq? t (lit callx)) (%cc-k-call node))
      ((eq? t (lit cast))
        (let ((e (%cc-k-expr (%cc-k-b node))))
          (def to (%cc-k-a node))
          (def f (rest e))
          (def cf (%cc-k-from (first e) to))
          (def c (%cc-k-conv to))
          (pair to (fn (_ fp) (c (cf (f fp)))))))
      (#t (%cc-oops "unknown expression")))))

; a place: (C-TYPE . ADDRESS), ADDRESS a closure of the frame's address
(set! %cc-k-lval
  (fn (_ node)
    (def t (first node))
    (match
      ((eq? t (lit var))
        (let ((p (%cc-k-place (%cc-k-a node))))
          (match
            ((null? p) (%cc-oops (string-append "undefined: " (%cc-k-a node))))
            ((eq? (first p) (lit local))
              (let ((off (first (rest p)))) (pair (rest (rest p)) (fn (_ fp) (+ fp off)))))
            (#t (let ((a (first (rest p)))) (pair (rest (rest p)) (fn (_ fp) a)))))))
      ; A[I] is at A + I, and C lets either be the address
      ((eq? t (lit idx))
        (let ((e (%cc-k-expr (list (lit bin) "+" (%cc-k-a node) (%cc-k-b node)))))
          (pair (c-type-elem (first e)) (rest e))))
      ((eq? t (lit dot))
        (let ((l (%cc-k-lval (%cc-k-a node))))
          (def f (%cc-k-field (first l) (%cc-k-b node)))
          (def off (first f))
          (def fa (rest l))
          (pair (rest f) (fn (_ fp) (+ (fa fp) off)))))
      ((eq? t (lit arrow))
        (let ((e (%cc-k-expr (%cc-k-a node))))
          (def f (%cc-k-field (c-type-elem (first e)) (%cc-k-b node)))
          (def off (first f))
          (def fe (rest e))
          (pair (rest f) (fn (_ fp) (+ (fe fp) off)))))
      ((if (eq? t (lit un)) (string=? (%cc-k-a node) "*") #f)
        (let ((e (%cc-k-expr (%cc-k-b node)))) (pair (c-type-elem (first e)) (rest e))))
      ; a struct returned by value lives at the address the call answers
      ((if (eq? t (lit call)) #t (eq? t (lit callx))) (%cc-k-expr node))
      (#t (%cc-oops "not an lvalue")))))

; --- calls ---------------------------------------------------------------------

; the converters for a call's arguments, of the C types KS, to the function
; NAME: each to the C type its parameter declares, where the function
; declares one, and a float past the parameters to a double
(def %cc-k-arg-convs
  (fn (_ name ks)
    (def f (%cc-fun name))
    (def label (if (null? f) (library-double-label name) ()))
    (def ps
      (match
        ((not (null? f))
          (let ((ps (first (rest (rest f)))))
            (if (null? (%cc-fixed (first f))) ps (%cc-take (- (length ps) 1) ps))))
        ((null? label) ())
        ((string=? label "d->d") (list (lit double)))
        ((string=? label "dd->d") (list (lit double) (lit double)))
        (#t ())))
    (def go
      (fn (self ks ps)
        (if (null? ks) ()
          (pair
            (match
              ((not (null? ps)) (%cc-k-from (first ks) (first ps)))
              ((eq? (first ks) (lit float)) (%cc-k-from (first ks) (lit double)))
              (#t %cc-id))
            (self (rest ks) (if (null? ps) () (rest ps)))))))
    (go ks ps)))

; the argument values: each closure's, converted
(def %cc-k-arg-values
  (fn (self fs cs fp)
    (if (null? fs) () (%cc-k-arg-next self fs cs fp))))

; the first argument's value, worked out before the rest's
(def %cc-k-arg-next
  (fn (_ go fs cs fp)
    (def v ((first cs) ((first fs) fp)))
    (pair v (go (rest fs) (rest cs) fp))))

(set! %cc-k-call
  (fn (_ node)
    (def args (map (fn (_ a) (%cc-k-expr a)) (%cc-k-b node)))
    (def ks (map (fn (_ e) (first e)) args))
    (def fs (map (fn (_ e) (rest e)) args))
    (def named?
      (if (eq? (first node) (lit call)) (null? (%cc-k-place (%cc-k-a node))) #f))
    (if named?
      ; a named call: its function's C type, or the library's
      (let ((name (%cc-k-a node)))
        (def f (%cc-fun name))
        (def k (if (null? f) (library-c-type name)
                 (let ((r (rest (rest (rest f))))) (if (null? r) (lit int) (first r)))))
        (def cs (%cc-k-arg-convs name ks))
        (pair k (fn (_ fp) (%cc-call name (%cc-k-arg-values fs cs fp)))))
      ; a call through a value: a variable holding a function, or any other
      ; expression -- (*f)(x) is f(x), * on a function value the function
      (let ((target
              (if (eq? (first node) (lit call))
                (%cc-k-expr (list (lit var) (%cc-k-a node)))
                (%cc-k-expr (%cc-k-a node)))))
        (def strip
          (fn (self n)
            (if (if (eq? (first n) (lit un)) (string=? (first (rest n)) "*") #f)
              (self (first (rest (rest n))))
              n)))
        (def ft
          (if (eq? (first node) (lit call)) (rest target)
            (rest (%cc-k-expr (strip (%cc-k-a node))))))
        (pair (%cc-called-c-type (first target))
          (fn (_ fp)
            (let ((name (%cc-fun-name (ft fp))))
              (%cc-call name (%cc-k-arg-values fs (%cc-k-arg-convs name ks) fp)))))))))

; --- initializers --------------------------------------------------------------
; (%cc-k-init K INIT): a closure of the frame's address and the place's that
; lays INIT there: a braced list fills an array's elements or a struct's
; fields in order (missing trailing items stay as they are); a string fills
; a char array with its bytes and a NUL; a struct value copies; a scalar
; stores

(def %cc-k-init
  (fn (self k init)
    (match
      ((eq? (first init) (lit initlist))
        (let ((items (first (rest init))))
          (match
            ((if (pair? k) (eq? (first k) (lit array)) #f)
              (let ((ek (c-type-elem k)))
                (def es (c-type-size ek))
                (def go (fn (self2 is i)
                          (if (null? is) ()
                            (pair (pair (* i es) (self ek (first is))) (self2 (rest is) (+ i 1))))))
                (%cc-k-init-each (go items 0))))
            ((%cc-struct-c-type? k)
              (let ((e (struct-entry (first (rest k)))))
                (def go (fn (self2 is fs)
                          (match
                            ((null? is) ())
                            ((null? fs) (%cc-oops "too many initializers for a struct"))
                            (#t (pair (pair (first (rest (first fs)))
                                        (self (first (rest (rest (first fs)))) (first is)))
                                  (self2 (rest is) (rest fs)))))))
                (%cc-k-init-each (go items (rest (rest e))))))
            ((null? items) (fn (_ fp a) ()))
            (#t (self k (first items))))))
      ((if (eq? (first init) (lit str)) (if (pair? k) (eq? (first k) (lit array)) #f) #f)
        (let ((text (first (rest init))))
          (def n (byte-len text))
          (fn (_ fp a) (%cc-put-text! a text n))))
      ((%cc-struct-c-type? k)
        (let ((f (rest (%cc-k-expr init))) (n (c-type-size k)))
          (fn (_ fp a) (%cc-copy-bytes! a (f fp) n))))
      (#t
        (let ((e (%cc-k-expr init)))
          (def f (rest e))
          (def cf (%cc-k-from (first e) k))
          (def st (%cc-k-store k))
          (fn (_ fp a) (st a (cf (f fp)))))))))

; PARTS, ((OFF . INIT) ...), each laid at its offset from the place
(def %cc-k-init-each
  (fn (_ parts)
    (def go (fn (self ps fp a)
              (if (null? ps) ()
                (do ((rest (first ps)) fp (+ a (first (first ps))))
                    (self (rest ps) fp a)))))
    (fn (_ fp a) (go parts fp a))))

; --- statements ----------------------------------------------------------------
; A statement translates to (RUN SEEK LABELS): RUN, a closure of the frame's
; address, answers control; SEEK, of the frame's address and a label's name,
; enters the statement at that label inside it; LABELS, the labels it holds
; at any depth.  A declaration is (decl INIT), its INIT run where it stands.

(def %cc-k-run (fn (_ s) (first s)))
(def %cc-k-seek (fn (_ s) (first (rest s))))
(def %cc-k-labels (fn (_ s) (first (rest (rest s)))))
(def %cc-k-decl? (fn (_ s) (eq? (first s) (lit decl))))
(def %cc-k-has?
  (fn (_ s name)
    (if (%cc-k-decl? s) #f
      (let ((go (fn (self l) (if (null? l) #f (if (string=? (first l) name) #t (self (rest l)))))))
        (go (%cc-k-labels s))))))
(def %cc-k-any-has?
  (fn (self ss name) (if (null? ss) #f (if (%cc-k-has? (first ss) name) #t (self (rest ss) name)))))
(def %cc-k-tail
  (fn (self ss name) (if (%cc-k-has? (first ss) name) ss (self (rest ss) name))))
(def %cc-k-all-labels
  (fn (self ss) (if (null? ss) () (if (%cc-k-decl? (first ss)) (self (rest ss))
                                    (append (%cc-k-labels (first ss)) (self (rest ss)))))))
(def %cc-k-noseek
  (fn (_ fp name) (%cc-oops "a goto into a statement that holds no label")))
(def %cc-k-stmt ())

; A block's statements from ITEMS on, ALL being every one of them.  SEEK,
; when not (), is a label being gone to, in ITEMS: the statements before it
; are passed over, their declarations not initialized, as C leaves them.  A
; goto a statement answers goes on here when its label is one of the
; block's.
(def %cc-k-items
  (fn (self all items fp seek)
    (if (null? items) ()
      (match
        ((%cc-k-decl? (first items))
          (do (if (null? seek) ((first (rest (first items))) fp) ())
              (self all (rest items) fp seek)))
        ((if (null? seek) #f (not (%cc-k-has? (first items) seek)))
          (self all (rest items) fp seek))
        (#t
          (%cc-k-items-on self all items fp
            (if (null? seek)
              ((%cc-k-run (first items)) fp)
              ((%cc-k-seek (first items)) fp seek))))))))

; the block's walk once its first item in ITEMS answered C
(def %cc-k-items-on
  (fn (_ go all items fp c)
    (match
      ((null? c) (go all (rest items) fp ()))
      ((not (%cc-ctrl? c (lit goto))) c)
      ((%cc-k-any-has? (rest items) (first (rest c)))
        (go all (rest items) fp (first (rest c))))
      ((%cc-k-any-has? all (first (rest c)))
        (go all (%cc-k-tail all (first (rest c))) fp (first (rest c))))
      (#t c))))

; a declaration: its slot, or a static's storage made and initialized now,
; once; the name in scope in its own initializer
(def %cc-k-decl
  (fn (_ item)
    (def name (first (rest item)))
    (def k (first (rest (rest item))))
    (def init (first (rest (rest (rest item)))))
    (if (not (null? (rest (rest (rest (rest item))))))
      (let ((a (%cc-heap (c-type-size k))))
        (set! %cc-k-locals (pair (pair name (pair (lit global) (pair a k))) %cc-k-locals))
        (if (null? init) () ((%cc-k-init k init) 0 a))
        (list (lit decl) (fn (_ fp) ())))
      (let ((off (%cc-k-slot! name k)))
        (match
          ((null? init) (list (lit decl) (fn (_ fp) ())))
          ; an array or a struct is zero where its initializer stops, each
          ; time its declaration is reached
          ((%cc-c-type-decays? k)
            (let ((f (%cc-k-init k init)) (n (round-up (c-type-size k) 8)))
              (list (lit decl) (fn (_ fp) (do (%cc-k-zero! (+ fp off) n) (f fp (+ fp off)))))))
          (#t (let ((f (%cc-k-init k init)))
                (list (lit decl) (fn (_ fp) (f fp (+ fp off)))))))))))

; N bytes of the frame at A, a multiple of eight, to zero
(def %cc-k-zero!
  (fn (_ a n)
    (def at (fx- a %cc-base))
    (def go (fn (self i)
              (if (fx< i n)
                (do (word-set! %cc-memp (fx+ at i) 0) (self (fx+ i 8)))
                ())))
    (go 0)))

; STMTS translated in order, each declaration in scope after it, and the
; names they bring out of scope at the end
(def %cc-k-stmts
  (fn (_ stmts)
    (def saved %cc-k-locals)
    (def go (fn (self ss)
              (if (null? ss) ()
                (let ((s (first ss)))
                  (let ((r (if (eq? (first s) (lit decl)) (%cc-k-decl s) (%cc-k-stmt s))))
                    (pair r (self (rest ss))))))))
    (def out (go stmts))
    (set! %cc-k-locals saved)
    out))

; the rest of a loop after a pass over its body answered C: a break ends it,
; nothing or a continue goes on to the next pass as NEXT does, and anything
; else -- a return, a goto -- leaves it
(def %cc-k-loop-on
  (fn (_ next)
    (fn (self fp c)
      (match
        ((%cc-ctrl? c (lit break)) ())
        ((if (null? c) #t (%cc-ctrl? c (lit continue))) (next self fp))
        (#t c)))))

(set! %cc-k-stmt
  (fn (self stmt)
    (def t (first stmt))
    (match
      ((eq? t (lit expr))
        (let ((f (rest (%cc-k-expr (first (rest stmt))))))
          (list (fn (_ fp) (do (f fp) ())) %cc-k-noseek ())))
      ((eq? t (lit block))
        (let ((items (%cc-k-stmts (first (rest stmt)))))
          (list (fn (_ fp) (%cc-k-items items items fp ()))
                (fn (_ fp name) (%cc-k-items items items fp name))
                (%cc-k-all-labels items))))
      ((eq? t (lit if))
        (let ((c (%cc-k-test (first (rest stmt)))) (th (self (first (rest (rest stmt))))))
          (def e (first (rest (rest (rest stmt)))))
          (def el (if (null? e) () (self e)))
          (list (if (null? el)
                  (fn (_ fp) (if (c fp) ((%cc-k-run th) fp) ()))
                  (fn (_ fp) (if (c fp) ((%cc-k-run th) fp) ((%cc-k-run el) fp))))
                (fn (_ fp name)
                  (if (%cc-k-has? th name) ((%cc-k-seek th) fp name) ((%cc-k-seek el) fp name)))
                (append (%cc-k-labels th) (if (null? el) () (%cc-k-labels el))))))
      ((eq? t (lit while))
        (let ((c (%cc-k-test (first (rest stmt)))) (b (self (first (rest (rest stmt))))))
          (def br (%cc-k-run b))
          (def on (%cc-k-loop-on (fn (_ on fp) (if (c fp) (on fp (br fp)) ()))))
          (list (fn (_ fp) (if (c fp) (on fp (br fp)) ()))
                (fn (_ fp name) (on fp ((%cc-k-seek b) fp name)))
                (%cc-k-labels b))))
      ((eq? t (lit do))
        (let ((b (self (first (rest stmt)))) (c (%cc-k-test (first (rest (rest stmt))))))
          (def br (%cc-k-run b))
          (def on (%cc-k-loop-on (fn (_ on fp) (if (c fp) (on fp (br fp)) ()))))
          (list (fn (_ fp) (on fp (br fp)))
                (fn (_ fp name) (on fp ((%cc-k-seek b) fp name)))
                (%cc-k-labels b))))
      ((eq? t (lit for))
        (let ((i-n (first (rest stmt))) (c-n (first (rest (rest stmt))))
              (u-n (first (rest (rest (rest stmt))))))
          (def fi (if (null? i-n) (fn (_ fp) ()) (rest (%cc-k-expr i-n))))
          (def c (if (null? c-n) (fn (_ fp) #t) (%cc-k-test c-n)))
          (def fu (if (null? u-n) (fn (_ fp) ()) (rest (%cc-k-expr u-n))))
          (def b (self (first (rest (rest (rest (rest stmt)))))))
          (def br (%cc-k-run b))
          (def on (%cc-k-loop-on (fn (_ on fp) (do (fu fp) (if (c fp) (on fp (br fp)) ())))))
          (list (fn (_ fp) (do (fi fp) (if (c fp) (on fp (br fp)) ())))
                (fn (_ fp name) (on fp ((%cc-k-seek b) fp name)))
                (%cc-k-labels b))))
      ((eq? t (lit goto))
        (let ((g (list (lit goto) (first (rest stmt)))))
          (list (fn (_ fp) g) %cc-k-noseek ())))
      ((eq? t (lit label))
        (let ((name (first (rest stmt))) (s (self (first (rest (rest stmt))))))
          (def sr (%cc-k-run s))
          (list sr
                (fn (_ fp n) (if (string=? n name) (sr fp) ((%cc-k-seek s) fp n)))
                (pair name (%cc-k-labels s)))))
      ((eq? t (lit return))
        (let ((e (first (rest stmt))))
          (if (null? e) (list (fn (_ fp) %cc-ret0) %cc-k-noseek ())
            (let ((ce (%cc-k-expr e)))
              (def f (rest ce))
              (def k (first ce))
              (list (fn (_ fp) (list (lit return) (f fp) k)) %cc-k-noseek ())))))
      ((eq? t (lit switch)) (%cc-k-switch stmt))
      ((eq? t (lit break)) (list (fn (_ fp) %cc-brk) %cc-k-noseek ()))
      ((eq? t (lit continue)) (list (fn (_ fp) %cc-cnt) %cc-k-noseek ()))
      (#t (%cc-oops "unknown statement")))))

; A switch: the matched clause and every clause after it run as one block
; (fallthrough), the default's when none matches; a break ends the switch,
; and return and continue pass through to the function or loop around it.
; Every clause's statements are one scope.
(def %cc-k-switch
  (fn (_ stmt)
    (def fv (rest (%cc-k-expr (first (rest stmt)))))
    (def clauses (first (rest (rest stmt))))
    (def all
      (%cc-k-stmts
        (let ((go (fn (self cs) (if (null? cs) () (append (rest (first cs)) (self (rest cs)))))))
          (go clauses))))
    ; ((VALUE-CLOSURE-OR-NIL . ITEMS-FROM-THE-CLAUSE) ...)
    (def starts
      (let ((go (fn (self cs items)
                  (if (null? cs) ()
                    (pair (pair (if (null? (first (first cs))) ()
                                  (rest (%cc-k-expr (first (first cs)))))
                                items)
                      (self (rest cs) (%cc-gen-drop-n (length (rest (first cs))) items)))))))
        (go clauses all)))
    (def from
      (fn (self ss v fp)
        (match
          ((null? ss) ())
          ((if (null? (first (first ss))) #f (= v ((first (first ss)) fp))) (rest (first ss)))
          (#t (self (rest ss) v fp)))))
    (def default
      (let ((go (fn (self ss) (if (null? ss) () (if (null? (first (first ss))) (rest (first ss)) (self (rest ss)))))))
        (go starts)))
    (def finish (fn (_ c) (if (%cc-ctrl? c (lit break)) () c)))
    (list (fn (_ fp)
            (let ((at (from starts (fv fp) fp)))
              (def body (if (null? at) default at))
              (if (null? body) () (finish (%cc-k-items body body fp ())))))
          (fn (_ fp name) (finish (%cc-k-items all all fp name)))
          (%cc-k-all-labels all))))

; what follows the first N of a list
(def %cc-gen-drop-n
  (fn (self n xs) (if (<= n 0) xs (self (- n 1) (rest xs)))))

; --- functions -----------------------------------------------------------------
; A function's translation: (SIZE PARAMS RET BODY FIXED), PARAMS ((OFF STORE
; . STRUCT-SIZE) ...) for each parameter's slot, FIXED the count of a
; variadic function's fixed parameters, else nil.

(def %cc-k-funs ())     ; ((name . translation) ...), made the first time each is called

(def %cc-k-fun
  (fn (_ name)
    (def go (fn (self es)
              (match
                ((null? es) ())
                ((string=? (first (first es)) name) (rest (first es)))
                (#t (self (rest es))))))
    (def hit (go %cc-k-funs))
    (if (not (null? hit)) hit
      (let ((f (%cc-fun name)) (saved-l %cc-k-locals) (saved-s %cc-k-size))
        ; f is (params body c-types ret)
        (set! %cc-k-locals ())
        (set! %cc-k-size 0)
        (def params
          (let ((go (fn (self ps ks)
                      (if (null? ps) ()
                        (let ((k (if (null? ks) (lit int) (first ks))))
                          (def off (%cc-k-slot! (first ps) k))
                          (pair (pair off (pair (%cc-k-store k)
                                                (if (%cc-struct-c-type? k) (c-type-size k) ())))
                            (self (rest ps) (if (null? ks) () (rest ks)))))))))
            (go (first f) (first (rest (rest f))))))
        (def body (%cc-k-stmt (first (rest f))))
        (def ret (let ((r (rest (rest (rest f))))) (if (null? r) (lit int) (first r))))
        (def tr (list %cc-k-size params ret body (%cc-fixed (first f))))
        (set! %cc-k-locals saved-l)
        (set! %cc-k-size saved-s)
        (set! %cc-k-funs (pair (pair name tr) %cc-k-funs))
        tr))))

; NAME called with ARGS: one of the program's functions -- its frame made,
; its parameters stored, its body run, its frame freed wholesale; a struct
; it answers by value moves out of the popped frame into a fresh slot in the
; caller's, which lives until the caller returns -- or exit, or the C
; library's
(def %cc-call-fun
  (fn (_ name args)
    (def tr (%cc-k-fun name))
    (def saved-sp %cc-sp)
    (def n (first (rest (rest (rest (rest tr))))))
    (if (if (null? n) #f (fx< (length args) n))
      (%cc-oops (string-append name " with too few arguments")))
    ; a variadic function's arguments past its fixed ones go as a
    ; va_list, its "..."
    (def all
      (if (null? n) args
        (append (%cc-take n args) (list (%cc-va-list (%cc-drop n args))))))
    (def fp (%cc-alloca (first tr)))
    (def bind
      (fn (self ps as)
        (if (null? ps) ()
          (do (if (null? as) ()
                (if (null? (rest (rest (first ps))))
                  ((first (rest (first ps))) (fx+ fp (first (first ps))) (first as))
                  (%cc-copy-bytes! (fx+ fp (first (first ps))) (first as)
                    (rest (rest (first ps))))))
              (self (rest ps) (if (null? as) () (rest as)))))))
    (bind (first (rest tr)) all)
    (def ret (first (rest (rest tr))))
    (def c ((%cc-k-run (first (rest (rest (rest tr))))) fp))
    (if (%cc-ctrl? c (lit goto))
      (%cc-oops (string-append "a goto to a label the function does not have: "
                  (first (rest c)))))
    ; (return V C-TYPE): V in the C type the function answers
    (def v
      (if (%cc-ctrl? c (lit return))
        (%cc-convert-from (first (rest c)) (first (rest (rest c))) ret)
        0))
    (set! %cc-sp saved-sp)
    (if (%cc-struct-c-type? ret)
      (%cc-moved-out v (c-type-size ret))
      v)))

; a struct answered by value: its N bytes at V, in the popped frame, moved
; into a fresh slot in the caller's
(def %cc-moved-out
  (fn (_ v n)
    (def vals (%cc-read-bytes v n))
    (def tmp (%cc-alloca n))
    (%cc-write-bytes! tmp vals)
    tmp))

(def %cc-call-run
  (fn (_ name args)
    (if (not (null? (%cc-fun name)))
      (%cc-call-fun name args)
      ; exit leaves through the interpreter, once the C library has written
      ; what it holds; everything else is the C library's
      (if (string=? name "exit")
        (do (%cc-libc-flush!)
            (set! %cc-exit-code (first args))
            (Err raise (lit cc-exit) "exit" ()))
        (let ((label (library-double-label name)))
          (if (null? label) (%cc-libc-call name args) (%cc-libm-call label name args)))))))

(def %cc-call ())
(set! %cc-call %cc-call-run)

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
    (set! %cc-k-funs ())
    (set! %cc-k-locals ())
    (set! %cc-k-size 0)
    (set! %cc-fun-ids ())
    (%cc-callbacks-free!)
    (set! %cc-exit-code ())
    (def prog (cc-parse (cc-lex src)))
    (def load!
      (fn (self items)
        (if (null? items) ()
          (let ((item (first items)))
            (do (if (eq? (first item) (lit fun))
                  ; (fun NAME PARAMS BODY C-TYPES) -> (NAME PARAMS BODY C-TYPES)
                  (set! %cc-funs (pair (rest item) %cc-funs))
                  (let ((name (first (rest item))))
                    (def c-type (first (rest (rest item))))
                    (def init (first (rest (rest (rest item)))))
                    (def size (c-type-size c-type))
                    (def a (%cc-heap size))
                    ; in scope in its own initializer, as a local is
                    (do (set! %cc-genv (pair (pair name (pair a c-type)) %cc-genv))
                        (if (null? init) ()
                          ((%cc-k-init c-type init) 0 a)))))
                (self (rest items)))))))
    (load! prog)
    (%cc-scan-program! prog)
    (def saved
      (match
        ((null? input) ())
        ((eq? input (lit caller)) (do (%cc-stdin-reclaim!) ()))
        (#t (%cc-stdin-from! input))))
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

; The command line's caller's standard input as fd 0.  Under the command
; line the boot stream holds fd 0 and the caller's stdin waits on fd 3, the
; platform's arrangement (lib/x/repl/loop.x; x-os's launcher); it goes back
; on 0 when 3 is open.  Through the C library, which has dup2 on every
; platform this runs on.
(def %cc-stdin-reclaim!
  (fn (_)
    (if (>= (%cc-libc-do "fcntl" 3 1) 0)               ; F_GETFD
      (do (%cc-libc-do "dup2" 3 0)
          (%cc-libc-do "close" 3)
          (%cc-stdin-reset!))
      ())))

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
; the program's name first; with INPUT nil, standard input is fd 0, and
; with INPUT caller, the command line's caller's (%cc-stdin-reclaim!)
(def cc-run-with (fn (_ src input argv) (%cc-run-core src input argv)))

(def cc-run (fn (_ src) (%cc-run-core src () (list "a.out"))))

(provide cc/eval cc-run cc-run-with common-c-type c-type-elem
  library-c-type library-double-fns library-double-label library-variadic
  promoted-c-type signed? unsigned-divide)
