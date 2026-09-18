; # x-cc -- a C compiler on x-lang
;
; ## cc/gen.x -- code generation
;
; @author [Jon Ruttan](jonruttan@gmail.com)
; @copyright 2026 Jon Ruttan
; @license MIT No Attribution (MIT-0)
;
; A program compiles to the bytes of its code, entry first.  The code goes
; through the platform assembler, x/tool/asm, whose mnemonics encode for
; arm64 and x86-64 alike; the assembler encodes for the machine it runs on,
; so the executable is for the platform the compiler runs on: an arm64
; Mach-O on macOS, an x86-64 ELF on Linux.
;
; Expressions evaluate on a stack machine.  Each leaves its value in x0; a
; binary operator evaluates its left operand and pushes it, evaluates the
; right, moves it to x1 and pops the left back into x0.  C's `int` is 32
; bits: an operator whose result can leave that range sign-extends it again
; from bit 31, so arithmetic wraps as C's does.
;
; Compiled so far: main and the functions beside it, with globals, locals and
; parameters of `int`, `char`, `short` and their unsigned narrower kinds,
; each at its kind's size, assignment, ++ and --, `if`/`else`, `while`, `do`,
; `for`, `break`, `continue`, `return` and calls (recursion included), over
; integer constants, + - * / %, & | ^ << >>, the six comparisons, &&, ||,
; the ternary, the comma and unary - ~ !, and `putchar`, `puts` of a literal
; and `printf` of a literal format with %d %c %s and %%, unless the program
; defines its own.  Everything else refuses by name: `long` and the unsigned
; kinds of int's width or more, pointers, aggregates, more than four
; arguments, and the rest of the runtime.
;
; The convention is this compiler's own, since nothing else links with what
; it writes: arguments in x0, x1, x2 and x8, the answer in x0, frames off
; x20 in a region below the machine stack, x19 the frame's base, x21 the
; runtime helper and x22 the data.

(import x/tool/asm)
(import x/platform/syscall)

(def %cc-gen-no
  (fn (_ what)
    (Err raise (lit cc) (string-append "cc: compile: not built yet: " what) ())))

; the executable format for the platform the compiler runs on
(def %cc-gen-target
  (fn (_)
    (match
      ((if os-darwin? arch-arm64? #f) (lit macho-arm64))
      ((if os-linux? arch-x86-64? #f) (lit elf-x86-64))
      (#t (Err raise (lit cc) "cc: compile: no executable format for this platform yet" ())))))

; --- the entry ---------------------------------------------------------------
; Calls main, then exits with what it answered.  The assembler has no
; system-call instruction, so each target's entry is written out here.

(def %cc-gen-le32
  (fn (_ w) (list (& w 255) (& (>> w 8) 255) (& (>> w 16) 255) (& (>> w 24) 255))))

; The frames go in a region below the machine stack, so a push never lands
; in one: the entry points x20 at the region's top and moves the machine
; stack below it, and each function's prologue takes its frame off x20.
(def %cc-gen-region 65536)

; the bytes of several pieces, in order
(def %cc-gen-cat
  (fn (self pieces)
    (if (null? pieces) () (append (first pieces) (self (rest pieces))))))

; adr RD, #IMM -- the address IMM bytes on from this instruction
(def %cc-gen-adr
  (fn (_ rd imm)
    (| 0x10000000
      (| (<< (& imm 3) 29) (| (<< (& (>> imm 2) 0x7FFFF) 5) rd)))))

; The entry, and the one piece of runtime compiled code calls: a write.
; Neither the system call nor a program-counter-relative address has a
; portable mnemonic, so both are written out per target.  The entry puts the
; helper's address in x21, where nothing the generator emits touches it, and
; compiled code reaches the helper through it: fd in x0, the bytes in x1,
; how many in x2.  Those are already arm64's system-call registers, and
; x86-64's indirect call marshals x0 and x2 into the two its own convention
; wants, with x1 already in place.
;
; x22 gets the address of the data, which the container puts on the page
; after the code.  DATAAT is how far that is from the entry's first byte,
; which the container works out; the entry is a fixed length per target, so
; the two instructions that take the address know where they stand.
(def %cc-gen-entry
  (fn (_ target dataat)
    (def exit-nr (syscall-id (lit exit)))
    (def write-nr (syscall-id (lit write)))
    (if (eq? target (lit macho-arm64))
      ; ten words: adr x21, write3; adr x22, the data; mov x20, sp;
      ; sub sp, #64K; bl main (six words on); movz x16, #exit; svc #0x80;
      ; then write3: movz x16, #write; svc #0x80; ret
      (%cc-gen-cat
        (list (%cc-gen-le32 (%cc-gen-adr 21 28))
              (%cc-gen-le32 (%cc-gen-adr 22 (- dataat 4)))
              (%cc-gen-le32 0x910003F4)
              (%cc-gen-le32 (| 0xD14003FF (<< (/ %cc-gen-region 4096) 10)))
              (%cc-gen-le32 0x94000006)
              (%cc-gen-le32 (| 0xD2800010 (<< exit-nr 5)))
              (%cc-gen-le32 0xD4001001)
              (%cc-gen-le32 (| 0xD2800010 (<< write-nr 5)))
              (%cc-gen-le32 0xD4001001)
              (%cc-gen-le32 0xD65F03C0)))
      ; forty-seven bytes: lea r13, [rip+32] (write3); lea r14, [rip+...]
      ; (the data); mov r12, rsp; sub rsp, 64K; call main (eighteen bytes
      ; on); mov rdi, rax; mov eax, exit; syscall; then write3:
      ; mov eax, write; syscall; ret
      (%cc-gen-cat
        (list (list 0x4C 0x8D 0x2D) (%cc-gen-le32 32)
              (list 0x4C 0x8D 0x35) (%cc-gen-le32 (- dataat 14))
              (list 0x49 0x89 0xE4)
              (list 0x48 0x81 0xEC) (%cc-gen-le32 %cc-gen-region)
              (list 0xE8) (%cc-gen-le32 18)
              (list 0x48 0x89 0xC7)
              (list 0xB8) (%cc-gen-le32 exit-nr)
              (list 0x0F 0x05)
              (list 0xB8) (%cc-gen-le32 write-nr)
              (list 0x0F 0x05 0xC3))))))

; how long the entry is; the container lays the code out from here
(def %cc-gen-entry-len
  (fn (_ target) (if (eq? target (lit macho-arm64)) 40 47)))

; where the container puts the data, as a distance from the entry's start
(def %cc-gen-data-at
  (fn (_ target codelen)
    (if (eq? target (lit macho-arm64))
      (%cc-macho-data-at codelen)
      (%cc-elf-data-at codelen))))

; --- expressions -------------------------------------------------------------

(def %cc-gen-asm ())                   ; the assembler for the compile under way
(def %cc-gen-nlabels 0)

(def %cc-gen! (fn (_ . args) (apply asm-emit! (pair %cc-gen-asm args))))

(def %cc-gen-label
  (fn (_)
    (do (set! %cc-gen-nlabels (+ %cc-gen-nlabels 1))
        (convert (string-append "cc-" (convert %cc-gen-nlabels %string)) %symbol))))

; x0 back into int range: shifted up 32 and arithmetically down again
(def %cc-gen-int!
  (fn (_)
    (do (%cc-gen! (lit mov) x2 (imm 32))
        (%cc-gen! (lit lslv) x0 x0 x2)
        (%cc-gen! (lit asrv) x0 x0 x2))))

; V as the int its low 32 bits make
(def %cc-gen-int-of
  (fn (_ v)
    (let ((u (& v 4294967295)))
      (if (>= u 2147483648) (- u 4294967296) u))))

; a constant into x0
(def %cc-gen-const!
  (fn (_ v) (asm-load-imm64! %cc-gen-asm x0 (%cc-gen-int-of v))))

; x0 = 1 if the flags satisfy BRANCH, else 0
(def %cc-gen-flag!
  (fn (_ branch)
    (def yes (%cc-gen-label))
    (def done (%cc-gen-label))
    (do (%cc-gen! branch (label yes))
        (%cc-gen! (lit mov) x0 (imm 0))
        (%cc-gen! (lit b) (label done))
        (asm-label! %cc-gen-asm yes)
        (%cc-gen! (lit mov) x0 (imm 1))
        (asm-label! %cc-gen-asm done))))

; the left operand in x0, the right in x1, the result to x0
(def %cc-gen-bin!
  (fn (_ op)
    (match
      ((string=? op "+") (do (%cc-gen! (lit add) x0 x0 x1) (%cc-gen-int!)))
      ((string=? op "-") (do (%cc-gen! (lit sub) x0 x0 x1) (%cc-gen-int!)))
      ((string=? op "*") (do (%cc-gen! (lit mul) x0 x0 x1) (%cc-gen-int!)))
      ((string=? op "/") (do (%cc-gen! (lit sdiv) x0 x0 x1) (%cc-gen-int!)))
      ((string=? op "%")
        (do (%cc-gen! (lit sdiv) x2 x0 x1)
            (%cc-gen! (lit msub) x0 x2 x1 x0)))
      ((string=? op "&") (%cc-gen! (lit and) x0 x0 x1))
      ((string=? op "|") (%cc-gen! (lit orr) x0 x0 x1))
      ((string=? op "^") (%cc-gen! (lit eor) x0 x0 x1))
      ((string=? op "<<") (do (%cc-gen! (lit lslv) x0 x0 x1) (%cc-gen-int!)))
      ((string=? op ">>") (%cc-gen! (lit asrv) x0 x0 x1))
      (#t (%cc-gen-no (string-append "the operator " op))))))

(def %cc-gen-branch
  (fn (_ op)
    (match
      ((string=? op "==") (lit b/eq))
      ((string=? op "!=") (lit b/ne))
      ((string=? op "<")  (lit b/lt))
      ((string=? op "<=") (lit b/le))
      ((string=? op ">")  (lit b/gt))
      ((string=? op ">=") (lit b/ge))
      (#t (%cc-gen-no (string-append "the comparison " op))))))

; --- the frame --------------------------------------------------------------
; Every local and parameter has the size and alignment of its kind, at a
; fixed offset from x19, which the prologue points at the frame it took off
; x20.  A value loads at its width, extended by its sign -- a char
; sign-extends, an unsigned char zero-extends -- and arithmetic happens in
; int, which is what C's promotions make of every kind narrower than int.
; A store narrows the value to its kind's width, and so does the value an
; assignment answers.  long and the unsigned kinds of int's width or more
; want arithmetic of their own, so they refuse by name.

(def %cc-gen-env ())        ; ((name offset . kind) ...)
(def %cc-gen-frame-bytes 0) ; how much of the frame the named ones take
(def %cc-gen-ret-kind ())   ; what the function being compiled returns

; KIND, if the compiled code holds it; WHAT names the holder in a refusal
(def %cc-gen-kind!
  (fn (_ kind what)
    (match
      ((eq? kind (lit int)) kind)
      ((eq? kind (lit char)) kind)
      ((eq? kind (lit uchar)) kind)
      ((eq? kind (lit short)) kind)
      ((eq? kind (lit ushort)) kind)
      ((eq? kind (lit long)) (%cc-gen-no "the type long"))
      ((eq? kind (lit uint)) (%cc-gen-no "the type unsigned int"))
      ((eq? kind (lit ulong)) (%cc-gen-no "the type unsigned long"))
      (#t (%cc-gen-no (string-append what " that is not an integer"))))))

(def %cc-gen-byte? (fn (_ kind) (if (eq? kind (lit char)) #t (eq? kind (lit uchar)))))
(def %cc-gen-half? (fn (_ kind) (if (eq? kind (lit short)) #t (eq? kind (lit ushort)))))

; the load that brings a value of KIND into a register, extended by its sign
(def %cc-gen-load-op
  (fn (_ kind)
    (match
      ((eq? kind (lit char)) (lit ldrsb))
      ((eq? kind (lit uchar)) (lit ldrb))
      ((eq? kind (lit short)) (lit ldrsh))
      ((eq? kind (lit ushort)) (lit ldrh))
      (#t (lit ldrsw)))))

(def %cc-gen-store-op
  (fn (_ kind)
    (match
      ((%cc-gen-byte? kind) (lit strb))
      ((%cc-gen-half? kind) (lit strh))
      (#t (lit strw)))))

; x0 as a value of KIND: shifted to the top of the register and back down,
; arithmetically for a signed kind
(def %cc-gen-narrow!
  (fn (_ kind)
    (def bits (match ((%cc-gen-byte? kind) 56) ((%cc-gen-half? kind) 48) (#t 32)))
    (do (%cc-gen! (lit mov) x2 (imm bits))
        (%cc-gen! (lit lslv) x0 x0 x2)
        (%cc-gen! (if (%cc-signed? kind) (lit asrv) (lit lsrv)) x0 x0 x2))))
(def %cc-gen-loops ())      ; ((break-label . continue-label) ...), innermost first
(def %cc-gen-funs ())       ; ((name . label) ...), every function in the program
(def %cc-gen-epilogue ())   ; where `return` goes in the function being compiled
(def %cc-gen-scratch 0)     ; the slot past the named ones, which the runtime writes from

; A function that calls printf has an area past the scratch slot for it:
; the count of bytes written so far, the cursor into the digits, sixteen
; bytes the digits are built in, then one slot for each argument after the
; format.  It is in the frame, so a printf reached from another's arguments,
; or from a recursive call, has its own.
(def %cc-gen-pf 0)          ; where the area starts
(def %cc-gen-pf-count 0)
(def %cc-gen-pf-cursor 8)
(def %cc-gen-pf-end 32)     ; the digits end here, and the arguments start

; The data a program carries, in the segment the container maps readable and
; writable on the page after the code: the globals first, each at the size
; and alignment of its kind, then the string literals end to end and
; NUL-terminated.  x22 holds where the data starts, taken
; program-counter-relatively by the entry, and everything in it is an offset
; from there.  The globals come first because their offsets are wanted while
; the bodies compile, and a literal's is not settled until one is met.
(def %cc-gen-databytes 0)
(def %cc-gen-data ())       ; ((offset . bytes) ...), the last laid first
(def %cc-gen-globals ())    ; ((name offset . kind) ...)
(def %cc-gen-strings ())    ; ((text . offset) ...)

; room for BYTES in the data, at a multiple of ALIGN; answers where
(def %cc-gen-data!
  (fn (_ bytes align)
    (let ((off (%cc-round-up %cc-gen-databytes align)))
      (do (set! %cc-gen-data (pair (pair off bytes) %cc-gen-data))
          (set! %cc-gen-databytes (+ off (length bytes)))
          off))))

(def %cc-gen-string!
  (fn (_ text)
    (def go (fn (self es)
              (if (null? es) ()
                (if (string=? (first (first es)) text) (rest (first es))
                  (self (rest es))))))
    (def bytes
      (fn (self i out) (if (< i 0) out (self (- i 1) (pair (byte-at text i) out)))))
    (let ((hit (go %cc-gen-strings)))
      (if (not (null? hit)) hit
        (let ((off (%cc-gen-data! (bytes (- (byte-len text) 1) (list 0)) 1)))
          (do (set! %cc-gen-strings (pair (pair text off) %cc-gen-strings))
              off))))))

; (OFFSET . KIND) for a global's name, or nil
(def %cc-gen-global-find
  (fn (_ name)
    (def go (fn (self es)
              (if (null? es) ()
                (if (string=? (first (first es)) name) (rest (first es))
                  (self (rest es))))))
    (go %cc-gen-globals)))

; a global takes room of its kind, and its initializer's value goes in it --
; the low bytes of the value, which is what narrowing it to the kind keeps
(def %cc-gen-global!
  (fn (_ node)
    (def name (first (rest node)))
    (def kind (first (rest (rest node))))
    (if (pair? kind)
      (%cc-gen-no (string-append "a global that is not an integer: " name)))
    (%cc-gen-kind! kind "a global")
    (if (not (null? (%cc-gen-global-find name)))
      (%cc-gen-no (string-append "a second declaration of " name)))
    (def init (first (rest (rest (rest node)))))
    (def v (if (null? init) 0 (%cc-gen-fold init)))
    (def size (%cc-kind-size kind))
    (def off
      (%cc-gen-data!
        (%cc-gen-take size
          (append (%cc-gen-le32 v) (%cc-gen-le32 (if (< v 0) 0xFFFFFFFF 0))))
        size))
    (set! %cc-gen-globals (pair (pair name (pair off kind)) %cc-gen-globals))))

; What a global starts out holding.  C asks for a constant here, so the
; value is worked out now and the program starts with it in place.
(def %cc-gen-fold
  (fn (self node)
    (let ((t (first node)))
      (match
        ((eq? t (lit num)) (%cc-gen-int-of (first (rest node))))
        ((eq? t (lit un))
          (let ((op (first (rest node))) (v (self (first (rest (rest node))))))
            (%cc-gen-int-of
              (match
                ((string=? op "-") (- 0 v))
                ((string=? op "~") (- (- 0 v) 1))
                ((string=? op "!") (if (= v 0) 1 0))
                (#t (%cc-gen-no (string-append "a global initialized with " op)))))))
        ((eq? t (lit bin))
          (%cc-gen-int-of
            (%cc-gen-fold-bin (first (rest node))
              (self (first (rest (rest node))))
              (self (first (rest (rest (rest node))))))))
        (#t (%cc-gen-no "a global initialized by something other than a constant"))))))

(def %cc-gen-fold-bin
  (fn (_ op a b)
    (match
      ((string=? op "+") (+ a b))
      ((string=? op "-") (- a b))
      ((string=? op "*") (* a b))
      ((string=? op "/") (/ a b))
      ((string=? op "%") (% a b))
      ((string=? op "&") (& a b))
      ((string=? op "|") (| a b))
      ((string=? op "^") (^ a b))
      ((string=? op "<<") (<< a b))
      ((string=? op ">>") (>> a b))
      (#t (%cc-gen-no (string-append "a global initialized with " op))))))

; the bytes of the data: every piece at its offset, zeros between.  The
; pieces are listed last-laid first, so the bytes build from the end back.
(def %cc-gen-data-bytes
  (fn (_)
    (def zeros (fn (self n acc) (if (<= n 0) acc (self (- n 1) (pair 0 acc)))))
    (def go
      (fn (self ps cursor acc)
        (if (null? ps) (zeros cursor acc)
          (let ((off (first (first ps))) (bs (rest (first ps))))
            (self (rest ps) off
              (append bs (zeros (- cursor (+ off (length bs))) acc)))))))
    (go %cc-gen-data %cc-gen-databytes ())))

; a literal's address: where the strings start, plus its offset
(def %cc-gen-string-at!
  (fn (_ text)
    (let ((off (%cc-gen-string! text)))
      (do (%cc-gen! (lit mov) x0 x22)
          (if (= off 0) () (%cc-gen! (lit add) x0 x0 (imm off)))))))

; the registers a call hands its arguments in, in order
(def %cc-gen-args (list x0 x1 x2 x8))

; arm64 leaves the return address in the link register, so a function that
; calls another has to save it; x86-64's call puts it on the stack itself.
(def %cc-gen-link ())       ; the link register to save, or nil
(def %cc-gen-lr (reg 30))

; The two backends spell the call apart -- arm64 `bl`, x86-64 `call` -- where
; they share `b` for the plain branch.
(def %cc-gen-callop ())

(def %cc-gen-find
  (fn (_ name)
    (def go (fn (self es)
              (if (null? es) ()
                (if (string=? (first (first es)) name) (rest (first es))
                  (self (rest es))))))
    (go %cc-gen-env)))

; a slot of KIND's size, at a multiple of it; answers its offset
(def %cc-gen-slot!
  (fn (_ name kind)
    (if (not (null? (%cc-gen-find name)))
      (%cc-gen-no (string-append "a second declaration of " name)))
    (def size (%cc-kind-size kind))
    (def off (%cc-round-up %cc-gen-frame-bytes size))
    (set! %cc-gen-frame-bytes (+ off size))
    (set! %cc-gen-env (pair (pair name (pair off kind)) %cc-gen-env))
    off))

; Where a name lives, as (OPERAND . KIND) -- a frame slot, or a global's
; room in the data -- or a refusal naming it.  A local of the same name
; wins, as C says.
(def %cc-gen-place-of
  (fn (_ name)
    (let ((l (%cc-gen-find name)))
      (if (not (null? l)) (pair (mem x19 (first l)) (rest l))
        (let ((g (%cc-gen-global-find name)))
          (if (null? g)
            (%cc-gen-no (string-append "the name " name))
            (pair (mem x22 (first g)) (rest g))))))))

(def %cc-gen-load!
  (fn (_ place) (%cc-gen! (%cc-gen-load-op (rest place)) x0 (first place))))

(def %cc-gen-put!
  (fn (_ place) (%cc-gen! (%cc-gen-store-op (rest place)) x0 (first place))))

; an assignment's store: the value it answers is narrowed as the stored
; one was, which an int already is
(def %cc-gen-store!
  (fn (_ place)
    (do (%cc-gen-put! place)
        (if (eq? (rest place) (lit int)) () (%cc-gen-narrow! (rest place))))))

(def %cc-gen-expr! ())
(set! %cc-gen-expr!
  (fn (self node)
    (let ((t (first node)))
      (match
        ((eq? t (lit num)) (%cc-gen-const! (first (rest node))))
        ((eq? t (lit un))
          (let ((op (first (rest node))))
            (do (self (first (rest (rest node))))
                (match
                  ((string=? op "-")
                    (do (%cc-gen! (lit sub) x0 xzr x0) (%cc-gen-int!)))
                  ((string=? op "~") (%cc-gen! (lit orn) x0 xzr x0))
                  ((string=? op "!")
                    (do (%cc-gen! (lit cmp) x0 (imm 0))
                        (%cc-gen-flag! (lit b/eq))))
                  (#t (%cc-gen-no (string-append "the unary operator " op)))))))
        ((if (eq? t (lit bin)) #t (eq? t (lit cmp)))
          (let ((op (first (rest node))))
            (do (self (first (rest (rest node))))
                (asm-push! %cc-gen-asm x0)
                (self (first (rest (rest (rest node)))))
                (%cc-gen! (lit mov) x1 x0)
                (asm-pop! %cc-gen-asm x0)
                (if (eq? t (lit bin))
                  (%cc-gen-bin! op)
                  (do (%cc-gen! (lit cmp) x0 x1)
                      (%cc-gen-flag! (%cc-gen-branch op)))))))
        ((eq? t (lit var)) (%cc-gen-load! (%cc-gen-place-of (first (rest node)))))
        ((eq? t (lit assign))
          (let ((lv (first (rest node))))
            (if (not (eq? (first lv) (lit var)))
              (%cc-gen-no "an assignment to something other than a name"))
            (do (self (first (rest (rest node))))
                (%cc-gen-store! (%cc-gen-place-of (first (rest lv)))))))
        ((%cc-gen-step? t) (%cc-gen-step! t node))
        ((eq? t (lit ternary))
          (let ((else- (%cc-gen-label)) (done (%cc-gen-label)))
            (do (self (first (rest node)))
                (%cc-gen! (lit cmp) x0 (imm 0))
                (%cc-gen! (lit b/eq) (label else-))
                (self (first (rest (rest node))))
                (%cc-gen! (lit b) (label done))
                (asm-label! %cc-gen-asm else-)
                (self (first (rest (rest (rest node)))))
                (asm-label! %cc-gen-asm done))))
        ((if (eq? t (lit and)) #t (eq? t (lit or)))
          ; the right operand runs only when the left did not settle it
          (let ((no (%cc-gen-label)) (done (%cc-gen-label)))
            (def out (if (eq? t (lit and)) 0 1))
            (def leave (if (eq? t (lit and)) (lit b/eq) (lit b/ne)))
            (do (self (first (rest node)))
                (%cc-gen! (lit cmp) x0 (imm 0))
                (%cc-gen! leave (label no))
                (self (first (rest (rest node))))
                (%cc-gen! (lit cmp) x0 (imm 0))
                (%cc-gen! leave (label no))
                (%cc-gen! (lit mov) x0 (imm (- 1 out)))
                (%cc-gen! (lit b) (label done))
                (asm-label! %cc-gen-asm no)
                (%cc-gen! (lit mov) x0 (imm out))
                (asm-label! %cc-gen-asm done))))
        ((eq? t (lit comma))
          (do (self (first (rest node))) (self (first (rest (rest node))))))
        ((eq? t (lit call)) (%cc-gen-call! (first (rest node)) (first (rest (rest node)))))
        (#t (%cc-gen-no (string-append "the expression " (convert t %string))))))))

; ++ and -- over a name, before or after
(def %cc-gen-step?
  (fn (_ t)
    (match
      ((eq? t (lit preinc)) #t)
      ((eq? t (lit predec)) #t)
      ((eq? t (lit postinc)) #t)
      ((eq? t (lit postdec)) #t)
      (#t #f))))

(def %cc-gen-step!
  (fn (_ t node)
    (def lv (first (rest node)))
    (if (not (eq? (first lv) (lit var)))
      (%cc-gen-no "a step of something other than a name"))
    (def at (%cc-gen-place-of (first (rest lv))))
    (def up (if (eq? t (lit preinc)) #t (eq? t (lit postinc))))
    (def after (if (eq? t (lit preinc)) #t (eq? t (lit predec))))
    (do (%cc-gen-load! at)
        ; the old value waits in x8 for the postfix forms: x2 is the
        ; re-extension's shift amount
        (%cc-gen! (lit mov) x8 x0)
        (%cc-gen! (lit mov) x1 (imm 1))
        (%cc-gen! (if up (lit add) (lit sub)) x0 x0 x1)
        (%cc-gen-int!)
        (%cc-gen-store! at)
        (if after () (%cc-gen! (lit mov) x0 x8)))))

; A call evaluates its arguments left to right, each onto the stack, then
; takes them back into the argument registers -- last argument first, since
; that is the one on top.  The answer comes back in x0.
(def %cc-gen-call!
  (fn (_ name args)
    (if (null? (%cc-gen-fun-find name))
      (match
        ((string=? name "putchar") (%cc-gen-putchar! args))
        ((string=? name "puts") (%cc-gen-puts! args))
        ((string=? name "printf") (%cc-gen-printf! args))
        (#t (%cc-gen-call-fun! name args)))
      (%cc-gen-call-fun! name args))))

; puts, for a literal: the text and the newline it adds, in one write.
; Both are known here, so the newline goes into the string area on the end
; of the text and nothing walks the string at run time.  It answers zero,
; which is one of the answers C allows: any number that is not negative.
(def %cc-gen-puts!
  (fn (_ args)
    (if (not (= (length args) 1))
      (%cc-gen-no "puts with other than one argument"))
    (def arg (first args))
    (if (not (eq? (first arg) (lit str)))
      (%cc-gen-no "puts of something other than a literal"))
    (def text (string-append (first (rest arg)) "\n"))
    (do (%cc-gen-string-at! text)
        (%cc-gen! (lit mov) x1 x0)
        (%cc-gen! (lit mov) x0 (imm 1))
        (%cc-gen! (lit mov) x2 (imm (byte-len text)))
        (%cc-gen! (lit blr) x21)
        (%cc-gen-const! 0))))

(def %cc-gen-call-fun!
  (fn (_ name args)
    (def to (%cc-gen-fun-label name))
    (if (> (length args) (length %cc-gen-args))
      (%cc-gen-no (string-append "a call with more than four arguments: " name)))
    (def push-all
      (fn (self as)
        (if (null? as) ()
          (do (%cc-gen-expr! (first as))
              (asm-push! %cc-gen-asm x0)
              (self (rest as))))))
    (def pop-into
      (fn (self regs)
        (if (null? regs) ()
          (do (self (rest regs)) (asm-pop! %cc-gen-asm (first regs))))))
    (do (push-all args)
        (pop-into (%cc-gen-take (length args) %cc-gen-args))
        (%cc-gen! %cc-gen-callop (label to)))))

; the first N of a list
(def %cc-gen-take
  (fn (self n xs)
    (if (<= n 0) () (if (null? xs) () (pair (first xs) (self (- n 1) (rest xs)))))))

(def %cc-gen-fun-find
  (fn (_ name)
    (def go (fn (self es)
              (if (null? es) ()
                (if (string=? (first (first es)) name) (rest (first es))
                  (self (rest es))))))
    (go %cc-gen-funs)))

(def %cc-gen-fun-label
  (fn (_ name)
    (let ((hit (%cc-gen-fun-find name)))
      (if (null? hit)
        (%cc-gen-no (string-append "a call to " name))
        hit))))

; the low byte of x0 to standard output, from the frame's scratch slot
(def %cc-gen-put-byte!
  (fn (_)
    (def off %cc-gen-scratch)
    (do (%cc-gen! (lit str) x0 (mem x19 off))
        (%cc-gen! (lit mov) x0 (imm 1))
        (%cc-gen! (lit mov) x1 x19)
        (if (= off 0) () (%cc-gen! (lit add) x1 x1 (imm off)))
        (%cc-gen! (lit mov) x2 (imm 1))
        (%cc-gen! (lit blr) x21))))

; putchar, unless the program defines one of its own.  It answers the
; character, as C's does.
(def %cc-gen-putchar!
  (fn (_ args)
    (if (not (= (length args) 1))
      (%cc-gen-no "putchar with other than one argument"))
    (do (%cc-gen-expr! (first args))
        (%cc-gen-put-byte!)
        (%cc-gen! (lit ldr) x0 (mem x19 %cc-gen-scratch)))))

; --- printf ------------------------------------------------------------------
; printf of a literal format is laid out here, at compile time: the format
; splits into runs of text and conversions, a %s's literal and a %% join the
; text around them, and what is left for run time is a write per run of
; text, one per %c, and a conversion to decimal per %d.  Every argument is
; evaluated before anything is written, as a call's are.  It answers the
; count of bytes written, as C's does.

; (PIECES . ARGS) for FORMAT and the arguments after it: each piece is
; (text . STRING), or (d . N) or (c . N) for the Nth argument left to run time
(def %cc-gen-printf-plan
  (fn (_ fmt args)
    (def n (byte-len fmt))
    ; the text gathered so far, as a piece, unless it is empty
    (def flush
      (fn (_ text pieces)
        (let ((s (string-concat (reverse text))))
          (if (= (byte-len s) 0) pieces (pair (pair (lit text) s) pieces)))))
    (def go
      (fn (self i from text args pieces later)
        (match
          ((>= i n)
            (do (if (not (null? args))
                  (%cc-gen-no "printf with more arguments than conversions"))
                (pair (reverse (flush (pair (substring fmt from n) text) pieces))
                  (reverse later))))
          ((not (= (byte-at fmt i) 37)) (self (+ i 1) from text args pieces later))
          ((>= (+ i 1) n) (%cc-gen-no "printf's % at the end of its format"))
          (#t
            (let ((c (byte-at fmt (+ i 1)))
                  (text (pair (substring fmt from i) text)))
              (match
                ((= c 37) (self (+ i 2) (+ i 2) (pair "%" text) args pieces later))
                ((not (if (= c 115) #t (if (= c 100) #t (= c 99))))
                  (%cc-gen-no
                    (string-append "printf's %" (substring fmt (+ i 1) (+ i 2)))))
                ((null? args) (%cc-gen-no "printf with fewer arguments than conversions"))
                ((= c 115)
                  (if (not (eq? (first (first args)) (lit str)))
                    (%cc-gen-no "printf's %s of something other than a literal")
                    (self (+ i 2) (+ i 2) (pair (first (rest (first args))) text)
                      (rest args) pieces later)))
                (#t
                  (self (+ i 2) (+ i 2) () (rest args)
                    (pair (pair (if (= c 100) (lit d) (lit c)) (length later))
                      (flush text pieces))
                    (pair (first args) later)))))))))
    (go 0 0 () args () ())))

; the most arguments a call to printf in NODE takes, the format included;
; 0 when there is none
(def %cc-gen-printf-width
  (fn (self node)
    (if (not (pair? node)) 0
      (let ((here (if (if (eq? (first node) (lit call)) (string=? (first (rest node)) "printf") #f)
                    (length (first (rest (rest node))))
                    0)))
        (def go
          (fn (self2 xs best)
            (if (null? xs) best
              (self2 (rest xs) (let ((w (self (first xs)))) (if (> w best) w best))))))
        (go node here)))))

; x0 bytes were just written: they go on the count
(def %cc-gen-printf-count!
  (fn (_)
    (def at (mem x19 (+ %cc-gen-pf %cc-gen-pf-count)))
    (do (%cc-gen! (lit ldr) x1 at)
        (%cc-gen! (lit add) x1 x1 x0)
        (%cc-gen! (lit str) x1 at))))

; A run of text: its bytes are in the data, so one write.
(def %cc-gen-printf-text!
  (fn (_ text)
    (do (%cc-gen-string-at! text)
        (%cc-gen! (lit mov) x1 x0)
        (%cc-gen! (lit mov) x0 (imm 1))
        (%cc-gen! (lit mov) x2 (imm (byte-len text)))
        (%cc-gen! (lit blr) x21)
        (%cc-gen-printf-count!))))

; A %d: the sign first if there is one, then the digits, built from the end
; of the buffer back.  The cursor lives in its slot rather than a register:
; x86-64's multiply-and-subtract leaves its product where the quotient was,
; so the quotient is copied out first and every register is spoken for.
; The magnitude of the most negative int still fits the 64-bit register.
(def %cc-gen-printf-int!
  (fn (_ slot)
    (def cursor (mem x19 (+ %cc-gen-pf %cc-gen-pf-cursor)))
    (def end (+ %cc-gen-pf %cc-gen-pf-end))
    (def plus (%cc-gen-label))
    (def digit (%cc-gen-label))
    (do (%cc-gen! (lit ldr) x0 (mem x19 slot))
        (%cc-gen! (lit cmp) x0 (imm 0))
        (%cc-gen! (lit b/ge) (label plus))
        (%cc-gen! (lit sub) x0 xzr x0)
        (%cc-gen! (lit str) x0 (mem x19 slot))
        (%cc-gen! (lit mov) x0 (imm 45))
        (%cc-gen-put-byte!)
        (%cc-gen-printf-count!)
        (%cc-gen! (lit ldr) x0 (mem x19 slot))
        (asm-label! %cc-gen-asm plus)
        (%cc-gen! (lit mov) x2 x19)
        (%cc-gen! (lit add) x2 x2 (imm end))
        (%cc-gen! (lit str) x2 cursor)
        (%cc-gen! (lit mov) x8 (imm 10))
        (asm-label! %cc-gen-asm digit)
        (%cc-gen! (lit sdiv) x2 x0 x8)
        (%cc-gen! (lit mov) x1 x2)
        (%cc-gen! (lit msub) x0 x2 x8 x0)
        (%cc-gen! (lit add) x0 x0 (imm 48))
        (%cc-gen! (lit ldr) x2 cursor)
        (%cc-gen! (lit sub) x2 x2 (imm 1))
        (%cc-gen! (lit strb) x0 (mem x2 0))
        (%cc-gen! (lit str) x2 cursor)
        (%cc-gen! (lit mov) x0 x1)
        (%cc-gen! (lit cmp) x0 (imm 0))
        (%cc-gen! (lit b/ne) (label digit))
        ; the digits, from the cursor to the end
        (%cc-gen! (lit ldr) x1 cursor)
        (%cc-gen! (lit mov) x2 x19)
        (%cc-gen! (lit add) x2 x2 (imm end))
        (%cc-gen! (lit sub) x2 x2 x1)
        (%cc-gen! (lit mov) x0 (imm 1))
        (%cc-gen! (lit blr) x21)
        (%cc-gen-printf-count!))))

(def %cc-gen-printf!
  (fn (_ args)
    (if (null? args) (%cc-gen-no "printf without a format"))
    (if (not (eq? (first (first args)) (lit str)))
      (%cc-gen-no "printf of a format that is not a literal"))
    (def plan (%cc-gen-printf-plan (first (rest (first args))) (rest args)))
    (def later (rest plan))
    (def arg-at (fn (_ k) (+ %cc-gen-pf (+ %cc-gen-pf-end (* 8 k)))))
    (def push-all
      (fn (self as)
        (if (null? as) ()
          (do (%cc-gen-expr! (first as))
              (asm-push! %cc-gen-asm x0)
              (self (rest as))))))
    ; the last one pushed is on top, so the slots fill from the last back
    (def pop-all
      (fn (self k)
        (if (< k 0) ()
          (do (asm-pop! %cc-gen-asm x0)
              (%cc-gen! (lit str) x0 (mem x19 (arg-at k)))
              (self (- k 1))))))
    (def emit
      (fn (self pieces)
        (if (null? pieces) ()
          (let ((p (first pieces)))
            (do (match
                  ((eq? (first p) (lit text)) (%cc-gen-printf-text! (rest p)))
                  ((eq? (first p) (lit c))
                    (do (%cc-gen! (lit ldr) x0 (mem x19 (arg-at (rest p))))
                        (%cc-gen-put-byte!)
                        (%cc-gen-printf-count!)))
                  (#t (%cc-gen-printf-int! (arg-at (rest p)))))
                (self (rest pieces)))))))
    (do (push-all later)
        (pop-all (- (length later) 1))
        ; the count starts once the arguments are in: one of them may have
        ; been a printf of its own, in this same frame
        (%cc-gen! (lit mov) x0 (imm 0))
        (%cc-gen! (lit str) x0 (mem x19 (+ %cc-gen-pf %cc-gen-pf-count)))
        (emit (first plan))
        (%cc-gen! (lit ldr) x0 (mem x19 (+ %cc-gen-pf %cc-gen-pf-count))))))

; --- statements --------------------------------------------------------------

; a condition, then a branch taken when it is false
(def %cc-gen-test!
  (fn (_ node to)
    (do (%cc-gen-expr! node)
        (%cc-gen! (lit cmp) x0 (imm 0))
        (%cc-gen! (lit b/eq) (label to)))))

(def %cc-gen-loop-label
  (fn (_ which)
    (if (null? %cc-gen-loops)
      (%cc-gen-no (string-append which " outside a loop"))
      (if (string=? which "break")
        (first (first %cc-gen-loops))
        (rest (first %cc-gen-loops))))))

(def %cc-gen-stmt! ())
(set! %cc-gen-stmt!
  (fn (self node)
    (let ((t (first node)))
      (match
        ((eq? t (lit block))
          (let ((go (fn (self2 items)
                      (if (null? items) ()
                        (do (self (first items)) (self2 (rest items)))))))
            (go (first (rest node)))))
        ((eq? t (lit decl))
          ; the scan gave it its slot before any code was emitted, and a
          ; local of the name wins over a global of it
          (let ((at (%cc-gen-place-of (first (rest node)))))
            (def init (first (rest (rest (rest node)))))
            (do (if (null? init) (%cc-gen-const! 0) (%cc-gen-expr! init))
                (%cc-gen-put! at))))
        ((eq? t (lit expr)) (%cc-gen-expr! (first (rest node))))
        ((eq? t (lit if))
          (let ((other (%cc-gen-label)) (done (%cc-gen-label)))
            (def else- (first (rest (rest (rest node)))))
            (do (%cc-gen-test! (first (rest node)) other)
                (self (first (rest (rest node))))
                (%cc-gen! (lit b) (label done))
                (asm-label! %cc-gen-asm other)
                (if (null? else-) () (self else-))
                (asm-label! %cc-gen-asm done))))
        ((eq? t (lit while))
          (let ((top (%cc-gen-label)) (out (%cc-gen-label)))
            (set! %cc-gen-loops (pair (pair out top) %cc-gen-loops))
            (do (asm-label! %cc-gen-asm top)
                (%cc-gen-test! (first (rest node)) out)
                (self (first (rest (rest node))))
                (%cc-gen! (lit b) (label top))
                (asm-label! %cc-gen-asm out)
                (set! %cc-gen-loops (rest %cc-gen-loops)))))
        ((eq? t (lit do))
          (let ((top (%cc-gen-label)) (again (%cc-gen-label)) (out (%cc-gen-label)))
            (set! %cc-gen-loops (pair (pair out again) %cc-gen-loops))
            (do (asm-label! %cc-gen-asm top)
                (self (first (rest node)))
                (asm-label! %cc-gen-asm again)
                (%cc-gen-expr! (first (rest (rest node))))
                (%cc-gen! (lit cmp) x0 (imm 0))
                (%cc-gen! (lit b/ne) (label top))
                (asm-label! %cc-gen-asm out)
                (set! %cc-gen-loops (rest %cc-gen-loops)))))
        ((eq? t (lit for))
          ; the step is where `continue` lands, so it runs on every path
          (let ((top (%cc-gen-label)) (step (%cc-gen-label)) (out (%cc-gen-label)))
            (def init (first (rest node)))
            (def test (first (rest (rest node))))
            (def up (first (rest (rest (rest node)))))
            (set! %cc-gen-loops (pair (pair out step) %cc-gen-loops))
            ; the init is a declaration or a bare expression
            (do (if (null? init) ()
                  (if (eq? (first init) (lit decl)) (self init) (%cc-gen-expr! init)))
                (asm-label! %cc-gen-asm top)
                (if (null? test) () (%cc-gen-test! test out))
                (self (first (rest (rest (rest (rest node))))))
                (asm-label! %cc-gen-asm step)
                (if (null? up) () (%cc-gen-expr! up))
                (%cc-gen! (lit b) (label top))
                (asm-label! %cc-gen-asm out)
                (set! %cc-gen-loops (rest %cc-gen-loops)))))
        ((eq? t (lit return))
          (do (if (null? (first (rest node)))
                (%cc-gen-const! 0)
                (%cc-gen-expr! (first (rest node))))
              ; the value converts to what the function returns
              (if (if (%cc-gen-byte? %cc-gen-ret-kind) #t (%cc-gen-half? %cc-gen-ret-kind))
                (%cc-gen-narrow! %cc-gen-ret-kind)
                ())
              (%cc-gen! (lit b) (label %cc-gen-epilogue))))
        ((eq? t (lit break))
          (%cc-gen! (lit b) (label (%cc-gen-loop-label "break"))))
        ((eq? t (lit continue))
          (%cc-gen! (lit b) (label (%cc-gen-loop-label "continue"))))
        (#t (%cc-gen-no (string-append "the statement " (convert t %string))))))))

; the bytes at P from offset 0 through I, as a list
(def %cc-gen-read
  (fn (self p i acc)
    (if (< i 0) acc (self p (- i 1) (pair (mem-ref-byte p i) acc)))))

; --- a function --------------------------------------------------------------

; Every declaration in the body takes a slot before any code is emitted: the
; prologue has to know the frame's size, and it comes first.
(def %cc-gen-scan!
  (fn (self node)
    (if (not (pair? node)) ()
      (let ((t (first node)))
        (match
          ((eq? t (lit decl))
            (%cc-gen-slot! (first (rest node))
              (%cc-gen-kind! (first (rest (rest node))) "a local")))
          ((eq? t (lit block))
            (let ((go (fn (self2 items)
                        (if (null? items) ()
                          (do (self (first items)) (self2 (rest items)))))))
              (go (first (rest node)))))
          ((eq? t (lit if))
            (do (self (first (rest (rest node))))
                (let ((e (first (rest (rest (rest node))))))
                  (if (null? e) () (self e)))))
          ((eq? t (lit while)) (self (first (rest (rest node)))))
          ((eq? t (lit do)) (self (first (rest node))))
          ((eq? t (lit for))
            (do (let ((i (first (rest node)))) (if (null? i) () (self i)))
                (self (first (rest (rest (rest (rest node))))))))
          (#t ()))))))

(def %cc-gen-fun!
  (fn (_ f)
    (def params (first (rest (rest f))))
    (def body (first (rest (rest (rest f)))))
    (def kinds (first (rest (rest (rest (rest f))))))
    (def ret (first (rest (rest (rest (rest (rest f)))))))
    (if (> (length params) (length %cc-gen-args))
      (%cc-gen-no (string-append "more than four parameters: " (first (rest f)))))
    (set! %cc-gen-ret-kind
      (if (eq? ret (lit void)) ret (%cc-gen-kind! ret "a function returning something")))
    (set! %cc-gen-env ())
    (set! %cc-gen-frame-bytes 0)
    (set! %cc-gen-loops ())
    (set! %cc-gen-epilogue (%cc-gen-label))
    ; the parameters take the first slots, then the body's declarations
    (def places
      (let ((go (fn (self ps ks)
                  (if (null? ps) ()
                    (let ((k (%cc-gen-kind! (first ks) "a parameter")))
                      (pair (pair (mem x19 (%cc-gen-slot! (first ps) k)) k)
                        (self (rest ps) (rest ks))))))))
        (go params kinds)))
    (%cc-gen-scan! body)
    ; the slot past the named ones, for the runtime to write a byte from,
    ; then printf's area if the function calls it
    (set! %cc-gen-scratch (%cc-round-up %cc-gen-frame-bytes 8))
    (set! %cc-gen-pf (+ %cc-gen-scratch 8))
    (def width
      (if (null? (%cc-gen-fun-find "printf")) (%cc-gen-printf-width body) 0))
    (def pf-slots (if (= width 0) 0 (+ 3 width)))
    (def frame (%cc-round-up (+ %cc-gen-pf (* 8 pf-slots)) 16))
    (if (> frame 4080) (%cc-gen-no "a frame past four kilobytes"))
    (asm-label! %cc-gen-asm (%cc-gen-fun-label (first (rest f))))
    ; prologue: the caller's frame base is saved, this one taken off x20
    (if (null? %cc-gen-link) () (asm-push! %cc-gen-asm %cc-gen-link))
    (asm-push! %cc-gen-asm x19)
    ; an immediate, not a scratch register: the arguments are still in theirs
    (if (= frame 0) () (%cc-gen! (lit sub) x20 x20 (imm frame)))
    (%cc-gen! (lit mov) x19 x20)
    ; the arguments arrived in registers; they live in slots from here,
    ; each narrowed to its parameter's kind as it is stored
    (let ((go (fn (self ps regs)
                (if (null? ps) ()
                  (do (%cc-gen! (%cc-gen-store-op (rest (first ps))) (first regs)
                        (first (first ps)))
                      (self (rest ps) (rest regs)))))))
      (go places %cc-gen-args))
    (%cc-gen-stmt! body)
    ; falling off the end answers 0, which is what C says of main
    (%cc-gen-const! 0)
    (asm-label! %cc-gen-asm %cc-gen-epilogue)
    (if (= frame 0) () (%cc-gen! (lit add) x20 x20 (imm frame)))
    (asm-pop! %cc-gen-asm x19)
    (if (null? %cc-gen-link) () (asm-pop! %cc-gen-asm %cc-gen-link))
    (%cc-gen! (lit ret))))

; --- the program -------------------------------------------------------------

; the image for SRC on TARGET, as (CODE . DATA): the entry, then main, then
; the rest.  main comes first because the entry branches to a fixed offset.
(def cc-compile-image
  (fn (_ src target)
    (def prog (cc-parse (cc-lex src)))
    (def funs (filter (fn (_ it) (eq? (first it) (lit fun))) prog))
    (def mains (filter (fn (_ f) (string=? (first (rest f)) "main")) funs))
    (if (null? mains) (%cc-gen-no "a program without main"))
    (def main (first mains))
    (if (not (null? (first (rest (rest main))))) (%cc-gen-no "parameters to main"))
    (def others (filter (fn (_ f) (not (string=? (first (rest f)) "main"))) funs))
    ; the globals take the front of the data, before a body asks for one
    (set! %cc-gen-globals ())
    (set! %cc-gen-strings ())
    (set! %cc-gen-databytes 0)
    (set! %cc-gen-data ())
    (let ((go (fn (self ds)
                (if (null? ds) ()
                  (do (%cc-gen-global! (first ds)) (self (rest ds)))))))
      (go (filter (fn (_ it) (eq? (first it) (lit gdecl))) prog)))
    (def a (asm-new 262144))
    (set! %cc-gen-asm a)
    (set! %cc-gen-nlabels 0)
    (set! %cc-gen-link (if (eq? target (lit macho-arm64)) %cc-gen-lr ()))
    (set! %cc-gen-callop (if (eq? target (lit macho-arm64)) (lit bl) (lit call)))
    ; every function gets its label before any code, so a call can name one
    ; that has not been compiled yet
    (set! %cc-gen-funs ())
    (let ((go (fn (self fs)
                (if (null? fs) ()
                  (do (set! %cc-gen-funs
                        (pair (pair (first (rest (first fs))) (%cc-gen-label))
                          %cc-gen-funs))
                      (self (rest fs)))))))
      (go funs))
    ; a refusal can raise partway through; the buffer is released first
    (guard (err (do (asm-free! a)
                    (set! %cc-gen-asm ())
                    (error err (if (Err err? err) (err msg) "cc: compile failed"))))
      (let ((go (fn (self fs) (if (null? fs) () (do (%cc-gen-fun! (first fs)) (self (rest fs)))))))
        (go (pair main others))))
    (def n (asm-pos a))
    (def code (%cc-gen-read (asm-finalize! a) (- n 1) ()))
    (asm-free! a)
    (set! %cc-gen-asm ())
    (def entry
      (%cc-gen-entry target (%cc-gen-data-at target (+ (%cc-gen-entry-len target) n))))
    ; the entry's two addresses are taken from where it stands, so a length
    ; the layout did not expect would point them somewhere else
    (if (not (= (length entry) (%cc-gen-entry-len target)))
      (Err raise (lit cc) "cc: compile: the entry is not the length the layout takes it for" ()))
    (pair (append entry code) (%cc-gen-data-bytes))))

; compile SRC to an executable at PATH
(def cc-compile
  (fn (_ src path)
    (def target (%cc-gen-target))
    (def image (cc-compile-image src target))
    (if (eq? target (lit macho-arm64))
      (%cc-macho-write! path (first image) (rest image))
      (%cc-elf-write! path (first image) (rest image) %cc-elf-machine-x86-64))))

; compile SRC, run the executable, print what it wrote, answer its status
(def cc-exe-run
  (fn (_ src)
    (def path
      (string-append "/tmp/x-cc-exe-"
        (substring (sha256-hex-n src (byte-len src)) 0 16)))
    (cc-compile src path)
    (let ((r (proc-capture (list path))))
      (do (display (rest r)) (first r)))))
