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
; Compiled so far: `int main(void) { return EXPR; }`, where EXPR is built
; from integer constants, + - * / %, & | ^ << >>, the six comparisons, and
; unary - ~ !.  Everything else refuses by name.

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

(def %cc-gen-entry
  (fn (_ target)
    (def nr (syscall-id (lit exit)))
    (if (eq? target (lit macho-arm64))
      ; bl main (three words on); movz x16, #exit; svc #0x80
      (append (%cc-gen-le32 0x94000003)
        (append (%cc-gen-le32 (| 0xD2800010 (<< nr 5)))
          (%cc-gen-le32 0xD4001001)))
      ; call main (ten bytes on); mov rdi, rax; mov eax, exit; syscall
      (append (list 0xE8 10 0 0 0 0x48 0x89 0xC7 0xB8)
        (append (%cc-gen-le32 nr) (list 0x0F 0x05))))))

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
        (#t (%cc-gen-no (string-append "the expression " (convert t %string))))))))

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
    (def items (first (rest (first (rest (rest (rest f)))))))
    (if (not (if (= (length items) 1) (eq? (first (first items)) (lit return)) #f))
      (%cc-gen-no "a body other than one return"))
    (def e (first (rest (first items))))
    (if (null? e) (%cc-gen-no "a return with no value"))
    (def a (asm-new 65536))
    (set! %cc-gen-asm a)
    (set! %cc-gen-nlabels 0)
    ; a refusal can raise partway through; the buffer is released first
    (guard (err (do (asm-free! a)
                    (set! %cc-gen-asm ())
                    (error err (if (Err err? err) (err msg) "cc: compile failed"))))
      (do (%cc-gen-expr! e) (%cc-gen! (lit ret))))
    (def n (asm-pos a))
    (def body (%cc-gen-read (asm-finalize! a) (- n 1) ()))
    (asm-free! a)
    (set! %cc-gen-asm ())
    (append (%cc-gen-entry target) body)))

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
