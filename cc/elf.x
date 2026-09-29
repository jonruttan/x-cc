; # x-cc -- a C compiler on x-lang
;
; ## cc/elf.x -- the Linux executable container
;
; @author [Jon Ruttan](jonruttan@gmail.com)
; @copyright 2026 Jon Ruttan
; @license MIT No Attribution (MIT-0)
;
; A 64-bit ELF executable that the C library is loaded into: the file
; header, four program headers, the loader's path, then the code and the
; data.  The first program header names the loader, ld-linux; the second
; maps the headers, the path and the code readable and executable at a
; fixed address; the third maps the data readable and writable on the next
; page; the fourth points the loader at the dynamic section.  The data ends
; with what the loader reads: the dynamic section, which names libc.so.6
; and libm.so.6, where glibc keeps the maths functions, and where the rest
; is; a symbol table, the program's imports each an
; undefined function; their names; a hash table with every bucket empty,
; since the program defines nothing for anyone to find; and a relocation
; for each import's slot, which the loader fills with the function's
; address before it jumps to the entry.
(module cc/elf)

(import cc/prims append byte-at byte-len length reverse)
(import cc/image img-new img-u8! img-u16! img-u32! img-u64! img-bytes! img-write!)

(def %cc-elf-base 0x400000)
(def %cc-elf-interp "/lib64/ld-linux-x86-64.so.2")
(def %cc-elf-codeoff 320)          ; the header, four program headers, the path
(def %cc-elf-pagesize 4096)

(def elf-machine-x86-64 62)

; Where the data goes, as a distance from the start of the code: the next
; page after it, since a segment's file offset and address agree there.  The
; generator asks for this to reach the data from the entry.
(def elf-data-at
  (fn (_ codelen)
    (let ((end (+ %cc-elf-codeoff codelen)))
      (let ((m (+ end (- %cc-elf-pagesize 1))))
        (- (- m (% m %cc-elf-pagesize)) %cc-elf-codeoff)))))

; a program header at AT: TYPE, FLAGS, and the file range OFF..OFF+FILESZ
; mapped at the base plus OFF, MEMSZ long
(def %cc-elf-phdr!
  (fn (_ img at type flags off filesz memsz align)
    (do (img-u32! img at type)
        (img-u32! img (+ at 4) flags)
        (img-u64! img (+ at 8) off)
        (img-u64! img (+ at 16) (+ %cc-elf-base off))
        (img-u64! img (+ at 24) (+ %cc-elf-base off))
        (img-u64! img (+ at 32) filesz)
        (img-u64! img (+ at 40) memsz)
        (img-u64! img (+ at 48) align))))

; CODE is the code, entry first; DATA the bytes of the data segment; MACHINE
; the e_machine value; IMPORTS the slots in the data the loader fills with
; the C library's functions, each (OFFSET . NAME).
; Writes the executable to PATH and answers its size in bytes.
(def elf-write!
  (fn (_ path code data machine imports)
    (def codelen (length code))
    (def datalen (length data))
    (def dataoff (+ %cc-elf-codeoff (elf-data-at codelen)))
    (def n (length imports))
    ; the names: a NUL, libc.so.6, libm.so.6, then each import's
    (def names
      (let ((go (fn (self is at acc offs)
                  (if (null? is) (pair acc (reverse offs))
                    (let ((s (rest (first is))))
                      (self (rest is) (+ at (+ (byte-len s) 1))
                        (append acc (append (%cc-elf-ascii s) (list 0)))
                        (pair at offs)))))))
        (go imports 21
          (append (list 0)
            (append (%cc-elf-ascii "libc.so.6")
              (append (list 0) (append (%cc-elf-ascii "libm.so.6") (list 0)))))
          ())))
    (def strsz (length (first names)))
    ; the loader's tables, after the data at eight-byte boundaries
    (def dyn (* 8 (/ (+ dataoff datalen 7) 8)))
    (def ndyn 12)
    (def symtab (+ dyn (* 16 ndyn)))
    (def strtab (+ symtab (* 24 (+ n 1))))
    (def hash (* 8 (/ (+ strtab strsz 7) 8)))
    (def rela (+ hash (* 4 (+ 3 (+ n 1)))))
    (def relasz (* 24 n))
    (def total (* 8 (/ (+ rela relasz 7) 8)))
    (def img (img-new total))
    (def entry (+ %cc-elf-base %cc-elf-codeoff))
    (def addr (fn (_ off) (+ %cc-elf-base off)))

    ; e_ident: magic, 64-bit, little-endian, version 1, System V
    (img-bytes! img 0 (list 0x7F 0x45 0x4C 0x46 2 1 1 0))
    (img-u16! img 16 2)                 ; ET_EXEC
    (img-u16! img 18 machine)
    (img-u32! img 20 1)                 ; EV_CURRENT
    (img-u64! img 24 entry)
    (img-u64! img 32 64)                ; program headers follow the header
    (img-u16! img 52 64)                ; header size
    (img-u16! img 54 56)                ; program header size
    (img-u16! img 56 4)                 ; four program headers
    (img-u16! img 58 64)                ; section header size, none present

    ; PT_INTERP, then the code's PT_LOAD, read and execute, from the start
    (%cc-elf-phdr! img 64 3 4 288 (+ (byte-len %cc-elf-interp) 1)
      (+ (byte-len %cc-elf-interp) 1) 1)
    (%cc-elf-phdr! img 120 1 5 0 (+ %cc-elf-codeoff codelen)
      (+ %cc-elf-codeoff codelen) %cc-elf-pagesize)
    ; the data's PT_LOAD, read and write, through the loader's tables: the
    ; offset and the address agree modulo the page, which is what the
    ; kernel asks of a mapping
    (%cc-elf-phdr! img 176 1 6 dataoff (- total dataoff) (- total dataoff) %cc-elf-pagesize)
    ; PT_DYNAMIC
    (%cc-elf-phdr! img 232 2 6 dyn (* 16 ndyn) (* 16 ndyn) 8)
    (img-bytes! img 288 (%cc-elf-ascii %cc-elf-interp))

    (img-bytes! img %cc-elf-codeoff code)
    (img-bytes! img dataoff data)

    ; the dynamic section
    (def tag!
      (fn (_ k tag v)
        (do (img-u64! img (+ dyn (* 16 k)) tag)
            (img-u64! img (+ dyn (+ (* 16 k) 8)) v))))
    (tag! 0 1 1)                        ; DT_NEEDED libc.so.6
    (tag! 1 1 11)                       ; DT_NEEDED libm.so.6
    (tag! 2 4 (addr hash))              ; DT_HASH
    (tag! 3 5 (addr strtab))            ; DT_STRTAB
    (tag! 4 6 (addr symtab))            ; DT_SYMTAB
    (tag! 5 10 strsz)                   ; DT_STRSZ
    (tag! 6 11 24)                      ; DT_SYMENT
    (tag! 7 7 (addr rela))              ; DT_RELA
    (tag! 8 8 relasz)                   ; DT_RELASZ
    (tag! 9 9 24)                       ; DT_RELAENT
    (tag! 10 24 0)                      ; DT_BIND_NOW
    (tag! 11 0 0)                       ; DT_NULL

    ; the symbols: the null one, then each import, an undefined global
    ; function; the relocations fill each slot with its symbol's address
    (let ((go (fn (self is k offs)
                (if (null? is) ()
                  (let ((sym (+ symtab (* 24 k))) (r (+ rela (* 24 (- k 1)))))
                    (do (img-u32! img sym (first offs))
                        (img-u8! img (+ sym 4) 0x12)
                        (img-u64! img r (addr (+ dataoff (first (first is)))))
                        (img-u64! img (+ r 8) (+ (* k 4294967296) 6))  ; R_X86_64_GLOB_DAT
                        (self (rest is) (+ k 1) (rest offs))))))))
      (go imports 1 (rest names)))
    (img-bytes! img strtab (first names))
    ; the hash table: one bucket, empty, and a chain entry per symbol
    (img-u32! img hash 1)
    (img-u32! img (+ hash 4) (+ n 1))

    (img-write! img path total)
    total))

; the bytes of ASCII text S
(def %cc-elf-ascii
  (fn (_ s)
    (let ((go (fn (self i) (if (>= i (byte-len s)) () (pair (+ 0 (byte-at s i)) (self (+ i 1)))))))
      (go 0))))

(provide cc/elf elf-write! elf-data-at elf-machine-x86-64)
