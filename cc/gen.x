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
; in the form of its kind (the integer kinds, below), and an operator whose
; result can leave that form puts it back, so arithmetic wraps as C's does.
;
; Compiled so far: main and the functions beside it, with globals, locals
; (static ones kept once, in the data), and parameters of `char`, `short`,
; `int` and `long`, signed and unsigned,
; pointers to anything, and arrays, structs and unions of any of these, each
; at its kind's size,
; assignment, ++ and --, `if`/`else`, `while`, `do`, `for`, `switch`,
; `break`, `continue`, `return` and calls (recursion included), over integer
; constants typed by their suffixes and string literals, + - * / %,
; & | ^ << >>, the six comparisons, &&, ||, the ternary, the comma,
; unary - ~ ! & *, casts, subscripts, `.` and `->`, each in the kind C's
; usual conversions give it, `putchar`, `puts`, `printf` of a literal
; format with %d %i %u %x %ld %li %lu %lx %c %s and %%, `exit`, `malloc`,
; `free`, `strlen`, `strcmp`, `strncmp`, `strcpy`, `strncpy`, `strcat`,
; `strchr`, `memcpy`, `memset`, `memcmp`, `atoi`, `isdigit`, `isalpha`,
; `isalnum`, `isspace`, `isupper`, `islower`, `toupper`, `tolower` and
; `abs`, unless the program defines its own; structs are
; passed and returned by value.  Everything else refuses by name: floating point,
; function pointers, and the rest of the runtime.
;
; The convention is this compiler's own, since nothing else links with what
; it writes: of the first four arguments, the ones that are not structs in
; x0, x1, x2 and x8, and the rest -- structs whole -- at the top of the
; callee's frame, under the word that says where a struct it answers goes;
; the answer in x0, frames off x20 in a region below the machine stack,
; x19 the frame's base, x21 the runtime helper and x22 the data.
(module cc/gen)

(import x/tool/asm)
(import x/platform/syscall)
(import cc/prims append byte-at byte-len convert filter length mem-ref-byte
  proc-capture reverse sha256-hex-n string-append string-concat string=?
  substring)
(import cc/lex cc-lex)
(import cc/parse cc-parse kind-size kind-align round-up struct-entry)
(import cc/eval common-c-type ctype-ranges kind-elem library-c-type printf-conversion
  printf-fit printf-pad promoted-c-type signed? unsigned-divide)
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

; The entry, and the one piece of runtime compiled code calls: a write.
; The system call has no portable mnemonic, so both are written out per
; target, bytes and all, and the entry takes its two addresses from where
; it stands with its own encoding of adr.  The entry puts the
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
      ; sub sp, #4M; bl main (six words on); movz x16, #exit; svc #0x80;
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
      ; (the data); mov r12, rsp; sub rsp, 4M; call main (eighteen bytes
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

; how far before the write helper the entry's exit starts: the instructions
; after the call to main, which exit with the status in x0.  exit() branches
; there from anywhere, since nothing is left to unwind.
(def %cc-gen-exit-back
  (fn (_ target) (if (eq? target (lit macho-arm64)) 8 10)))

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

; --- integer kinds -----------------------------------------------------------
; A value is held in a whole register in the form its kind reads it: an int,
; and anything narrower, which C promotes to int, sign-extended from bit 31;
; an unsigned int zero-extended; a long or an unsigned long as all 64 bits.
; An operator works in the kind C's usual conversions give its operands and
; leaves its result in that kind's form.  Between the 64-bit kinds and from
; either 32-bit one to them, the form already is the conversion: an int's
; sign-extension is the long, and the unsigned long, it converts to.  The
; C types C's promotions and usual conversions give are cc/eval.x's
; (promoted-c-type, common-c-type), which run works in too.

; a bit-field, (bits C-TYPE BIT WIDTH): WIDTH bits from bit BIT of a unit of
; C-TYPE (parse.x)
(def %cc-gen-bits? (fn (_ k) (if (pair? k) (eq? (first k) (lit bits)) #f)))

(def %cc-gen-unsigned? (fn (_ k) (if (eq? k (lit uint)) #t (eq? k (lit ulong)))))

; x0 into the form KIND holds a value in, after an operation that can leave it
(def %cc-gen-normalize!
  (fn (_ kind)
    (match
      ((eq? kind (lit int)) (%cc-gen-int!))
      ((eq? kind (lit uint)) (%cc-gen-uint!))
      (#t ()))))

; V as the int its low 32 bits make
(def %cc-gen-int-of
  (fn (_ v)
    (let ((u (& v 4294967295)))
      (if (>= u 2147483648) (- u 4294967296) u))))

; a constant into x0, as an int
(def %cc-gen-const!
  (fn (_ v) (asm-load-imm64! %cc-gen-asm x0 (%cc-gen-int-of v))))

; V in the form a value of KIND is held in: cut to the kind's width and
; extended by its sign -- an int's from bit 31, an unsigned int's with
; zeros -- and an eight-byte kind's as it is
(def %cc-gen-form
  (fn (_ v kind)
    (def size (kind-size kind))
    (if (>= size 8) v
      (let ((top (<< 1 (- (* 8 size) 1))))
        (def low (& v (- (* 2 top) 1)))
        (if (if (signed? kind) (>= low top) #f) (- low (* 2 top)) low)))))

; a constant of KIND into x0, in that kind's form
(def %cc-gen-const-kind!
  (fn (_ v kind) (asm-load-imm64! %cc-gen-asm x0 (%cc-gen-form v kind))))

; the kind of a literal: the one the lexer read, an int when it read none
(def %cc-gen-num-kind
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

; The left operand in x0, the right in x1, both in KIND's form, the result
; to x0 in it.  An unsigned int is zero-extended, so signed division and a
; right shift that brings in zeros are the unsigned ones on it.
(def %cc-gen-bin!
  (fn (_ op kind)
    (match
      ((string=? op "+") (do (%cc-gen! (lit add) x0 x0 x1) (%cc-gen-normalize! kind)))
      ((string=? op "-") (do (%cc-gen! (lit sub) x0 x0 x1) (%cc-gen-normalize! kind)))
      ((string=? op "*") (do (%cc-gen! (lit mul) x0 x0 x1) (%cc-gen-normalize! kind)))
      ((string=? op "/")
        (if (eq? kind (lit ulong)) (%cc-gen-udiv64! #f)
          (do (%cc-gen! (lit sdiv) x0 x0 x1) (%cc-gen-normalize! kind))))
      ((string=? op "%")
        (if (eq? kind (lit ulong)) (%cc-gen-udiv64! #t)
          (do (%cc-gen! (lit sdiv) x2 x0 x1)
              (%cc-gen! (lit msub) x0 x2 x1 x0))))
      ((string=? op "&") (%cc-gen! (lit and) x0 x0 x1))
      ((string=? op "|") (%cc-gen! (lit orr) x0 x0 x1))
      ((string=? op "^") (%cc-gen! (lit eor) x0 x0 x1))
      ((string=? op "<<") (do (%cc-gen! (lit lslv) x0 x0 x1) (%cc-gen-normalize! kind)))
      ((string=? op ">>")
        (%cc-gen! (if (%cc-gen-unsigned? kind) (lit lsrv) (lit asrv)) x0 x0 x1))
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

; x0 and x1, both in KIND's form, compared: an unsigned int's form is a
; non-negative 64-bit number, so a signed compare orders them; an unsigned
; long's top bits are flipped first, which makes the signed order the
; unsigned one
(def %cc-gen-compare!
  (fn (_ kind)
    (do (if (eq? kind (lit ulong))
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
    (def size (fn (_ k) (kind-size (kind-elem k))))
    (match
      ((if (string=? op "-") (if (%cc-gen-addr-kind? ka) (%cc-gen-addr-kind? kb) #f) #f)
        (do (%cc-gen! (lit sub) x0 x0 x1)
            (if (= (size ka) 1) ()
              (do (%cc-gen! (lit mov) x1 (imm (size ka)))
                  (%cc-gen! (lit sdiv) x0 x0 x1)))))
      ((if (string=? op "-") (%cc-gen-addr-kind? ka) #f)
        (do (%cc-gen-scale! x1 (size ka)) (%cc-gen! (lit sub) x0 x0 x1)))
      ((if (string=? op "+") (%cc-gen-addr-kind? ka) #f)
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
; Every local and parameter has the size and alignment of its kind, at a
; fixed offset from x19, which the prologue points at the frame it took off
; x20.  A value loads at its width, extended by its sign -- a char
; sign-extends, an unsigned char zero-extends -- into the form its kind
; is held in (the integer kinds, above).  A store converts the value to its
; place's kind, and so does the value an assignment answers.
;
; A pointer is an eight-byte address.  An array is its elements end to
; end, and where it is used as a value it stands for its first element's
; address, which is all a subscript or pointer arithmetic needs.

(def %cc-gen-env ())        ; ((name offset . kind) ...)
(def %cc-gen-frame-bytes 0) ; how much of the frame the named ones take
(def %cc-gen-ret-kind ())   ; what the function being compiled returns

(def %cc-gen-ptr? (fn (_ k) (if (pair? k) (eq? (first k) (lit ptr)) #f)))
(def %cc-gen-array? (fn (_ k) (if (pair? k) (eq? (first k) (lit array)) #f)))
(def %cc-gen-addr-kind? (fn (_ k) (if (%cc-gen-ptr? k) #t (%cc-gen-array? k))))

; A struct is its fields at the offsets the parser laid out, a union one
; whose fields all sit at 0.  Like an array, it is never loaded whole: where
; it is used, the address it is at stands for it.
(def %cc-gen-struct? (fn (_ k) (if (pair? k) (eq? (first k) (lit struct)) #f)))
(def %cc-gen-aggregate? (fn (_ k) (if (%cc-gen-array? k) #t (%cc-gen-struct? k))))

; (OFFSET . KIND) of the field FNAME of the struct kind K
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
  (fn (_ k) (if (%cc-gen-array? k) (list (lit ptr) (kind-elem k)) k)))

; KIND, if the compiled code holds it; WHAT names the holder in a refusal.
; A pointer may point at any kind -- what a load through it reads is
; checked where the load is -- and an array's elements are held as a
; value would be.
(def %cc-gen-kind!
  (fn (self kind what)
    (match
      ((eq? kind (lit int)) kind)
      ((eq? kind (lit char)) kind)
      ((eq? kind (lit uchar)) kind)
      ((eq? kind (lit short)) kind)
      ((eq? kind (lit ushort)) kind)
      ((eq? kind (lit long)) kind)
      ((eq? kind (lit uint)) kind)
      ((eq? kind (lit ulong)) kind)
      ((%cc-gen-ptr? kind) kind)
      ((%cc-gen-fnptr? kind) kind)
      ((%cc-gen-bits? kind) (do (self (first (rest kind)) what) kind))
      ((%cc-gen-array? kind) (do (self (kind-elem kind) "an array's element") kind))
      ((%cc-gen-struct? kind)
        (do (let ((go (fn (go fs)
                        (if (null? fs) ()
                          (do (self (first (rest (rest (first fs)))) "a struct's field")
                              (go (rest fs)))))))
              (go (rest (rest (struct-entry (first (rest kind)))))))
            kind))
      (#t (%cc-gen-no
            (string-append what
              " that is not an integer, a pointer, an array or a struct"))))))

(def %cc-gen-byte? (fn (_ kind) (if (eq? kind (lit char)) #t (eq? kind (lit uchar)))))
(def %cc-gen-half? (fn (_ kind) (if (eq? kind (lit short)) #t (eq? kind (lit ushort)))))

; what is left when a value of KIND is loaded or stored: the kinds a
; register holds, and a refusal naming any other
(def %cc-gen-value-kind!
  (fn (_ kind)
    (do (%cc-gen-kind! kind "a value")
        (match
          ((%cc-gen-array? kind) (%cc-gen-no "an array as a value"))
          ((%cc-gen-struct? kind) (%cc-gen-no "a struct as a value"))
          (#t kind)))))

; the load that brings a value of KIND into a register, extended by its sign
(def %cc-gen-load-op
  (fn (_ kind)
    (match
      ((eq? kind (lit char)) (lit ldrsb))
      ((eq? kind (lit uchar)) (lit ldrb))
      ((eq? kind (lit short)) (lit ldrsh))
      ((eq? kind (lit ushort)) (lit ldrh))
      ((eq? kind (lit uint)) (lit ldrw))
      ((%cc-gen-wide? kind) (lit ldr))
      (#t (do (%cc-gen-value-kind! kind) (lit ldrsw))))))

(def %cc-gen-store-op
  (fn (_ kind)
    (match
      ((%cc-gen-byte? kind) (lit strb))
      ((%cc-gen-half? kind) (lit strh))
      ((%cc-gen-wide? kind) (lit str))
      (#t (do (%cc-gen-value-kind! kind) (lit strw))))))

; the kinds held in all 64 bits: an address, a long, an unsigned long
(def %cc-gen-wide?
  (fn (_ k)
    (match
      ((%cc-gen-ptr? k) #t)
      ((%cc-gen-fnptr? k) #t)
      ((eq? k (lit long)) #t)
      ((eq? k (lit ulong)) #t)
      (#t #f))))

; a pointer to a function, (fnptr RET): the function's address, which a
; call through it answers a RET from (parse.x)
(def %cc-gen-fnptr? (fn (_ k) (if (pair? k) (eq? (first k) (lit fnptr)) #f)))

; x0 as a value of KIND: shifted to the top of the register and back down,
; arithmetically for a signed kind
(def %cc-gen-narrow!
  (fn (_ kind)
    (def bits (match ((%cc-gen-byte? kind) 56) ((%cc-gen-half? kind) 48) (#t 32)))
    (do (%cc-gen! (lit mov) x2 (imm bits))
        (%cc-gen! (lit lslv) x0 x0 x2)
        (%cc-gen! (if (signed? kind) (lit asrv) (lit lsrv)) x0 x0 x2))))
(def %cc-gen-loops ())      ; ((break-label . continue-label) ...), innermost first
(def %cc-gen-funs ())       ; ((name . label) ...), every function in the program
(def %cc-gen-rets ())       ; ((name . kind) ...), what each one returns

(def %cc-gen-ret-find
  (fn (_ name)
    (def go (fn (self es)
              (if (null? es) ()
                (if (string=? (first (first es)) name) (rest (first es))
                  (self (rest es))))))
    (go %cc-gen-rets)))

(def %cc-gen-params ())     ; ((name . kinds) ...), what each one takes

(def %cc-gen-params-find
  (fn (_ name)
    (def go (fn (self es)
              (if (null? es) ()
                (if (string=? (first (first es)) name) (rest (first es))
                  (self (rest es))))))
    (go %cc-gen-params)))
(def %cc-gen-epilogue ())   ; where `return` goes in the function being compiled
(def %cc-gen-scratch 0)     ; the slot past the named ones, which the runtime writes from

; A function that calls printf has an area past the scratch slot for it:
; the count of bytes written so far, the cursor into the digits, a slot a
; conversion keeps a number in across a write, twenty-four bytes the
; digits are built in -- an unsigned long has twenty -- then one slot for
; each argument after the format.  It is in the frame, so a printf
; reached from another's arguments, or from a recursive call, has its own.
(def %cc-gen-pf 0)          ; where the area starts
(def %cc-gen-pf-count 0)
(def %cc-gen-pf-cursor 8)
(def %cc-gen-pf-held 16)
(def %cc-gen-pf-end 48)     ; the digits end here, and the arguments start

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

; (OFFSET . KIND) for a global's name, or nil
(def %cc-gen-global-find
  (fn (_ name)
    (def go (fn (self es)
              (if (null? es) ()
                (if (string=? (first (first es)) name) (rest (first es))
                  (self (rest es))))))
    (go %cc-gen-globals)))

; A global takes room of its kind, with its initializer's bytes in it.
; The initializer is a constant, as C asks, so the bytes are worked out
; here.  An address in the data would move with the executable, which the
; kernel loads at a place of its choosing and nothing relocates, so a
; pointer that starts at one starts as zeros and main writes the address
; before its body runs (%cc-gen-fixups!).
(def %cc-gen-global!
  (fn (_ node)
    (def name (first (rest node)))
    (def kind (%cc-gen-kind! (first (rest (rest node))) "a global"))
    (if (not (null? (%cc-gen-global-find name)))
      (%cc-gen-no (string-append "a second declaration of " name)))
    (def init (first (rest (rest (rest node)))))
    (set! %cc-gen-pending ())
    (def off (%cc-gen-data! (%cc-gen-const-bytes kind init 0) (kind-align kind)))
    (%cc-gen-keep-fixups! off)
    (set! %cc-gen-globals (pair (pair name (pair off kind)) %cc-gen-globals))))

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
            (pair (+ (first p) (* (if (string=? op "-") (- 0 n) n) (kind-size (rest p))))
              (rest p)))))
      ((eq? t (lit cast))
        (pair (first (self (first (rest (rest node))))) (kind-elem (first (rest node)))))
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
          (if (%cc-gen-array? (rest p)) (pair (first p) (kind-elem (rest p)))
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
    (def c-type (%cc-gen-kind! (first (rest (rest node))) "a local"))
    (set! %cc-gen-pending ())
    (def off
      (%cc-gen-data! (%cc-gen-const-bytes c-type (first (rest (rest (rest node)))) 0)
        (kind-align c-type)))
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

; the little-endian bytes of V at KIND's width
(def %cc-gen-value-bytes
  (fn (_ kind v)
    (%cc-gen-take (kind-size kind)
      (append (%cc-gen-le32 v) (%cc-gen-le32 (>> v 32))))))

; the bytes a constant initializer INIT lays down for KIND
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
  (fn (self kind init at)
    (def zeros
      (fn (zeros n acc) (if (<= n 0) acc (zeros (- n 1) (pair 0 acc)))))
    (match
      ((null? init) (zeros (kind-size kind) ()))
      ((%cc-gen-array? kind)
        (let ((n (first (rest kind))) (ek (kind-elem kind)))
          (match
            ((eq? (first init) (lit initlist))
              (let ((items (first (rest init))))
                (if (> (length items) n)
                  (%cc-gen-no "more initializers than an array has elements"))
                (def go
                  (fn (go i is)
                    (if (>= i n) ()
                      (append (self ek (if (null? is) () (first is)) (+ at (* i (kind-size ek))))
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
      ((%cc-gen-struct? kind)
        (do (if (not (eq? (first init) (lit initlist)))
              (%cc-gen-no "a global struct initialized by something other than a list"))
            (let ((items (first (rest init)))
                  (fields (rest (rest (struct-entry (first (rest kind)))))))
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
                  (if (null? is) (zeros (- (kind-size kind) cur) ())
                    (let ((foff (first (rest (first fs)))) (fk (first (rest (rest (first fs))))))
                      (if (%cc-gen-bits? fk)
                        (unit fs is foff (first (rest fk)) 0 (kind-size (first (rest fk))) 0 cur)
                        (do (if (< foff cur) (%cc-gen-no "more initializers than a union takes"))
                            (append (zeros (- foff cur) ())
                              (append (self fk (first is) (+ at foff))
                                (go (rest fs) (rest is) (+ foff (kind-size fk)))))))))))
              (go fields items 0))))
      ; a pointer that starts at an address, a function's included
      ((if (%cc-gen-ptr? kind) (%cc-gen-address-form? init) #f)
        (do (set! %cc-gen-pending (pair (pair at init) %cc-gen-pending))
            (zeros 8 ())))
      ((if (%cc-gen-fnptr? kind) (not (null? (%cc-gen-function-form init))) #f)
        (do (set! %cc-gen-pending (pair (pair at init) %cc-gen-pending))
            (zeros 8 ())))
      ((eq? (first init) (lit initlist))
        (%cc-gen-no "a braced initializer for something that is not an array or a struct"))
      (#t (%cc-gen-value-bytes kind (%cc-gen-fold init))))))

; What a global starts out holding.  C asks for a constant here, so the
; value is worked out now: each operation in the kind C's conversions give
; it, its result in that kind's form, as the code for it would leave it.
; The program starts with the value's low bytes, as many as the global's
; kind has, in place.
(def %cc-gen-fold
  (fn (self node)
    (let ((t (first node)))
      (match
        ((eq? t (lit num)) (%cc-gen-form (first (rest node)) (%cc-gen-num-kind node)))
        ((eq? t (lit un))
          (let ((op (first (rest node))) (v (self (first (rest (rest node))))))
            (%cc-gen-form
              (match
                ((string=? op "-") (- 0 v))
                ((string=? op "~") (- (- 0 v) 1))
                ((string=? op "!") (if (= v 0) 1 0))
                (#t (%cc-gen-no (string-append "a global initialized with " op))))
              (%cc-gen-kind-of node))))
        ((eq? t (lit bin))
          (let ((a (self (first (rest (rest node)))))
                (b (self (first (rest (rest (rest node)))))))
            (%cc-gen-fold-bin (first (rest node)) a b (%cc-gen-kind-of node))))
        ((eq? t (lit cast))
          (let ((k (first (rest node))))
            (if (if (eq? k (lit void)) #t (%cc-gen-aggregate? k))
              (%cc-gen-no "a global initialized by something other than a constant"))
            (%cc-gen-form (self (first (rest (rest node)))) k)))
        (#t (%cc-gen-no "a global initialized by something other than a constant"))))))

; OP on the constants A and B, in KIND: each operand converted to it first,
; but a shift's count, which keeps its own
(def %cc-gen-fold-bin
  (fn (_ op a b kind)
    (if (%cc-gen-addr-kind? kind)
      (%cc-gen-no "a global initialized by arithmetic on an address"))
    (def shift? (if (string=? op "<<") #t (string=? op ">>")))
    (def x (%cc-gen-form a kind))
    (def y (if shift? b (%cc-gen-form b kind)))
    (def wide? (eq? kind (lit ulong)))
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
      kind)))

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

(def %cc-gen-exit-at 0)     ; the entry's exit, this far before x21's helper

(def %cc-gen-heap-bytes 0)  ; the heap the executable maps past the data
(def %cc-gen-heap-size 67108864)   ; sixty-four megabytes of address space

(def %cc-gen-find
  (fn (_ name)
    (def go (fn (self es)
              (if (null? es) ()
                (if (string=? (first (first es)) name) (rest (first es))
                  (self (rest es))))))
    (go %cc-gen-env)))

; a slot of KIND's size and alignment; answers its offset
(def %cc-gen-slot!
  (fn (_ name kind)
    (if (not (null? (%cc-gen-find name)))
      (%cc-gen-no (string-append "a second declaration of " name)))
    (def off (round-up %cc-gen-frame-bytes (kind-align kind)))
    ; a scalar loads and stores at its offset from x19, which reaches 4095
    ; of its widths; an array or a struct is reached through its address
    (if (if (%cc-gen-aggregate? kind) #f (> off (* 4095 (kind-size kind))))
      (%cc-gen-no "more locals than a load reaches"))
    (set! %cc-gen-frame-bytes (+ off (kind-size kind)))
    (set! %cc-gen-env (pair (pair name (pair off kind)) %cc-gen-env))
    off))

; A struct parameter, where the caller stored it: OFF bytes below the top of
; this frame (%cc-gen-homes).  The top is known once the frame is laid out,
; so the offset counts back from it, negative, and a place adds the frame's
; size.  A struct is reached through its address, from any distance.
(def %cc-gen-frame-top 0)   ; the size of the frame being compiled
(def %cc-gen-slot-above!
  (fn (_ name kind off)
    (if (not (null? (%cc-gen-find name)))
      (%cc-gen-no (string-append "a second declaration of " name)))
    (set! %cc-gen-env (pair (pair name (pair (- 0 off) kind)) %cc-gen-env))))

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

; Room for KIND in the frame, with no name: where a call puts the struct
; it answers (%cc-gen-scan-calls!)
(def %cc-gen-room!
  (fn (_ kind)
    (def off (round-up %cc-gen-frame-bytes (kind-align kind)))
    (set! %cc-gen-frame-bytes (+ off (kind-size kind)))
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

; A place is (BASE OFFSET . KIND): a register and a byte offset from it.
; A name's is a frame slot off x19 or a global's room off x22, and one
; worked out at run time is the register holding it, at offset 0.
(def %cc-gen-place (fn (_ base off kind) (pair base (pair off kind))))
(def %cc-gen-place-mem (fn (_ p) (mem (first p) (first (rest p)))))
(def %cc-gen-place-kind (fn (_ p) (rest (rest p))))

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
              ((if (%cc-gen-array? (rest g)) #f (> (first g) (* 4095 (kind-size (rest g)))))
                (%cc-gen-no "more globals than a load reaches"))
              (#t (%cc-gen-place x22 (first g) (rest g))))))))))

(def %cc-gen-load!
  (fn (_ place)
    (def k (%cc-gen-place-kind place))
    (if (%cc-gen-bits? k) (%cc-gen-bits-load! (%cc-gen-place-mem place) k)
      (%cc-gen! (%cc-gen-load-op k) x0 (%cc-gen-place-mem place)))))

(def %cc-gen-put!
  (fn (_ place)
    (def k (%cc-gen-place-kind place))
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

; a kind whose values are held in an int's form: int, and the kinds C
; promotes to it
(def %cc-gen-int-form?
  (fn (_ k) (if (pair? k) #f (eq? (promoted-c-type k) (lit int)))))

; x0, a value of kind FROM, converted to KIND: narrowed to a char or short,
; and into an int's or an unsigned int's form from any other kind, an
; address included.  The eight-byte kinds need nothing: every value's form
; is already its conversion to them.
(def %cc-gen-convert!
  (fn (_ kind from)
    (match
      ((if (%cc-gen-byte? kind) #t (%cc-gen-half? kind)) (%cc-gen-narrow! kind))
      ((eq? kind (lit int)) (if (%cc-gen-int-form? from) () (%cc-gen-int!)))
      ((eq? kind (lit uint)) (if (eq? from (lit uint)) () (%cc-gen-uint!)))
      (#t ()))))

; an assignment's store, of a value of kind FROM: the value it answers is
; converted as the stored one was
(def %cc-gen-store!
  (fn (_ place from)
    (do (%cc-gen-put! place)
        (%cc-gen-convert! (%cc-gen-place-kind place) from))))

; A value of KIND whose address is in x0, into x0: loaded, unless it is an
; array, whose value is that address.
(def %cc-gen-load-at!
  (fn (_ kind)
    (match
      ((%cc-gen-aggregate? kind) ())
      ((%cc-gen-bits? kind) (%cc-gen-bits-load! (mem x0 0) kind))
      (#t (%cc-gen! (%cc-gen-load-op kind) x0 (mem x0 0))))))

; The kind of what NODE computes, worked out without computing it: what a
; pointer's arithmetic scales by and what a load through it reads.
(def %cc-gen-kind-of ())
(set! %cc-gen-kind-of
  (fn (self node)
    (let ((t (first node)))
      (match
        ; a function's name is a pointer to it
        ((if (eq? t (lit var)) (%cc-gen-function-name? (first (rest node))) #f)
          (list (lit fnptr) (%cc-gen-ret-find (first (rest node)))))
        ((eq? t (lit var)) (%cc-gen-place-kind (%cc-gen-place-of (first (rest node)))))
        ((eq? t (lit num)) (%cc-gen-num-kind node))
        ((eq? t (lit szof)) (lit ulong))
        ((eq? t (lit str))
          (list (lit array) (+ (byte-len (first (rest node))) 1) (lit char)))
        ((eq? t (lit idx))
          (let ((ka (self (first (rest node)))))
            (kind-elem (if (%cc-gen-addr-kind? ka) ka (self (first (rest (rest node))))))))
        ((eq? t (lit un))
          (let ((op (first (rest node))))
            (match
              ((string=? op "*") (kind-elem (self (first (rest (rest node))))))
              ; & of a function is the same pointer its name is
              ((string=? op "&")
                (let ((x (self (first (rest (rest node))))))
                  (if (%cc-gen-fnptr? x) x (list (lit ptr) x))))
              ((string=? op "!") (lit int))
              (#t (promoted-c-type (self (first (rest (rest node)))))))))
        ((eq? t (lit bin))
          (%cc-gen-bin-kind (first (rest node))
            (self (first (rest (rest node)))) (self (first (rest (rest (rest node)))))))
        ((eq? t (lit assign)) (self (first (rest node))))
        ((%cc-gen-step? t) (self (first (rest node))))
        ((eq? t (lit ternary))
          (let ((ka (self (first (rest (rest node))))))
            (if (%cc-gen-addr-kind? ka) (%cc-gen-decay ka)
              (let ((kb (self (first (rest (rest (rest node)))))))
                (if (%cc-gen-addr-kind? kb) (%cc-gen-decay kb)
                  (common-c-type ka kb))))))
        ((eq? t (lit comma)) (self (first (rest (rest node)))))
        ((eq? t (lit dot))
          (rest (%cc-gen-field (self (first (rest node))) (first (rest (rest node))))))
        ((eq? t (lit arrow))
          (rest (%cc-gen-field (kind-elem (self (first (rest node))))
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

; The kind a binary operator answers: + and - keep an address one and make
; two of them a count (a long, as ptrdiff_t is); a shift answers its left
; operand's kind; anything else, the kind its operands meet in.
(def %cc-gen-bin-kind
  (fn (_ op ka kb)
    (match
      ((if (string=? op "+") #t (string=? op "-"))
        (match ((if (%cc-gen-addr-kind? ka) (%cc-gen-addr-kind? kb) #f) (lit long))
               ((%cc-gen-addr-kind? ka) (%cc-gen-decay ka))
               ((if (string=? op "+") (%cc-gen-addr-kind? kb) #f) (%cc-gen-decay kb))
               (#t (common-c-type ka kb))))
      ((if (string=? op "<<") #t (string=? op ">>")) (promoted-c-type ka))
      (#t (common-c-type ka kb)))))

; The address of what NODE names, into x0, answering the kind there: a
; name's own place, the pointee of a `*`, or an element.
(def %cc-gen-addr! ())
(set! %cc-gen-addr!
  (fn (self node)
    (let ((t (first node)))
      (match
        ((eq? t (lit var))
          (let ((at (%cc-gen-place-of (first (rest node)))))
            (do (%cc-gen-address! (first at) (first (rest at)))
                (%cc-gen-place-kind at))))
        ((if (eq? t (lit un)) (string=? (first (rest node)) "*") #f)
          (let ((k (%cc-gen-kind-of (first (rest (rest node))))))
            (if (not (%cc-gen-addr-kind? k))
              (%cc-gen-no "the indirection of something that is not a pointer"))
            (do (%cc-gen-expr! (first (rest (rest node))))
                (kind-elem k))))
        ((eq? t (lit idx)) (%cc-gen-index! (first (rest node)) (first (rest (rest node)))))
        ; a call that answers a struct answers its address
        ((if (eq? t (lit call)) (%cc-gen-struct? (%cc-gen-kind-of node)) #f)
          (do (%cc-gen-expr! node) (%cc-gen-kind-of node)))
        ; a field: the struct's address, or the one a pointer holds, and
        ; the field's offset on
        ((eq? t (lit dot))
          (let ((k (self (first (rest node)))))
            (if (not (%cc-gen-struct? k)) (%cc-gen-no "a field of something that is not a struct"))
            (let ((f (%cc-gen-field k (first (rest (rest node))))))
              (do (%cc-gen-bump! #t (first f)) (rest f)))))
        ((eq? t (lit arrow))
          (let ((k (%cc-gen-kind-of (first (rest node)))))
            (if (not (if (%cc-gen-addr-kind? k) (%cc-gen-struct? (kind-elem k)) #f))
              (%cc-gen-no "a -> of something that is not a pointer to a struct"))
            (let ((f (%cc-gen-field (kind-elem k) (first (rest (rest node))))))
              (do (%cc-gen-expr! (first (rest node)))
                  (%cc-gen-bump! #t (first f))
                  (rest f)))))
        (#t (%cc-gen-no "the address of something that is not a name, a pointee, an element or a field"))))))

; The address of A[I]: the address A stands for, plus I elements.  C lets
; either operand be the address, so I[A] is the same element.
(def %cc-gen-index!
  (fn (_ a i)
    (def swap (not (%cc-gen-addr-kind? (%cc-gen-kind-of a))))
    (def at (if swap i a))
    (def k (%cc-gen-kind-of at))
    (if (not (%cc-gen-addr-kind? k))
      (%cc-gen-no "a subscript of something that is not a pointer or an array"))
    (do (%cc-gen-expr! at)
        (asm-push! %cc-gen-asm x0)
        (%cc-gen-expr! (if swap a i))
        (%cc-gen-scale! x0 (kind-size (kind-elem k)))
        (%cc-gen! (lit mov) x1 x0)
        (asm-pop! %cc-gen-asm x0)
        (%cc-gen! (lit add) x0 x0 x1)
        (kind-elem k))))

(def %cc-gen-expr! ())
(set! %cc-gen-expr!
  (fn (self node)
    (let ((t (first node)))
      (match
        ((eq? t (lit num)) (%cc-gen-const-kind! (first (rest node)) (%cc-gen-num-kind node)))
        ((eq? t (lit str)) (%cc-gen-string-at! (first (rest node))))
        ((eq? t (lit szof))
          (%cc-gen-const-kind! (kind-size (%cc-gen-kind-of (first (rest node)))) (lit ulong)))
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
            (def k (promoted-c-type (%cc-gen-kind-of (first (rest (rest node))))))
            (do (self (first (rest (rest node))))
                (match
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
            (def ka (%cc-gen-kind-of (first (rest (rest node)))))
            (def kb (%cc-gen-kind-of (first (rest (rest (rest node))))))
            (if (if (%cc-gen-struct? ka) #t (%cc-gen-struct? kb))
              (%cc-gen-no (string-append "the operator " op " on a struct")))
            ; a pointer to a function compares as the address it is, and
            ; takes no arithmetic
            (def fn? (if (%cc-gen-fnptr? ka) #t (%cc-gen-fnptr? kb)))
            (if (if fn? (eq? t (lit bin)) #f)
              (%cc-gen-no "arithmetic on a pointer to a function"))
            (def addr? (if (%cc-gen-addr-kind? ka) #t (if (%cc-gen-addr-kind? kb) #t fn?)))
            ; a shift works in its left operand's kind, anything else in the
            ; kind its two operands meet in
            (def k (if (if (string=? op "<<") #t (string=? op ">>"))
                     (promoted-c-type ka)
                     (common-c-type ka kb)))
            (do (self (first (rest (rest node))))
                (asm-push! %cc-gen-asm x0)
                (self (first (rest (rest (rest node)))))
                (%cc-gen! (lit mov) x1 x0)
                (asm-pop! %cc-gen-asm x0)
                ; an int converted to an unsigned int takes that kind's form
                (if (if (eq? k (lit uint)) (not addr?) #f)
                  (do (%cc-gen-uint!) (%cc-gen-uint-x1!))
                  ())
                (match
                  ((eq? t (lit cmp))
                    (do (if addr? (%cc-gen! (lit cmp) x0 x1) (%cc-gen-compare! k))
                        (%cc-gen-flag! (%cc-gen-branch op))))
                  (addr? (%cc-gen-addr-bin! op ka kb))
                  (#t (%cc-gen-bin! op k))))))
        ((eq? t (lit var))
          (let ((at (%cc-gen-place-of (first (rest node)))))
            (if (%cc-gen-aggregate? (%cc-gen-place-kind at))
              (%cc-gen-address! (first at) (first (rest at)))
              (%cc-gen-load! at))))
        ((if (eq? t (lit dot)) #t (eq? t (lit arrow)))
          (%cc-gen-load-at! (%cc-gen-addr! node)))
        ((eq? t (lit assign))
          (let ((lv (first (rest node))))
            (def k (%cc-gen-kind-of lv))
            (def from (%cc-gen-kind-of (first (rest (rest node)))))
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
                (let ((k (%cc-gen-value-kind! (%cc-gen-addr! lv))))
                  (do (asm-push! %cc-gen-asm x0)
                      (self (first (rest (rest node))))
                      (asm-pop! %cc-gen-asm x1)
                      (%cc-gen-store! (%cc-gen-place x1 0 k) from)))))))
        ((%cc-gen-step? t) (%cc-gen-step! t node))
        ((eq? t (lit ternary))
          (let ((else- (%cc-gen-label)) (done (%cc-gen-label)))
            ; each arm converts to the kind the two meet in
            (def k (%cc-gen-kind-of node))
            (def arm
              (fn (_ n) (do (self n) (%cc-gen-convert! k (%cc-gen-kind-of n)))))
            (do (self (first (rest node)))
                (%cc-gen! (lit cmp) x0 (imm 0))
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
        ((eq? t (lit call)) (%cc-gen-call! node))
        ((eq? t (lit callx)) (%cc-gen-call-through! (first (rest node)) (first (rest (rest node)))))
        ((eq? t (lit cast))
          (let ((k (first (rest node))) (e (first (rest (rest node)))))
            (def from (%cc-gen-kind-of e))
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
    (def k (%cc-gen-value-kind! (%cc-gen-place-kind at)))
    (do (%cc-gen-load! at)
        ; the old value waits in x8 for the postfix forms: x2 is the
        ; re-extension's shift amount
        (%cc-gen! (lit mov) x8 x0)
        (if (%cc-gen-ptr? k)
          (%cc-gen-bump! up (kind-size (kind-elem k)))
          (do (%cc-gen-bump! up 1) (%cc-gen-normalize! (promoted-c-type k))))
        (%cc-gen-store! at k)
        (if after () (%cc-gen! (lit mov) x0 x8)))))

; A call: to one of the runtime's functions the program does not define
; itself, to one of the program's own, or to a piece of the runtime the
; generator writes out where the call is (putchar, puts, printf, exit,
; free).  The answer comes back in x0.
(def %cc-gen-call!
  (fn (_ node)
    (def name (first (rest node)))
    (def args (first (rest (rest node))))
    (def entry (%cc-gen-runtime-find name))
    (match
      ; a name that is a local's or a global's holds a pointer to a function
      ((%cc-gen-variable? name) (%cc-gen-call-through! (list (lit var) name) args))
      ((not (null? entry)) (%cc-gen-runtime-call! node entry))
      ((not (null? (%cc-gen-fun-find name))) (%cc-gen-call-fun! node))
      ; calloc is malloc of the product: the heap is zeros where nothing has
      ; been, and nothing is given back
      ((string=? name "calloc")
        (do (if (not (null? (%cc-gen-fun-find "malloc")))
              (%cc-gen-no "calloc beside a malloc of the program's own"))
            (%cc-gen-call!
              (list (lit call) "malloc"
                (list (list (lit bin) "*" (first args) (first (rest args))))))))
      ((string=? name "putchar") (%cc-gen-putchar! args))
      ((string=? name "puts") (%cc-gen-puts! args))
      ((string=? name "printf") (%cc-gen-printf! args))
      ((string=? name "exit") (%cc-gen-exit! args))
      ((string=? name "free") (%cc-gen-free! args))
      (#t (%cc-gen-call-fun! node)))))

; the runtime function's entry (%cc-gen-runtime) for NAME, unless the
; program defines one of that name; nil otherwise
(def %cc-gen-runtime-find
  (fn (_ name)
    (def go (fn (self es)
              (match
                ((null? es) ())
                ((string=? (first (first es)) name) (first es))
                (#t (self (rest es))))))
    (go %cc-gen-runtime-live)))

; A call to one of the runtime's functions: the first makes its label, and
; each is a call like any other (%cc-gen-call-fun!).
(def %cc-gen-runtime-call!
  (fn (_ node entry)
    (def name (first entry))
    (def n (first (rest entry)))
    (if (not (= (length (first (rest (rest node)))) n))
      (%cc-gen-no
        (string-append name " with other than "
          (match ((= n 1) "one argument") ((= n 2) "two arguments") (#t "three arguments")))))
    (if (null? (%cc-gen-fun-find name))
      (let ((l (%cc-gen-label)))
        (do (set! %cc-gen-funs (pair (pair name l) %cc-gen-funs))
            (set! %cc-gen-runtime-called (pair (pair entry l) %cc-gen-runtime-called))))
      ())
    (%cc-gen-call-fun! node)))

; free: the heap is only ever taken from, so nothing goes back; the
; argument is still worked out, for whatever else it does
(def %cc-gen-free!
  (fn (_ args)
    (if (not (= (length args) 1))
      (%cc-gen-no "free with other than one argument"))
    (%cc-gen-expr! (first args))))

; The runtime's malloc, written after the program, when the data's size is
; final.  The heap follows the data at its next sixteen-byte boundary, and
; the kernel maps it zero-filled; eight bytes at the data's end count what
; is taken.  A block is the size asked for, rounded up to sixteen; a size
; past the heap's, a negative one (a size_t past 2^63), and one the heap has
; no room left for answer the null pointer.  x86-64 spells a three-operand
; op as a move and a two-operand one, so no destination here is also its
; second source.
(def %cc-gen-malloc-body!
  (fn (_)
    (def taken (%cc-gen-data! (list 0 0 0 0 0 0 0 0) 8))
    (def base (round-up %cc-gen-databytes 16))
    (def full (%cc-gen-label))
    (set! %cc-gen-heap-bytes %cc-gen-heap-size)
    (%cc-gen! (lit cmp) x0 (imm 0))
    (%cc-gen! (lit b/lt) (label full))
    (asm-load-imm64! %cc-gen-asm x2 %cc-gen-heap-size)
    (%cc-gen! (lit cmp) x0 x2)
    (%cc-gen! (lit b/gt) (label full))
    ; x0 = the size rounded up to sixteen
    (%cc-gen! (lit add) x0 x0 (imm 15))
    (%cc-gen! (lit mov) x2 (imm 4))
    (%cc-gen! (lit lsrv) x0 x0 x2)
    (%cc-gen! (lit lslv) x0 x0 x2)
    ; x8 = where the count is, x1 = the count, x0 = the count with this block
    (asm-load-imm64! %cc-gen-asm x8 taken)
    (%cc-gen! (lit add) x8 x8 x22)
    (%cc-gen! (lit ldr) x1 (mem x8 0))
    (%cc-gen! (lit add) x0 x0 x1)
    (asm-load-imm64! %cc-gen-asm x2 %cc-gen-heap-size)
    (%cc-gen! (lit cmp) x0 x2)
    (%cc-gen! (lit b/gt) (label full))
    (%cc-gen! (lit str) x0 (mem x8 0))
    ; the block: the heap's start, past what was taken before
    (asm-load-imm64! %cc-gen-asm x0 base)
    (%cc-gen! (lit add) x0 x0 x22)
    (%cc-gen! (lit add) x0 x0 x1)
    (%cc-gen! (lit ret))
    (asm-label! %cc-gen-asm full)
    (%cc-gen! (lit mov) x0 (imm 0))
    (%cc-gen! (lit ret))))

; strlen: the bytes before the NUL at x0
(def %cc-gen-strlen-body!
  (fn (_)
    (def next (%cc-gen-label))
    (def done (%cc-gen-label))
    (%cc-gen! (lit mov) x1 x0)
    (asm-label! %cc-gen-asm next)
    (%cc-gen! (lit ldrb) x2 (mem x0 0))
    (%cc-gen! (lit cmp) x2 (imm 0))
    (%cc-gen! (lit b/eq) (label done))
    (%cc-gen! (lit add) x0 x0 (imm 1))
    (%cc-gen! (lit b) (label next))
    (asm-label! %cc-gen-asm done)
    (%cc-gen! (lit sub) x0 x0 x1)
    (%cc-gen! (lit ret))))

; strcmp: the first difference between the strings at x0 and x1, each byte
; read as an unsigned char; 0 when they are the same
(def %cc-gen-strcmp-body!
  (fn (_)
    (def next (%cc-gen-label))
    (def differ (%cc-gen-label))
    (def same (%cc-gen-label))
    (asm-label! %cc-gen-asm next)
    (%cc-gen! (lit ldrb) x2 (mem x0 0))
    (%cc-gen! (lit ldrb) x8 (mem x1 0))
    (%cc-gen! (lit cmp) x2 x8)
    (%cc-gen! (lit b/ne) (label differ))
    (%cc-gen! (lit cmp) x2 (imm 0))
    (%cc-gen! (lit b/eq) (label same))
    (%cc-gen! (lit add) x0 x0 (imm 1))
    (%cc-gen! (lit add) x1 x1 (imm 1))
    (%cc-gen! (lit b) (label next))
    (asm-label! %cc-gen-asm differ)
    (%cc-gen! (lit sub) x2 x2 x8)
    (%cc-gen! (lit mov) x0 x2)
    (%cc-gen! (lit ret))
    (asm-label! %cc-gen-asm same)
    (%cc-gen! (lit mov) x0 (imm 0))
    (%cc-gen! (lit ret))))

; strcpy: the string at x1, its NUL included, to x0; answers x0
(def %cc-gen-strcpy-body!
  (fn (_)
    (def next (%cc-gen-label))
    (def done (%cc-gen-label))
    (%cc-gen! (lit mov) x8 x0)
    (asm-label! %cc-gen-asm next)
    (%cc-gen! (lit ldrb) x2 (mem x1 0))
    (%cc-gen! (lit strb) x2 (mem x0 0))
    (%cc-gen! (lit cmp) x2 (imm 0))
    (%cc-gen! (lit b/eq) (label done))
    (%cc-gen! (lit add) x0 x0 (imm 1))
    (%cc-gen! (lit add) x1 x1 (imm 1))
    (%cc-gen! (lit b) (label next))
    (asm-label! %cc-gen-asm done)
    (%cc-gen! (lit mov) x0 x8)
    (%cc-gen! (lit ret))))

; memcpy: x2 bytes from x1 to x0, a byte at a time; answers x0, which
; waits on the stack since the four registers are all in use
(def %cc-gen-memcpy-body!
  (fn (_)
    (def next (%cc-gen-label))
    (def done (%cc-gen-label))
    (asm-push! %cc-gen-asm x0)
    (asm-label! %cc-gen-asm next)
    (%cc-gen! (lit cmp) x2 (imm 0))
    (%cc-gen! (lit b/eq) (label done))
    (%cc-gen! (lit ldrb) x8 (mem x1 0))
    (%cc-gen! (lit strb) x8 (mem x0 0))
    (%cc-gen! (lit add) x0 x0 (imm 1))
    (%cc-gen! (lit add) x1 x1 (imm 1))
    (%cc-gen! (lit sub) x2 x2 (imm 1))
    (%cc-gen! (lit b) (label next))
    (asm-label! %cc-gen-asm done)
    (asm-pop! %cc-gen-asm x0)
    (%cc-gen! (lit ret))))

; memmove: x2 bytes from x1 to x0, from the end back when x0 is past x1, so
; an overlap copies what was there; answers x0
(def %cc-gen-memmove-body!
  (fn (_)
    (def back (%cc-gen-label))
    (def fore (%cc-gen-label))
    (def done (%cc-gen-label))
    (asm-push! %cc-gen-asm x0)
    (%cc-gen! (lit cmp) x0 x1)
    (%cc-gen! (lit b/le) (label fore))
    (%cc-gen! (lit add) x0 x0 x2)
    (%cc-gen! (lit add) x1 x1 x2)
    (asm-label! %cc-gen-asm back)
    (%cc-gen! (lit cmp) x2 (imm 0))
    (%cc-gen! (lit b/eq) (label done))
    (%cc-gen! (lit sub) x0 x0 (imm 1))
    (%cc-gen! (lit sub) x1 x1 (imm 1))
    (%cc-gen! (lit ldrb) x8 (mem x1 0))
    (%cc-gen! (lit strb) x8 (mem x0 0))
    (%cc-gen! (lit sub) x2 x2 (imm 1))
    (%cc-gen! (lit b) (label back))
    (asm-label! %cc-gen-asm fore)
    (%cc-gen! (lit cmp) x2 (imm 0))
    (%cc-gen! (lit b/eq) (label done))
    (%cc-gen! (lit ldrb) x8 (mem x1 0))
    (%cc-gen! (lit strb) x8 (mem x0 0))
    (%cc-gen! (lit add) x0 x0 (imm 1))
    (%cc-gen! (lit add) x1 x1 (imm 1))
    (%cc-gen! (lit sub) x2 x2 (imm 1))
    (%cc-gen! (lit b) (label fore))
    (asm-label! %cc-gen-asm done)
    (asm-pop! %cc-gen-asm x0)
    (%cc-gen! (lit ret))))

; memset: x2 bytes at x0, each the low byte of x1; answers x0
(def %cc-gen-memset-body!
  (fn (_)
    (def next (%cc-gen-label))
    (def done (%cc-gen-label))
    (asm-push! %cc-gen-asm x0)
    (asm-label! %cc-gen-asm next)
    (%cc-gen! (lit cmp) x2 (imm 0))
    (%cc-gen! (lit b/eq) (label done))
    (%cc-gen! (lit strb) x1 (mem x0 0))
    (%cc-gen! (lit add) x0 x0 (imm 1))
    (%cc-gen! (lit sub) x2 x2 (imm 1))
    (%cc-gen! (lit b) (label next))
    (asm-label! %cc-gen-asm done)
    (asm-pop! %cc-gen-asm x0)
    (%cc-gen! (lit ret))))

; strcat: the string at x1, its NUL included, onto the end of the one at
; x0; answers x0
(def %cc-gen-strcat-body!
  (fn (_)
    (def seek (%cc-gen-label))
    (def copy (%cc-gen-label))
    (def done (%cc-gen-label))
    (%cc-gen! (lit mov) x8 x0)
    (asm-label! %cc-gen-asm seek)
    (%cc-gen! (lit ldrb) x2 (mem x0 0))
    (%cc-gen! (lit cmp) x2 (imm 0))
    (%cc-gen! (lit b/eq) (label copy))
    (%cc-gen! (lit add) x0 x0 (imm 1))
    (%cc-gen! (lit b) (label seek))
    (asm-label! %cc-gen-asm copy)
    (%cc-gen! (lit ldrb) x2 (mem x1 0))
    (%cc-gen! (lit strb) x2 (mem x0 0))
    (%cc-gen! (lit cmp) x2 (imm 0))
    (%cc-gen! (lit b/eq) (label done))
    (%cc-gen! (lit add) x0 x0 (imm 1))
    (%cc-gen! (lit add) x1 x1 (imm 1))
    (%cc-gen! (lit b) (label copy))
    (asm-label! %cc-gen-asm done)
    (%cc-gen! (lit mov) x0 x8)
    (%cc-gen! (lit ret))))

; strncmp, NUL? true, and memcmp: the first difference among the x2 bytes
; at x0 and x1, each read as an unsigned char, stopping at a NUL for
; strncmp; 0 when there is none.  Two bytes, two addresses and the count
; are one more than the registers, so the count waits in a frame of its
; own, taken off x20 as a function's is.
(def %cc-gen-compare-body!
  (fn (_ nul?)
    (def next (%cc-gen-label))
    (def differ (%cc-gen-label))
    (def same (%cc-gen-label))
    (def out (%cc-gen-label))
    (%cc-gen! (lit sub) x20 x20 (imm 16))
    (%cc-gen! (lit str) x2 (mem x20 0))
    (asm-label! %cc-gen-asm next)
    (%cc-gen! (lit ldr) x2 (mem x20 0))
    (%cc-gen! (lit cmp) x2 (imm 0))
    (%cc-gen! (lit b/eq) (label same))
    (%cc-gen! (lit sub) x2 x2 (imm 1))
    (%cc-gen! (lit str) x2 (mem x20 0))
    (%cc-gen! (lit ldrb) x2 (mem x0 0))
    (%cc-gen! (lit ldrb) x8 (mem x1 0))
    (%cc-gen! (lit cmp) x2 x8)
    (%cc-gen! (lit b/ne) (label differ))
    (if nul?
      (do (%cc-gen! (lit cmp) x2 (imm 0))
          (%cc-gen! (lit b/eq) (label same)))
      ())
    (%cc-gen! (lit add) x0 x0 (imm 1))
    (%cc-gen! (lit add) x1 x1 (imm 1))
    (%cc-gen! (lit b) (label next))
    (asm-label! %cc-gen-asm differ)
    (%cc-gen! (lit sub) x2 x2 x8)
    (%cc-gen! (lit mov) x0 x2)
    (%cc-gen! (lit b) (label out))
    (asm-label! %cc-gen-asm same)
    (%cc-gen! (lit mov) x0 (imm 0))
    (asm-label! %cc-gen-asm out)
    (%cc-gen! (lit add) x20 x20 (imm 16))
    (%cc-gen! (lit ret))))

; strncpy: x2 bytes to x0 -- the string at x1, then NULs to the end of the
; count; answers x0, which waits in a frame of its own
(def %cc-gen-strncpy-body!
  (fn (_)
    (def next (%cc-gen-label))
    (def pad (%cc-gen-label))
    (def done (%cc-gen-label))
    (%cc-gen! (lit sub) x20 x20 (imm 16))
    (%cc-gen! (lit str) x0 (mem x20 0))
    (asm-label! %cc-gen-asm next)
    (%cc-gen! (lit cmp) x2 (imm 0))
    (%cc-gen! (lit b/eq) (label done))
    (%cc-gen! (lit ldrb) x8 (mem x1 0))
    (%cc-gen! (lit strb) x8 (mem x0 0))
    (%cc-gen! (lit add) x0 x0 (imm 1))
    (%cc-gen! (lit sub) x2 x2 (imm 1))
    (%cc-gen! (lit cmp) x8 (imm 0))
    (%cc-gen! (lit b/eq) (label pad))
    (%cc-gen! (lit add) x1 x1 (imm 1))
    (%cc-gen! (lit b) (label next))
    ; x8 is the NUL just copied
    (asm-label! %cc-gen-asm pad)
    (%cc-gen! (lit cmp) x2 (imm 0))
    (%cc-gen! (lit b/eq) (label done))
    (%cc-gen! (lit strb) x8 (mem x0 0))
    (%cc-gen! (lit add) x0 x0 (imm 1))
    (%cc-gen! (lit sub) x2 x2 (imm 1))
    (%cc-gen! (lit b) (label pad))
    (asm-label! %cc-gen-asm done)
    (%cc-gen! (lit ldr) x0 (mem x20 0))
    (%cc-gen! (lit add) x20 x20 (imm 16))
    (%cc-gen! (lit ret))))

; strchr: the address of the first x1, read as an unsigned char, in the
; string at x0 -- its NUL included -- or 0
(def %cc-gen-strchr-body!
  (fn (_)
    (def next (%cc-gen-label))
    (def found (%cc-gen-label))
    (def none (%cc-gen-label))
    (%cc-gen! (lit mov) x2 (imm 255))
    (%cc-gen! (lit and) x1 x1 x2)
    (asm-label! %cc-gen-asm next)
    (%cc-gen! (lit ldrb) x2 (mem x0 0))
    (%cc-gen! (lit cmp) x2 x1)
    (%cc-gen! (lit b/eq) (label found))
    (%cc-gen! (lit cmp) x2 (imm 0))
    (%cc-gen! (lit b/eq) (label none))
    (%cc-gen! (lit add) x0 x0 (imm 1))
    (%cc-gen! (lit b) (label next))
    (asm-label! %cc-gen-asm none)
    (%cc-gen! (lit mov) x0 (imm 0))
    (asm-label! %cc-gen-asm found)
    (%cc-gen! (lit ret))))

; strrchr: the address of the last x1, read as an unsigned char, in the
; string at x0 -- its NUL included -- or 0; the last one seen is in x8
(def %cc-gen-strrchr-body!
  (fn (_)
    (def next (%cc-gen-label))
    (def miss (%cc-gen-label))
    (def done (%cc-gen-label))
    (%cc-gen! (lit mov) x2 (imm 255))
    (%cc-gen! (lit and) x1 x1 x2)
    (%cc-gen! (lit mov) x8 (imm 0))
    (asm-label! %cc-gen-asm next)
    (%cc-gen! (lit ldrb) x2 (mem x0 0))
    (%cc-gen! (lit cmp) x2 x1)
    (%cc-gen! (lit b/ne) (label miss))
    (%cc-gen! (lit mov) x8 x0)
    (asm-label! %cc-gen-asm miss)
    (%cc-gen! (lit cmp) x2 (imm 0))
    (%cc-gen! (lit b/eq) (label done))
    (%cc-gen! (lit add) x0 x0 (imm 1))
    (%cc-gen! (lit b) (label next))
    (asm-label! %cc-gen-asm done)
    (%cc-gen! (lit mov) x0 x8)
    (%cc-gen! (lit ret))))

; strstr: the address of the first place the string at x1 starts in the
; one at x0, or 0; an empty one starts at x0.  Where the search is and the
; string sought wait in a frame of their own while x0 and x1 walk the two
; and x2 and x8 hold their bytes.
(def %cc-gen-strstr-body!
  (fn (_)
    (def outer (%cc-gen-label))
    (def inner (%cc-gen-label))
    (def next (%cc-gen-label))
    (def found (%cc-gen-label))
    (def none (%cc-gen-label))
    (def out (%cc-gen-label))
    (%cc-gen! (lit sub) x20 x20 (imm 16))
    (%cc-gen! (lit str) x0 (mem x20 0))
    (%cc-gen! (lit str) x1 (mem x20 8))
    (asm-label! %cc-gen-asm outer)
    (%cc-gen! (lit ldr) x0 (mem x20 0))
    (%cc-gen! (lit ldr) x1 (mem x20 8))
    (asm-label! %cc-gen-asm inner)
    (%cc-gen! (lit ldrb) x8 (mem x1 0))
    (%cc-gen! (lit cmp) x8 (imm 0))
    (%cc-gen! (lit b/eq) (label found))
    (%cc-gen! (lit ldrb) x2 (mem x0 0))
    ; the string searched ended first: it holds no more places to start
    (%cc-gen! (lit cmp) x2 (imm 0))
    (%cc-gen! (lit b/eq) (label none))
    (%cc-gen! (lit cmp) x2 x8)
    (%cc-gen! (lit b/ne) (label next))
    (%cc-gen! (lit add) x0 x0 (imm 1))
    (%cc-gen! (lit add) x1 x1 (imm 1))
    (%cc-gen! (lit b) (label inner))
    (asm-label! %cc-gen-asm next)
    (%cc-gen! (lit ldr) x0 (mem x20 0))
    (%cc-gen! (lit add) x0 x0 (imm 1))
    (%cc-gen! (lit str) x0 (mem x20 0))
    (%cc-gen! (lit b) (label outer))
    (asm-label! %cc-gen-asm found)
    (%cc-gen! (lit ldr) x0 (mem x20 0))
    (%cc-gen! (lit b) (label out))
    (asm-label! %cc-gen-asm none)
    (%cc-gen! (lit mov) x0 (imm 0))
    (asm-label! %cc-gen-asm out)
    (%cc-gen! (lit add) x20 x20 (imm 16))
    (%cc-gen! (lit ret))))

; atoi: the int the digits at x0 spell, after spaces and a sign; the sign
; waits in a frame of its own while x1 gathers the digits
(def %cc-gen-atoi-body!
  (fn (_)
    (def skip (%cc-gen-label))
    (def over (%cc-gen-label))
    (def sign (%cc-gen-label))
    (def plus (%cc-gen-label))
    (def digits (%cc-gen-label))
    (def next (%cc-gen-label))
    (def end (%cc-gen-label))
    (def positive (%cc-gen-label))
    (%cc-gen! (lit sub) x20 x20 (imm 16))
    (asm-label! %cc-gen-asm skip)
    (%cc-gen! (lit ldrb) x2 (mem x0 0))
    (%cc-gen! (lit cmp) x2 (imm 32))
    (%cc-gen! (lit b/eq) (label over))
    (%cc-gen! (lit cmp) x2 (imm 9))
    (%cc-gen! (lit b/lt) (label sign))
    (%cc-gen! (lit cmp) x2 (imm 13))
    (%cc-gen! (lit b/gt) (label sign))
    (asm-label! %cc-gen-asm over)
    (%cc-gen! (lit add) x0 x0 (imm 1))
    (%cc-gen! (lit b) (label skip))
    ; x8 = 1 for a minus sign, else 0
    (asm-label! %cc-gen-asm sign)
    (%cc-gen! (lit mov) x8 (imm 0))
    (%cc-gen! (lit cmp) x2 (imm 45))
    (%cc-gen! (lit b/ne) (label plus))
    (%cc-gen! (lit mov) x8 (imm 1))
    (%cc-gen! (lit add) x0 x0 (imm 1))
    (%cc-gen! (lit b) (label digits))
    (asm-label! %cc-gen-asm plus)
    (%cc-gen! (lit cmp) x2 (imm 43))
    (%cc-gen! (lit b/ne) (label digits))
    (%cc-gen! (lit add) x0 x0 (imm 1))
    (asm-label! %cc-gen-asm digits)
    (%cc-gen! (lit str) x8 (mem x20 0))
    (%cc-gen! (lit mov) x1 (imm 0))
    (asm-label! %cc-gen-asm next)
    (%cc-gen! (lit ldrb) x2 (mem x0 0))
    (%cc-gen! (lit cmp) x2 (imm 48))
    (%cc-gen! (lit b/lt) (label end))
    (%cc-gen! (lit cmp) x2 (imm 57))
    (%cc-gen! (lit b/gt) (label end))
    (%cc-gen! (lit mov) x8 (imm 10))
    (%cc-gen! (lit mul) x1 x1 x8)
    (%cc-gen! (lit sub) x2 x2 (imm 48))
    (%cc-gen! (lit add) x1 x1 x2)
    (%cc-gen! (lit add) x0 x0 (imm 1))
    (%cc-gen! (lit b) (label next))
    (asm-label! %cc-gen-asm end)
    (%cc-gen! (lit ldr) x8 (mem x20 0))
    (%cc-gen! (lit cmp) x8 (imm 0))
    (%cc-gen! (lit b/eq) (label positive))
    (%cc-gen! (lit sub) x1 xzr x1)
    (asm-label! %cc-gen-asm positive)
    (%cc-gen! (lit mov) x0 x1)
    (%cc-gen! (lit add) x20 x20 (imm 16))
    (%cc-gen! (lit ret))))

; x0 = 1 if x0 lies in one of RANGES, ((LOW . HIGH) ...), else 0: one of
; <ctype.h>'s classifications (ctype-ranges)
(def %cc-gen-ranges-body!
  (fn (_ ranges)
    (def yes (%cc-gen-label))
    (def go
      (fn (self rs)
        (if (null? rs) ()
          (let ((next (%cc-gen-label)))
            (do (%cc-gen! (lit cmp) x0 (imm (first (first rs))))
                (%cc-gen! (lit b/lt) (label next))
                (%cc-gen! (lit cmp) x0 (imm (rest (first rs))))
                (%cc-gen! (lit b/le) (label yes))
                (asm-label! %cc-gen-asm next)
                (self (rest rs)))))))
    (go ranges)
    (%cc-gen! (lit mov) x0 (imm 0))
    (%cc-gen! (lit ret))
    (asm-label! %cc-gen-asm yes)
    (%cc-gen! (lit mov) x0 (imm 1))
    (%cc-gen! (lit ret))))

; x0 moved thirty-two by OP when it lies in LOW..HIGH: toupper and tolower
(def %cc-gen-case-body!
  (fn (_ low high op)
    (def same (%cc-gen-label))
    (%cc-gen! (lit cmp) x0 (imm low))
    (%cc-gen! (lit b/lt) (label same))
    (%cc-gen! (lit cmp) x0 (imm high))
    (%cc-gen! (lit b/gt) (label same))
    (%cc-gen! op x0 x0 (imm 32))
    (asm-label! %cc-gen-asm same)
    (%cc-gen! (lit ret))))

; abs: x0, negated when it is below zero
(def %cc-gen-abs-body!
  (fn (_)
    (def done (%cc-gen-label))
    (%cc-gen! (lit cmp) x0 (imm 0))
    (%cc-gen! (lit b/ge) (label done))
    (%cc-gen! (lit sub) x0 xzr x0)
    (asm-label! %cc-gen-asm done)
    (%cc-gen! (lit ret))))

; The runtime's functions: each written after the program's last function
; when the program calls it and does not define its own.  An entry is
; (NAME ARGUMENTS C-TYPE . BODY): how many arguments it takes, the C type
; it answers, and what writes its code.  Its arguments arrive in registers,
; as any call's first four do.  The classifications come from the table
; run reads them from.
(def %cc-gen-runtime
  (append
    (list (pair "malloc" (pair 1 (pair (library-c-type "malloc") %cc-gen-malloc-body!)))
          (pair "strlen" (pair 1 (pair (library-c-type "strlen") %cc-gen-strlen-body!)))
          (pair "strcmp" (pair 2 (pair (library-c-type "strcmp") %cc-gen-strcmp-body!)))
          (pair "strcpy" (pair 2 (pair (library-c-type "strcpy") %cc-gen-strcpy-body!)))
          (pair "memcpy" (pair 3 (pair (library-c-type "memcpy") %cc-gen-memcpy-body!)))
          (pair "memset" (pair 3 (pair (library-c-type "memset") %cc-gen-memset-body!)))
          (pair "strcat" (pair 2 (pair (library-c-type "strcat") %cc-gen-strcat-body!)))
          (pair "strncmp" (pair 3 (pair (library-c-type "strncmp") (fn (_) (%cc-gen-compare-body! #t)))))
          (pair "memcmp" (pair 3 (pair (library-c-type "memcmp") (fn (_) (%cc-gen-compare-body! #f)))))
          (pair "strncpy" (pair 3 (pair (library-c-type "strncpy") %cc-gen-strncpy-body!)))
          (pair "strchr" (pair 2 (pair (library-c-type "strchr") %cc-gen-strchr-body!)))
          (pair "strrchr" (pair 2 (pair (library-c-type "strrchr") %cc-gen-strrchr-body!)))
          (pair "strstr" (pair 2 (pair (library-c-type "strstr") %cc-gen-strstr-body!)))
          (pair "memmove" (pair 3 (pair (library-c-type "memmove") %cc-gen-memmove-body!)))
          (pair "atoi" (pair 1 (pair (library-c-type "atoi") %cc-gen-atoi-body!)))
          (pair "toupper" (pair 1 (pair (library-c-type "toupper") (fn (_) (%cc-gen-case-body! 97 122 (lit sub))))))
          (pair "tolower" (pair 1 (pair (library-c-type "tolower") (fn (_) (%cc-gen-case-body! 65 90 (lit add))))))
          (pair "abs" (pair 1 (pair (library-c-type "abs") %cc-gen-abs-body!)))
          ; a negation of the whole register serves a long as well
          (pair "labs" (pair 1 (pair (library-c-type "labs") %cc-gen-abs-body!))))
    (let ((go (fn (self es)
                (if (null? es) ()
                  (let ((ranges (rest (first es))))
                    (pair (pair (first (first es))
                            (pair 1 (pair (lit int) (fn (_) (%cc-gen-ranges-body! ranges)))))
                      (self (rest es))))))))
      (go ctype-ranges))))
(def %cc-gen-runtime-live ())    ; the entries the program does not define
(def %cc-gen-runtime-called ())  ; ((ENTRY . LABEL) ...), the ones it calls

; each runtime function the program called, at its label
(def %cc-gen-runtime-emit!
  (fn (_)
    (def go
      (fn (self cs)
        (if (null? cs) ()
          (do (asm-label! %cc-gen-asm (rest (first cs)))
              ((rest (rest (rest (first (first cs))))))
              (self (rest cs))))))
    (go (reverse %cc-gen-runtime-called))))

; exit: the status into x0, then the entry's own exit, the one main's
; return reaches
(def %cc-gen-exit!
  (fn (_ args)
    (if (not (= (length args) 1))
      (%cc-gen-no "exit with other than one argument"))
    (do (%cc-gen-expr! (first args))
        (%cc-gen! (lit sub) x1 x21 (imm %cc-gen-exit-at))
        (%cc-gen! (lit blr) x1))))

; puts: the string and the newline it adds.  A literal's text is known
; here, so the newline goes into the data on the end of it and one write
; does both; any other string is walked to its NUL at run time.  It
; answers zero, which is one of the answers C allows: any number that is
; not negative.
(def %cc-gen-puts!
  (fn (_ args)
    (if (not (= (length args) 1))
      (%cc-gen-no "puts with other than one argument"))
    (def arg (first args))
    (if (eq? (first arg) (lit str))
      (let ((text (string-append (first (rest arg)) "\n")))
        (do (%cc-gen-string-at! text)
            (%cc-gen! (lit mov) x1 x0)
            (%cc-gen! (lit mov) x0 (imm 1))
            (%cc-gen! (lit mov) x2 (imm (byte-len text)))
            (%cc-gen! (lit blr) x21)
            (%cc-gen-const! 0)))
      (do (if (not (%cc-gen-addr-kind? (%cc-gen-kind-of arg)))
            (%cc-gen-no "puts of something that is not a string"))
          (%cc-gen-expr! arg)
          (%cc-gen-put-cstr!)
          (%cc-gen! (lit mov) x0 (imm 10))
          (%cc-gen-put-byte!)
          (%cc-gen-const! 0)))))

; the string whose address is in x0, to standard output: a cursor walks
; to its NUL, and the bytes before it go in one write, whose count comes
; back in x0
(def %cc-gen-put-cstr!
  (fn (_)
    (do (%cc-gen-cstr-length! ())
        (%cc-gen! (lit mov) x0 (imm 1))
        (%cc-gen! (lit blr) x21))))

; x1 = x0, and x2 = the count of bytes from there to the NUL, or to MOST
; when that comes first and is not ()
(def %cc-gen-cstr-length!
  (fn (_ most)
    (def top (%cc-gen-label))
    (def done (%cc-gen-label))
    (do (%cc-gen! (lit mov) x1 x0)
        (%cc-gen! (lit mov) x2 x0)
        (asm-label! %cc-gen-asm top)
        (if (null? most) ()
          (do (%cc-gen! (lit mov) x8 x2)
              (%cc-gen! (lit sub) x8 x8 x1)
              (%cc-gen! (lit cmp) x8 (imm most))
              (%cc-gen! (lit b/ge) (label done))))
        (%cc-gen! (lit ldrb) x0 (mem x2 0))
        (%cc-gen! (lit cmp) x0 (imm 0))
        (%cc-gen! (lit b/eq) (label done))
        (%cc-gen! (lit add) x2 x2 (imm 1))
        (%cc-gen! (lit b) (label top))
        (asm-label! %cc-gen-asm done)
        (%cc-gen! (lit sub) x2 x2 x1))))

; Where each argument of a call goes, by the kinds of the callee's
; parameters: (reg . R) for one of the first four that is not a struct,
; else (above . OFF), the argument starting OFF bytes below the top of the
; frame the callee takes -- each in whole words, in order, under the word
; that says where a struct the callee answers goes (%cc-gen-fun!).  Caller
; and callee both lay it out from the same kinds.
(def %cc-gen-homes
  (fn (_ kinds sret?)
    (def go
      (fn (self ks regs used)
        (if (null? ks) ()
          (let ((k (first ks)))
            (if (if (null? regs) #f (not (%cc-gen-struct? k)))
              (pair (pair (lit reg) (first regs)) (self (rest ks) (rest regs) used))
              (let ((off (+ used (round-up (kind-size k) 8))))
                (pair (pair (lit above) off)
                  (self (rest ks) (if (null? regs) () (rest regs)) off))))))))
    (go kinds %cc-gen-args (if sret? 8 0))))

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
    (if (not (null? (%cc-gen-runtime-find name)))
      (%cc-gen-no (string-append "the address of the library's " name)))
    (def params (%cc-gen-params-find name))
    (if (if (> (length params) 3) #t
          (if (%cc-gen-struct? (%cc-gen-ret-find name)) #t
            (not (null? (filter %cc-gen-struct? params)))))
      (%cc-gen-no (string-append "the address of " name
                    ", which takes a struct or more than three arguments, or answers a struct")))
    (%cc-gen! (lit adr) x0 (label (%cc-gen-fun-label name)))))

; A call through TARGET, a pointer to a function, with ARGS: the address,
; then each argument in its own C type's promoted form, wait on the stack;
; the arguments go into the first registers and the address into x8,
; which three arguments leave free.  It answers what the pointer's RET says.
(def %cc-gen-call-through!
  (fn (_ target args)
    (if (not (%cc-gen-fnptr? (%cc-gen-kind-of target)))
      (%cc-gen-no "a call through something that is not a pointer to a function"))
    (if (> (length args) 3)
      (%cc-gen-no "a call through a pointer with more than three arguments"))
    (def push-all
      (fn (self as)
        (if (null? as) ()
          (do (if (%cc-gen-struct? (%cc-gen-kind-of (first as)))
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
        (%cc-gen! (lit blr) x8))))

(def %cc-gen-call-fun!
  (fn (_ node)
    (def name (first (rest node)))
    (def args (first (rest (rest node))))
    (def to (%cc-gen-fun-label name))
    (def params (%cc-gen-params-find name))
    (def sret? (%cc-gen-struct? (%cc-gen-ret-find name)))
    ; (ARG KIND . HOME) per argument; past the parameters, an argument's
    ; own kind says where it goes
    (def kinds
      (let ((go (fn (self as ps)
                  (if (null? as) ()
                    (pair (if (null? ps) (%cc-gen-kind-of (first as)) (first ps))
                      (self (rest as) (if (null? ps) () (rest ps))))))))
        (go args params)))
    (def triples
      (let ((go (fn (self as ks hs)
                  (if (null? as) ()
                    (pair (pair (first as) (pair (first ks) (first hs)))
                      (self (rest as) (rest ks) (rest hs)))))))
        (go args kinds (%cc-gen-homes kinds sret?))))
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
                  (if (%cc-gen-struct? (%cc-gen-kind-of (first t)))
                    (%cc-gen-no "a struct passed for a parameter that is not one")
                    ()))
                (%cc-gen-expr! (first t))
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
                  (%cc-gen-copy! (kind-size (first (rest t))))
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

; the low byte of x0 to standard output, from the frame's scratch slot
(def %cc-gen-put-byte!
  (fn (_)
    (def off %cc-gen-scratch)
    (do (%cc-gen! (lit str) x0 (mem x19 off))
        (%cc-gen! (lit mov) x0 (imm 1))
        (if (= off 0)
          (%cc-gen! (lit mov) x1 x19)
          (%cc-gen! (lit add) x1 x19 (imm off)))
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
; text, one per %c, and a conversion per %d, %u, %ld or %lu to decimal and
; per %x or %lx to hex (%i and %li are %d and %ld).  A conversion reads its
; flags, field width and precision as run's printf does
; (printf-conversion): a padding whose size is known here is text, and one
; that waits on the value is a write of that many bytes from a run of
; spaces or zeros in the data.  Every argument is evaluated before anything
; is written, as a call's are.  It answers the count of bytes written, as
; C's does.

; (PIECES . ARGS) for FORMAT and the arguments after it: each piece is
; (text . STRING), or (CONV N . FIELD) for the Nth argument left to run
; time, CONV one of d u x ld lu lx c s and FIELD (LEFT? ZERO? WIDTH
; PRECISION)
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
          (#t
            (let ((text (pair (substring fmt from i) text))
                  (spec (printf-conversion fmt i)))
              (if (null? spec) (%cc-gen-no "printf's % at the end of its format"))
              (def next (first spec))
              (def c (first (rest spec)))
              (def l? (first (rest (rest spec))))
              (def field (rest (rest (rest spec))))
              (def left? (first field))
              (def zero? (if (first (rest field)) (not left?) #f))
              (def width (first (rest (rest field))))
              (def precision (first (rest (rest (rest field)))))
              (def conv
                (match
                  ((if l? #f (= c 37)) (lit pct))
                  ((if (= c 100) #t (= c 105)) (if l? (lit ld) (lit d)))
                  ((= c 117) (if l? (lit lu) (lit u)))
                  ((= c 120) (if l? (lit lx) (lit x)))
                  ((if l? #f (= c 99)) (lit c))
                  ((if l? #f (= c 115)) (lit s))
                  (#t (%cc-gen-no (string-append "printf's %" (substring fmt (+ i 1) next))))))
              (if (> width 4095) (%cc-gen-no "printf's field width past 4095"))
              (if (if (null? precision) #f (> precision 4095))
                (%cc-gen-no "printf's precision past 4095"))
              (match
                ((eq? conv (lit pct)) (self next next (pair "%" text) args pieces later))
                ((null? args) (%cc-gen-no "printf with fewer arguments than conversions"))
                ; a literal's text, fitted to its field, joins the text around it
                ((if (eq? conv (lit s)) (eq? (first (first args)) (lit str)) #f)
                  (self next next (pair (printf-fit c (first (rest (first args))) field) text)
                    (rest args) pieces later))
                ((if (eq? conv (lit s)) (not (%cc-gen-addr-kind? (%cc-gen-kind-of (first args)))) #f)
                  (%cc-gen-no "printf's %s of something that is not a string"))
                ; a character is one byte, so its padding is text before or after it
                ((eq? conv (lit c))
                  (let ((pad (printf-pad zero? (- width 1))))
                    (self next next (if left? (list pad) ()) (rest args)
                      (pair (pair conv (pair (length later) field))
                        (flush (if left? text (pair pad text)) pieces))
                      (pair (first args) later))))
                (#t
                  (self next next () (rest args)
                    (pair (pair conv (pair (length later) field)) (flush text pieces))
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

; Padding that waits on the value: N less the number LENGTH! leaves in x0
; bytes of PAD, a run of spaces or zeros N long, when that is above zero.
; The run's address may take x2, so the count waits on the stack.
(def %cc-gen-printf-pad!
  (fn (_ pad n length!)
    (def skip (%cc-gen-label))
    (do (length!)
        (%cc-gen! (lit mov) x2 (imm n))
        (%cc-gen! (lit sub) x2 x2 x0)
        (%cc-gen! (lit cmp) x2 (imm 0))
        (%cc-gen! (lit b/le) (label skip))
        (asm-push! %cc-gen-asm x2)
        (%cc-gen-string-at! pad)
        (%cc-gen! (lit mov) x1 x0)
        (asm-pop! %cc-gen-asm x2)
        (%cc-gen! (lit mov) x0 (imm 1))
        (%cc-gen! (lit blr) x21)
        (%cc-gen-printf-count!)
        (asm-label! %cc-gen-asm skip))))

; A string, from the address in SLOT, in its FIELD (LEFT? ZERO? WIDTH
; PRECISION): its bytes to the NUL, or to the precision, padded to the
; field width.  The count waits in the held slot across the padding.
(def %cc-gen-printf-str!
  (fn (_ slot field)
    (def left? (first field))
    (def zero? (if (first (rest field)) (not left?) #f))
    (def width (first (rest (rest field))))
    (def held (mem x19 (+ %cc-gen-pf %cc-gen-pf-held)))
    (def length! (fn (_) (%cc-gen! (lit ldr) x0 held)))
    (do (%cc-gen! (lit ldr) x0 (mem x19 slot))
        (%cc-gen-cstr-length! (first (rest (rest (rest field)))))
        (%cc-gen! (lit str) x2 held)
        (if (if left? #t (= width 0)) () (%cc-gen-printf-pad! (printf-pad zero? width) width length!))
        (%cc-gen! (lit ldr) x1 (mem x19 slot))
        (%cc-gen! (lit ldr) x2 held)
        (%cc-gen! (lit mov) x0 (imm 1))
        (%cc-gen! (lit blr) x21)
        (%cc-gen-printf-count!)
        (if (if left? (> width 0) #f) (%cc-gen-printf-pad! (printf-pad #f width) width length!) ()))))

; A number, as CONV reads it -- d and ld signed, u and lu unsigned, x and
; lx in hex, the l forms all 64 bits -- in its FIELD (LEFT? ZERO? WIDTH
; PRECISION).  The digits of its magnitude are built from the end of the
; buffer back before anything is written; then come the padding before,
; the sign, zeros to the field width for ZERO? or to the precision, the
; digits, and the padding after.  The value stays in its slot; the
; magnitude, then the length the field is filled against, is in the held
; slot, and the cursor in its own, rather than in registers, which the
; division and the multiply take.
(def %cc-gen-printf-int!
  (fn (_ slot conv field)
    (def left? (first field))
    (def width (first (rest (rest field))))
    (def precision (first (rest (rest (rest field)))))
    (def zero? (if (first (rest field)) (if left? #f (null? precision)) #f))
    (def cursor (mem x19 (+ %cc-gen-pf %cc-gen-pf-cursor)))
    (def held (mem x19 (+ %cc-gen-pf %cc-gen-pf-held)))
    (def end (+ %cc-gen-pf %cc-gen-pf-end))
    (def digit (%cc-gen-label))
    (def digits-done (%cc-gen-label))
    (def signed? (if (eq? conv (lit d)) #t (eq? conv (lit ld))))
    (def hex? (if (eq? conv (lit x)) #t (eq? conv (lit lx))))
    ; x0 = the count of digits built
    (def digits!
      (fn (_)
        (do (%cc-gen-address! x19 end)
            (%cc-gen! (lit ldr) x1 cursor)
            (%cc-gen! (lit sub) x0 x0 x1))))
    (def length! (fn (_) (%cc-gen! (lit ldr) x0 held)))
    (do (%cc-gen! (lit ldr) x0 (mem x19 slot))
        ; %d reads an int, and %u and %x an unsigned int: the argument's low
        ; 32 bits, in that C type's form
        (match
          ((eq? conv (lit d)) (do (%cc-gen-int!) (%cc-gen! (lit str) x0 (mem x19 slot))))
          ((if (eq? conv (lit u)) #t (eq? conv (lit x)))
            (do (%cc-gen-uint!) (%cc-gen! (lit str) x0 (mem x19 slot))))
          (#t ()))
        (if signed?
          (let ((plus (%cc-gen-label)))
            (do (%cc-gen! (lit cmp) x0 (imm 0))
                (%cc-gen! (lit b/ge) (label plus))
                (%cc-gen! (lit sub) x0 xzr x0)
                (asm-label! %cc-gen-asm plus)))
          ())
        (%cc-gen! (lit str) x0 held)
        (%cc-gen! (lit add) x2 x19 (imm end))
        (%cc-gen! (lit str) x2 cursor)
        ; a zero at precision 0 has no digits
        (if (if (null? precision) #f (= precision 0))
          (do (%cc-gen! (lit cmp) x0 (imm 0))
              (%cc-gen! (lit b/eq) (label digits-done)))
          ())
        (asm-label! %cc-gen-asm digit)
        (if hex?
          ; A hex digit a turn: the low four bits, then the number shifted
          ; right four with zeros in, as unsigned.
          (let ((low (%cc-gen-label)))
            (do (%cc-gen! (lit ldr) x0 held)
                (%cc-gen! (lit mov) x8 x0)
                (%cc-gen! (lit mov) x1 (imm 15))
                (%cc-gen! (lit and) x0 x0 x1)
                (%cc-gen! (lit cmp) x0 (imm 10))
                (%cc-gen! (lit b/lt) (label low))
                (%cc-gen! (lit add) x0 x0 (imm 39))
                (asm-label! %cc-gen-asm low)
                (%cc-gen! (lit add) x0 x0 (imm 48))
                (%cc-gen! (lit mov) x2 (imm 4))
                (%cc-gen! (lit lsrv) x8 x8 x2)))
          ; A decimal digit a turn, the number read as unsigned: halved, it is
          ; not negative, so a signed division by five is the unsigned one by
          ; ten.  That also carries the most negative long, whose negation is
          ; itself.
          (do (%cc-gen! (lit ldr) x0 held)
              (%cc-gen! (lit mov) x2 (imm 1))
              (%cc-gen! (lit lsrv) x0 x0 x2)
              (%cc-gen! (lit mov) x1 (imm 5))
              (%cc-gen! (lit sdiv) x0 x0 x1)
              (%cc-gen! (lit mov) x8 x0)
              (%cc-gen! (lit mov) x1 (imm 10))
              (%cc-gen! (lit mul) x2 x8 x1)
              (%cc-gen! (lit ldr) x0 held)
              (%cc-gen! (lit sub) x0 x0 x2)
              (%cc-gen! (lit add) x0 x0 (imm 48))))
        ; the digit goes in before the ones already written; x8 is the rest
        (%cc-gen! (lit ldr) x2 cursor)
        (%cc-gen! (lit sub) x2 x2 (imm 1))
        (%cc-gen! (lit strb) x0 (mem x2 0))
        (%cc-gen! (lit str) x2 cursor)
        (%cc-gen! (lit str) x8 held)
        (%cc-gen! (lit cmp) x8 (imm 0))
        (%cc-gen! (lit b/ne) (label digit))
        (asm-label! %cc-gen-asm digits-done)
        ; the length the field is filled against: the digits, or the
        ; precision when that is more, and the sign
        (if (> width 0)
          (do (digits!)
              (if (null? precision) ()
                (let ((more (%cc-gen-label)))
                  (do (%cc-gen! (lit cmp) x0 (imm precision))
                      (%cc-gen! (lit b/ge) (label more))
                      (%cc-gen! (lit mov) x0 (imm precision))
                      (asm-label! %cc-gen-asm more))))
              (if signed?
                (let ((plus (%cc-gen-label)))
                  (do (%cc-gen! (lit ldr) x1 (mem x19 slot))
                      (%cc-gen! (lit cmp) x1 (imm 0))
                      (%cc-gen! (lit b/ge) (label plus))
                      (%cc-gen! (lit add) x0 x0 (imm 1))
                      (asm-label! %cc-gen-asm plus)))
                ())
              (%cc-gen! (lit str) x0 held))
          ())
        (if (if (> width 0) (if left? #f (not zero?)) #f)
          (%cc-gen-printf-pad! (printf-pad #f width) width length!)
          ())
        (if signed?
          (let ((plus (%cc-gen-label)))
            (do (%cc-gen! (lit ldr) x0 (mem x19 slot))
                (%cc-gen! (lit cmp) x0 (imm 0))
                (%cc-gen! (lit b/ge) (label plus))
                (%cc-gen! (lit mov) x0 (imm 45))
                (%cc-gen-put-byte!)
                (%cc-gen-printf-count!)
                (asm-label! %cc-gen-asm plus)))
          ())
        (if (if zero? (> width 0) #f)
          (%cc-gen-printf-pad! (printf-pad #t width) width length!)
          ())
        (if (if (null? precision) #f (> precision 0))
          (%cc-gen-printf-pad! (printf-pad #t precision) precision digits!)
          ())
        ; the digits, from the cursor to the end
        (%cc-gen! (lit ldr) x1 cursor)
        (%cc-gen! (lit add) x2 x19 (imm end))
        (%cc-gen! (lit sub) x2 x2 x1)
        (%cc-gen! (lit mov) x0 (imm 1))
        (%cc-gen! (lit blr) x21)
        (%cc-gen-printf-count!)
        (if (if left? (> width 0) #f)
          (%cc-gen-printf-pad! (printf-pad #f width) width length!)
          ()))))

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
                    (do (%cc-gen! (lit ldr) x0 (mem x19 (arg-at (first (rest p)))))
                        (%cc-gen-put-byte!)
                        (%cc-gen-printf-count!)))
                  ((eq? (first p) (lit s))
                    (%cc-gen-printf-str! (arg-at (first (rest p))) (rest (rest p))))
                  (#t (%cc-gen-printf-int! (arg-at (first (rest p))) (first p) (rest (rest p)))))
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

; An array in the frame, from its initializer: a braced list stores its
; items in order, a nested list filling a nested array, and the elements
; it does not reach are zero, as C says; a string fills a char array with
; its bytes, then zeros.
(def %cc-gen-init-array!
  (fn (self at init)
    (def base (first at))
    (def off (first (rest at)))
    (def k (%cc-gen-place-kind at))
    (def n (first (rest k)))
    (def ek (kind-elem k))
    (def es (kind-size ek))
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
                          (do (%cc-gen-expr! item) (%cc-gen-put! (elem i))))))
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
    (if (%cc-gen-struct? (%cc-gen-place-kind at))
      (%cc-gen-init-struct! at init)
      (%cc-gen-init-array! at init))))

; A struct in the frame, from its initializer: a braced list stores its
; items in the fields' order, a nested list filling a nested aggregate, and
; the fields it does not reach are zero, as C says -- so the struct is
; zeroed first, which also leaves a union's other members as its first one's
; bytes make them.  An expression of the same struct is copied.
(def %cc-gen-init-struct!
  (fn (_ at init)
    (def base (first at))
    (def off (first (rest at)))
    (def k (%cc-gen-place-kind at))
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
                  (if (%cc-gen-bits? fk) (first (rest (rest (rest fk)))) (* 8 (kind-size fk))))
                ; a field that starts before the last one ends overlaps it,
                ; which is a union's: it takes one
                (if (< start end) (%cc-gen-no "more initializers than a union takes"))
                (do (if (%cc-gen-aggregate? fk)
                      (%cc-gen-init-aggregate! fat (first is))
                      (do (%cc-gen-expr! (first is)) (%cc-gen-put! fat)))
                    (fill (rest fs) (rest is) (+ start size)))))))
        (fill fields items 0)))))

; the same struct kind, or a refusal saying what the value was not
(def %cc-gen-same-struct!
  (fn (_ k node what)
    (let ((ks (%cc-gen-kind-of node)))
      (if (if (%cc-gen-struct? ks) (string=? (first (rest ks)) (first (rest k))) #f) ()
        (%cc-gen-no (string-append what " of something other than the same struct"))))))

; the struct at AT, a copy of the one SRC stands for
(def %cc-gen-copy-into!
  (fn (_ at src)
    (%cc-gen-same-struct! (%cc-gen-place-kind at) src "a struct initialized by")
    (do (%cc-gen-expr! src)
        (asm-push! %cc-gen-asm x0)
        (%cc-gen-address! (first at) (first (rest at)))
        (%cc-gen! (lit mov) x1 x0)
        (asm-pop! %cc-gen-asm x0)
        (%cc-gen-copy! (kind-size (%cc-gen-place-kind at))))))

; A struct assigned: the right one's bytes copied over the left's.  The
; left's address waits on the stack while the right's is worked out, and
; the answer is the left's address, which stands for the struct.
(def %cc-gen-struct-assign!
  (fn (_ lv rhs)
    (def k (%cc-gen-kind-of lv))
    (%cc-gen-same-struct! k rhs "an assignment to a struct")
    (do (%cc-gen-addr! lv)
        (asm-push! %cc-gen-asm x0)
        (%cc-gen-expr! rhs)
        (asm-pop! %cc-gen-asm x1)
        (%cc-gen-copy! (kind-size k))
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
    (def k (%cc-gen-place-kind at))
    (def base (first at))
    (def off (first (rest at)))
    (match
      ((%cc-gen-array? k)
        (let ((ek (kind-elem k)))
          (def go
            (fn (go i)
              (if (>= i (first (rest k))) ()
                (do (self (%cc-gen-place base (+ off (* i (kind-size ek))) ek))
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
    (do (%cc-gen-expr! node)
        (%cc-gen! (lit cmp) x0 (imm 0))
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

; a case label's value, in KIND: a constant, worked out now as a global's
; initializer is
(def %cc-gen-case-value
  (fn (_ node kind)
    (%cc-gen-form
      (guard (e (%cc-gen-no "a case label that is not a constant")) (%cc-gen-fold node))
      kind)))

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
            (if (%cc-gen-aggregate? (%cc-gen-place-kind at))
              (if (null? init) () (%cc-gen-init-aggregate! at init))
              (do (if (null? init) (%cc-gen-const! 0) (%cc-gen-expr! init))
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
        ; a struct is copied to where the caller asked for it, in the word
        ; the prologue brought down from the frame's top, and that address
        ; answers
        ((if (eq? t (lit return)) (%cc-gen-struct? %cc-gen-ret-kind) #f)
          (do (%cc-gen-same-struct! %cc-gen-ret-kind (first (rest node)) "a return")
              (%cc-gen-expr! (first (rest node)))
              (%cc-gen! (lit ldr) x1 (mem x19 %cc-gen-sret-slot))
              (%cc-gen-copy! (kind-size %cc-gen-ret-kind))
              (%cc-gen! (lit mov) x0 x1)
              (%cc-gen! (lit b) (label %cc-gen-epilogue))))
        ((eq? t (lit return))
          (do (if (null? (first (rest node)))
                (%cc-gen-const! 0)
                (%cc-gen-expr! (first (rest node))))
              ; the value converts to what the function returns
              (%cc-gen-convert! %cc-gen-ret-kind
                (if (null? (first (rest node))) (lit int) (%cc-gen-kind-of (first (rest node)))))
              (%cc-gen! (lit b) (label %cc-gen-epilogue))))
        ((eq? t (lit break))
          (%cc-gen! (lit b) (label (%cc-gen-loop-label "break"))))
        ((eq? t (lit continue))
          (%cc-gen! (lit b) (label (%cc-gen-loop-label "continue"))))
        ((eq? t (lit switch))
          ; the value is compared with each case label in turn: the first
          ; to match, else the default, else nothing, is where the body is
          ; entered, and the clauses after it run on until a break.  C
          ; promotes the value, and each label converts to its kind.
          (let ((out (%cc-gen-label)))
            (def e (first (rest node)))
            (def k (promoted-c-type (%cc-gen-kind-of e)))
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
              (let ((c-type (%cc-gen-kind! (first (rest (rest node))) "a local")))
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
    (def kinds (first (rest (rest (rest (rest f))))))
    (def ret (first (rest (rest (rest (rest (rest f)))))))
    (set! %cc-gen-ret-kind
      (match
        ((eq? ret (lit void)) ret)
        (#t (%cc-gen-kind! ret "a function returning something"))))
    (def sret? (%cc-gen-struct? %cc-gen-ret-kind))
    (set! %cc-gen-env ())
    (set! %cc-gen-frame-bytes 0)
    (set! %cc-gen-loops ())
    (set! %cc-gen-rslots ())
    (set! %cc-gen-labels ())
    (set! %cc-gen-placed ())
    (set! %cc-gen-epilogue (%cc-gen-label))
    ; The frame, from its base in x19 up: the slot the runtime writes a byte
    ; from; the parameters, the declarations that are not arrays or structs,
    ; and the word that says where a struct the function answers goes, each
    ; where a load reaches it; printf's area when the function calls it; the
    ; arrays and structs, reached through their address from any distance;
    ; and at the top, the arguments the caller stored there (%cc-gen-homes),
    ; which the prologue copies down into slots of their own, a struct
    ; excepted.
    (set! %cc-gen-scratch (%cc-gen-room! (lit long)))
    (def pkinds
      (let ((go (fn (self ks)
                  (if (null? ks) ()
                    (pair (%cc-gen-kind! (first ks) "a parameter") (self (rest ks)))))))
        (go kinds)))
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
    ; printf's area: to the digits' end, then a slot per argument after the
    ; format
    (def width
      (if (null? (%cc-gen-fun-find "printf")) (%cc-gen-printf-width body) 0))
    (def pf-slots (if (= width 0) 0 (+ (/ %cc-gen-pf-end 8) (- width 1))))
    (set! %cc-gen-pf (round-up %cc-gen-frame-bytes 8))
    (set! %cc-gen-frame-bytes (+ %cc-gen-pf (* 8 pf-slots)))
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
    (if (not (null? (first (rest (rest main))))) (%cc-gen-no "parameters to main"))
    (def others (filter (fn (_ f) (not (string=? (first (rest f)) "main"))) funs))
    ; the globals take the front of the data, before a body asks for one
    (set! %cc-gen-globals ())
    (set! %cc-gen-fixups ())
    (set! %cc-gen-pending ())
    (set! %cc-gen-strings ())
    (set! %cc-gen-databytes 0)
    (set! %cc-gen-data ())
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
    (set! %cc-gen-exit-at (%cc-gen-exit-back target))
    (set! %cc-gen-runtime-called ())
    (set! %cc-gen-heap-bytes 0)
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
    ; the runtime's malloc answers an address
    ; the runtime's functions the program does not define, and the C types
    ; they answer
    (set! %cc-gen-runtime-live
      (filter (fn (_ e) (null? (%cc-gen-fun-find (first e)))) %cc-gen-runtime))
    (let ((go (fn (self es)
                (if (null? es) ()
                  (do (set! %cc-gen-rets
                        (pair (pair (first (first es)) (first (rest (rest (first es)))))
                          %cc-gen-rets))
                      (self (rest es)))))))
      (go %cc-gen-runtime-live))
    ; a refusal can raise partway through; the buffer is released first
    (guard (err (do (asm-free! a)
                    (set! %cc-gen-asm ())
                    (error err (if (Err err? err) (err msg) "cc: compile failed"))))
      (let ((go (fn (self fs) (if (null? fs) () (do (%cc-gen-fun! (first fs)) (self (rest fs)))))))
        (do (go (pair main others))
            (%cc-gen-runtime-emit!))))
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
      (macho-write! path (first image) (rest image) %cc-gen-heap-bytes)
      (elf-write! path (first image) (rest image) elf-machine-x86-64 %cc-gen-heap-bytes))))

; compile SRC, run the executable, print what it wrote, answer its status
(def cc-exe-run
  (fn (_ src)
    (def path
      (string-append "/tmp/x-cc-exe-"
        (substring (sha256-hex-n src (byte-len src)) 0 16)))
    (cc-compile src path)
    (let ((r (proc-capture (list path))))
      (do (display (rest r)) (first r)))))

(provide cc/gen cc-compile cc-compile-image cc-exe-run)
