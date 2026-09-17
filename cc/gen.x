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
; Compiled so far: `int main(void)` with integer locals, assignment, ++ and
; --, `if`/`else`, `while`, `do`, `for`, `break`, `continue` and `return`,
; over integer constants, + - * / %, & | ^ << >>, the six comparisons, &&,
; ||, the ternary, the comma and unary - ~ !.  Everything else refuses by
; name: globals, other functions, calls, pointers and aggregates.

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

; the frame the locals need, in bytes: the stack stays sixteen-aligned, and
; the entry's one reserving instruction takes twelve bits of it
(def %cc-gen-frame
  (fn (_)
    (def n (let ((m (+ (* 8 %cc-gen-slots) 15))) (- m (% m 16))))
    (if (> n 4080) (%cc-gen-no "a frame past four kilobytes") n)))

(def %cc-gen-entry
  (fn (_ target frame)
    (def nr (syscall-id (lit exit)))
    (if (eq? target (lit macho-arm64))
      ; sub sp, #frame; mov x19, sp; bl main (three words on);
      ; movz x16, #exit; svc #0x80
      (append (%cc-gen-le32 (| 0xD10003FF (<< frame 10)))
        (append (%cc-gen-le32 0x910003F3)
          (append (%cc-gen-le32 0x94000003)
            (append (%cc-gen-le32 (| 0xD2800010 (<< nr 5)))
              (%cc-gen-le32 0xD4001001)))))
      ; sub rsp, frame; mov rbx, rsp; call main (ten bytes on);
      ; mov rdi, rax; mov eax, exit; syscall
      (append (list 0x48 0x81 0xEC)
        (append (%cc-gen-le32 frame)
          (append (list 0x48 0x89 0xE3 0xE8 10 0 0 0 0x48 0x89 0xC7 0xB8)
            (append (%cc-gen-le32 nr) (list 0x0F 0x05))))))))

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

; a constant into x0, as the int its low 32 bits make
(def %cc-gen-const!
  (fn (_ v)
    (let ((u (& v 4294967295)))
      (asm-load-imm64! %cc-gen-asm x0 (if (>= u 2147483648) (- u 4294967296) u)))))

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
; Every local is one eight-byte slot at a fixed offset from x19, which the
; entry points at the frame it reserved.  A slot holds a whole machine word;
; the narrower loads and stores a `char` or `short` local wants are a
; recorded pending, and arithmetic re-extends from bit 31 as C's `int` does.

(def %cc-gen-env ())        ; ((name . offset) ...)
(def %cc-gen-slots 0)
(def %cc-gen-loops ())      ; ((break-label . continue-label) ...), innermost first

(def %cc-gen-find
  (fn (_ name)
    (def go (fn (self es)
              (if (null? es) ()
                (if (string=? (first (first es)) name) (rest (first es))
                  (self (rest es))))))
    (go %cc-gen-env)))

(def %cc-gen-slot!
  (fn (_ name)
    (if (not (null? (%cc-gen-find name)))
      (%cc-gen-no (string-append "a second declaration of " name)))
    (def off (* 8 %cc-gen-slots))
    (set! %cc-gen-slots (+ %cc-gen-slots 1))
    (set! %cc-gen-env (pair (pair name off) %cc-gen-env))
    off))

; the slot a name stands for, or a refusal naming it
(def %cc-gen-slot-of
  (fn (_ name)
    (let ((off (%cc-gen-find name)))
      (if (null? off) (%cc-gen-no (string-append "the name " name)) off))))

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
        ((eq? t (lit var))
          (%cc-gen! (lit ldr) x0 (mem x19 (%cc-gen-slot-of (first (rest node))))))
        ((eq? t (lit assign))
          (let ((lv (first (rest node))))
            (if (not (eq? (first lv) (lit var)))
              (%cc-gen-no "an assignment to something other than a name"))
            (do (self (first (rest (rest node))))
                (%cc-gen! (lit str) x0
                  (mem x19 (%cc-gen-slot-of (first (rest lv))))))))
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
    (def off (%cc-gen-slot-of (first (rest lv))))
    (def up (if (eq? t (lit preinc)) #t (eq? t (lit postinc))))
    (def after (if (eq? t (lit preinc)) #t (eq? t (lit predec))))
    (do (%cc-gen! (lit ldr) x0 (mem x19 off))
        ; the old value waits in x8 for the postfix forms: x2 is the
        ; re-extension's shift amount
        (%cc-gen! (lit mov) x8 x0)
        (%cc-gen! (lit mov) x1 (imm 1))
        (%cc-gen! (if up (lit add) (lit sub)) x0 x0 x1)
        (%cc-gen-int!)
        (%cc-gen! (lit str) x0 (mem x19 off))
        (if after () (%cc-gen! (lit mov) x0 x8)))))

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
          (let ((kind (first (rest (rest node)))))
            (if (pair? kind)
              (%cc-gen-no "a local that is not an integer"))
            (def off (%cc-gen-slot! (first (rest node))))
            (def init (first (rest (rest (rest node)))))
            (do (if (null? init) (%cc-gen-const! 0) (%cc-gen-expr! init))
                (%cc-gen! (lit str) x0 (mem x19 off)))))
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
              (%cc-gen! (lit ret))))
        ((eq? t (lit break))
          (%cc-gen! (lit b) (label (%cc-gen-loop-label "break"))))
        ((eq? t (lit continue))
          (%cc-gen! (lit b) (label (%cc-gen-loop-label "continue"))))
        (#t (%cc-gen-no (string-append "the statement " (convert t %string))))))))

; the bytes at P from offset 0 through I, as a list
(def %cc-gen-read
  (fn (self p i acc)
    (if (< i 0) acc (self p (- i 1) (pair (mem-ref-byte p i) acc)))))

; --- the program -------------------------------------------------------------

; the code for SRC on TARGET: the entry, then main
(def cc-compile-bytes
  (fn (_ src target)
    (def prog (cc-parse (cc-lex src)))
    (if (not (null? (filter (fn (_ it) (not (eq? (first it) (lit fun)))) prog)))
      (%cc-gen-no "global declarations"))
    (if (not (= (length prog) 1)) (%cc-gen-no "functions other than main"))
    (def f (first prog))
    (if (not (string=? (first (rest f)) "main")) (%cc-gen-no "a program without main"))
    (if (not (null? (first (rest (rest f))))) (%cc-gen-no "parameters to main"))
    (def body (first (rest (rest (rest f)))))
    (def a (asm-new 65536))
    (set! %cc-gen-asm a)
    (set! %cc-gen-nlabels 0)
    (set! %cc-gen-env ())
    (set! %cc-gen-slots 0)
    (set! %cc-gen-loops ())
    ; a refusal can raise partway through; the buffer is released first
    (guard (err (do (asm-free! a)
                    (set! %cc-gen-asm ())
                    (error err (if (Err err? err) (err msg) "cc: compile failed"))))
      (do (%cc-gen-stmt! body)
          ; running off the end of main answers 0, as C says
          (%cc-gen-const! 0)
          (%cc-gen! (lit ret))))
    (def n (asm-pos a))
    (def code (%cc-gen-read (asm-finalize! a) (- n 1) ()))
    (def frame (%cc-gen-frame))
    (asm-free! a)
    (set! %cc-gen-asm ())
    (append (%cc-gen-entry target frame) code)))

; compile SRC to an executable at PATH
(def cc-compile
  (fn (_ src path)
    (def target (%cc-gen-target))
    (def bytes (cc-compile-bytes src target))
    (if (eq? target (lit macho-arm64))
      (%cc-macho-write! path bytes)
      (%cc-elf-write! path bytes %cc-elf-machine-x86-64))))

; compile SRC, run the executable, print what it wrote, answer its status
(def cc-exe-run
  (fn (_ src)
    (def path
      (string-append "/tmp/x-cc-exe-"
        (substring (sha256-hex-n src (byte-len src)) 0 16)))
    (cc-compile src path)
    (let ((r (proc-capture (list path))))
      (do (display (rest r)) (first r)))))
