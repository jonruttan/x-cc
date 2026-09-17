; # x-cc -- a C compiler on x-lang
;
; ## cc/elf.x -- the Linux executable container
;
; @author [Jon Ruttan](jonruttan@gmail.com)
; @copyright 2026 Jon Ruttan
; @license MIT No Attribution (MIT-0)
;
; A static 64-bit ELF executable: the file header, one program header that
; maps the whole file readable and executable at a fixed address, then the
; code.  Linux runs a static executable directly, so there is no loader to
; name, nothing to link and no signature.

(def %cc-elf-base 0x400000)
(def %cc-elf-codeoff 120)          ; the 64-byte header and one 56-byte PT_LOAD

(def %cc-elf-machine-x86-64 62)

; BYTES is the code, entry first; MACHINE the e_machine value.
; Writes the executable to PATH and answers its size in bytes.
(def %cc-elf-write!
  (fn (_ path bytes machine)
    (def total (+ %cc-elf-codeoff (length bytes)))
    (def img (%cc-img-new total))
    (def entry (+ %cc-elf-base %cc-elf-codeoff))

    ; e_ident: magic, 64-bit, little-endian, version 1, System V
    (%cc-img-bytes! img 0 (list 0x7F 0x45 0x4C 0x46 2 1 1 0))
    (%cc-img-u16! img 16 2)                 ; ET_EXEC
    (%cc-img-u16! img 18 machine)
    (%cc-img-u32! img 20 1)                 ; EV_CURRENT
    (%cc-img-u64! img 24 entry)
    (%cc-img-u64! img 32 64)                ; program headers follow the header
    (%cc-img-u16! img 52 64)                ; header size
    (%cc-img-u16! img 54 56)                ; program header size
    (%cc-img-u16! img 56 1)                 ; one program header
    (%cc-img-u16! img 58 64)                ; section header size, none present

    ; PT_LOAD: the whole file, read and execute
    (%cc-img-u32! img 64 1)
    (%cc-img-u32! img 68 5)
    (%cc-img-u64! img 80 %cc-elf-base)      ; p_vaddr
    (%cc-img-u64! img 88 %cc-elf-base)      ; p_paddr
    (%cc-img-u64! img 96 total)             ; p_filesz
    (%cc-img-u64! img 104 total)            ; p_memsz
    (%cc-img-u64! img 112 0x1000)           ; p_align

    (%cc-img-bytes! img %cc-elf-codeoff bytes)
    (%cc-img-write! img path total)
    total))
