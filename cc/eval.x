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
                "rewind" "setbuf" "clearerr"))))))

(def library-c-type
  (fn (_ name)
    (def go (fn (self es)
              (match
                ((null? es) (lit int))
                ((string=? (first (first es)) name) (rest (first es)))
                (#t (self (rest es))))))
    (go library-c-types)))

; <ctype.h>'s classifications in the C locale, each the ranges of codes it
; takes in: (NAME (LOW . HIGH) ...).  run reads them here and the compiled
; runtime is written from them.
(def ctype-ranges
  (list (list "isdigit" (pair 48 57))
        (list "isalpha" (pair 65 90) (pair 97 122))
        (list "isalnum" (pair 48 57) (pair 65 90) (pair 97 122))
        (list "isspace" (pair 9 13) (pair 32 32))
        (list "isupper" (pair 65 90))
        (list "islower" (pair 97 122))
        (list "isxdigit" (pair 48 57) (pair 65 70) (pair 97 102))
        (list "ispunct" (pair 33 47) (pair 58 64) (pair 91 96) (pair 123 126))
        (list "isprint" (pair 32 126))
        (list "iscntrl" (pair 0 31) (pair 127 127))
        (list "isgraph" (pair 33 126))))

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
; on x86-64 Linux a record whose offsets say the registers are used up, so
; every argument is read from the slots.  The answer is converted to the C
; type the function's header declares (library-c-type).

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

; the variadic functions: (NAME V-NAME FIXED), FIXED the arguments before
; the variable ones
(def %cc-libc-variadic
  (list (list "printf" "vprintf" 1) (list "fprintf" "vfprintf" 2)
        (list "sprintf" "vsprintf" 2) (list "snprintf" "vsnprintf" 3)
        (list "dprintf" "vdprintf" 2) (list "scanf" "vscanf" 1)
        (list "fscanf" "vfscanf" 2) (list "sscanf" "vsscanf" 2)))

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
    (if os-darwin? slots
      (let ((v (%cc-alloca 24)))
        (do (%cc-raw-set! v 48 4)
            (%cc-raw-set! (+ v 4) 304 4)
            (%cc-raw-set! (+ v 8) slots 8)
            v)))))

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
        (go %cc-libc-variadic)))
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
          (if (null? e) (lit int) (rest (rest e)))))
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
      ((eq? t (lit call))
        ; a named call's C type is the one its function declares it returns,
        ; or the library's when the program has no function of that name
        (let ((f (if (null? (%cc-find (first (rest node)) env)) (%cc-fun (first (rest node))) ())))
          (if (null? f) (library-c-type (first (rest node)))
            (let ((r (rest (rest (rest f))))) (if (null? r) (lit int) (first r))))))
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
; an unsigned int, else an int.  The compiled code works in the same C
; types (cc/gen.x).
(def promoted-c-type
  (fn (_ k)
    (match
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
              ; the operands in the C type they meet in, an address as it
              ; is; an unsigned long compares with its top bit flipped,
              ; which is unsigned order
              (def k (if (if (%cc-address? ka) #t (%cc-address? kb)) (lit long) (common-c-type ka kb)))
              (def flip (if (eq? k (lit ulong)) (<< 1 63) 0))
              (def x (^ (%cc-convert a k) flip))
              (def y (^ (%cc-convert b k) flip))
              (%cc-b
                (match
                  ((string=? op "<") (< x y))
                  ((string=? op "<=") (<= x y))
                  ((string=? op ">") (> x y))
                  ((string=? op ">=") (>= x y))
                  ((string=? op "==") (= x y))
                  (#t (not (= x y))))))))
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
              ; - and ~ in the operand's C type, promoted; ~v is -v-1
              (let ((v (%cc-eval (first (rest (rest node))) env)))
                (if (string=? op "!") (%cc-b (= v 0))
                  (%cc-convert (if (string=? op "-") (- 0 v) (- (- 0 v) 1))
                    (promoted-c-type (%cc-kind-of (first (rest (rest node))) env))))))))
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
        (def v (if (if (pair? c) (eq? (first c) (lit return)) #f) (first (rest c)) 0))
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
        (%cc-libc-call name args)))))

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
        (if (%cc-tru (%cc-eval (first (rest stmt)) env))
          (%cc-exec (first (rest (rest stmt))) env)
          (let ((e (first (rest (rest (rest stmt))))))
            (if (null? e) () (%cc-exec e env))))
      (if (eq? t (lit while))
        (if (%cc-tru (%cc-eval (first (rest stmt)) env))
          (%cc-while-on stmt env (%cc-exec (first (rest (rest stmt))) env))
          ())
      (if (eq? t (lit do))
        (%cc-do-on stmt env (%cc-exec (first (rest stmt)) env))
      (if (eq? t (lit for))
        (let ((i-n (first (rest stmt))) (c-n (first (rest (rest stmt)))))
          (do (if (null? i-n) () (%cc-eval i-n env))
              (if (if (null? c-n) #t (%cc-tru (%cc-eval c-n env)))
                (%cc-for-on stmt env (%cc-exec (first (rest (rest (rest (rest stmt))))) env))
                ())))
      (if (eq? t (lit goto)) (list (lit goto) (first (rest stmt)))
      (if (eq? t (lit label)) (%cc-exec (first (rest (rest stmt))) env)
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
        (%cc-oops "unknown statement"))))))))))))))))

; The rest of a loop after a pass over its body answered C: a break ends
; it, nothing or a continue goes on to the next pass, as the loop's own
; test and step say, and anything else -- a return, a goto -- leaves it.
(def %cc-while-on
  (fn (self stmt env c)
    (match
      ((%cc-ctrl? c (lit break)) ())
      ((if (null? c) #t (%cc-ctrl? c (lit continue)))
        (if (%cc-tru (%cc-eval (first (rest stmt)) env))
          (self stmt env (%cc-exec (first (rest (rest stmt))) env))
          ()))
      (#t c))))

(def %cc-do-on
  (fn (self stmt env c)
    (match
      ((%cc-ctrl? c (lit break)) ())
      ((if (null? c) #t (%cc-ctrl? c (lit continue)))
        (if (%cc-tru (%cc-eval (first (rest (rest stmt))) env))
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
            (if (if (null? c-n) #t (%cc-tru (%cc-eval c-n env)))
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
  (fn (_ src)
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
        (& (%cc-call "main" ()) 255)))
    (%cc-libc-flush!)
    status))

(def cc-run (fn (_ src) (%cc-run-core src)))

(provide cc/eval cc-run common-c-type ctype-ranges kind-elem library-c-type printf-conversion
  printf-fit printf-pad promoted-c-type signed? unsigned-divide)
