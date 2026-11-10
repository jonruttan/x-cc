; # x-cc -- a C compiler on x-lang
;
; ## cc/link.x -- the linker: objects to an executable
;
; @author [Jon Ruttan](jonruttan@gmail.com)
; @copyright 2026 Jon Ruttan
; @license MIT No Attribution (MIT-0)
;
; Each unit compiles to an object (cc/gen): its code and data as sections,
; its functions and globals as symbols, and every place that takes a name
; of another unit's, or one of the linker's own, as a relocation.  The
; link lays the objects out as one program through x/tool/link, with a
; runtime object of its own in front: the entry, the trampoline into the
; C library, the gate the library comes back in through, a thunk for each
; function whose address is taken, the setjmp and longjmp routines, the
; routine that writes the addresses the data's pointers start at, and in
; the data an import slot for each function of the C library the units
; call, exit's first, and the word the frame stack's top is kept in.  The
; executable is then the container's (cc/macho, cc/elf): the text at the
; front of the file, the data on the page after it.
(module cc/link)

(import x/tool/asm)
(import x/type/dict)
(import x/tool/link link link-undefined link-write! link-read)
(import cc/prims append byte-at byte-len convert filter length map mem-copy! mem-make mem-ptr
  mem-set-byte! proc-capture reverse sha256-hex-n string-append string-concat string=?
  substring heap-collect)
(import cc/gen cc-compile-unit cc-target cc-target-arm64? cc-elf-machine cc-libc-has?)
(import cc/eval library-trampoline-arm64)
(import cc/macho macho-write! macho-data-at macho-code-at)
(import cc/elf elf-write! elf-data-at elf-code-at)

(def %string (Type named STRING))
(def %symbol (Type named SYMBOL))

(def %cc-link-no
  (fn (_ what) (Err raise (lit cc) (string-append "cc: link: " what) ())))

(def %cc-link-le32
  (fn (_ w) (list (& w 255) (& (>> w 8) 255) (& (>> w 16) 255) (& (>> w 24) 255))))

(def %cc-link-cat
  (fn (self pieces)
    (if (null? pieces) () (append (first pieces) (self (rest pieces))))))

; does S end in SUFFIX
(def %cc-link-ends?
  (fn (_ s suffix)
    (def n (byte-len s))
    (def m (byte-len suffix))
    (if (< n m) #f (string=? (substring s (- n m) n) suffix))))

; S without its last N bytes
(def %cc-link-strip (fn (_ s n) (substring s 0 (- (byte-len s) n))))

; the frames' region below the machine stack (cc/gen's %cc-gen-region)
(def %cc-link-region 4194304)

; --- the runtime object ----------------------------------------------------------
; Assembled like a unit, with the pieces the portable mnemonics do not
; spell -- the trampoline, the gate's register saves, the setjmp and
; longjmp routines -- as raw bytes: each is emitted as nops of its length
; at its place and its bytes put over them once the code is copied out,
; since the assembler's buffer is executable, and not writable, after
; finalize.

(def %cc-link-asm ())
(def %cc-link-raws ())      ; ((position . bytes) ...), the raw pieces

(def %cc-link! (fn (_ . args) (apply asm-emit! (pair %cc-link-asm args))))

; the symbol NAME, a string, as the assembler's label
(def %cc-link-label (fn (_ name) (label (convert name %symbol))))
(def %cc-link-label! (fn (_ name) (asm-label! %cc-link-asm (convert name %symbol))))

; BYTES, a list of byte values, at the position: nops now, the bytes later
(def %cc-link-raw!
  (fn (_ arm64? bytes)
    (set! %cc-link-raws (pair (pair (asm-pos %cc-link-asm) bytes) %cc-link-raws))
    (def go
      (fn (self n) (if (> n 0) (do (%cc-link! (lit nop)) (self (- n 1))) ())))
    (go (if arm64? (>> (length bytes) 2) (length bytes)))))

(def %cc-link-words! (fn (_ ws) (%cc-link-raw! #t (%cc-link-cat (map %cc-link-le32 ws)))))

; The entry: calls main and hands what it answers to the C library's exit,
; whose slot is the data's first eight bytes, so exit writes out what the
; library's streams hold.  It puts the trampoline's address in x21, where
; nothing the generator emits touches it, and the data's in x22; points
; x20 at the frames' region below the machine stack, and moves the stack
; below the region; and before main, with main's arguments kept, calls the
; routine that writes the addresses the data's pointers start at.  main is
; handed argc in x0 and argv in x1, as any call's first two arguments:
; dyld calls a Mach-O's entry as it would main, with the two already there,
; and an ELF's entry loads them from the stack the kernel starts it on,
; argc on top and the pointers after it.
(def %cc-link-entry!
  (fn (_ target)
    (def arm64? (cc-target-arm64? target))
    (match
      ; ldr x0, [sp]; add x1, sp, #8
      ((eq? target (lit elf-arm64)) (%cc-link-words! (list 0xF94003E0 0x910023E1)))
      ; mov rax, [rsp]; lea rsi, [rsp+8]
      ((eq? target (lit elf-x86-64))
        (%cc-link-raw! #f (list 0x48 0x8B 0x04 0x24 0x48 0x8D 0x74 0x24 0x08)))
      (#t ()))
    (asm-adr-far! %cc-link-asm x21 (lit @tramp))
    (asm-adr-far! %cc-link-asm x22 (lit @data))
    (asm-push! %cc-link-asm x0)
    (asm-push! %cc-link-asm x1)
    (%cc-link! (if arm64? (lit bl) (lit call)) (label (lit @fixups)))
    (asm-pop! %cc-link-asm x1)
    (asm-pop! %cc-link-asm x0)
    (if arm64?
      ; mov x20, sp; sub sp, sp, #4M
      (%cc-link-words! (list 0x910003F4 (| 0xD14003FF (<< (/ %cc-link-region 4096) 10))))
      ; mov r12, rsp; sub rsp, 4M
      (%cc-link-raw! #f (append (list 0x49 0x89 0xE4 0x48 0x81 0xEC) (%cc-link-le32 %cc-link-region))))
    (%cc-link! (if arm64? (lit bl) (lit call)) (label (lit main)))
    (if arm64?
      ; ldr x16, [x22]; br x16
      (%cc-link-words! (list 0xF94002D0 0xD61F0200))
      ; mov rdi, rax; mov r11, [r14]; and rsp, -16; call r11
      (%cc-link-raw! #f (list 0x48 0x89 0xC7 0x4D 0x8B 0x1E 0x48 0x83 0xE4 0xF0 0x41 0xFF 0xD3)))))

; The trampoline into the C library.  Compiled code calls it with x0 the
; address of six eight-byte integer arguments and four doubles after them,
; and x8 the function; it loads the arguments where the C calling
; convention takes them -- the integers in the general registers, the
; doubles in d0 to d3 -- gives the stack the sixteen-byte alignment the
; convention asks for, and calls the function, whose answer comes back in
; x0, or in d0 for a double.  arm64's is cc/eval's
; library-trampoline-arm64, which also copies the area's stack words onto
; the stack and loads x6 and x7; x86-64's indirect call puts x0 in rdi on
; the way in: push rbp; mov rbp, rsp; and rsp, -16; mov r11, rdi; mov rcx,
; [r11+128]; lea rax, [rcx*8+15]; and rax, -16; sub rsp, rax -- room for
; the stack words; lea rsi, [r11+136]; mov rdi, rsp; rep movsq -- the
; words copied up; mov rdi, [r11]; mov rsi, [r11+8]; mov rdx, [r11+16];
; mov rcx, [r11+24]; mov r8, [r11+32]; mov r9, [r11+40]; movsd
; xmm0..xmm3, [r11+64..88]; xor eax, eax; call r10; mov rsp, rbp; pop
; rbp; ret
(def %cc-link-trampoline!
  (fn (_ target)
    (%cc-link-label! "@tramp")
    (if (cc-target-arm64? target)
      (%cc-link-words! library-trampoline-arm64)
      (%cc-link-raw! #f
        (list 0x55 0x48 0x89 0xE5 0x48 0x83 0xE4 0xF0 0x49 0x89 0xFB
              0x49 0x8B 0x8B 0x80 0x00 0x00 0x00
              0x48 0x8D 0x04 0xCD 0x0F 0x00 0x00 0x00 0x48 0x83 0xE0 0xF0
              0x48 0x29 0xC4
              0x49 0x8D 0xB3 0x88 0x00 0x00 0x00 0x48 0x89 0xE7 0xF3 0x48 0xA5
              0x49 0x8B 0x3B 0x49 0x8B 0x73 0x08 0x49 0x8B 0x53 0x10
              0x49 0x8B 0x4B 0x18 0x4D 0x8B 0x43 0x20 0x4D 0x8B 0x4B 0x28
              0xF2 0x41 0x0F 0x10 0x43 0x40 0xF2 0x41 0x0F 0x10 0x4B 0x48
              0xF2 0x41 0x0F 0x10 0x53 0x50 0xF2 0x41 0x0F 0x10 0x5B 0x58
              0x31 0xC0 0x41 0xFF 0xD2 0x48 0x89 0xEC 0x5D 0xC3)))))

; The thunks and the gate.  A pointer to a function is its thunk's
; address, one for the program: the thunk takes the function's address
; into x8 and branches to the gate, which is the way in for the C library;
; the program's own calls through a pointer come in at its last
; instruction, twelve bytes in, a branch to the function.  The gate takes
; registers the portable model does not name: it keeps the caller's x19
; to x22, which the C calling convention has the callee keep; takes up the
; program's own -- the data and the trampoline from where it stands, the
; frame stack's top from where the last call out left it -- and keeps that
; slot to put back; moves the arguments into the program's registers (on
; x86-64: rax from rdi, rcx from rdx); calls the function; and puts
; everything back.  A pointer between the first thunk and the gate is the
; program's own; the generator compares against both (@thunks, @gate).
(def %cc-link-thunks!
  (fn (_ target names)
    (def arm64? (cc-target-arm64? target))
    (%cc-link-label! "@thunks")
    (def go
      (fn (self ns)
        (if (null? ns) ()
          (do (%cc-link-label! (string-append (first ns) "@thunk"))
              (asm-adr-far! %cc-link-asm x8 (convert (first ns) %symbol))
              (%cc-link! (lit b) (label (lit @gate)))
              (%cc-link! (lit b) (%cc-link-label (first ns)))
              (self (rest ns))))))
    (go names)
    (%cc-link-label! "@gate")
    (if arm64?
      (do (%cc-link-words! (list 0xA9BF7BFD 0xA9BF53F3 0xA9BF5BF5))
          (asm-adr-far! %cc-link-asm x22 (lit @data))
          (asm-adr-far! %cc-link-asm x21 (lit @tramp))
          (%cc-link-words!
            (list 0xF94006D4 0xF94006C9 0xF81F0FE9 0xD63F0100 0xF84107E9 0xF90006C9
                  0xA8C15BF5 0xA8C153F3 0xA8C17BFD 0xD65F03C0)))
      (do (%cc-link-raw! #f (list 0x53 0x41 0x54 0x41 0x55 0x41 0x56))
          (asm-adr-far! %cc-link-asm x22 (lit @data))
          (asm-adr-far! %cc-link-asm x21 (lit @tramp))
          (%cc-link-raw! #f
            (list 0x4D 0x8B 0x66 0x08 0x41 0xFF 0x76 0x08 0x48 0x89 0xF8
                  0x48 0x89 0xD1 0x41 0xFF 0xD2 0x41 0x8F 0x46 0x08
                  0x41 0x5E 0x41 0x5D 0x41 0x5C 0x5B 0xC3))))))

; setjmp and longjmp, when the units call them: the C library's setjmp
; keeps the frame of the function that calls it, which here is the gate's,
; gone by the time a longjmp comes back to it.  Each is a routine of the
; compiler's own, called by the program's convention, with the jmp_buf in
; x0: setjmp keeps x19 and x20 (the frame's base and the frame stack's
; top), the machine stack's pointer as the call left it, and the address
; the call returns to, and answers 0; longjmp, with its value in x1, puts
; all four back and returns to that address with the value -- 1 for a 0.
; A function keeps nothing in a register across a call, so those four are
; the whole of where the setjmp's caller stood.
(def %cc-link-jumps!
  (fn (_ target names)
    (def arm64? (cc-target-arm64? target))
    (def routine
      (fn (_ name)
        (%cc-link-label! (string-append name "@cc"))
        (if arm64?
          (%cc-link-words!
            (if (string=? name "setjmp")
              ; stp x19, x20, [x0]; add x9, sp, #0; stp x9, x30, [x0, #16];
              ; movz x0, #0; ret
              (list 0xA9005013 0x910003E9 0xA9017809 0xD2800000 0xD65F03C0)
              ; ldp x19, x20, [x0]; ldp x9, x30, [x0, #16]; add sp, x9, #0;
              ; cmp x1, #0; csinc x0, x1, xzr, ne; ret
              (list 0xA9405013 0xA9417809 0x9100013F 0xF100003F 0x9A9F1420 0xD65F03C0)))
          (%cc-link-raw! #f
            (if (string=? name "setjmp")
              ; mov [rax], rbx; mov [rax+8], r12; lea r11, [rsp+8];
              ; mov [rax+16], r11; mov r11, [rsp]; mov [rax+24], r11;
              ; xor eax, eax; ret
              (list 0x48 0x89 0x18 0x4C 0x89 0x60 0x08 0x4C 0x8D 0x5C 0x24 0x08
                    0x4C 0x89 0x58 0x10 0x4C 0x8B 0x1C 0x24 0x4C 0x89 0x58 0x18
                    0x31 0xC0 0xC3)
              ; mov rbx, [rax]; mov r12, [rax+8]; mov r11, [rax+24];
              ; mov rsp, [rax+16]; mov rax, rsi; test rax, rax; jnz +5;
              ; mov eax, 1; jmp r11
              (list 0x48 0x8B 0x18 0x4C 0x8B 0x60 0x08 0x4C 0x8B 0x58 0x18
                    0x48 0x8B 0x60 0x10 0x48 0x89 0xF0 0x48 0x85 0xC0 0x75 0x05
                    0xB8 0x01 0x00 0x00 0x00 0x41 0xFF 0xE3))))))
    (map routine names)))

; The routine that writes the addresses the data's pointers start at,
; which the entry calls before main: x22 is the data's address only at
; run time.  Each pointer is a relocation of a unit's, (pointer data),
; (pointer text) or (pointer slot), at an offset in that unit's data,
; which the linker names @dataN for the Nth object; the address it starts
; at is an address in the data, a function's thunk's, or what the C
; library's import slot holds.  Every one is a relocation of this
; routine's own, resolved with the rest.
(def %cc-link-fixups!
  (fn (_ objects)
    (%cc-link-label! "@fixups")
    (def site!
      (fn (_ i off)
        (do (%cc-link! (lit mov) x1 x22)
            (%cc-link-reloc! (list (lit imm64)) (string-append "@data" (convert i %string)) off)
            (asm-load-imm64! %cc-link-asm x2 0)
            (%cc-link! (lit add) x1 x1 x2))))
    ; an address in the data: a name the unit's own -- its data section,
    ; a static global -- is taken as its offset from @dataN, which is
    ; the linker's name for the same place, since a local symbol of one
    ; object cannot be named from another
    (def local-of
      (fn (_ symbols name)
        (def go
          (fn (self ss)
            (match
              ((null? ss) ())
              ((if (string=? (first (first ss)) name)
                 (if (eq? (first (rest (first ss))) (lit data))
                   (eq? (first (rest (rest (rest (first ss))))) (lit local))
                   #f)
                 #f)
                (first (rest (rest (first ss)))))
              (#t (self (rest ss))))))
        (go symbols)))
    (def value!
      (fn (_ i symbols what name addend)
        (match
          ((eq? what (lit text)) (asm-adr-far! %cc-link-asm x0 (convert name %symbol)))
          ((eq? what (lit slot))
            (do (%cc-link-reloc! (list (lit imm64)) name 0)
                (asm-load-imm64! %cc-link-asm x0 0)
                (%cc-link! (lit add) x0 x0 x22)
                (%cc-link! (lit ldr) x0 (mem x0 0))))
          (#t
            (let ((off (local-of symbols name)))
              (do (%cc-link! (lit mov) x0 x22)
                  (if (null? off)
                    (%cc-link-reloc! (list (lit imm64)) name addend)
                    (%cc-link-reloc! (list (lit imm64)) (string-append "@data" (convert i %string))
                      (+ off addend)))
                  (asm-load-imm64! %cc-link-asm x2 0)
                  (%cc-link! (lit add) x0 x0 x2)))))))
    (def go
      (fn (self os i)
        (if (null? os) ()
          (do (map (fn (_ r)
                     (if (if (pair? (first (rest (rest r)))) (eq? (first (first (rest (rest r)))) (lit pointer)) #f)
                       (do (site! i (first (rest r)))
                           (value! i (first (rest (first os))) (first (rest (first (rest (rest r)))))
                             (first (rest (rest (rest r)))) (first (rest (rest (rest (rest r))))))
                           (%cc-link! (lit str) x0 (mem x1 0)))
                       ()))
                (first (rest (rest (first os)))))
              ; an engine's tables of functions are thousands of pointers,
              ; and nothing else collects their garbage
              (heap-collect)
              (self (rest os) (+ i 1))))))
    (go objects 1)
    (%cc-link! (lit ret))))

; the runtime object's relocations, as a unit's
(def %cc-link-relocs ())
(def %cc-link-reloc!
  (fn (_ kind name addend)
    (set! %cc-link-relocs
      (pair (list (lit text) (asm-pos %cc-link-asm) kind name addend) %cc-link-relocs))))

; The runtime object for TARGET, in front of OBJECTS: its text the entry,
; the fixups routine, the trampoline, the thunks of the functions THUNKS
; names, the gate and the routines JUMPS names; its data a slot for each
; import SLOTS names, exit's first, the frame stack's top word after it.
; Answers (OBJECT . IMPORTS), IMPORTS each (OFFSET . NAME) in slot order.
(def %cc-link-runtime
  (fn (_ target objects slots thunks jumps)
    (def arm64? (cc-target-arm64? target))
    (def names (pair "exit" (filter (fn (_ s) (not (string=? s "exit"))) slots)))
    ; exit at 0, the frame stack's top at 8, the rest from 16
    (def slot-symbols
      (let ((go (fn (self ns at acc)
                  (if (null? ns) (reverse acc)
                    (self (rest ns) (+ at 8)
                      (pair (list (string-append (first ns) "@slot") (lit data) (if (= at 0) 0 (+ at 8)) (lit global))
                        acc))))))
        (go names 0 ())))
    (def datasize (+ 16 (* 8 (- (length names) 1))))
    ; room for the fixups routine, some sixty bytes a pointer, and the rest
    (def npointers
      (let ((go (fn (self os n)
                  (if (null? os) n
                    (self (rest os)
                      (+ n (length (filter (fn (_ r) (if (pair? (first (rest (rest r)))) (eq? (first (first (rest (rest r)))) (lit pointer)) #f))
                                     (first (rest (rest (first os))))))))))))
        (go objects 0)))
    (def a (asm-new (+ 65536 (* 64 npointers) (* 32 (length thunks)))))
    (set! %cc-link-asm a)
    (set! %cc-link-raws ())
    (set! %cc-link-relocs ())
    (guard (err (do (asm-free! a) (set! %cc-link-asm ()) (error err (if (Err err? err) (err msg) "cc: link failed"))))
      (do (%cc-link-entry! target)
          (%cc-link-fixups! objects)
          (%cc-link-trampoline! target)
          (%cc-link-thunks! target thunks)
          (%cc-link-jumps! target jumps)))
    ; the branches and addresses naming the units' labels, as relocations
    (def patches
      (map (fn (_ p)
             (list (lit text) (first p)
               (list (lit patch) (first (rest p)) (first (rest (rest p))))
               (convert (first (rest (rest (rest p)))) %string) 0))
        (asm-unresolved! a (list (lit arm64-adrp) (lit arm64-lo12)))))
    (def symbols
      (map (fn (_ l) (list (convert (first l) %string) (lit text) (rest l) (lit global)))
        (asm-labels a)))
    (def n (asm-pos a))
    (def p (asm-finalize! a))
    (def text (mem-make n))
    (mem-copy! (mem-ptr text) 0 p n)
    (asm-free! a)
    (set! %cc-link-asm ())
    ; the raw pieces over their nops
    (let ((poke (fn (self at bs)
                  (if (null? bs) ()
                    (do (mem-set-byte! (mem-ptr text) at (first bs)) (self (+ at 1) (rest bs)))))))
      (map (fn (_ r) (poke (first r) (rest r))) %cc-link-raws))
    (pair
      (list (list (list (lit text) 16 n text) (list (lit data) 16 datasize ()))
            (append (list (list "@data" (lit data) 0 (lit global))) (append slot-symbols symbols))
            (append (reverse %cc-link-relocs) patches))
      (map (fn (_ s) (pair (first (rest (rest s))) (%cc-link-strip (first s) 5))) slot-symbols))))

; --- the link ---------------------------------------------------------------------

; what a name of the linker's own asks for: (slot . NAME), (thunk . NAME)
; or (jump . NAME), or nil for a unit's
(def %cc-link-ask
  (fn (_ name)
    (match
      ((%cc-link-ends? name "@slot") (pair (lit slot) (%cc-link-strip name 5)))
      ((%cc-link-ends? name "@thunk") (pair (lit thunk) (%cc-link-strip name 6)))
      ((%cc-link-ends? name "@cc") (pair (lit jump) (%cc-link-strip name 3)))
      (#t ()))))

(def %cc-link-asks
  (fn (_ names what)
    (map rest
      (filter (fn (_ a) (if (null? a) #f (eq? (first a) what))) (map %cc-link-ask names)))))

; is NAME a unit's own: the linker's names, and a static function's as
; the units name it for the linker, carry an @
(def %cc-link-own-name?
  (fn (_ name)
    (def go
      (fn (self i)
        (match ((>= i (byte-len name)) #t) ((= (byte-at name i) #\@) #f) (#t (self (+ i 1))))))
    (go 0)))

; the global symbols OBJECTS define, ((NAME . SECTION) ...)
(def %cc-link-globals
  (fn (_ objects)
    (def go
      (fn (self os acc)
        (if (null? os) (reverse acc)
          (self (rest os)
            ((fn (self2 ss acc2)
               (if (null? ss) acc2
                 (let ((s (first ss)))
                   (self2 (rest ss)
                     (if (if (null? (first (rest s))) #f (eq? (first (rest (rest (rest s)))) (lit global)))
                       (pair (pair (first s) (first (rest s))) acc2)
                       acc2)))))
             (first (rest (first os))) acc)))))
    (go objects ())))

(def %cc-link-assoc
  (fn (_ name es)
    (def go (fn (self es)
              (match ((null? es) ()) ((string=? (first (first es)) name) (first es)) (#t (self (rest es))))))
    (go es)))

; What ASK exports -- nil, `all`, or names -- each (NAME . text) for a
; function, whose thunk is then made, or (NAME . data) for a global, among
; GLOBALS; a name none defines refuses.
(def %cc-link-exports
  (fn (_ ask globals)
    (if (eq? ask (lit all))
      (filter (fn (_ g) (%cc-link-own-name? (first g))) globals)
      (map (fn (_ name)
             (let ((g (%cc-link-assoc name globals)))
               (if (null? g)
                 (Err raise (lit cc) (string-append "cc: compile: exported symbol not defined: " name) ())
                 g)))
        ask))))

; Each object's data section as a global symbol the runtime's fixups
; routine names, @dataN for the Nth object from 1
(def %cc-link-named
  (fn (_ objects)
    (def go
      (fn (self os i acc)
        (if (null? os) (reverse acc)
          (let ((o (first os)))
            (self (rest os) (+ i 1)
              (pair (list (first o)
                      (pair (list (string-append "@data" (convert i %string)) (lit data) 0 (lit global))
                        (first (rest o)))
                      (first (rest (rest o))))
                acc))))))
    (go objects 1 ())))

; The executable's image for OBJECTS on TARGET, exporting what ASK says:
; (TEXT DATA IMPORTS EXPORTS), TEXT and DATA each (LENGTH . BUFFER), IMPORTS
; each (OFFSET . NAME) in slot order, EXPORTS each (NAME text . OFFSET) or
; (NAME data . OFFSET).  The runtime object goes first, so the entry is
; the text's first byte and exit's slot the data's.  The units' names
; resolve among themselves; a name of the linker's own -- a slot, a
; thunk, a routine -- is made for it; a function both a unit and the C
; library have, called through a prototype from another unit, refuses,
; since that call was compiled as the library's.
(def cc-link-image
  (fn (_ objects target ask)
    (def units (%cc-link-named objects))
    (def globals (%cc-link-globals units))
    (if (null? (%cc-link-assoc "main" globals)) (%cc-link-no "not built yet: a program without main"))
    (def exports (%cc-link-exports ask globals))
    ; each link-undefined builds the symbol tables anew, tens of millions
    ; of objects for an engine's sixty-four units: asked once, and the
    ; garbage collected at each stage, since nothing else collects it
    (def undefined (link-undefined units))
    (heap-collect)
    (def slots (%cc-link-asks undefined (lit slot)))
    (map (fn (_ s)
           (let ((g (%cc-link-assoc s globals)))
             (if (if (null? g) #f (eq? (rest g) (lit text)))
               (%cc-link-no (string-append s " is both the program's and the C library's")))))
      slots)
    (def thunks
      (let ((asked (%cc-link-asks undefined (lit thunk))))
        (append asked
          (filter (fn (_ n) (null? (filter (fn (_ t) (string=? t n)) asked)))
            (map first (filter (fn (_ e) (eq? (rest e) (lit text))) exports))))))
    (def jumps (%cc-link-asks undefined (lit jump)))
    (def rt (%cc-link-runtime target units slots thunks jumps))
    (def all (pair (first rt) units))
    ; what the units leave undefined that the runtime object does not define
    (def defines
      (map first (filter (fn (_ s) (not (null? (first (rest s))))) (first (rest (first rt))))))
    (map (fn (_ n)
           (if (null? (filter (fn (_ d) (string=? d n)) defines))
             (%cc-link-no (string-append "undefined: " n))
             ()))
      undefined)
    (heap-collect)
    ; where the container puts the sections: the text at its code offset,
    ; the data on the page after the code
    (def arm64? (cc-target-arm64? target))
    (def code-at (if (eq? target (lit macho-arm64)) (macho-code-at) (elf-code-at)))
    (def data-address 0)
    (def addresses
      (fn (_ sizes)
        (def codelen (rest (%cc-link-assq (lit text) sizes)))
        (set! data-address
          (+ code-at
            (if (eq? target (lit macho-arm64))
              (macho-data-at codelen)
              (elf-data-at codelen (cc-elf-machine target)))))
        (list (pair (lit text) code-at) (pair (lit data) data-address))))
    (def patch
      (fn (_ p o kind value site)
        (match
          ((eq? (first kind) (lit patch))
            (let ((w (first (rest kind))) (t (first (rest (rest kind)))))
              (match
                ((eq? t (lit arm64-adrp)) (asm-patch-adrp! p o (- (>> value 12) (>> site 12))))
                ((eq? t (lit arm64-lo12)) (asm-patch-lo12! p o value))
                (#t (asm-patch-at! p o w t (- value (- site o)))))))
          ((eq? (first kind) (lit imm64)) (asm-reloc-at! p o (- value data-address)))
          (#t ()))))
    (def r (link all addresses patch))
    (def sections (first r))
    (def symbols (first (rest r)))
    (def section-of
      (fn (_ name)
        (def s (%cc-link-assq name sections))
        (if (null? s) (pair 0 ()) (pair (first (rest (rest s))) (first (rest (rest (rest s))))))))
    (list
      (section-of (lit text))
      (section-of (lit data))
      (rest rt)
      (map (fn (_ e)
             (if (eq? (rest e) (lit text))
               (pair (first e) (pair (lit text) (first (rest (symbols get (string-append (first e) "@thunk"))))))
               (pair (first e) (pair (lit data) (first (rest (symbols get (first e))))))))
        exports))))

(def %cc-link-assq
  (fn (_ key es)
    (def go (fn (self es)
              (match ((null? es) ()) ((eq? (first (first es)) key) (first es)) (#t (self (rest es))))))
    (go es)))

; OBJECTS linked for TARGET into the executable at PATH, exporting what ASK
; says (cc-link-image)
(def cc-link
  (fn (_ objects target path ask)
    (def image (cc-link-image objects target ask))
    (def text (first image))
    (def data (first (rest image)))
    (def imports (first (rest (rest image))))
    (def exports (first (rest (rest (rest image)))))
    (if (eq? target (lit macho-arm64))
      (macho-write! path text data imports exports)
      (elf-write! path text data (cc-elf-machine target) imports exports))))

; --- the compiler's doors ----------------------------------------------------------

; the units of SRC: one file's text, or a list of (PATH . TEXT)
(def %cc-link-units
  (fn (_ src) (if (str? src) (list src) (map (fn (_ u) (list u)) src))))

; the image of SRC on TARGET: (TEXT . DATA), each (LENGTH . BUFFER).
; EXPORTS, when given, is what the executable exports: nil, `all` or names.
(def cc-compile-image
  (fn (_ src target . more)
    (def ask (if (null? more) () (first more)))
    (def image
      (cc-link-image (map (fn (_ u) (cc-compile-unit u target)) (%cc-link-units src)) target ask))
    (pair (first image) (first (rest image)))))

; compile SRC to an executable at PATH, exporting EXPORTS when given
(def cc-compile
  (fn (_ src path . more)
    (def target (cc-target))
    (cc-link (map (fn (_ u) (cc-compile-unit u target)) (%cc-link-units src)) target path
      (if (null? more) () (first more)))))

; compile SRC and run the executable with INPUT as its standard input and
; the rest of ARGV after its name, which is its path; print what it wrote,
; answer its status.  With INPUT nil, it reads the caller's standard input.
; EXPORTS, when given, is what the executable exports (cc-compile).
(def cc-exe-run-with
  (fn (_ src input argv . more)
    ; a program of several files is named for their texts together
    (def text (if (str? src) src (string-concat (map (fn (_ u) (rest u)) src))))
    (def path
      (string-append "/tmp/x-cc-exe-"
        (substring (sha256-hex-n text (byte-len text)) 0 16)))
    (cc-compile src path (if (null? more) () (first more)))
    (let ((r (proc-capture
               (if (null? input)
                 (pair path (rest argv))
                 (append (list "/bin/sh" "-c" "i=$1; shift; printf %s \"$i\" | \"$@\""
                           "sh" input path)
                   (rest argv))))))
      (do (display (rest r)) (first r)))))

; compile SRC, run the executable, print what it wrote, answer its status
(def cc-exe-run (fn (_ src) (cc-exe-run-with src () (list "a.out"))))

(provide cc/link cc-link cc-link-image cc-compile cc-compile-image cc-exe-run cc-exe-run-with)
