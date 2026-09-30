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
; right, moves it to x1 and pops the left back into x0.  Every value is held
; in the form of its C type (the integer C types, below), and an operator whose
; result can leave that form puts it back, so arithmetic wraps as C's does.
;
; Compiled so far: main and the functions beside it, with globals, locals
; (static ones kept once, in the data), and parameters of `char`, `short`,
; `int` and `long`, signed and unsigned, `double` and `float`,
; pointers to anything, and arrays, structs and unions of any of these, each
; at its C type's size,
; assignment, ++ and --, `if`/`else`, `while`, `do`, `for`, `switch`,
; `break`, `continue`, `return` and calls (recursion included), over integer
; constants whose C type comes from their suffixes, floating constants and string
; literals, + - * / %,
; & | ^ << >>, the six comparisons, &&, ||, the ternary, the comma,
; unary - ~ ! & *, casts, subscripts, `.` and `->`, each in the C type C's
; usual conversions give it, and calls into the C library -- six arguments
; at most, a variadic function's through its v- form; pointers to
; functions, which the C library can call back through; structs are passed
; and returned by value.  Everything else refuses by name: `long double`
; among it.
;
; The convention is this compiler's own, since nothing else links with what
; it writes: of the first four arguments, the ones that are not structs in
; x0, x1, x2 and x8, and the rest -- structs whole -- at the top of the
; callee's frame, under the word that says where a struct it answers goes;
; the answer in x0, frames off x20 in a region below the machine stack,
; x19 the frame's base, x21 the trampoline into the C library and x22 the
; data.  A call to a function the program does not define goes to the C
; library, through a slot in the data the loader fills.
(module cc/gen)

(import x/tool/asm)
(import x/platform/syscall)
(import cc/prims append byte-at byte-len convert filter length map mem-ref-byte
  proc-capture reverse sha256-hex-n string-append string-concat string=?
  substring)
(import cc/lex cc-lex)
(import cc/parse cc-parse c-type-size c-type-align round-up struct-entry)
(import cc/eval common-c-type c-type-elem library-c-type
  library-double-label library-variadic promoted-c-type signed? unsigned-divide)
(import cc/real convert-real real-arith real-negate)
(import cc/macho macho-write! macho-data-at)
(import cc/elf elf-write! elf-data-at elf-machine-x86-64)

; The type handles this file asks convert for, fetched by name through the
; platform's public door and private to this module.
(def %string (Type named STRING))
(def %symbol (Type named SYMBOL))

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
; Four megabytes of the eight a process's stack has on both targets; a
; frame takes at most a megabyte of it.
(def %cc-gen-region 4194304)
(def %cc-gen-frame-most 1048576)

; the bytes of several pieces, in order
(def %cc-gen-cat
  (fn (self pieces)
    (if (null? pieces) () (append (first pieces) (self (rest pieces))))))

; adr RD, #IMM -- the address IMM bytes on from this instruction
(def %cc-gen-adr
  (fn (_ rd imm)
    (| 0x10000000
      (| (<< (& imm 3) 29) (| (<< (& (>> imm 2) 0x7FFFF) 5) rd)))))

; The entry, and the one piece of it compiled code calls: a trampoline into
; the C library.  Neither is made of portable mnemonics -- the trampoline
; takes more argument registers than the portable call does -- so both are
; written out per target.
;
; The entry calls main and hands what it answers to the C library's exit,
; whose slot is the data's first eight bytes, so exit writes out what the
; library's streams hold.  It puts the trampoline's address in x21, where
; nothing the generator emits touches it.  Compiled code calls the
; trampoline with x0 the address of six eight-byte integer arguments and
; four doubles after them, and x8 the function; the trampoline loads the
; arguments where the C calling convention takes them -- the integers in
; the general registers, the doubles in d0 to d3 -- gives the stack the
; sixteen-byte alignment the convention asks for, and calls the function,
; whose answer comes back in x0, or in d0 for a double.  x86-64's
; indirect call puts x0 in rdi on the way in.
;
; main is handed argc in x0 and argv in x1, as any call's first two
; arguments: dyld calls a Mach-O's entry as it would main, with the two
; already there, and the ELF's entry loads them from the stack the kernel
; starts it on, argc on top and the pointers after it.
;
; x22 gets the address of the data, which the container puts on the page
; after the code.  DATAAT is how far that is from the entry's first byte,
; which the container works out; the entry is a fixed length per target, so
; the two instructions that take the address know where they stand.
(def %cc-gen-entry
  (fn (_ target dataat)
    (if (eq? target (lit macho-arm64))
      ; seventeen words: adr x21, the trampoline; adr x22, the data;
      ; mov x20, sp; sub sp, #4M; bl main (thirteen words on);
      ; ldr x16, [x22]; br x16 -- exit, with main's answer in x0; then the
      ; trampoline: stp x29, x30, [sp, #-16]!; mov x9, x0; ldp x0, x1,
      ; [x9]; ldp x2, x3, [x9, #16]; ldp x4, x5, [x9, #32]; ldp d0, d1,
      ; [x9, #48]; ldp d2, d3, [x9, #64]; blr x8; ldp x29, x30, [sp], #16;
      ; ret
      (%cc-gen-cat
        (map %cc-gen-le32
          (list (%cc-gen-adr 21 28)
                (%cc-gen-adr 22 (- dataat 4))
                0x910003F4
                (| 0xD14003FF (<< (/ %cc-gen-region 4096) 10))
                0x9400000D
                0xF94002D0 0xD61F0200
                0xA9BF7BFD 0xAA0003E9 0xA9400520 0xA9410D22 0xA9421524
                0x6D430520 0x6D440D22 0xD63F0100 0xA8C17BFD 0xD65F03C0)))
      ; a hundred and nineteen bytes: mov rax, [rsp] (argc); lea rsi,
      ; [rsp+8] (argv); lea r13, [rip+35] (the trampoline); lea r14,
      ; [rip+...] (the data); mov r12, rsp; sub rsp, 4M; call main
      ; (eighty-one bytes on); mov rdi, rax; mov r11, [r14]; and rsp, -16;
      ; call r11 -- exit; then the trampoline: push rbp; mov rbp, rsp;
      ; and rsp, -16; mov r11, rdi; mov rdi, [r11]; mov rsi, [r11+8];
      ; mov rdx, [r11+16]; mov rcx, [r11+24]; mov r8, [r11+32];
      ; mov r9, [r11+40]; movsd xmm0..xmm3, [r11+48..72]; xor eax, eax;
      ; call r10; mov rsp, rbp; pop rbp; ret
      (%cc-gen-cat
        (list (list 0x48 0x8B 0x04 0x24)
              (list 0x48 0x8D 0x74 0x24 0x08)
              (list 0x4C 0x8D 0x2D) (%cc-gen-le32 35)
              (list 0x4C 0x8D 0x35) (%cc-gen-le32 (- dataat 23))
              (list 0x49 0x89 0xE4)
              (list 0x48 0x81 0xEC) (%cc-gen-le32 %cc-gen-region)
              (list 0xE8) (%cc-gen-le32 81)
              (list 0x48 0x89 0xC7 0x4D 0x8B 0x1E 0x48 0x83 0xE4 0xF0 0x41 0xFF 0xD3)
              (list 0x55 0x48 0x89 0xE5 0x48 0x83 0xE4 0xF0 0x49 0x89 0xFB
                    0x49 0x8B 0x3B 0x49 0x8B 0x73 0x08 0x49 0x8B 0x53 0x10
                    0x49 0x8B 0x4B 0x18 0x4D 0x8B 0x43 0x20 0x4D 0x8B 0x4B 0x28
                    0xF2 0x41 0x0F 0x10 0x43 0x30 0xF2 0x41 0x0F 0x10 0x4B 0x38
                    0xF2 0x41 0x0F 0x10 0x53 0x40 0xF2 0x41 0x0F 0x10 0x5B 0x48
                    0x31 0xC0 0x41 0xFF 0xD2 0x48 0x89 0xEC 0x5D 0xC3))))))

; how long the entry is; the container lays the code out from here
(def %cc-gen-entry-len
  (fn (_ target) (if (eq? target (lit macho-arm64)) 68 119)))

; where the container puts the data, as a distance from the entry's start
(def %cc-gen-data-at
  (fn (_ target codelen)
    (if (eq? target (lit macho-arm64))
      (macho-data-at codelen)
      (elf-data-at codelen))))

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

; x0 = its low 32 bits, zero-extended: an unsigned int's form
(def %cc-gen-uint!
  (fn (_)
    (do (%cc-gen! (lit mov) x2 (imm 32))
        (%cc-gen! (lit lslv) x0 x0 x2)
        (%cc-gen! (lit lsrv) x0 x0 x2))))

; --- the real types ------------------------------------------------------------
; A double is held as its IEEE bits in a general register, as a long is,
; and a float as its single's 32 bits, zero above, as an unsigned int is.
; Each operation moves the bits to d0 and d1, works there -- a float as
; the double it widens to, rounded back to a single after, which gives the
; single-precision answer -- and moves the answer back; nothing stays in a
; d register between operations.  x1 can hold a place's address while a
; value converts, so the conversions keep off it.

(def %cc-gen-real? (fn (_ k) (if (eq? k (lit double)) #t (eq? k (lit float)))))
(def %cc-gen-top-bit (<< 1 63))
(def %cc-gen-two-63 0x43E0000000000000)   ; 2^63 as a double
(def %cc-gen-one 0x3FF0000000000000)      ; 1.0

; the value of real C type K in the general register X, as a double in D
(def %cc-gen-real-in!
  (fn (_ d x k)
    (do (%cc-gen! (lit fmov/d) d x)
        (if (eq? k (lit float)) (%cc-gen! (lit fcvt/d) d d) ()))))

; the double in d0, as real C type K in x0
(def %cc-gen-real-out!
  (fn (_ k)
    (do (if (eq? k (lit float)) (%cc-gen! (lit fcvt/s) d0 d0) ())
        (%cc-gen! (lit fmov/x) x0 d0))))

; x0, an integer of C type FROM, as real C type K, converted in one rounding
; (scvtf, scvtf/s).  An unsigned long past the signed range converts
; halved, its last bit kept so it rounds as C does, and doubled, which
; is exact.
(def %cc-gen-int->real!
  (fn (_ from k)
    (def cvt (if (eq? k (lit float)) (lit scvtf/s) (lit scvtf)))
    (if (eq? from (lit ulong))
      (let ((big (%cc-gen-label)) (done (%cc-gen-label)))
        (do (%cc-gen! (lit cmp) x0 (imm 0))
            (%cc-gen! (lit b/lt) (label big))
            (%cc-gen! cvt d0 x0)
            (%cc-gen! (lit b) (label done))
            (asm-label! %cc-gen-asm big)
            (%cc-gen! (lit mov) x2 (imm 1))
            (%cc-gen! (lit and) x2 x2 x0)
            (%cc-gen! (lit fmov/d) d1 x2)
            (%cc-gen! (lit mov) x2 (imm 1))
            (%cc-gen! (lit lsrv) x0 x0 x2)
            (%cc-gen! (lit fmov/x) x2 d1)
            (%cc-gen! (lit orr) x0 x0 x2)
            (%cc-gen! cvt d0 x0)
            (if (eq? k (lit float)) (%cc-gen! (lit fcvt/d) d0 d0) ())
            (%cc-gen! (lit fadd) d0 d0 d0)
            (if (eq? k (lit float)) (%cc-gen! (lit fcvt/s) d0 d0) ())
            (asm-label! %cc-gen-asm done)
            (%cc-gen! (lit fmov/x) x0 d0)))
      (do (%cc-gen! cvt d0 x0)
          (%cc-gen! (lit fmov/x) x0 d0)))))

; x0, of real C type FROM, as an integer of C-TYPE, toward zero.  An unsigned
; long at 2^63 or past it converts less 2^63 and takes the top bit back.
(def %cc-gen-real->int!
  (fn (_ c-type from)
    (%cc-gen-real-in! d0 x0 from)
    (if (eq? c-type (lit ulong))
      (let ((small (%cc-gen-label)) (done (%cc-gen-label)))
        (do (asm-load-imm64! %cc-gen-asm x2 %cc-gen-two-63)
            (%cc-gen! (lit fmov/d) d1 x2)
            (%cc-gen! (lit flt) x2 d0 d1)
            (%cc-gen! (lit cmp) x2 (imm 0))
            (%cc-gen! (lit b/ne) (label small))
            (%cc-gen! (lit fsub) d0 d0 d1)
            (%cc-gen! (lit fcvtzs) x0 d0)
            (asm-load-imm64! %cc-gen-asm x2 %cc-gen-top-bit)
            (%cc-gen! (lit eor) x0 x0 x2)
            (%cc-gen! (lit b) (label done))
            (asm-label! %cc-gen-asm small)
            (%cc-gen! (lit fcvtzs) x0 d0)
            (asm-label! %cc-gen-asm done)))
      (do (%cc-gen! (lit fcvtzs) x0 d0)
          (%cc-gen-convert! c-type (lit long))))))

; x0 and x1, both of real C type K, put together by OP, into x0
(def %cc-gen-real-bin!
  (fn (_ op k)
    (def f
      (match
        ((string=? op "+") (lit fadd))
        ((string=? op "-") (lit fsub))
        ((string=? op "*") (lit fmul))
        ((string=? op "/") (lit fdiv))
        (#t (%cc-gen-no (string-append "the operator " op " on a " (%cc-gen-real-name k))))))
    (%cc-gen-real-in! d0 x0 k)
    (%cc-gen-real-in! d1 x1 k)
    (%cc-gen! f d0 d0 d1)
    (%cc-gen-real-out! k)))

(def %cc-gen-real-name (fn (_ k) (if (eq? k (lit float)) "float" "double")))

; x0 = 1 when x0 and x1, both of real C type K, compare as OP says, else 0:
; false for a NaN on either side but for !=
(def %cc-gen-real-compare!
  (fn (_ op k)
    (%cc-gen-real-in! d0 x0 k)
    (%cc-gen-real-in! d1 x1 k)
    (match
      ((string=? op "<") (%cc-gen! (lit flt) x0 d0 d1))
      ((string=? op ">") (%cc-gen! (lit flt) x0 d1 d0))
      ((string=? op "==") (%cc-gen! (lit feq) x0 d0 d1))
      ((string=? op "!=")
        (do (%cc-gen! (lit feq) x0 d0 d1)
            (%cc-gen! (lit mov) x1 (imm 1))
            (%cc-gen! (lit eor) x0 x0 x1)))
      ((string=? op "<=")
        (do (%cc-gen! (lit flt) x0 d0 d1)
            (%cc-gen! (lit feq) x1 d0 d1)
            (%cc-gen! (lit orr) x0 x0 x1)))
      ((string=? op ">=")
        (do (%cc-gen! (lit flt) x0 d1 d0)
            (%cc-gen! (lit feq) x1 d0 d1)
            (%cc-gen! (lit orr) x0 x0 x1)))
      (#t (%cc-gen-no (string-append "the comparison " op))))))

; x0, of real C type K, without its sign: zero at either zero, which is what
; a test of it asks.  A float's sign is bit 31, with zeros above it.
(def %cc-gen-drop-sign!
  (fn (_ k)
    (do (%cc-gen! (lit mov) x2 (imm (if (eq? k (lit float)) 33 1)))
        (%cc-gen! (lit lslv) x0 x0 x2))))

; the unary OP on x0, of real C type K: - flips its sign, ! tests it
(def %cc-gen-real-unary!
  (fn (_ op k)
    (match
      ((string=? op "-")
        (do (asm-load-imm64! %cc-gen-asm x2
              (if (eq? k (lit float)) 0x80000000 %cc-gen-top-bit))
            (%cc-gen! (lit eor) x0 x0 x2)))
      ((string=? op "!")
        (do (%cc-gen-drop-sign! k)
            (%cc-gen! (lit cmp) x0 (imm 0))
            (%cc-gen-flag! (lit b/eq))))
      (#t (%cc-gen-no (string-append "the operator " op " on a " (%cc-gen-real-name k)))))))

; x0, of real C type K, moved one step, up or down
(def %cc-gen-real-step!
  (fn (_ up k)
    (do (%cc-gen-real-in! d0 x0 k)
        (asm-load-imm64! %cc-gen-asm x2 %cc-gen-one)
        (%cc-gen! (lit fmov/d) d1 x2)
        (%cc-gen! (if up (lit fadd) (lit fsub)) d0 d0 d1)
        (%cc-gen-real-out! k))))

; --- integer C types -----------------------------------------------------------
; A value is held in a whole register in the form its C type reads it: an int,
; and anything narrower, which C promotes to int, sign-extended from bit 31;
; an unsigned int zero-extended; a long or an unsigned long as all 64 bits.
; An operator works in the C type C's usual conversions give its operands and
; leaves its result in that C type's form.  Between the 64-bit C types and from
; either 32-bit one to them, the form already is the conversion: an int's
; sign-extension is the long, and the unsigned long, it converts to.  The
; C types C's promotions and usual conversions give are cc/eval.x's
; (promoted-c-type, common-c-type), which run works in too.

; a bit-field, (bits C-TYPE BIT WIDTH): WIDTH bits from bit BIT of a unit of
; C-TYPE (parse.x)
(def %cc-gen-bits? (fn (_ k) (if (pair? k) (eq? (first k) (lit bits)) #f)))

(def %cc-gen-unsigned? (fn (_ k) (if (eq? k (lit uint)) #t (eq? k (lit ulong)))))

; x0 into the form C-TYPE holds a value in, after an operation that can leave it
(def %cc-gen-normalize!
  (fn (_ c-type)
    (match
      ((eq? c-type (lit int)) (%cc-gen-int!))
      ((eq? c-type (lit uint)) (%cc-gen-uint!))
      (#t ()))))

; V as the int its low 32 bits make
(def %cc-gen-int-of
  (fn (_ v)
    (let ((u (& v 4294967295)))
      (if (>= u 2147483648) (- u 4294967296) u))))

; a constant into x0, as an int
(def %cc-gen-const!
  (fn (_ v) (asm-load-imm64! %cc-gen-asm x0 (%cc-gen-int-of v))))

; V in the form a value of C-TYPE is held in: cut to the C type's width and
; extended by its sign -- an int's from bit 31, an unsigned int's with
; zeros -- and an eight-byte C type's as it is
(def %cc-gen-form
  (fn (_ v c-type)
    (def size (c-type-size c-type))
    (if (>= size 8) v
      (let ((top (<< 1 (- (* 8 size) 1))))
        (def low (& v (- (* 2 top) 1)))
        (if (if (signed? c-type) (>= low top) #f) (- low (* 2 top)) low)))))

; a constant of C-TYPE into x0, in that C type's form
(def %cc-gen-const-c-type!
  (fn (_ v c-type) (asm-load-imm64! %cc-gen-asm x0 (%cc-gen-form v c-type))))

; the C type of a literal: the one the lexer read, an int when it read none
(def %cc-gen-num-c-type
  (fn (_ node) (if (null? (rest (rest node))) (lit int) (first (rest (rest node))))))

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

; The left operand in x0, the right in x1, both in C-TYPE's form, the result
; to x0 in it.  An unsigned int is zero-extended, so signed division and a
; right shift that brings in zeros are the unsigned ones on it.
(def %cc-gen-bin!
  (fn (_ op c-type)
    (match
      ((string=? op "+") (do (%cc-gen! (lit add) x0 x0 x1) (%cc-gen-normalize! c-type)))
      ((string=? op "-") (do (%cc-gen! (lit sub) x0 x0 x1) (%cc-gen-normalize! c-type)))
      ((string=? op "*") (do (%cc-gen! (lit mul) x0 x0 x1) (%cc-gen-normalize! c-type)))
      ((string=? op "/")
        (if (eq? c-type (lit ulong)) (%cc-gen-udiv64! #f)
          (do (%cc-gen! (lit sdiv) x0 x0 x1) (%cc-gen-normalize! c-type))))
      ((string=? op "%")
        (if (eq? c-type (lit ulong)) (%cc-gen-udiv64! #t)
          (do (%cc-gen! (lit sdiv) x2 x0 x1)
              (%cc-gen! (lit msub) x0 x2 x1 x0))))
      ((string=? op "&") (%cc-gen! (lit and) x0 x0 x1))
      ((string=? op "|") (%cc-gen! (lit orr) x0 x0 x1))
      ((string=? op "^") (%cc-gen! (lit eor) x0 x0 x1))
      ((string=? op "<<") (do (%cc-gen! (lit lslv) x0 x0 x1) (%cc-gen-normalize! c-type)))
      ((string=? op ">>")
        (%cc-gen! (if (%cc-gen-unsigned? c-type) (lit lsrv) (lit asrv)) x0 x0 x1))
      (#t (%cc-gen-no (string-append "the operator " op))))))

; x0 / x1, or x0 % x1, as unsigned 64-bit numbers, from signed division
; (Hacker's Delight 9-3).  A divisor below 2^63 divides the dividend halved,
; which is non-negative, doubles the quotient and adds one more when what is
; left is a divisor or more; that is unsigned r >= d, which for a divisor
; below 2^63 is r negative or signed r >= d.  A divisor of 2^63 or more goes
; in once or not at all, and when it does both have the top bit set, so a
; signed compare orders them.  The dividend waits on the stack.
(def %cc-gen-udiv64!
  (fn (_ rem?)
    (def big (%cc-gen-label))
    (def more (%cc-gen-label))
    (def done (%cc-gen-label))
    (do (asm-push! %cc-gen-asm x0)
        (%cc-gen! (lit cmp) x1 (imm 0))
        (%cc-gen! (lit b/lt) (label big))
        (%cc-gen! (lit mov) x2 (imm 1))
        (%cc-gen! (lit lsrv) x0 x0 x2)
        (%cc-gen! (lit sdiv) x0 x0 x1)
        (%cc-gen! (lit lslv) x0 x0 x2)
        (asm-pop! %cc-gen-asm x2)
        (asm-push! %cc-gen-asm x2)
        (%cc-gen! (lit mul) x8 x0 x1)
        (%cc-gen! (lit sub) x2 x2 x8)
        (%cc-gen! (lit cmp) x2 (imm 0))
        (%cc-gen! (lit b/lt) (label more))
        (%cc-gen! (lit cmp) x2 x1)
        (%cc-gen! (lit b/lt) (label done))
        (asm-label! %cc-gen-asm more)
        (%cc-gen! (lit add) x0 x0 (imm 1))
        (%cc-gen! (lit sub) x2 x2 x1)
        (%cc-gen! (lit b) (label done))
        (asm-label! %cc-gen-asm big)
        (asm-pop! %cc-gen-asm x2)
        (asm-push! %cc-gen-asm x2)
        (%cc-gen! (lit mov) x0 (imm 0))
        (%cc-gen! (lit cmp) x2 (imm 0))
        (%cc-gen! (lit b/ge) (label done))
        (%cc-gen! (lit cmp) x2 x1)
        (%cc-gen! (lit b/lt) (label done))
        (%cc-gen! (lit mov) x0 (imm 1))
        (%cc-gen! (lit sub) x2 x2 x1)
        (asm-label! %cc-gen-asm done)
        (asm-pop! %cc-gen-asm x8)
        (if rem? (%cc-gen! (lit mov) x0 x2) ()))))

; x0 and x1, both in C-TYPE's form, compared: an unsigned int's form is a
; non-negative 64-bit number, so a signed compare orders them; an unsigned
; long's top bits are flipped first, which makes the signed order the
; unsigned one
(def %cc-gen-compare!
  (fn (_ c-type)
    (do (if (eq? c-type (lit ulong))
          (do (asm-load-imm64! %cc-gen-asm x2 (<< 1 63))
              (%cc-gen! (lit eor) x0 x0 x2)
              (%cc-gen! (lit eor) x1 x1 x2))
          ())
        (%cc-gen! (lit cmp) x0 x1))))

; x1 into an unsigned int's form: a signed operand converted to one
(def %cc-gen-uint-x1!
  (fn (_)
    (do (%cc-gen! (lit mov) x2 (imm 32))
        (%cc-gen! (lit lslv) x1 x1 x2)
        (%cc-gen! (lit lsrv) x1 x1 x2))))

; + and - with an address among the operands, left in x0 and right in x1:
; the count beside an address moves it by that many elements, and two
; addresses subtract to the count of elements between them.  An address
; is 64 bits, so nothing re-extends from bit 31.
(def %cc-gen-addr-bin!
  (fn (_ op ka kb)
    (def size (fn (_ k) (c-type-size (c-type-elem k))))
    (match
      ((if (string=? op "-") (if (%cc-gen-addr-c-type? ka) (%cc-gen-addr-c-type? kb) #f) #f)
        (do (%cc-gen! (lit sub) x0 x0 x1)
            (if (= (size ka) 1) ()
              (do (%cc-gen! (lit mov) x1 (imm (size ka)))
                  (%cc-gen! (lit sdiv) x0 x0 x1)))))
      ((if (string=? op "-") (%cc-gen-addr-c-type? ka) #f)
        (do (%cc-gen-scale! x1 (size ka)) (%cc-gen! (lit sub) x0 x0 x1)))
      ((if (string=? op "+") (%cc-gen-addr-c-type? ka) #f)
        (do (%cc-gen-scale! x1 (size ka)) (%cc-gen! (lit add) x0 x0 x1)))
      ((string=? op "+")
        (do (%cc-gen-scale! x0 (size kb)) (%cc-gen! (lit add) x0 x0 x1)))
      (#t (%cc-gen-no (string-append "the operator " op " on an address"))))))

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
; Every local and parameter has the size and alignment of its C type, at a
; fixed offset from x19, which the prologue points at the frame it took off
; x20.  A value loads at its width, extended by its sign -- a char
; sign-extends, an unsigned char zero-extends -- into the form its C type
; is held in (the integer C types, above).  A store converts the value to its
; place's C type, and so does the value an assignment answers.
;
; A pointer is an eight-byte address.  An array is its elements end to
; end, and where it is used as a value it stands for its first element's
; address, which is all a subscript or pointer arithmetic needs.

(def %cc-gen-env ())        ; ((name offset . c-type) ...)
(def %cc-gen-frame-bytes 0) ; how much of the frame the named ones take
(def %cc-gen-ret-c-type ())   ; what the function being compiled returns

(def %cc-gen-ptr? (fn (_ k) (if (pair? k) (eq? (first k) (lit ptr)) #f)))
(def %cc-gen-array? (fn (_ k) (if (pair? k) (eq? (first k) (lit array)) #f)))
(def %cc-gen-addr-c-type? (fn (_ k) (if (%cc-gen-ptr? k) #t (%cc-gen-array? k))))

; A struct is its fields at the offsets the parser laid out, a union one
; whose fields all sit at 0.  Like an array, it is never loaded whole: where
; it is used, the address it is at stands for it.
(def %cc-gen-struct? (fn (_ k) (if (pair? k) (eq? (first k) (lit struct)) #f)))
(def %cc-gen-aggregate? (fn (_ k) (if (%cc-gen-array? k) #t (%cc-gen-struct? k))))

; (OFFSET . C-TYPE) of the field FNAME of the struct C type K
(def %cc-gen-field
  (fn (_ k fname)
    (def entry (struct-entry (first (rest k))))
    (if (null? entry) (%cc-gen-no (string-append "the struct " (first (rest k)))))
    (def go
      (fn (self fs)
        (match
          ((null? fs)
            (%cc-gen-no (string-append "no field " fname " in struct " (first (rest k)))))
          ((string=? (first (first fs)) fname)
            (pair (first (rest (first fs))) (first (rest (rest (first fs))))))
          (#t (self (rest fs))))))
    (go (rest (rest entry)))))

; an array as the value it stands for: a pointer to its first element
(def %cc-gen-decay
  (fn (_ k) (if (%cc-gen-array? k) (list (lit ptr) (c-type-elem k)) k)))

; C-TYPE, if the compiled code holds it; WHAT names the holder in a refusal.
; A pointer may point at any C type -- what a load through it reads is
; checked where the load is -- and an array's elements are held as a
; value would be.
(def %cc-gen-c-type!
  (fn (self c-type what)
    (match
      ((eq? c-type (lit int)) c-type)
      ((eq? c-type (lit char)) c-type)
      ((eq? c-type (lit uchar)) c-type)
      ((eq? c-type (lit short)) c-type)
      ((eq? c-type (lit ushort)) c-type)
      ((eq? c-type (lit long)) c-type)
      ((eq? c-type (lit uint)) c-type)
      ((eq? c-type (lit ulong)) c-type)
      ((eq? c-type (lit double)) c-type)
      ((eq? c-type (lit float)) c-type)
      ((%cc-gen-ptr? c-type) c-type)
      ((%cc-gen-fnptr? c-type) c-type)
      ((%cc-gen-bits? c-type) (do (self (first (rest c-type)) what) c-type))
      ((%cc-gen-array? c-type) (do (self (c-type-elem c-type) "an array's element") c-type))
      ((%cc-gen-struct? c-type)
        (do (let ((go (fn (go fs)
                        (if (null? fs) ()
                          (do (self (first (rest (rest (first fs)))) "a struct's field")
                              (go (rest fs)))))))
              (go (rest (rest (struct-entry (first (rest c-type)))))))
            c-type))
      (#t (%cc-gen-no
            (string-append what
              " that is not an integer, a double, a float, a pointer, an array or a struct"))))))

(def %cc-gen-byte? (fn (_ c-type) (if (eq? c-type (lit char)) #t (eq? c-type (lit uchar)))))
(def %cc-gen-half? (fn (_ c-type) (if (eq? c-type (lit short)) #t (eq? c-type (lit ushort)))))

; what is left when a value of C-TYPE is loaded or stored: the C types a
; register holds, and a refusal naming any other
(def %cc-gen-value-c-type!
  (fn (_ c-type)
    (do (%cc-gen-c-type! c-type "a value")
        (match
          ((%cc-gen-array? c-type) (%cc-gen-no "an array as a value"))
          ((%cc-gen-struct? c-type) (%cc-gen-no "a struct as a value"))
          (#t c-type)))))

; the load that brings a value of C-TYPE into a register, extended by its sign
(def %cc-gen-load-op
  (fn (_ c-type)
    (match
      ((eq? c-type (lit char)) (lit ldrsb))
      ((eq? c-type (lit uchar)) (lit ldrb))
      ((eq? c-type (lit short)) (lit ldrsh))
      ((eq? c-type (lit ushort)) (lit ldrh))
      ((eq? c-type (lit uint)) (lit ldrw))
      ((eq? c-type (lit float)) (lit ldrw))
      ((%cc-gen-wide? c-type) (lit ldr))
      (#t (do (%cc-gen-value-c-type! c-type) (lit ldrsw))))))

(def %cc-gen-store-op
  (fn (_ c-type)
    (match
      ((%cc-gen-byte? c-type) (lit strb))
      ((%cc-gen-half? c-type) (lit strh))
      ((%cc-gen-wide? c-type) (lit str))
      (#t (do (%cc-gen-value-c-type! c-type) (lit strw))))))

; the C types held in all 64 bits: an address, a long, an unsigned long, a
; double
(def %cc-gen-wide?
  (fn (_ k)
    (match
      ((%cc-gen-ptr? k) #t)
      ((%cc-gen-fnptr? k) #t)
      ((eq? k (lit long)) #t)
      ((eq? k (lit ulong)) #t)
      ((eq? k (lit double)) #t)
      (#t #f))))

; a pointer to a function, (fnptr RET): the function's address, which a
; call through it answers a RET from (parse.x)
(def %cc-gen-fnptr? (fn (_ k) (if (pair? k) (eq? (first k) (lit fnptr)) #f)))

; x0 as a value of C-TYPE: shifted to the top of the register and back down,
; arithmetically for a signed C type
(def %cc-gen-narrow!
  (fn (_ c-type)
    (def bits (match ((%cc-gen-byte? c-type) 56) ((%cc-gen-half? c-type) 48) (#t 32)))
    (do (%cc-gen! (lit mov) x2 (imm bits))
        (%cc-gen! (lit lslv) x0 x0 x2)
        (%cc-gen! (if (signed? c-type) (lit asrv) (lit lsrv)) x0 x0 x2))))
(def %cc-gen-loops ())      ; ((break-label . continue-label) ...), innermost first
(def %cc-gen-funs ())       ; ((name . label) ...), every function in the program
(def %cc-gen-rets ())       ; ((name . c-type) ...), what each one returns

(def %cc-gen-ret-find
  (fn (_ name)
    (def go (fn (self es)
              (if (null? es) ()
                (if (string=? (first (first es)) name) (rest (first es))
                  (self (rest es))))))
    (go %cc-gen-rets)))

(def %cc-gen-params ())     ; ((name . c-types) ...), what each one takes

(def %cc-gen-params-find
  (fn (_ name)
    (def go (fn (self es)
              (if (null? es) ()
                (if (string=? (first (first es)) name) (rest (first es))
                  (self (rest es))))))
    (go %cc-gen-params)))
(def %cc-gen-epilogue ())   ; where `return` goes in the function being compiled

; A function that calls into the C library has an area in its frame for the
; calls: six eight-byte integer arguments and four doubles, which the
; trampoline loads where the C calling convention takes them; then
; x86-64's va_list record, whose offsets say the argument registers are
; used up; then a slot for each argument a variadic call passes past its
; fixed ones, which the va_list points at -- directly on arm64 macOS,
; through the record on x86-64.  The arguments are all evaluated before any
; goes into the area, so a call among another's arguments does not disturb
; it.
(def %cc-gen-ca 0)          ; where the area starts
(def %cc-gen-ca-doubles 48) ; the four doubles
(def %cc-gen-ca-record 80)  ; x86-64's va_list record
(def %cc-gen-ca-vars 104)   ; the variable arguments
(def %cc-gen-sysv? #f)      ; whether the target takes x86-64's va_list

; The data a program carries, in the segment the container maps readable and
; writable on the page after the code: the globals first, each at the size
; and alignment of its C type, then the string literals end to end and
; NUL-terminated.  x22 holds where the data starts, taken
; program-counter-relatively by the entry, and everything in it is an offset
; from there.  The globals come first because their offsets are wanted while
; the bodies compile, and a literal's is not settled until one is met.
(def %cc-gen-databytes 0)
(def %cc-gen-data ())       ; ((offset . bytes) ...), the last laid first
(def %cc-gen-globals ())    ; ((name offset . c-type) ...)
(def %cc-gen-strings ())    ; ((text . offset) ...)

; room for BYTES in the data, at a multiple of ALIGN; answers where
(def %cc-gen-data!
  (fn (_ bytes align)
    (let ((off (round-up %cc-gen-databytes align)))
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

; (OFFSET . C-TYPE) for a global's name, or nil
(def %cc-gen-global-find
  (fn (_ name)
    (def go (fn (self es)
              (if (null? es) ()
                (if (string=? (first (first es)) name) (rest (first es))
                  (self (rest es))))))
    (go %cc-gen-globals)))

; A global takes room of its C type, with its initializer's bytes in it.
; The initializer is a constant, as C asks, so the bytes are worked out
; here.  An address in the data would move with the executable, which the
; kernel loads at a place of its choosing and nothing relocates, so a
; pointer that starts at one starts as zeros and main writes the address
; before its body runs (%cc-gen-fixups!).
(def %cc-gen-global!
  (fn (_ node)
    (def name (first (rest node)))
    (def c-type (%cc-gen-c-type! (first (rest (rest node))) "a global"))
    (if (not (null? (%cc-gen-global-find name)))
      (%cc-gen-no (string-append "a second declaration of " name)))
    (def init (first (rest (rest (rest node)))))
    (set! %cc-gen-pending ())
    (def off (%cc-gen-data! (%cc-gen-const-bytes c-type init 0) (c-type-align c-type)))
    (%cc-gen-keep-fixups! off)
    (set! %cc-gen-globals (pair (pair name (pair off c-type)) %cc-gen-globals))))

; (OFFSET INIT . SCOPE) for each pointer in the data that starts at an
; address: where the pointer is, what names the address, and the static
; locals in scope where INIT is (%cc-gen-static-scope)
(def %cc-gen-fixups ())

; the notes the object just placed at OFF left (%cc-gen-pending), as fixups
(def %cc-gen-keep-fixups!
  (fn (_ off)
    (def go
      (fn (self ps)
        (if (null? ps) ()
          (do (set! %cc-gen-fixups
                (pair (pair (+ off (first (first ps)))
                        (pair (rest (first ps)) %cc-gen-static-scope))
                  %cc-gen-fixups))
              (self (rest ps))))))
    (go %cc-gen-pending)
    (set! %cc-gen-pending ())))

; ((NAME OFFSET . C-TYPE) ...), the static locals in scope at a point of a
; function, the latest first: a name in a constant initializer there is
; one of them before it is a global's
(def %cc-gen-static-scope ())

; (OFFSET . C-TYPE) for the object NAME names in a constant initializer:
; a static local in scope, else a global; nil when neither
(def %cc-gen-constant-find
  (fn (_ name)
    (def go
      (fn (self es)
        (match
          ((null? es) (%cc-gen-global-find name))
          ((string=? (first (first es)) name) (rest (first es)))
          (#t (self (rest es))))))
    (go %cc-gen-static-scope)))

; (OFFSET . C-TYPE) for the address NODE stands for: where in the data it
; lies, and the C type of what is there.  A string literal or an array
; stands for its first element's; & takes a global's, an element's at a
; constant index, a field's or a pointee's.  A constant added or taken
; away moves the address by that many of what it points at, and a cast
; to a pointer changes what that is.
(def %cc-gen-address-target
  (fn (self node)
    (def t (first node))
    (def field
      (fn (_ s fname)
        (let ((f (%cc-gen-field (rest s) fname)))
          (pair (+ (first s) (first f)) (rest f)))))
    (match
      ((eq? t (lit str)) (pair (%cc-gen-string! (first (rest node))) (lit char)))
      ((eq? t (lit bin))
        (let ((op (first (rest node)))
              (a (first (rest (rest node))))
              (b (first (rest (rest (rest node))))))
          (def left? (%cc-gen-address-form? a))
          (if (not (if (string=? op "+") #t (if (string=? op "-") left? #f)))
            (%cc-gen-no (string-append "the operator " op " on an address")))
          (let ((p (self (if left? a b))) (n (%cc-gen-fold (if left? b a))))
            (pair (+ (first p) (* (if (string=? op "-") (- 0 n) n) (c-type-size (rest p))))
              (rest p)))))
      ((eq? t (lit cast))
        (pair (first (self (first (rest (rest node))))) (c-type-elem (first (rest node)))))
      ((if (eq? t (lit un)) (string=? (first (rest node)) "&") #f)
        (let ((x (first (rest (rest node)))))
          (def xt (first x))
          (match
            ((eq? xt (lit var))
              (let ((g (%cc-gen-constant-find (first (rest x)))))
                (if (null? g)
                  (%cc-gen-no "a global pointer initialized with the address of something not global")
                  g)))
            ((eq? xt (lit idx))
              (self (list (lit bin) "+" (first (rest x)) (first (rest (rest x))))))
            ((eq? xt (lit dot))
              (field (self (list (lit un) "&" (first (rest x)))) (first (rest (rest x)))))
            ((eq? xt (lit arrow))
              (field (self (first (rest x))) (first (rest (rest x)))))
            ((if (eq? xt (lit un)) (string=? (first (rest x)) "*") #f)
              (self (first (rest (rest x)))))
            (#t (%cc-gen-no "a global pointer initialized with an address worked out at run time")))))
      ; anything else names an object, which is an address only as an array
      (#t
        (let ((p (self (list (lit un) "&" node))))
          (if (%cc-gen-array? (rest p)) (pair (first p) (c-type-elem (rest p)))
            (%cc-gen-no "a global pointer initialized with a value that is not an address")))))))

; where in the data the address INIT names lies
(def %cc-gen-address-constant
  (fn (_ init) (first (%cc-gen-address-target init))))

; The addresses the pointers in the data start at, written by main before
; its body runs: x22 is the data's address only at run time
(def %cc-gen-fixups!
  (fn (_)
    (def go
      (fn (self fs)
        (if (null? fs) ()
          (let ((f (first fs)))
            (set! %cc-gen-static-scope (rest (rest f)))
            (%cc-gen-address! x22 (first f))
            (%cc-gen! (lit mov) x1 x0)
            (def fname (%cc-gen-function-named (first (rest f))))
            (if (null? fname)
              (%cc-gen-address! x22 (%cc-gen-address-constant (first (rest f))))
              (%cc-gen-function-address! fname))
            (%cc-gen! (lit str) x0 (mem x1 0))
            (self (rest fs))))))
    (go (reverse %cc-gen-fixups))
    (set! %cc-gen-static-scope ())))

; the name NODE gives when it is NAME or &NAME, or ()
(def %cc-gen-function-form
  (fn (_ node)
    (match
      ((eq? (first node) (lit var)) (first (rest node)))
      ((if (eq? (first node) (lit un))
         (if (string=? (first (rest node)) "&") (eq? (first (first (rest (rest node)))) (lit var)) #f)
         #f)
        (first (rest (first (rest (rest node))))))
      (#t ()))))

; the function a constant initializer NODE names -- NAME or &NAME, when
; no static local in scope there or global has the name -- or ()
(def %cc-gen-function-named
  (fn (_ node)
    (def n (%cc-gen-function-form node))
    (if (null? n) ()
      (if (if (null? (%cc-gen-constant-find n)) (not (null? (%cc-gen-fun-find n))) #f) n ()))))

; A static local is kept once for the program, as a global is: room in the
; data with its initializer's bytes in place, laid out with the globals
; before any function is compiled.  (NODE OFFSET . C-TYPE), the
; declaration's node found again by identity; the name is its function's
; alone (%cc-gen-scan!).
(def %cc-gen-statics ())

(def %cc-gen-static-decl?
  (fn (_ node) (not (null? (rest (rest (rest (rest node))))))))

; A static local is in scope from its own initializer on, so the pointer
; in it can start at its own address.
(def %cc-gen-static!
  (fn (_ node)
    (def c-type (%cc-gen-c-type! (first (rest (rest node))) "a local"))
    (set! %cc-gen-pending ())
    (def off
      (%cc-gen-data! (%cc-gen-const-bytes c-type (first (rest (rest (rest node)))) 0)
        (c-type-align c-type)))
    (set! %cc-gen-static-scope
      (pair (pair (first (rest node)) (pair off c-type)) %cc-gen-static-scope))
    (%cc-gen-keep-fixups! off)
    (set! %cc-gen-statics (pair (pair node (pair off c-type)) %cc-gen-statics))))

; every static declaration in NODE, laid out; the ones a block or a
; function declares go out of scope at its end
(def %cc-gen-scan-statics!
  (fn (self node)
    (if (pair? node)
      (let ((scope %cc-gen-static-scope))
        (if (if (eq? (first node) (lit decl)) (%cc-gen-static-decl? node) #f)
          (%cc-gen-static! node)
          ())
        (let ((go (fn (go xs) (if (pair? xs) (do (self (first xs)) (go (rest xs))) ()))))
          (go node))
        (if (if (eq? (first node) (lit block)) #t (eq? (first node) (lit fun)))
          (set! %cc-gen-static-scope scope)
          ()))
      ())))

; the name a static declaration NODE declares, bound in the function being
; compiled to its room in the data: an entry whose offset is (x22 . OFFSET)
(def %cc-gen-bind-static!
  (fn (_ node)
    (def name (first (rest node)))
    (if (not (null? (%cc-gen-find name)))
      (%cc-gen-no (string-append "a second declaration of " name)))
    (def go (fn (self es)
              (match
                ((null? es) (%cc-gen-no "a static local that was not laid out"))
                ((same? (first (first es)) node) (rest (first es)))
                (#t (self (rest es))))))
    (def s (go %cc-gen-statics))
    (set! %cc-gen-env (pair (pair name (pair (pair x22 (first s)) (rest s))) %cc-gen-env))))

; the little-endian bytes of V at C-TYPE's width
(def %cc-gen-value-bytes
  (fn (_ c-type v)
    (%cc-gen-take (c-type-size c-type)
      (append (%cc-gen-le32 v) (%cc-gen-le32 (>> v 32))))))

; the bytes a constant initializer INIT lays down for C-TYPE
; AT is where in the object being laid out these bytes go: a pointer that
; starts at an address leaves zeros there and a note of the address,
; (AT . INIT), which the object's own placing turns into a fixup
; (%cc-gen-keep-fixups!)
(def %cc-gen-pending ())

; does NODE name an address a global pointer can start at: a string
; literal, an array, what & takes, one of these moved by a constant, or
; one cast to another pointer (%cc-gen-address-target)
(def %cc-gen-address-form?
  (fn (self node)
    (def t (first node))
    (match
      ((eq? t (lit str)) #t)
      ((eq? t (lit var)) #t)
      ((eq? t (lit idx)) #t)
      ((eq? t (lit dot)) #t)
      ((eq? t (lit arrow)) #t)
      ((eq? t (lit un))
        (if (string=? (first (rest node)) "&") #t (string=? (first (rest node)) "*")))
      ((eq? t (lit bin))
        (if (self (first (rest (rest node)))) #t (self (first (rest (rest (rest node)))))))
      ((eq? t (lit cast))
        (if (%cc-gen-ptr? (first (rest node))) (self (first (rest (rest node)))) #f))
      (#t #f))))

(def %cc-gen-const-bytes
  (fn (self c-type init at)
    (def zeros
      (fn (zeros n acc) (if (<= n 0) acc (zeros (- n 1) (pair 0 acc)))))
    (match
      ((null? init) (zeros (c-type-size c-type) ()))
      ((%cc-gen-array? c-type)
        (let ((n (first (rest c-type))) (ek (c-type-elem c-type)))
          (match
            ((eq? (first init) (lit initlist))
              (let ((items (first (rest init))))
                (if (> (length items) n)
                  (%cc-gen-no "more initializers than an array has elements"))
                (def go
                  (fn (go i is)
                    (if (>= i n) ()
                      (append (self ek (if (null? is) () (first is)) (+ at (* i (c-type-size ek))))
                        (go (+ i 1) (if (null? is) () (rest is)))))))
                (go 0 items)))
            ((if (eq? (first init) (lit str)) (%cc-gen-byte? ek) #f)
              (let ((text (first (rest init))))
                (if (> (byte-len text) n)
                  (%cc-gen-no "a string longer than the array it initializes"))
                (def go
                  (fn (go i)
                    (if (>= i n) ()
                      (pair (if (< i (byte-len text)) (byte-at text i) 0) (go (+ i 1))))))
                (go 0)))
            (#t (%cc-gen-no "an array initialized by something other than a list or a string")))))
      ; a struct: each field's bytes at its offset, zeros in the padding and
      ; after the last field given.  A field that starts before the last one
      ; ends overlaps it, which is a union's: it takes one initializer.  The
      ; bit-fields that share a unit are one value: each one's bits or'd in
      ; at its place.
      ((%cc-gen-struct? c-type)
        (do (if (not (eq? (first init) (lit initlist)))
              (%cc-gen-no "a global struct initialized by something other than a list"))
            (let ((items (first (rest init)))
                  (fields (rest (rest (struct-entry (first (rest c-type)))))))
              (if (> (length items) (length fields))
                (%cc-gen-no "more initializers than a struct has fields"))
              (def go ())
              ; The unit of C type UK at FOFF, from the bit-fields at the
              ; front of FS that share it and the items IS gives them: their
              ; bits or'd into V, and only the bytes LO to HI of the unit
              ; that they touch, since a field of another C type can sit in
              ; the rest (char c; int x : 4; puts c in the unit's first).
              (def unit
                (fn (unit fs is foff uk v lo hi cur)
                  (if (if (null? is) #t
                        (not (if (%cc-gen-bits? (first (rest (rest (first fs)))))
                               (= (first (rest (first fs))) foff) #f)))
                    (do (if (< (+ foff lo) cur) (%cc-gen-no "more initializers than a union takes"))
                        (append (zeros (- (+ foff lo) cur) ())
                          (append (%cc-gen-take (- hi lo) (%cc-gen-value-bytes uk (>> v (* 8 lo))))
                            (go fs is (+ foff hi)))))
                    (let ((fk (first (rest (rest (first fs))))))
                      (def bit (first (rest (rest fk))))
                      (def width (first (rest (rest (rest fk)))))
                      (def mask (- (<< 1 width) 1))
                      (unit (rest fs) (rest is) foff uk
                        (| v (<< (& (%cc-gen-fold (first is)) mask) bit))
                        (if (< (/ bit 8) lo) (/ bit 8) lo)
                        (if (> (/ (+ (+ bit width) 7) 8) hi) (/ (+ (+ bit width) 7) 8) hi)
                        cur)))))
              (set! go
                (fn (go fs is cur)
                  (if (null? is) (zeros (- (c-type-size c-type) cur) ())
                    (let ((foff (first (rest (first fs)))) (fk (first (rest (rest (first fs))))))
                      (if (%cc-gen-bits? fk)
                        (unit fs is foff (first (rest fk)) 0 (c-type-size (first (rest fk))) 0 cur)
                        (do (if (< foff cur) (%cc-gen-no "more initializers than a union takes"))
                            (append (zeros (- foff cur) ())
                              (append (self fk (first is) (+ at foff))
                                (go (rest fs) (rest is) (+ foff (c-type-size fk)))))))))))
              (go fields items 0))))
      ; a pointer that starts at an address, a function's included
      ((if (%cc-gen-ptr? c-type) (%cc-gen-address-form? init) #f)
        (do (set! %cc-gen-pending (pair (pair at init) %cc-gen-pending))
            (zeros 8 ())))
      ((if (%cc-gen-fnptr? c-type) (not (null? (%cc-gen-function-form init))) #f)
        (do (set! %cc-gen-pending (pair (pair at init) %cc-gen-pending))
            (zeros 8 ())))
      ((eq? (first init) (lit initlist))
        (%cc-gen-no "a braced initializer for something that is not an array or a struct"))
      (#t (let ((v (%cc-gen-fold init)))
            (%cc-gen-value-bytes c-type (convert-real v (%cc-gen-c-type-of init) c-type)))))))

; What a global starts out holding.  C asks for a constant here, so the
; value is worked out now: each operation in the C type C's conversions give
; it, its result in that C type's form, as the code for it would leave it.
; The program starts with the value's low bytes, as many as the global's
; C type has, in place.  A real value is worked out by run's own operations
; (cc/real.x), which are the machine's.
(def %cc-gen-fold
  (fn (self node)
    (let ((t (first node)))
      (match
        ((eq? t (lit num)) (%cc-gen-form (first (rest node)) (%cc-gen-num-c-type node)))
        ((if (eq? t (lit un)) (%cc-gen-real? (%cc-gen-c-type-of node)) #f)
          (if (string=? (first (rest node)) "-")
            (real-negate (self (first (rest (rest node)))) (%cc-gen-c-type-of node))
            (%cc-gen-no (string-append "a global " (%cc-gen-real-name (%cc-gen-c-type-of node)) " initialized with " (first (rest node))))))
        ((eq? t (lit un))
          (let ((op (first (rest node))) (v (self (first (rest (rest node))))))
            (%cc-gen-form
              (match
                ((string=? op "-") (- 0 v))
                ((string=? op "~") (- (- 0 v) 1))
                ((string=? op "!") (if (= v 0) 1 0))
                (#t (%cc-gen-no (string-append "a global initialized with " op))))
              (%cc-gen-c-type-of node))))
        ((eq? t (lit bin))
          (let ((l (first (rest (rest node)))) (r (first (rest (rest (rest node))))))
            (def op (first (rest node)))
            (def k (%cc-gen-c-type-of node))
            (match
              ((not (%cc-gen-real? k)) (%cc-gen-fold-bin op (self l) (self r) k))
              ((if (string=? op "+") #t
                 (if (string=? op "-") #t (if (string=? op "*") #t (string=? op "/"))))
                (real-arith op (convert-real (self l) (%cc-gen-c-type-of l) k)
                  (convert-real (self r) (%cc-gen-c-type-of r) k) k))
              (#t (%cc-gen-no (string-append "the operator " op " on a " (%cc-gen-real-name k)))))))
        ((eq? t (lit cast))
          (let ((k (first (rest node))) (e (first (rest (rest node)))))
            (if (if (eq? k (lit void)) #t (%cc-gen-aggregate? k))
              (%cc-gen-no "a global initialized by something other than a constant"))
            (%cc-gen-form (convert-real (self e) (%cc-gen-c-type-of e) k) k)))
        (#t (%cc-gen-no "a global initialized by something other than a constant"))))))

; OP on the constants A and B, in C-TYPE: each operand converted to it first,
; but a shift's count, which keeps its own
(def %cc-gen-fold-bin
  (fn (_ op a b c-type)
    (if (%cc-gen-addr-c-type? c-type)
      (%cc-gen-no "a global initialized by arithmetic on an address"))
    (def shift? (if (string=? op "<<") #t (string=? op ">>")))
    (def x (%cc-gen-form a c-type))
    (def y (if shift? b (%cc-gen-form b c-type)))
    (def wide? (eq? c-type (lit ulong)))
    (%cc-gen-form
      (match
        ((string=? op "+") (+ x y))
        ((string=? op "-") (- x y))
        ((string=? op "*") (* x y))
        ((string=? op "/") (if wide? (unsigned-divide x y #f) (/ x y)))
        ((string=? op "%") (if wide? (unsigned-divide x y #t) (% x y)))
        ((string=? op "&") (& x y))
        ((string=? op "|") (| x y))
        ((string=? op "^") (^ x y))
        ((string=? op "<<") (<< x y))
        ; an unsigned long past 2^63 shifts in zeros
        ((string=? op ">>")
          (if (if wide? (if (< x 0) (> y 0) #f) #f)
            (& (>> x y) (- (<< 1 (- 64 y)) 1))
            (>> x y)))
        (#t (%cc-gen-no (string-append "a global initialized with " op))))
      c-type)))

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
  (fn (_ text) (%cc-gen-address! x22 (%cc-gen-string! text))))

; x0 = BASE + OFF, where OFF may be below zero: a pointer into the data
; can start before its first byte
(def %cc-gen-address!
  (fn (_ base off)
    (do (%cc-gen! (lit mov) x0 base)
        (%cc-gen-bump! (>= off 0) (if (< off 0) (- 0 off) off)))))

; REG = REG * N, for an element's size
(def %cc-gen-scale!
  (fn (_ reg n)
    (if (= n 1) ()
      (do (if (< n 65536)
            (%cc-gen! (lit mov) x2 (imm n))
            (asm-load-imm64! %cc-gen-asm x2 n))
          (%cc-gen! (lit mul) reg reg x2)))))

; x0 = x0 + or - N.  arm64's add takes twelve bits of immediate and its
; encoder masks a wider one, so a farther N goes through x2.
(def %cc-gen-bump!
  (fn (_ up n)
    (match
      ((= n 0) ())
      ((<= n 4095) (%cc-gen! (if up (lit add) (lit sub)) x0 x0 (imm n)))
      (#t (do (asm-load-imm64! %cc-gen-asm x2 n)
              (%cc-gen! (if up (lit add) (lit sub)) x0 x0 x2))))))

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

; a slot of C-TYPE's size and alignment; answers its offset
(def %cc-gen-slot!
  (fn (_ name c-type)
    (if (not (null? (%cc-gen-find name)))
      (%cc-gen-no (string-append "a second declaration of " name)))
    (def off (round-up %cc-gen-frame-bytes (c-type-align c-type)))
    ; a scalar loads and stores at its offset from x19, which reaches 4095
    ; of its widths; an array or a struct is reached through its address
    (if (if (%cc-gen-aggregate? c-type) #f (> off (* 4095 (c-type-size c-type))))
      (%cc-gen-no "more locals than a load reaches"))
    (set! %cc-gen-frame-bytes (+ off (c-type-size c-type)))
    (set! %cc-gen-env (pair (pair name (pair off c-type)) %cc-gen-env))
    off))

; A struct parameter, where the caller stored it: OFF bytes below the top of
; this frame (%cc-gen-homes).  The top is known once the frame is laid out,
; so the offset counts back from it, negative, and a place adds the frame's
; size.  A struct is reached through its address, from any distance.
(def %cc-gen-frame-top 0)   ; the size of the frame being compiled
(def %cc-gen-slot-above!
  (fn (_ name c-type off)
    (if (not (null? (%cc-gen-find name)))
      (%cc-gen-no (string-append "a second declaration of " name)))
    (set! %cc-gen-env (pair (pair name (pair (- 0 off) c-type)) %cc-gen-env))))

(def %cc-gen-sret-slot 0)   ; where a struct the function answers goes, a word

; x20 moved by N, OP sub or add, in steps an arm64 immediate holds: the
; prologue's arguments are still in their registers, so none is free to
; hold the whole
(def %cc-gen-step-x20!
  (fn (self op n)
    (if (<= n 0) ()
      (let ((step (if (> n 4080) 4080 n)))
        (do (%cc-gen! op x20 x20 (imm step))
            (self op (- n step)))))))

; Room for C-TYPE in the frame, with no name: where a call puts the struct
; it answers (%cc-gen-scan-calls!)
(def %cc-gen-room!
  (fn (_ c-type)
    (def off (round-up %cc-gen-frame-bytes (c-type-align c-type)))
    (set! %cc-gen-frame-bytes (+ off (c-type-size c-type)))
    off))

; Each call in the function that answers a struct has a slot of its own for
; it, alive until the function returns, so two calls' structs never share
; one: (NODE . OFFSET), the call's node found again by identity.
(def %cc-gen-rslots ())
(def %cc-gen-scan-calls!
  (fn (self node)
    (if (pair? node)
      (do (if (if (eq? (first node) (lit call))
                (%cc-gen-struct? (%cc-gen-ret-find (first (rest node))))
                #f)
            (set! %cc-gen-rslots
              (pair (pair node (%cc-gen-room! (%cc-gen-ret-find (first (rest node)))))
                %cc-gen-rslots))
            ())
          (let ((go (fn (go xs) (if (pair? xs) (do (self (first xs)) (go (rest xs))) ()))))
            (go node)))
      ())))

(def %cc-gen-rslot-of
  (fn (_ node)
    (def go (fn (self es)
              (match
                ((null? es) (%cc-gen-no "a struct answered where no slot was set aside"))
                ((same? (first (first es)) node) (rest (first es)))
                (#t (self (rest es))))))
    (go %cc-gen-rslots)))

; A place is (BASE OFFSET . C-TYPE): a register and a byte offset from it.
; A name's is a frame slot off x19 or a global's room off x22, and one
; worked out at run time is the register holding it, at offset 0.
(def %cc-gen-place (fn (_ base off c-type) (pair base (pair off c-type))))
(def %cc-gen-place-mem (fn (_ p) (mem (first p) (first (rest p)))))
(def %cc-gen-place-c-type (fn (_ p) (rest (rest p))))

; Where a name lives, or a refusal naming it.  A local of the same name
; wins, as C says.
(def %cc-gen-place-of
  (fn (_ name)
    (let ((l (%cc-gen-find name)))
      (match
        ; a static local's room in the data (%cc-gen-bind-static!), laid out
        ; with the globals, so a load reaches it as it does them
        ((if (null? l) #f (pair? (first l)))
          (%cc-gen-place (first (first l)) (rest (first l)) (rest l)))
        ((not (null? l))
          (%cc-gen-place x19
            (if (< (first l) 0) (+ %cc-gen-frame-top (first l)) (first l))
            (rest l)))
        (#t
          (let ((g (%cc-gen-global-find name)))
            (match
              ((null? g) (%cc-gen-no (string-append "the name " name)))
              ; a load takes twelve bits of offset, in units of its width,
              ; and arm64's encoder masks a wider one
              ((if (%cc-gen-array? (rest g)) #f (> (first g) (* 4095 (c-type-size (rest g)))))
                (%cc-gen-no "more globals than a load reaches"))
              (#t (%cc-gen-place x22 (first g) (rest g))))))))))

(def %cc-gen-load!
  (fn (_ place)
    (def k (%cc-gen-place-c-type place))
    (if (%cc-gen-bits? k) (%cc-gen-bits-load! (%cc-gen-place-mem place) k)
      (%cc-gen! (%cc-gen-load-op k) x0 (%cc-gen-place-mem place)))))

(def %cc-gen-put!
  (fn (_ place)
    (def k (%cc-gen-place-c-type place))
    (if (%cc-gen-bits? k) (%cc-gen-bits-put! (%cc-gen-place-mem place) k)
      (%cc-gen! (%cc-gen-store-op k) x0 (%cc-gen-place-mem place)))))

; the load of a bit-field's unit, zero-extended: the field's bits are
; taken from it whole
(def %cc-gen-unit-load-op
  (fn (_ unit)
    (match ((%cc-gen-byte? unit) (lit ldrb)) ((%cc-gen-half? unit) (lit ldrh)) (#t (lit ldrw)))))

; A bit-field K from its unit at AT, into x0: the unit, its field shifted
; to the top of the register and back down, arithmetically for a signed
; C type.  The value is in the form its promotion holds.
(def %cc-gen-bits-load!
  (fn (_ at k)
    (def unit (first (rest k)))
    (def bit (first (rest (rest k))))
    (def width (first (rest (rest (rest k)))))
    (do (%cc-gen! (%cc-gen-unit-load-op unit) x0 at)
        (%cc-gen! (lit mov) x2 (imm (- 64 (+ bit width))))
        (%cc-gen! (lit lslv) x0 x0 x2)
        (%cc-gen! (lit mov) x2 (imm (- 64 width)))
        (%cc-gen! (if (signed? unit) (lit asrv) (lit lsrv)) x0 x0 x2))))

; x0 into the bit-field K of the unit at AT, the unit's other bits kept.
; x0 is left as the field then holds it, which is what an assignment
; answers.  AT's register is not touched, and x8, which a postfix ++
; keeps its old value in, waits on the stack.
(def %cc-gen-bits-put!
  (fn (_ at k)
    (def unit (first (rest k)))
    (def bit (first (rest (rest k))))
    (def width (first (rest (rest (rest k)))))
    (do ; the value as the field holds it
        (%cc-gen! (lit mov) x2 (imm (- 64 width)))
        (%cc-gen! (lit lslv) x0 x0 x2)
        (%cc-gen! (if (signed? unit) (lit asrv) (lit lsrv)) x0 x0 x2)
        (asm-push! %cc-gen-asm x8)
        (asm-push! %cc-gen-asm x0)
        ; its bits in the field's place, zeros around them
        (%cc-gen! (lit lslv) x0 x0 x2)
        (%cc-gen! (lit mov) x2 (imm (- 64 (+ bit width))))
        (%cc-gen! (lit lsrv) x0 x0 x2)
        (asm-push! %cc-gen-asm x0)
        ; the unit's bits above the field in x0, and below it in x8
        (%cc-gen! (%cc-gen-unit-load-op unit) x8 at)
        (%cc-gen! (lit mov) x0 x8)
        (%cc-gen! (lit mov) x2 (imm (+ bit width)))
        (%cc-gen! (lit lsrv) x0 x0 x2)
        (%cc-gen! (lit lslv) x0 x0 x2)
        (if (= bit 0)
          (%cc-gen! (lit mov) x8 x0)
          (do (%cc-gen! (lit mov) x2 (imm (- 64 bit)))
              (%cc-gen! (lit lslv) x8 x8 x2)
              (%cc-gen! (lit lsrv) x8 x8 x2)
              (%cc-gen! (lit orr) x8 x8 x0)))
        (asm-pop! %cc-gen-asm x0)
        (%cc-gen! (lit orr) x8 x8 x0)
        (%cc-gen! (%cc-gen-store-op unit) x8 at)
        (asm-pop! %cc-gen-asm x0)
        (asm-pop! %cc-gen-asm x8))))

; a C type whose values are held in an int's form: int, and the C types C
; promotes to it
(def %cc-gen-int-form?
  (fn (_ k) (if (pair? k) #f (eq? (promoted-c-type k) (lit int)))))

; x0, a value of C type FROM, converted to C-TYPE: narrowed to a char or short,
; and into an int's or an unsigned int's form from any other C type, an
; address included.  The eight-byte C types need nothing: every value's form
; is already its conversion to them.  A double and a float convert to each
; other and to and from the integers as C says (the real types, above).
(def %cc-gen-convert!
  (fn (_ c-type from)
    (match
      ((%cc-gen-real? c-type)
        (match
          ((eq? from c-type) ())
          ((%cc-gen-real? from) (do (%cc-gen-real-in! d0 x0 from) (%cc-gen-real-out! c-type)))
          (#t (%cc-gen-int->real! from c-type))))
      ((%cc-gen-real? from) (%cc-gen-real->int! c-type from))
      ((if (%cc-gen-byte? c-type) #t (%cc-gen-half? c-type)) (%cc-gen-narrow! c-type))
      ((eq? c-type (lit int)) (if (%cc-gen-int-form? from) () (%cc-gen-int!)))
      ((eq? c-type (lit uint)) (if (eq? from (lit uint)) () (%cc-gen-uint!)))
      (#t ()))))

; an assignment's store, of a value of C type FROM: the value it answers is
; converted as the stored one was.  A real value's bits are not an
; integer's, so a store with one on either side converts first.
(def %cc-gen-store!
  (fn (_ place from)
    (def k (%cc-gen-place-c-type place))
    (if (if (%cc-gen-real? k) #t (%cc-gen-real? from))
      (do (%cc-gen-convert! k from) (%cc-gen-put! place))
      (do (%cc-gen-put! place) (%cc-gen-convert! k from)))))

; x0, of C type FROM, as C-TYPE when either is real; any other value is left
; as it is, for a store to cut
(def %cc-gen-convert-real!
  (fn (_ c-type from)
    (if (if (%cc-gen-real? c-type) #t (%cc-gen-real? from)) (%cc-gen-convert! c-type from) ())))

; NODE's value into x0 and compared with zero, for a branch on whether it
; is true: a real value is false at either zero
(def %cc-gen-cond!
  (fn (_ node)
    (def k (%cc-gen-c-type-of node))
    (do (%cc-gen-expr! node)
        (if (%cc-gen-real? k) (%cc-gen-drop-sign! k) ())
        (%cc-gen! (lit cmp) x0 (imm 0)))))

; A value of C-TYPE whose address is in x0, into x0: loaded, unless it is an
; array, whose value is that address.
(def %cc-gen-load-at!
  (fn (_ c-type)
    (match
      ((%cc-gen-aggregate? c-type) ())
      ((%cc-gen-bits? c-type) (%cc-gen-bits-load! (mem x0 0) c-type))
      (#t (%cc-gen! (%cc-gen-load-op c-type) x0 (mem x0 0))))))

; The C type of what NODE computes, worked out without computing it: what a
; pointer's arithmetic scales by and what a load through it reads.
(def %cc-gen-c-type-of ())
(set! %cc-gen-c-type-of
  (fn (self node)
    (let ((t (first node)))
      (match
        ; a function's name is a pointer to it
        ((if (eq? t (lit var)) (%cc-gen-function-name? (first (rest node))) #f)
          (list (lit fnptr) (%cc-gen-ret-find (first (rest node)))))
        ((eq? t (lit var)) (%cc-gen-place-c-type (%cc-gen-place-of (first (rest node)))))
        ((eq? t (lit num)) (%cc-gen-num-c-type node))
        ((eq? t (lit szof)) (lit ulong))
        ((eq? t (lit str))
          (list (lit array) (+ (byte-len (first (rest node))) 1) (lit char)))
        ((eq? t (lit idx))
          (let ((ka (self (first (rest node)))))
            (c-type-elem (if (%cc-gen-addr-c-type? ka) ka (self (first (rest (rest node))))))))
        ((eq? t (lit un))
          (let ((op (first (rest node))))
            (match
              ((string=? op "*") (c-type-elem (self (first (rest (rest node))))))
              ; & of a function is the same pointer its name is
              ((string=? op "&")
                (let ((x (self (first (rest (rest node))))))
                  (if (%cc-gen-fnptr? x) x (list (lit ptr) x))))
              ((string=? op "!") (lit int))
              (#t (promoted-c-type (self (first (rest (rest node)))))))))
        ((eq? t (lit bin))
          (%cc-gen-bin-c-type (first (rest node))
            (self (first (rest (rest node)))) (self (first (rest (rest (rest node)))))))
        ((eq? t (lit assign)) (self (first (rest node))))
        ((%cc-gen-step? t) (self (first (rest node))))
        ((eq? t (lit ternary))
          (let ((ka (self (first (rest (rest node))))))
            (if (%cc-gen-addr-c-type? ka) (%cc-gen-decay ka)
              (let ((kb (self (first (rest (rest (rest node)))))))
                (if (%cc-gen-addr-c-type? kb) (%cc-gen-decay kb)
                  (common-c-type ka kb))))))
        ((eq? t (lit comma)) (self (first (rest (rest node)))))
        ((eq? t (lit dot))
          (rest (%cc-gen-field (self (first (rest node))) (first (rest (rest node))))))
        ((eq? t (lit arrow))
          (rest (%cc-gen-field (c-type-elem (self (first (rest node))))
                  (first (rest (rest node))))))
        ; a call through a pointer answers what the pointer says its function
        ; answers
        ((if (eq? t (lit call)) (%cc-gen-variable? (first (rest node))) #f)
          (let ((k (self (list (lit var) (first (rest node))))))
            (if (%cc-gen-fnptr? k) (first (rest k)) (lit int))))
        ((eq? t (lit call))
          (let ((r (%cc-gen-ret-find (first (rest node)))))
            (if (null? r) (library-c-type (first (rest node))) r)))
        ((eq? t (lit callx))
          (let ((k (self (first (rest node)))))
            (if (%cc-gen-fnptr? k) (first (rest k)) (lit int))))
        ((eq? t (lit cast)) (first (rest node)))
        (#t (lit int))))))

; is NAME a local's or a global's, not only a function's
(def %cc-gen-variable?
  (fn (_ name)
    (if (null? (%cc-gen-find name)) (not (null? (%cc-gen-global-find name))) #t)))

; The C type a binary operator answers: + and - keep an address one and make
; two of them a count (a long, as ptrdiff_t is); a shift answers its left
; operand's C type; anything else, the C type its operands meet in.
(def %cc-gen-bin-c-type
  (fn (_ op ka kb)
    (match
      ((if (string=? op "+") #t (string=? op "-"))
        (match ((if (%cc-gen-addr-c-type? ka) (%cc-gen-addr-c-type? kb) #f) (lit long))
               ((%cc-gen-addr-c-type? ka) (%cc-gen-decay ka))
               ((if (string=? op "+") (%cc-gen-addr-c-type? kb) #f) (%cc-gen-decay kb))
               (#t (common-c-type ka kb))))
      ((if (string=? op "<<") #t (string=? op ">>")) (promoted-c-type ka))
      (#t (common-c-type ka kb)))))

; The address of what NODE names, into x0, answering the C type there: a
; name's own place, the pointee of a `*`, or an element.
(def %cc-gen-addr! ())
(set! %cc-gen-addr!
  (fn (self node)
    (let ((t (first node)))
      (match
        ((eq? t (lit var))
          (let ((at (%cc-gen-place-of (first (rest node)))))
            (do (%cc-gen-address! (first at) (first (rest at)))
                (%cc-gen-place-c-type at))))
        ((if (eq? t (lit un)) (string=? (first (rest node)) "*") #f)
          (let ((k (%cc-gen-c-type-of (first (rest (rest node))))))
            (if (not (%cc-gen-addr-c-type? k))
              (%cc-gen-no "the indirection of something that is not a pointer"))
            (do (%cc-gen-expr! (first (rest (rest node))))
                (c-type-elem k))))
        ((eq? t (lit idx)) (%cc-gen-index! (first (rest node)) (first (rest (rest node)))))
        ; a call that answers a struct answers its address
        ((if (eq? t (lit call)) (%cc-gen-struct? (%cc-gen-c-type-of node)) #f)
          (do (%cc-gen-expr! node) (%cc-gen-c-type-of node)))
        ; a field: the struct's address, or the one a pointer holds, and
        ; the field's offset on
        ((eq? t (lit dot))
          (let ((k (self (first (rest node)))))
            (if (not (%cc-gen-struct? k)) (%cc-gen-no "a field of something that is not a struct"))
            (let ((f (%cc-gen-field k (first (rest (rest node))))))
              (do (%cc-gen-bump! #t (first f)) (rest f)))))
        ((eq? t (lit arrow))
          (let ((k (%cc-gen-c-type-of (first (rest node)))))
            (if (not (if (%cc-gen-addr-c-type? k) (%cc-gen-struct? (c-type-elem k)) #f))
              (%cc-gen-no "a -> of something that is not a pointer to a struct"))
            (let ((f (%cc-gen-field (c-type-elem k) (first (rest (rest node))))))
              (do (%cc-gen-expr! (first (rest node)))
                  (%cc-gen-bump! #t (first f))
                  (rest f)))))
        (#t (%cc-gen-no "the address of something that is not a name, a pointee, an element or a field"))))))

; The address of A[I]: the address A stands for, plus I elements.  C lets
; either operand be the address, so I[A] is the same element.
(def %cc-gen-index!
  (fn (_ a i)
    (def swap (not (%cc-gen-addr-c-type? (%cc-gen-c-type-of a))))
    (def at (if swap i a))
    (def k (%cc-gen-c-type-of at))
    (if (not (%cc-gen-addr-c-type? k))
      (%cc-gen-no "a subscript of something that is not a pointer or an array"))
    (do (%cc-gen-expr! at)
        (asm-push! %cc-gen-asm x0)
        (%cc-gen-expr! (if swap a i))
        (%cc-gen-scale! x0 (c-type-size (c-type-elem k)))
        (%cc-gen! (lit mov) x1 x0)
        (asm-pop! %cc-gen-asm x0)
        (%cc-gen! (lit add) x0 x0 x1)
        (c-type-elem k))))

(def %cc-gen-expr! ())
(set! %cc-gen-expr!
  (fn (self node)
    (let ((t (first node)))
      (match
        ((eq? t (lit num)) (%cc-gen-const-c-type! (first (rest node)) (%cc-gen-num-c-type node)))
        ((eq? t (lit str)) (%cc-gen-string-at! (first (rest node))))
        ((eq? t (lit szof))
          (%cc-gen-const-c-type! (c-type-size (%cc-gen-c-type-of (first (rest node)))) (lit ulong)))
        ; a function's name, or & of it, is its address
        ((if (eq? t (lit var)) (%cc-gen-function-name? (first (rest node))) #f)
          (%cc-gen-function-address! (first (rest node))))
        ((if (if (eq? t (lit un)) (string=? (first (rest node)) "&") #f)
           (if (eq? (first (first (rest (rest node)))) (lit var))
             (%cc-gen-function-name? (first (rest (first (rest (rest node))))))
             #f)
           #f)
          (%cc-gen-function-address! (first (rest (first (rest (rest node)))))))
        ((if (eq? t (lit un)) (string=? (first (rest node)) "&") #f)
          (%cc-gen-addr! (first (rest (rest node)))))
        ((if (eq? t (lit un)) (string=? (first (rest node)) "*") #f)
          (%cc-gen-load-at! (%cc-gen-addr! node)))
        ((eq? t (lit idx))
          (%cc-gen-load-at! (%cc-gen-index! (first (rest node)) (first (rest (rest node))))))
        ((eq? t (lit un))
          (let ((op (first (rest node))))
            (def k (promoted-c-type (%cc-gen-c-type-of (first (rest (rest node))))))
            (do (self (first (rest (rest node))))
                (match
                  ((%cc-gen-real? k) (%cc-gen-real-unary! op k))
                  ((string=? op "-")
                    (do (%cc-gen! (lit sub) x0 xzr x0) (%cc-gen-normalize! k)))
                  ((string=? op "~")
                    (do (%cc-gen! (lit orn) x0 xzr x0)
                        (if (eq? k (lit uint)) (%cc-gen-uint!) ())))
                  ((string=? op "!")
                    (do (%cc-gen! (lit cmp) x0 (imm 0))
                        (%cc-gen-flag! (lit b/eq))))
                  (#t (%cc-gen-no (string-append "the unary operator " op)))))))
        ((if (eq? t (lit bin)) #t (eq? t (lit cmp)))
          (let ((op (first (rest node))))
            (def ka (%cc-gen-c-type-of (first (rest (rest node)))))
            (def kb (%cc-gen-c-type-of (first (rest (rest (rest node))))))
            (if (if (%cc-gen-struct? ka) #t (%cc-gen-struct? kb))
              (%cc-gen-no (string-append "the operator " op " on a struct")))
            ; a pointer to a function compares as the address it is, and
            ; takes no arithmetic
            (def fn? (if (%cc-gen-fnptr? ka) #t (%cc-gen-fnptr? kb)))
            (if (if fn? (eq? t (lit bin)) #f)
              (%cc-gen-no "arithmetic on a pointer to a function"))
            (def addr? (if (%cc-gen-addr-c-type? ka) #t (if (%cc-gen-addr-c-type? kb) #t fn?)))
            ; a shift works in its left operand's C type, anything else in the
            ; C type its two operands meet in
            (def k (if (if (string=? op "<<") #t (string=? op ">>"))
                     (promoted-c-type ka)
                     (common-c-type ka kb)))
            (if (if (%cc-gen-real? k) (not addr?) #f)
              ; each operand converted to a double as it is worked out
              (do (self (first (rest (rest node))))
                  (%cc-gen-convert! k ka)
                  (asm-push! %cc-gen-asm x0)
                  (self (first (rest (rest (rest node)))))
                  (%cc-gen-convert! k kb)
                  (%cc-gen! (lit mov) x1 x0)
                  (asm-pop! %cc-gen-asm x0)
                  (if (eq? t (lit cmp)) (%cc-gen-real-compare! op k) (%cc-gen-real-bin! op k)))
              (do (self (first (rest (rest node))))
                  (asm-push! %cc-gen-asm x0)
                  (self (first (rest (rest (rest node)))))
                  (%cc-gen! (lit mov) x1 x0)
                  (asm-pop! %cc-gen-asm x0)
                  ; an int converted to an unsigned int takes that C type's form
                  (if (if (eq? k (lit uint)) (not addr?) #f)
                    (do (%cc-gen-uint!) (%cc-gen-uint-x1!))
                    ())
                  (match
                    ((eq? t (lit cmp))
                      (do (if addr? (%cc-gen! (lit cmp) x0 x1) (%cc-gen-compare! k))
                          (%cc-gen-flag! (%cc-gen-branch op))))
                    (addr? (%cc-gen-addr-bin! op ka kb))
                    (#t (%cc-gen-bin! op k)))))))
        ((eq? t (lit var))
          (let ((at (%cc-gen-place-of (first (rest node)))))
            (if (%cc-gen-aggregate? (%cc-gen-place-c-type at))
              (%cc-gen-address! (first at) (first (rest at)))
              (%cc-gen-load! at))))
        ((if (eq? t (lit dot)) #t (eq? t (lit arrow)))
          (%cc-gen-load-at! (%cc-gen-addr! node)))
        ((eq? t (lit assign))
          (let ((lv (first (rest node))))
            (def k (%cc-gen-c-type-of lv))
            (def from (%cc-gen-c-type-of (first (rest (rest node)))))
            (if (%cc-gen-array? k)
              (%cc-gen-no "an assignment to an array"))
            (match
              ((%cc-gen-struct? k) (%cc-gen-struct-assign! lv (first (rest (rest node)))))
              ((eq? (first lv) (lit var))
                (do (self (first (rest (rest node))))
                    (%cc-gen-store! (%cc-gen-place-of (first (rest lv))) from)))
              ; any other place is an address worked out at run time: it
              ; waits on the stack while the value is
              (#t
                (let ((k (%cc-gen-value-c-type! (%cc-gen-addr! lv))))
                  (do (asm-push! %cc-gen-asm x0)
                      (self (first (rest (rest node))))
                      (asm-pop! %cc-gen-asm x1)
                      (%cc-gen-store! (%cc-gen-place x1 0 k) from)))))))
        ((%cc-gen-step? t) (%cc-gen-step! t node))
        ((eq? t (lit ternary))
          (let ((else- (%cc-gen-label)) (done (%cc-gen-label)))
            ; each arm converts to the C type the two meet in
            (def k (%cc-gen-c-type-of node))
            (def arm
              (fn (_ n) (do (self n) (%cc-gen-convert! k (%cc-gen-c-type-of n)))))
            (do (%cc-gen-cond! (first (rest node)))
                (%cc-gen! (lit b/eq) (label else-))
                (arm (first (rest (rest node))))
                (%cc-gen! (lit b) (label done))
                (asm-label! %cc-gen-asm else-)
                (arm (first (rest (rest (rest node)))))
                (asm-label! %cc-gen-asm done))))
        ((if (eq? t (lit and)) #t (eq? t (lit or)))
          ; the right operand runs only when the left did not settle it
          (let ((no (%cc-gen-label)) (done (%cc-gen-label)))
            (def out (if (eq? t (lit and)) 0 1))
            (def leave (if (eq? t (lit and)) (lit b/eq) (lit b/ne)))
            (do (%cc-gen-cond! (first (rest node)))
                (%cc-gen! leave (label no))
                (%cc-gen-cond! (first (rest (rest node))))
                (%cc-gen! leave (label no))
                (%cc-gen! (lit mov) x0 (imm (- 1 out)))
                (%cc-gen! (lit b) (label done))
                (asm-label! %cc-gen-asm no)
                (%cc-gen! (lit mov) x0 (imm out))
                (asm-label! %cc-gen-asm done))))
        ((eq? t (lit comma))
          (do (self (first (rest node))) (self (first (rest (rest node))))))
        ((eq? t (lit call)) (%cc-gen-call! node))
        ((eq? t (lit callx)) (%cc-gen-call-through! (first (rest node)) (first (rest (rest node)))))
        ((eq? t (lit cast))
          (let ((k (first (rest node))) (e (first (rest (rest node)))))
            (def from (%cc-gen-c-type-of e))
            (if (%cc-gen-aggregate? k) (%cc-gen-no "a cast to an array or a struct"))
            (if (%cc-gen-struct? from) (%cc-gen-no "a cast of a struct"))
            (do (self e) (%cc-gen-convert! k from))))
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
    (def up (if (eq? t (lit preinc)) #t (eq? t (lit postinc))))
    (def after (if (eq? t (lit preinc)) #t (eq? t (lit predec))))
    ; a name is a place of its own; any other place is an address worked
    ; out at run time, held in x1 while the value is stepped
    (def at
      (if (eq? (first lv) (lit var))
        (%cc-gen-place-of (first (rest lv)))
        (let ((k (%cc-gen-addr! lv)))
          (do (%cc-gen! (lit mov) x1 x0)
              (%cc-gen-place x1 0 k)))))
    (def k (%cc-gen-value-c-type! (%cc-gen-place-c-type at)))
    (do (%cc-gen-load! at)
        ; the old value waits in x8 for the postfix forms: x2 is the
        ; re-extension's shift amount
        (%cc-gen! (lit mov) x8 x0)
        (match
          ((%cc-gen-ptr? k) (%cc-gen-bump! up (c-type-size (c-type-elem k))))
          ((%cc-gen-real? k) (%cc-gen-real-step! up k))
          (#t (do (%cc-gen-bump! up 1) (%cc-gen-normalize! (promoted-c-type k)))))
        (%cc-gen-store! at k)
        (if after () (%cc-gen! (lit mov) x0 x8)))))

; A call: to one of the program's own functions, or else into the C
; library.  The answer comes back in x0.
(def %cc-gen-call!
  (fn (_ node)
    (def name (first (rest node)))
    (def args (first (rest (rest node))))
    (match
      ; a name that is a local's or a global's holds a pointer to a function
      ((%cc-gen-variable? name) (%cc-gen-call-through! (list (lit var) name) args))
      ((null? (%cc-gen-fun-find name)) (%cc-gen-libc-call! name args))
      (#t (%cc-gen-call-fun! node)))))

(def %cc-gen-imports ())    ; ((name . offset) ...), the C library's functions called

; the offset in the data of the slot the loader fills with the C library's
; function NAME, taken the first time a call names it
(def %cc-gen-import-slot
  (fn (_ name)
    (def go (fn (self es)
              (match
                ((null? es) ())
                ((string=? (first (first es)) name) (rest (first es)))
                (#t (self (rest es))))))
    (def hit (go %cc-gen-imports))
    (if (not (null? hit)) hit
      (let ((off (%cc-gen-data! (list 0 0 0 0 0 0 0 0) 8)))
        (do (set! %cc-gen-imports (pair (pair name off) %cc-gen-imports))
            off)))))

; whether the C library has a function NAME: asked of the library this
; process has, which is the one the program will load
(def %cc-gen-libc ())
(def %cc-gen-libc-has?
  (fn (_ name)
    (if (null? %cc-gen-libc) (set! %cc-gen-libc ((prim-ref (lit ffi) (lit dlopen)) () 1)) ())
    (not (null? ((prim-ref (lit ffi) (lit dlsym)) %cc-gen-libc name)))))

; (V-NAME FIXED) for a variadic function of the C library, else nil
(def %cc-gen-variadic
  (fn (_ name)
    (def go (fn (self es)
              (match
                ((null? es) ())
                ((string=? (first (first es)) name) (rest (first es)))
                (#t (self (rest es))))))
    (go library-variadic)))

; A call into the C library, to a function the program does not define.
; The arguments are evaluated in order and pushed, then popped into the
; frame's call area, six at most; a variadic function is called through
; its v- form, with the arguments past its fixed ones in their slots and a
; va_list after the fixed ones.  x8 takes the function's address from its
; slot in the data, x0 the area's address, and the trampoline makes the
; call.  The answer is put in the form of the C type the function's header
; declares.  One of the library's functions on doubles (library-double-fns)
; takes its arguments as doubles, in the area's double slots, and a double
; answer comes back in d0.
(def %cc-gen-libc-call!
  (fn (_ name args)
    (def v (%cc-gen-variadic name))
    ; the maths functions are libm's, which glibc keeps apart from the C
    ; library this process can ask
    (def label (library-double-label name))
    (if (if (null? label) (not (%cc-gen-libc-has? (if (null? v) name (first v)))) #f)
      (%cc-gen-no (string-append "a call to " name)))
    (def doubles? (if (null? label) #f (not (string=? label "s0->d"))))
    (if (if doubles? (not (= (length args) (if (string=? label "dd->d") 2 1))) #f)
      (%cc-gen-no (string-append "a call to " name " with the wrong number of arguments")))
    (def fixed (if (null? v) (length args) (first (rest v))))
    (def nvar (- (length args) fixed))
    (if (< nvar 0) (%cc-gen-no (string-append name " with too few arguments")))
    (if (> (if (null? v) fixed (+ fixed 1)) 6)
      (%cc-gen-no (string-append "a call to " name " with more than six arguments")))
    (def at (fn (_ off) (mem x19 (+ %cc-gen-ca off))))
    (def push-all
      (fn (self as)
        (if (null? as) ()
          (do (%cc-gen-expr! (first as))
              ; a float goes as a double, C's default promotion
              (let ((k (%cc-gen-c-type-of (first as))))
                (if (if doubles? #t (eq? k (lit float))) (%cc-gen-convert! (lit double) k) ()))
              (asm-push! %cc-gen-asm x0)
              (self (rest as))))))
    ; the last pushed is on top: slots K down to 0 from BASE
    (def pop-into
      (fn (self k base)
        (if (< k 0) ()
          (do (asm-pop! %cc-gen-asm x0)
              (%cc-gen! (lit str) x0 (at (+ base (* 8 k))))
              (self (- k 1) base)))))
    (do (push-all args)
        (pop-into (- nvar 1) %cc-gen-ca-vars)
        (pop-into (- fixed 1) (if doubles? %cc-gen-ca-doubles 0))
        (if (null? v) ()
          (do (%cc-gen-address! x19 (+ %cc-gen-ca %cc-gen-ca-vars))
              (if %cc-gen-sysv?
                (do (%cc-gen! (lit str) x0 (at (+ %cc-gen-ca-record 8)))
                    (%cc-gen! (lit mov) x0 (imm 48))
                    (%cc-gen! (lit strw) x0 (at %cc-gen-ca-record))
                    (%cc-gen! (lit mov) x0 (imm 304))
                    (%cc-gen! (lit strw) x0 (at (+ %cc-gen-ca-record 4)))
                    (%cc-gen-address! x19 (+ %cc-gen-ca %cc-gen-ca-record)))
                ())
              (%cc-gen! (lit str) x0 (at (* 8 fixed)))))
        (asm-load-imm64! %cc-gen-asm x8
          (%cc-gen-import-slot (if (null? v) name (first v))))
        (%cc-gen! (lit add) x8 x8 x22)
        (%cc-gen! (lit ldr) x8 (mem x8 0))
        (%cc-gen-address! x19 %cc-gen-ca)
        (%cc-gen-frame-top!)
        (%cc-gen! (lit blr) x21)
        (if (eq? (library-c-type name) (lit double))
          (%cc-gen! (lit fmov/x) x0 d0)
          (%cc-gen-normalize! (library-c-type name))))))

; the frame stack's top, where the gate takes it up again when the library
; calls one of the program's functions
(def %cc-gen-frame-top!
  (fn (_) (%cc-gen! (lit str) x20 (mem x22 8))))

(def %cc-gen-thunks ())     ; ((name . label) ...), the functions whose address is taken
(def %cc-gen-gate ())       ; the label the gate follows the code at

; the label of NAME's thunk, which the function's address is: it takes
; the function's address into x8 and branches to the gate
(def %cc-gen-thunk-label
  (fn (_ name)
    (def go (fn (self es)
              (match
                ((null? es) ())
                ((string=? (first (first es)) name) (rest (first es)))
                (#t (self (rest es))))))
    (def hit (go %cc-gen-thunks))
    (if (not (null? hit)) hit
      (let ((l (%cc-gen-label)))
        (do (set! %cc-gen-thunks (pair (pair name l) %cc-gen-thunks)) l)))))

; each thunk, then the gate's label, after the program's last function
(def %cc-gen-thunks!
  (fn (_)
    (set! %cc-gen-gate (%cc-gen-label))
    (def go
      (fn (self ts)
        (if (null? ts) ()
          (do (asm-label! %cc-gen-asm (rest (first ts)))
              (%cc-gen! (lit adr) x8 (label (%cc-gen-fun-label (first (first ts)))))
              (%cc-gen! (lit b) (label %cc-gen-gate))
              (self (rest ts))))))
    (do (go (reverse %cc-gen-thunks))
        (asm-label! %cc-gen-asm %cc-gen-gate))))

; The gate, written out per target after the code, since it takes registers
; the portable model does not name.  A pointer to a function leads to it,
; from the C library or from the program's own call through a pointer, with
; the function in x8 and the arguments where the C calling convention
; puts them.  It keeps the caller's x19 to x22, which that convention has
; the callee keep; takes up the program's own -- the data and the
; trampoline from where the gate stands, the frame stack's top from where
; the last call out left it -- and keeps that slot to put back; moves the
; arguments into the program's registers (on x86-64: rax from rdi, rcx
; from rdx); calls the function; and puts everything back.  GATEPOS and
; DATAAT are the gate's and the data's distance from the entry's start.
(def %cc-gen-gate-bytes
  (fn (_ target gatepos dataat)
    (if (eq? target (lit macho-arm64))
      (%cc-gen-cat
        (map %cc-gen-le32
          (list 0xA9BF7BFD 0xA9BF53F3 0xA9BF5BF5
                (%cc-gen-adr 22 (- dataat (+ gatepos 12)))
                (%cc-gen-adr 21 (- 28 (+ gatepos 16)))
                0xF94006D4 0xF94006C9 0xF81F0FE9 0xD63F0100 0xF84107E9 0xF90006C9
                0xA8C15BF5 0xA8C153F3 0xA8C17BFD 0xD65F03C0)))
      (%cc-gen-cat
        (list (list 0x53 0x41 0x54 0x41 0x55 0x41 0x56)
              (list 0x4C 0x8D 0x35) (%cc-gen-le32 (- dataat (+ gatepos 14)))
              (list 0x4C 0x8D 0x2D) (%cc-gen-le32 (- 51 (+ gatepos 21)))
              (list 0x4D 0x8B 0x66 0x08 0x41 0xFF 0x76 0x08 0x48 0x89 0xF8
                    0x48 0x89 0xD1 0x41 0xFF 0xD2 0x41 0x8F 0x46 0x08
                    0x41 0x5E 0x41 0x5D 0x41 0x5C 0x5B 0xC3))))))

; how long the gate is
(def %cc-gen-gate-len
  (fn (_ target) (if (eq? target (lit macho-arm64)) 60 50)))

; Where each argument of a call goes, by the C types of the callee's
; parameters: (reg . R) for one of the first four that is not a struct,
; else (above . OFF), the argument starting OFF bytes below the top of the
; frame the callee takes -- each in whole words, in order, under the word
; that says where a struct the callee answers goes (%cc-gen-fun!).  Caller
; and callee both lay it out from the same C types.
(def %cc-gen-homes
  (fn (_ c-types sret?)
    (def go
      (fn (self ks regs used)
        (if (null? ks) ()
          (let ((k (first ks)))
            (if (if (null? regs) #f (not (%cc-gen-struct? k)))
              (pair (pair (lit reg) (first regs)) (self (rest ks) (rest regs) used))
              (let ((off (+ used (round-up (c-type-size k) 8))))
                (pair (pair (lit above) off)
                  (self (rest ks) (if (null? regs) () (rest regs)) off))))))))
    (go c-types %cc-gen-args (if sret? 8 0))))

; how many bytes the homes above take, whole sixteens
(def %cc-gen-above-size
  (fn (_ homes sret?)
    (def go
      (fn (self hs most)
        (if (null? hs) most
          (self (rest hs)
            (if (eq? (first (first hs)) (lit above)) (rest (first hs)) most)))))
    (round-up (go homes (if sret? 8 0)) 16)))

; A call.  The arguments that go in registers are worked out first and wait
; on the stack, then the ones that go above; every argument is worked out
; before any is stored, so a call inside one cannot overwrite the others.
; C leaves the order of arguments open.  The ones above are stored below
; this frame's base, x20, which is the top of the frame the callee takes off
; x20 next -- a struct copied there whole -- then the rest are popped into
; their registers.  A call that answers a struct first says where the
; struct goes: the slot the scan set aside for this call (%cc-gen-rslots),
; whose address is what the call answers.
; does NAME, used as a value, name one of the program's functions: no local
; or global has the name, and a function does
(def %cc-gen-function-name?
  (fn (_ name)
    (match
      ((not (null? (%cc-gen-find name))) #f)
      ((not (null? (%cc-gen-global-find name))) #f)
      (#t (not (null? (%cc-gen-fun-find name)))))))

; The function NAME's address, into x0, taken from where the instruction
; is.  A call through a pointer hands over the arguments in the first
; registers (%cc-gen-call-through!), so a function whose address is taken
; takes at most three, none of them a struct, and answers no struct.
(def %cc-gen-function-address!
  (fn (_ name)
    (def params (%cc-gen-params-find name))
    (if (if (> (length params) 3) #t
          (if (%cc-gen-struct? (%cc-gen-ret-find name)) #t
            (not (null? (filter %cc-gen-struct? params)))))
      (%cc-gen-no (string-append "the address of " name
                    ", which takes a struct or more than three arguments, or answers a struct")))
    (%cc-gen! (lit adr) x0 (label (%cc-gen-thunk-label name)))))

; A call through TARGET, a pointer to a function, with ARGS: the address,
; then each argument in its own C type's promoted form, wait on the stack;
; the arguments go into the first registers and the address into x8,
; which three arguments leave free.  It answers what the pointer's RET says.
(def %cc-gen-call-through!
  (fn (_ target args)
    (if (not (%cc-gen-fnptr? (%cc-gen-c-type-of target)))
      (%cc-gen-no "a call through something that is not a pointer to a function"))
    (if (> (length args) 3)
      (%cc-gen-no "a call through a pointer with more than three arguments"))
    (def push-all
      (fn (self as)
        (if (null? as) ()
          (do (if (%cc-gen-struct? (%cc-gen-c-type-of (first as)))
                (%cc-gen-no "a struct handed to a function through a pointer"))
              (%cc-gen-expr! (first as))
              (asm-push! %cc-gen-asm x0)
              (self (rest as))))))
    ; the last one pushed is on top, so the registers fill from the last back
    (def pop-all
      (fn (self rs)
        (if (null? rs) ()
          (do (asm-pop! %cc-gen-asm (first rs)) (self (rest rs))))))
    (do (%cc-gen-expr! target)
        (asm-push! %cc-gen-asm x0)
        (push-all args)
        (pop-all (reverse (%cc-gen-take (length args) (list x0 x1 x2))))
        (asm-pop! %cc-gen-asm x8)
        (%cc-gen-frame-top!)
        (%cc-gen! (lit blr) x8))))

(def %cc-gen-call-fun!
  (fn (_ node)
    (def name (first (rest node)))
    (def args (first (rest (rest node))))
    (def to (%cc-gen-fun-label name))
    (def params (%cc-gen-params-find name))
    (def sret? (%cc-gen-struct? (%cc-gen-ret-find name)))
    ; (ARG C-TYPE . HOME) per argument; past the parameters, an argument's
    ; own C type says where it goes
    (def c-types
      (let ((go (fn (self as ps)
                  (if (null? as) ()
                    (pair (if (null? ps) (%cc-gen-c-type-of (first as)) (first ps))
                      (self (rest as) (if (null? ps) () (rest ps))))))))
        (go args params)))
    (def triples
      (let ((go (fn (self as ks hs)
                  (if (null? as) ()
                    (pair (pair (first as) (pair (first ks) (first hs)))
                      (self (rest as) (rest ks) (rest hs)))))))
        (go args c-types (%cc-gen-homes c-types sret?))))
    (def home (fn (_ t) (rest (rest t))))
    (def in-reg? (fn (_ t) (eq? (first (home t)) (lit reg))))
    (def regs (filter in-reg? triples))
    (def above (filter (fn (_ t) (not (in-reg? t))) triples))
    (def push-each
      (fn (self ts)
        (if (null? ts) ()
          (let ((t (first ts)))
            (do (if (%cc-gen-struct? (first (rest t)))
                  (%cc-gen-same-struct! (first (rest t)) (first t) "a struct argument")
                  (if (%cc-gen-struct? (%cc-gen-c-type-of (first t)))
                    (%cc-gen-no "a struct passed for a parameter that is not one")
                    ()))
                (%cc-gen-expr! (first t))
                (%cc-gen-convert-real! (first (rest t)) (%cc-gen-c-type-of (first t)))
                (asm-push! %cc-gen-asm x0)
                (self (rest ts)))))))
    ; the last pushed is on top
    (def store-each
      (fn (self ts)
        (if (null? ts) ()
          (let ((t (first ts)))
            (do (asm-pop! %cc-gen-asm x0)
                (%cc-gen! (lit sub) x1 x20 (imm (rest (home t))))
                (if (%cc-gen-struct? (first (rest t)))
                  (%cc-gen-copy! (c-type-size (first (rest t))))
                  (%cc-gen! (lit str) x0 (mem x1 0)))
                (self (rest ts)))))))
    (def pop-each
      (fn (self ts)
        (if (null? ts) ()
          (do (asm-pop! %cc-gen-asm (rest (home (first ts))))
              (self (rest ts))))))
    (do (push-each regs)
        (push-each above)
        (store-each (reverse above))
        (if sret?
          (do (%cc-gen-address! x19 (%cc-gen-rslot-of node))
              (%cc-gen! (lit sub) x1 x20 (imm 8))
              (%cc-gen! (lit str) x0 (mem x1 0)))
          ())
        (pop-each (reverse regs))
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

; the call area's size for a function whose body is NODE: 0 when it calls
; nothing in the C library, else its fixed part and a slot for each of the
; most arguments one of its variadic calls passes past its fixed ones
(def %cc-gen-call-area
  (fn (_ node)
    ; -1 when NODE calls nothing in the library, else the most variable
    ; arguments one of its calls passes
    (def most
      (fn (self node)
        (if (not (pair? node)) -1
          (let ((here (if (if (eq? (first node) (lit call))
                                (null? (%cc-gen-fun-find (first (rest node))))
                                #f)
                        (let ((v (%cc-gen-variadic (first (rest node))))
                              (n (length (first (rest (rest node))))))
                          (if (null? v) 0 (- n (first (rest v)))))
                        -1)))
            (def go
              (fn (self2 xs best)
                (if (null? xs) best
                  (self2 (rest xs) (let ((w (self (first xs)))) (if (> w best) w best))))))
            (go node here)))))
    (let ((m (most node)))
      (if (< m 0) 0 (+ %cc-gen-ca-vars (* 8 m))))))

; --- statements --------------------------------------------------------------

; An array in the frame, from its initializer: a braced list stores its
; items in order, a nested list filling a nested array, and the elements
; it does not reach are zero, as C says; a string fills a char array with
; its bytes, then zeros.
(def %cc-gen-init-array!
  (fn (self at init)
    (def base (first at))
    (def off (first (rest at)))
    (def k (%cc-gen-place-c-type at))
    (def n (first (rest k)))
    (def ek (c-type-elem k))
    (def es (c-type-size ek))
    (def elem (fn (_ i) (%cc-gen-place base (+ off (* i es)) ek)))
    (match
      ((eq? (first init) (lit initlist))
        (let ((items (first (rest init))))
          (if (> (length items) n) (%cc-gen-no "more initializers than an array has elements"))
          (def fill
            (fn (fill i is)
              (if (>= i n) ()
                (do (if (null? is)
                      (%cc-gen-zero! (elem i))
                      (let ((item (first is)))
                        (if (%cc-gen-aggregate? ek)
                          (%cc-gen-init-aggregate! (elem i) item)
                          (do (%cc-gen-expr! item)
                              (%cc-gen-convert-real! ek (%cc-gen-c-type-of item))
                              (%cc-gen-put! (elem i))))))
                    (fill (+ i 1) (if (null? is) () (rest is)))))))
          (fill 0 items)))
      ((if (eq? (first init) (lit str)) (%cc-gen-byte? ek) #f)
        (let ((text (first (rest init))))
          (if (> (byte-len text) n) (%cc-gen-no "a string longer than the array it initializes"))
          (def fill
            (fn (fill i)
              (if (>= i n) ()
                (do (%cc-gen-const! (if (< i (byte-len text)) (byte-at text i) 0))
                    (%cc-gen-put! (elem i))
                    (fill (+ i 1))))))
          (fill 0)))
      (#t (%cc-gen-no "an array initialized by something other than a list or a string")))))

; An aggregate in the frame, from its initializer.
(def %cc-gen-init-aggregate!
  (fn (_ at init)
    (if (%cc-gen-struct? (%cc-gen-place-c-type at))
      (%cc-gen-init-struct! at init)
      (%cc-gen-init-array! at init))))

; A struct in the frame, from its initializer: a braced list stores its
; items in the fields' order, a nested list filling a nested aggregate, and
; the fields it does not reach are zero, as C says -- so the struct is
; zeroed first, which also leaves a union's other fields as its first one's
; bytes make them.  An expression of the same struct is copied.
(def %cc-gen-init-struct!
  (fn (_ at init)
    (def base (first at))
    (def off (first (rest at)))
    (def k (%cc-gen-place-c-type at))
    (def fields (rest (rest (struct-entry (first (rest k))))))
    (if (not (eq? (first init) (lit initlist)))
      (%cc-gen-copy-into! at init)
      (let ((items (first (rest init))))
        (if (> (length items) (length fields))
          (%cc-gen-no "more initializers than a struct has fields"))
        (%cc-gen-zero! at)
        (def fill
          (fn (fill fs is end)
            (if (null? is) ()
              (let ((f (first fs)))
                (def foff (first (rest f)))
                (def fk (first (rest (rest f))))
                (def fat (%cc-gen-place base (+ off foff) fk))
                ; where the field starts and ends, in bits: bit-fields share
                ; a unit
                (def start (+ (* 8 foff) (if (%cc-gen-bits? fk) (first (rest (rest fk))) 0)))
                (def size
                  (if (%cc-gen-bits? fk) (first (rest (rest (rest fk)))) (* 8 (c-type-size fk))))
                ; a field that starts before the last one ends overlaps it,
                ; which is a union's: it takes one
                (if (< start end) (%cc-gen-no "more initializers than a union takes"))
                (do (if (%cc-gen-aggregate? fk)
                      (%cc-gen-init-aggregate! fat (first is))
                      (do (%cc-gen-expr! (first is))
                          (%cc-gen-convert-real! fk (%cc-gen-c-type-of (first is)))
                          (%cc-gen-put! fat)))
                    (fill (rest fs) (rest is) (+ start size)))))))
        (fill fields items 0)))))

; the same struct C type, or a refusal saying what the value was not
(def %cc-gen-same-struct!
  (fn (_ k node what)
    (let ((ks (%cc-gen-c-type-of node)))
      (if (if (%cc-gen-struct? ks) (string=? (first (rest ks)) (first (rest k))) #f) ()
        (%cc-gen-no (string-append what " of something other than the same struct"))))))

; the struct at AT, a copy of the one SRC stands for
(def %cc-gen-copy-into!
  (fn (_ at src)
    (%cc-gen-same-struct! (%cc-gen-place-c-type at) src "a struct initialized by")
    (do (%cc-gen-expr! src)
        (asm-push! %cc-gen-asm x0)
        (%cc-gen-address! (first at) (first (rest at)))
        (%cc-gen! (lit mov) x1 x0)
        (asm-pop! %cc-gen-asm x0)
        (%cc-gen-copy! (c-type-size (%cc-gen-place-c-type at))))))

; A struct assigned: the right one's bytes copied over the left's.  The
; left's address waits on the stack while the right's is worked out, and
; the answer is the left's address, which stands for the struct.
(def %cc-gen-struct-assign!
  (fn (_ lv rhs)
    (def k (%cc-gen-c-type-of lv))
    (%cc-gen-same-struct! k rhs "an assignment to a struct")
    (do (%cc-gen-addr! lv)
        (asm-push! %cc-gen-asm x0)
        (%cc-gen-expr! rhs)
        (asm-pop! %cc-gen-asm x1)
        (%cc-gen-copy! (c-type-size k))
        (%cc-gen! (lit mov) x0 x1))))

; SIZE bytes from the address in x0 to the one in x1, through x2, the widest
; chunk first: each chunk's offset is then a multiple of its width, which is
; what arm64's scaled offsets need, and the byte offset stays in reach
(def %cc-gen-copy!
  (fn (_ size)
    (if (> size 4095) (%cc-gen-no "a struct copy past four kilobytes"))
    (def go
      (fn (self i)
        (if (>= i size) ()
          (let ((w (match ((>= (- size i) 8) 8) ((>= (- size i) 4) 4)
                          ((>= (- size i) 2) 2) (#t 1))))
            (do (%cc-gen! (match ((= w 8) (lit ldr)) ((= w 4) (lit ldrw))
                                 ((= w 2) (lit ldrh)) (#t (lit ldrb)))
                  x2 (mem x0 i))
                (%cc-gen! (match ((= w 8) (lit str)) ((= w 4) (lit strw))
                                 ((= w 2) (lit strh)) (#t (lit strb)))
                  x2 (mem x1 i))
                (self (+ i w)))))))
    (go 0)))

; zeros over the place AT, element by element or field by field
(def %cc-gen-zero!
  (fn (self at)
    (def k (%cc-gen-place-c-type at))
    (def base (first at))
    (def off (first (rest at)))
    (match
      ((%cc-gen-array? k)
        (let ((ek (c-type-elem k)))
          (def go
            (fn (go i)
              (if (>= i (first (rest k))) ()
                (do (self (%cc-gen-place base (+ off (* i (c-type-size ek))) ek))
                    (go (+ i 1))))))
          (go 0)))
      ((%cc-gen-struct? k)
        (let ((go (fn (go fs)
                    (if (null? fs) ()
                      (do (self (%cc-gen-place base (+ off (first (rest (first fs))))
                                  (first (rest (rest (first fs))))))
                          (go (rest fs)))))))
          (go (rest (rest (struct-entry (first (rest k))))))))
      (#t (do (%cc-gen! (lit mov) x0 (imm 0)) (%cc-gen-put! at))))))

; a condition, then a branch taken when it is false
(def %cc-gen-test!
  (fn (_ node to)
    (do (%cc-gen-cond! node)
        (%cc-gen! (lit b/eq) (label to)))))

; where a break or a continue goes: the innermost loop's, but a switch's
; for a break, and a continue in a switch goes to the loop around it
(def %cc-gen-loop-label
  (fn (_ which)
    (def to
      (match
        ((null? %cc-gen-loops) ())
        ((string=? which "break") (first (first %cc-gen-loops)))
        (#t (rest (first %cc-gen-loops)))))
    (if (null? to) (%cc-gen-no (string-append which " outside a loop")) to)))

; a case label's value, in C-TYPE: a constant, worked out now as a global's
; initializer is
(def %cc-gen-case-value
  (fn (_ node c-type)
    (%cc-gen-form
      (guard (e (%cc-gen-no "a case label that is not a constant")) (%cc-gen-fold node))
      c-type)))

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
        ; a static local was laid out, initializer and all, with the globals
        ((if (eq? t (lit decl)) (%cc-gen-static-decl? node) #f) ())
        ((eq? t (lit decl))
          ; the scan gave it its slot before any code was emitted, and a
          ; local of the name wins over a global of it
          (let ((at (%cc-gen-place-of (first (rest node)))))
            (def init (first (rest (rest (rest node)))))
            (if (%cc-gen-aggregate? (%cc-gen-place-c-type at))
              (if (null? init) () (%cc-gen-init-aggregate! at init))
              (do (if (null? init) (%cc-gen-const! 0)
                    (do (%cc-gen-expr! init)
                        (%cc-gen-convert-real! (%cc-gen-place-c-type at) (%cc-gen-c-type-of init))))
                  (%cc-gen-put! at)))))
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
                (%cc-gen-cond! (first (rest (rest node))))
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
        ; a struct is copied to where the caller asked for it, in the word
        ; the prologue brought down from the frame's top, and that address
        ; answers
        ((if (eq? t (lit return)) (%cc-gen-struct? %cc-gen-ret-c-type) #f)
          (do (%cc-gen-same-struct! %cc-gen-ret-c-type (first (rest node)) "a return")
              (%cc-gen-expr! (first (rest node)))
              (%cc-gen! (lit ldr) x1 (mem x19 %cc-gen-sret-slot))
              (%cc-gen-copy! (c-type-size %cc-gen-ret-c-type))
              (%cc-gen! (lit mov) x0 x1)
              (%cc-gen! (lit b) (label %cc-gen-epilogue))))
        ((eq? t (lit return))
          (do (if (null? (first (rest node)))
                (%cc-gen-const! 0)
                (%cc-gen-expr! (first (rest node))))
              ; the value converts to what the function returns
              (%cc-gen-convert! %cc-gen-ret-c-type
                (if (null? (first (rest node))) (lit int) (%cc-gen-c-type-of (first (rest node)))))
              (%cc-gen! (lit b) (label %cc-gen-epilogue))))
        ((eq? t (lit break))
          (%cc-gen! (lit b) (label (%cc-gen-loop-label "break"))))
        ((eq? t (lit continue))
          (%cc-gen! (lit b) (label (%cc-gen-loop-label "continue"))))
        ((eq? t (lit switch))
          ; the value is compared with each case label in turn: the first
          ; to match, else the default, else nothing, is where the body is
          ; entered, and the clauses after it run on until a break.  C
          ; promotes the value, and each label converts to its C type.
          (let ((out (%cc-gen-label)))
            (def e (first (rest node)))
            (def k (promoted-c-type (%cc-gen-c-type-of e)))
            ; ((LABEL VALUE stmt ...) ...), a label for each clause
            (def clauses
              (let ((go (fn (go cs)
                          (if (null? cs) ()
                            (pair (pair (%cc-gen-label) (first cs)) (go (rest cs)))))))
                (go (first (rest (rest node))))))
            (def default-
              (let ((go (fn (go cs)
                          (match
                            ((null? cs) out)
                            ((null? (first (rest (first cs)))) (first (first cs)))
                            (#t (go (rest cs)))))))
                (go clauses)))
            (def tests
              (fn (tests cs)
                (if (null? cs) ()
                  (do (if (null? (first (rest (first cs)))) ()
                        (do (asm-load-imm64! %cc-gen-asm x1
                              (%cc-gen-case-value (first (rest (first cs))) k))
                            (%cc-gen! (lit cmp) x0 x1)
                            (%cc-gen! (lit b/eq) (label (first (first cs))))))
                      (tests (rest cs))))))
            (def bodies
              (fn (bodies cs)
                (if (null? cs) ()
                  (do (asm-label! %cc-gen-asm (first (first cs)))
                      (self (list (lit block) (rest (rest (first cs)))))
                      (bodies (rest cs))))))
            (%cc-gen-expr! e)
            (tests clauses)
            (%cc-gen! (lit b) (label default-))
            (set! %cc-gen-loops
              (pair (pair out (if (null? %cc-gen-loops) () (rest (first %cc-gen-loops))))
                %cc-gen-loops))
            (bodies clauses)
            (set! %cc-gen-loops (rest %cc-gen-loops))
            (asm-label! %cc-gen-asm out)))
        ; every local has its slot for the whole function, so a goto is a
        ; branch, into a block or out of one
        ((eq? t (lit goto)) (%cc-gen! (lit b) (label (%cc-gen-label-find! (first (rest node))))))
        ((eq? t (lit label))
          (let ((name (first (rest node))))
            (if (%cc-gen-name-in? name %cc-gen-placed) (%cc-gen-no (string-append "a second label " name)))
            (set! %cc-gen-placed (pair name %cc-gen-placed))
            (asm-label! %cc-gen-asm (%cc-gen-label-find! name))
            (self (first (rest (rest node))))))
        (#t (%cc-gen-no (string-append "the statement " (convert t %string))))))))

; The function's labels, ((NAME . LABEL) ...): a goto branches to its
; label's, which the first goto or the label itself makes, since a goto can
; come before its label.  The names of the ones placed so far are in
; %cc-gen-placed.
(def %cc-gen-labels ())
(def %cc-gen-placed ())

(def %cc-gen-name-in?
  (fn (_ name names)
    (def go (fn (self ns) (if (null? ns) #f (if (string=? (first ns) name) #t (self (rest ns))))))
    (go names)))

(def %cc-gen-label-find!
  (fn (_ name)
    (def go (fn (self es)
              (match
                ((null? es) ())
                ((string=? (first (first es)) name) (rest (first es)))
                (#t (self (rest es))))))
    (def hit (go %cc-gen-labels))
    (if (not (null? hit)) hit
      (let ((l (%cc-gen-label)))
        (do (set! %cc-gen-labels (pair (pair name l) %cc-gen-labels)) l)))))

; every label a goto names was placed; C refuses a goto to a label the
; function does not have
(def %cc-gen-labels-placed!
  (fn (_)
    (def go (fn (self es)
              (match
                ((null? es) ())
                ((%cc-gen-name-in? (first (first es)) %cc-gen-placed) (self (rest es)))
                (#t (%cc-gen-no
                      (string-append "a goto to a label the function does not have: "
                        (first (first es))))))))
    (go %cc-gen-labels)))

; the bytes at P from offset 0 through I, as a list
(def %cc-gen-read
  (fn (self p i acc)
    (if (< i 0) acc (self p (- i 1) (pair (mem-ref-byte p i) acc)))))

; --- a function --------------------------------------------------------------

; Every declaration in the body takes a slot before any code is emitted: the
; prologue has to know the frame's size, and it comes first.  One pass takes
; the scalars and another, AGGREGATES? true, the arrays and structs, so the
; scalars sit low in the frame, where a load reaches them.
(def %cc-gen-scan!
  (fn (self node aggregates?)
    (if (not (pair? node)) ()
      (let ((t (first node)))
        (match
          ; a static local's name goes to its room in the data instead,
          ; bound in the first pass
          ((eq? t (lit decl))
            (if (%cc-gen-static-decl? node)
              (if aggregates? () (%cc-gen-bind-static! node))
              (let ((c-type (%cc-gen-c-type! (first (rest (rest node))) "a local")))
                (if (eq? (%cc-gen-aggregate? c-type) aggregates?)
                  (%cc-gen-slot! (first (rest node)) c-type)
                  ()))))
          ((eq? t (lit block))
            (let ((go (fn (self2 items)
                        (if (null? items) ()
                          (do (self (first items) aggregates?) (self2 (rest items)))))))
              (go (first (rest node)))))
          ((eq? t (lit if))
            (do (self (first (rest (rest node))) aggregates?)
                (let ((e (first (rest (rest (rest node))))))
                  (if (null? e) () (self e aggregates?)))))
          ((eq? t (lit while)) (self (first (rest (rest node))) aggregates?))
          ((eq? t (lit do)) (self (first (rest node)) aggregates?))
          ((eq? t (lit for))
            (do (let ((i (first (rest node)))) (if (null? i) () (self i aggregates?)))
                (self (first (rest (rest (rest (rest node))))) aggregates?)))
          ((eq? t (lit switch))
            (let ((go (fn (self2 cs)
                        (if (null? cs) ()
                          (do (self (list (lit block) (rest (first cs))) aggregates?)
                              (self2 (rest cs)))))))
              (go (first (rest (rest node))))))
          ((eq? t (lit label)) (self (first (rest (rest node))) aggregates?))
          (#t ()))))))

(def %cc-gen-fun!
  (fn (_ f)
    (def params (first (rest (rest f))))
    (def body (first (rest (rest (rest f)))))
    (def c-types (first (rest (rest (rest (rest f))))))
    (def ret (first (rest (rest (rest (rest (rest f)))))))
    (set! %cc-gen-ret-c-type
      (match
        ((eq? ret (lit void)) ret)
        (#t (%cc-gen-c-type! ret "a function returning something"))))
    (def sret? (%cc-gen-struct? %cc-gen-ret-c-type))
    (set! %cc-gen-env ())
    (set! %cc-gen-frame-bytes 0)
    (set! %cc-gen-loops ())
    (set! %cc-gen-rslots ())
    (set! %cc-gen-labels ())
    (set! %cc-gen-placed ())
    (set! %cc-gen-epilogue (%cc-gen-label))
    ; The frame, from its base in x19 up: the parameters, the declarations
    ; that are not arrays or structs, and the word that says where a struct
    ; the function answers goes, each where a load reaches it; the call area
    ; when the function calls into the C library; the arrays and structs,
    ; reached through their address from any distance; and at the top, the
    ; arguments the caller stored there (%cc-gen-homes), which the prologue
    ; copies down into slots of their own, a struct excepted.
    (def pkinds
      (let ((go (fn (self ks)
                  (if (null? ks) ()
                    (pair (%cc-gen-c-type! (first ks) "a parameter") (self (rest ks)))))))
        (go c-types)))
    (def homes (%cc-gen-homes pkinds sret?))
    ; (MEM C-TYPE . HOME) for each parameter but a struct stored above,
    ; which stays where the caller put it
    (def places
      (let ((go (fn (self ps ks hs)
                  (if (null? ps) ()
                    (if (if (eq? (first (first hs)) (lit above)) (%cc-gen-struct? (first ks)) #f)
                      (do (%cc-gen-slot-above! (first ps) (first ks) (rest (first hs)))
                          (self (rest ps) (rest ks) (rest hs)))
                      (pair (pair (mem x19 (%cc-gen-slot! (first ps) (first ks)))
                              (pair (first ks) (first hs)))
                        (self (rest ps) (rest ks) (rest hs))))))))
        (go params pkinds homes)))
    (set! %cc-gen-sret-slot (if sret? (%cc-gen-room! (lit long)) 0))
    (%cc-gen-scan! body #f)
    (set! %cc-gen-ca (round-up %cc-gen-frame-bytes 8))
    (set! %cc-gen-frame-bytes (+ %cc-gen-ca (%cc-gen-call-area body)))
    (if (> %cc-gen-frame-bytes 32760) (%cc-gen-no "more locals than a load reaches"))
    (%cc-gen-scan! body #t)
    (%cc-gen-scan-calls! body)
    (def frame
      (+ (round-up %cc-gen-frame-bytes 16) (%cc-gen-above-size homes sret?)))
    (if (> frame %cc-gen-frame-most) (%cc-gen-no "a frame past a megabyte"))
    (set! %cc-gen-frame-top frame)
    (def home (fn (_ p) (rest (rest p))))
    (def in-reg? (fn (_ p) (eq? (first (home p)) (lit reg))))
    (asm-label! %cc-gen-asm (%cc-gen-fun-label (first (rest f))))
    ; prologue: the caller's frame base is saved, this one taken off x20
    (if (null? %cc-gen-link) () (asm-push! %cc-gen-asm %cc-gen-link))
    (asm-push! %cc-gen-asm x19)
    (%cc-gen-step-x20! (lit sub) frame)
    (%cc-gen! (lit mov) x19 x20)
    ; the arguments in registers go to their slots first, each narrowed to
    ; its parameter's C type as it is stored; then the registers are free to
    ; bring the ones above down, through their address
    (let ((go (fn (self ps)
                (if (null? ps) ()
                  (let ((p (first ps)))
                    (do (if (in-reg? p)
                          (%cc-gen! (%cc-gen-store-op (first (rest p))) (rest (home p)) (first p))
                          ())
                        (self (rest ps))))))))
      (go places))
    (let ((go (fn (self ps)
                (if (null? ps) ()
                  (let ((p (first ps)))
                    (do (if (in-reg? p) ()
                          (do (%cc-gen-address! x19 (- frame (rest (home p))))
                              (%cc-gen! (%cc-gen-load-op (first (rest p))) x0 (mem x0 0))
                              (%cc-gen! (%cc-gen-store-op (first (rest p))) x0 (first p))))
                        (self (rest ps))))))))
      (go places))
    (if sret?
      (do (%cc-gen-address! x19 (- frame 8))
          (%cc-gen! (lit ldr) x0 (mem x0 0))
          (%cc-gen! (lit str) x0 (mem x19 %cc-gen-sret-slot)))
      ())
    ; main writes the addresses the data's pointers start at
    (if (string=? (first (rest f)) "main") (%cc-gen-fixups!) ())
    (%cc-gen-stmt! body)
    (%cc-gen-labels-placed!)
    ; falling off the end answers 0, which is what C says of main
    (%cc-gen-const! 0)
    (asm-label! %cc-gen-asm %cc-gen-epilogue)
    (%cc-gen-step-x20! (lit add) frame)
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
    ; main takes nothing, or argc and argv, which the entry hands it
    (let ((n (length (first (rest (rest main))))))
      (if (if (= n 0) #f (not (= n 2)))
        (%cc-gen-no "main with parameters other than argc and argv")))
    (def others (filter (fn (_ f) (not (string=? (first (rest f)) "main"))) funs))
    ; the globals take the front of the data, before a body asks for one
    (set! %cc-gen-globals ())
    (set! %cc-gen-fixups ())
    (set! %cc-gen-pending ())
    (set! %cc-gen-strings ())
    (set! %cc-gen-databytes 0)
    (set! %cc-gen-data ())
    ; the C library's exit, where the entry takes main's answer, in the
    ; data's first eight bytes
    (set! %cc-gen-imports ())
    (%cc-gen-import-slot "exit")
    ; then the frame stack's top as the last call out left it, which the
    ; gate takes up again (%cc-gen-gate-bytes)
    (%cc-gen-data! (list 0 0 0 0 0 0 0 0) 8)
    (set! %cc-gen-thunks ())
    ; the ones a load reaches first, then the arrays and structs, which are
    ; only ever reached through their address
    (def gdecls (filter (fn (_ it) (eq? (first it) (lit gdecl))) prog))
    (def aggregate-decl? (fn (_ d) (%cc-gen-aggregate? (first (rest (rest d))))))
    (let ((go (fn (self ds)
                (if (null? ds) ()
                  (do (%cc-gen-global! (first ds)) (self (rest ds)))))))
      (do (go (filter (fn (_ d) (not (aggregate-decl? d))) gdecls))
          (go (filter aggregate-decl? gdecls))))
    ; then the static locals, before a string can push them past a load's
    ; reach
    (set! %cc-gen-statics ())
    (set! %cc-gen-static-scope ())
    (%cc-gen-scan-statics! funs)
    (def a (asm-new 262144))
    (set! %cc-gen-asm a)
    (set! %cc-gen-nlabels 0)
    (set! %cc-gen-link (if (eq? target (lit macho-arm64)) %cc-gen-lr ()))
    (set! %cc-gen-callop (if (eq? target (lit macho-arm64)) (lit bl) (lit call)))
    (set! %cc-gen-sysv? (eq? target (lit elf-x86-64)))
    ; every function gets its label before any code, so a call can name one
    ; that has not been compiled yet
    (set! %cc-gen-funs ())
    (set! %cc-gen-rets ())
    (set! %cc-gen-params ())
    (let ((go (fn (self fs)
                (if (null? fs) ()
                  (let ((f (first fs)))
                    (do (set! %cc-gen-funs
                          (pair (pair (first (rest f)) (%cc-gen-label)) %cc-gen-funs))
                        (set! %cc-gen-rets
                          (pair (pair (first (rest f)) (first (rest (rest (rest (rest (rest f)))))))
                            %cc-gen-rets))
                        (set! %cc-gen-params
                          (pair (pair (first (rest f)) (first (rest (rest (rest (rest f))))))
                            %cc-gen-params))
                        (self (rest fs))))))))
      (go funs))
    ; a refusal can raise partway through; the buffer is released first
    (guard (err (do (asm-free! a)
                    (set! %cc-gen-asm ())
                    (error err (if (Err err? err) (err msg) "cc: compile failed"))))
      (let ((go (fn (self fs) (if (null? fs) () (do (%cc-gen-fun! (first fs)) (self (rest fs)))))))
        (do (go (pair main others))
            (%cc-gen-thunks!))))
    (def n (asm-pos a))
    (def code (%cc-gen-read (asm-finalize! a) (- n 1) ()))
    (asm-free! a)
    (set! %cc-gen-asm ())
    ; the gate follows the code, where the label the thunks branch to is
    (def gatepos (+ (%cc-gen-entry-len target) n))
    (def dataat (%cc-gen-data-at target (+ gatepos (%cc-gen-gate-len target))))
    (def entry (%cc-gen-entry target dataat))
    ; the entry's two addresses are taken from where it stands, so a length
    ; the layout did not expect would point them somewhere else
    (if (not (= (length entry) (%cc-gen-entry-len target)))
      (Err raise (lit cc) "cc: compile: the entry is not the length the layout takes it for" ()))
    (pair (append entry (append code (%cc-gen-gate-bytes target gatepos dataat)))
      (%cc-gen-data-bytes))))

; compile SRC to an executable at PATH
(def cc-compile
  (fn (_ src path)
    (def target (%cc-gen-target))
    (def image (cc-compile-image src target))
    ; the imports, (OFFSET . NAME) in the order of their slots
    (def imports (map (fn (_ i) (pair (rest i) (first i))) (reverse %cc-gen-imports)))
    (if (eq? target (lit macho-arm64))
      (macho-write! path (first image) (rest image) imports)
      (elf-write! path (first image) (rest image) elf-machine-x86-64 imports))))

; compile SRC and run the executable with INPUT as its standard input and
; the rest of ARGV after its name, which is its path; print what it wrote,
; answer its status.  With INPUT nil, it reads the caller's standard input.
(def cc-exe-run-with
  (fn (_ src input argv)
    (def path
      (string-append "/tmp/x-cc-exe-"
        (substring (sha256-hex-n src (byte-len src)) 0 16)))
    (cc-compile src path)
    (let ((r (proc-capture
               (if (null? input)
                 (pair path (rest argv))
                 (append (list "/bin/sh" "-c" "i=$1; shift; printf %s \"$i\" | \"$@\""
                           "sh" input path)
                   (rest argv))))))
      (do (display (rest r)) (first r)))))

; compile SRC, run the executable, print what it wrote, answer its status
(def cc-exe-run (fn (_ src) (cc-exe-run-with src () (list "a.out"))))

(provide cc/gen cc-compile cc-compile-image cc-exe-run cc-exe-run-with)
