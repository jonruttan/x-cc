; # x-cc -- a C compiler on x-lang
;
; ## cc/elf.x -- the Linux executable container
;
; @author [Jon Ruttan](jonruttan@gmail.com)
; @copyright 2026 Jon Ruttan
; @license MIT No Attribution (MIT-0)
;
; A static 64-bit ELF executable: the file header, two program headers, then
; the code and the data.  The first maps the header and the code readable and
; executable at a fixed address, the second maps the data readable and
; writable on the next page.  Linux runs a static executable directly, so
; there is no loader to name, nothing to link and no signature.

(def %cc-elf-base 0x400000)
(def %cc-elf-codeoff 176)          ; the 64-byte header and two 56-byte PT_LOADs
(def %cc-elf-pagesize 4096)

(def %cc-elf-machine-x86-64 62)

; Where the data goes, as a distance from the start of the code: the next
; page after it, since a segment's file offset and address agree there.  The
; generator asks for this to reach the data from the entry.
(def %cc-elf-data-at
  (fn (_ codelen)
    (let ((end (+ %cc-elf-codeoff codelen)))
      (let ((m (+ end (- %cc-elf-pagesize 1))))
        (- (- m (% m %cc-elf-pagesize)) %cc-elf-codeoff)))))

; CODE is the code, entry first; DATA the bytes of the data segment; MACHINE
; the e_machine value.
; Writes the executable to PATH and answers its size in bytes.
(def %cc-elf-write!
  (fn (_ path code data machine)
    (def codelen (length code))
    (def datalen (length data))
    (def dataoff (+ %cc-elf-codeoff (%cc-elf-data-at codelen)))
    (def total (+ dataoff datalen))
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
    (%cc-img-u16! img 56 2)                 ; two program headers
    (%cc-img-u16! img 58 64)                ; section header size, none present

    ; PT_LOAD: the header and the code, read and execute
    (%cc-img-u32! img 64 1)
    (%cc-img-u32! img 68 5)
    (%cc-img-u64! img 80 %cc-elf-base)      ; p_vaddr
    (%cc-img-u64! img 88 %cc-elf-base)      ; p_paddr
    (%cc-img-u64! img 96 (+ %cc-elf-codeoff codelen))    ; p_filesz
    (%cc-img-u64! img 104 (+ %cc-elf-codeoff codelen))   ; p_memsz
    (%cc-img-u64! img 112 %cc-elf-pagesize) ; p_align

    ; PT_LOAD: the data, read and write.  A program with none still gets the
    ; page, so every executable has the segment: the offset and the address
    ; agree modulo the page, which is what the kernel asks of a mapping.
    (%cc-img-u32! img 120 1)
    (%cc-img-u32! img 124 6)
    (%cc-img-u64! img 128 dataoff)          ; p_offset
    (%cc-img-u64! img 136 (+ %cc-elf-base dataoff))      ; p_vaddr
    (%cc-img-u64! img 144 (+ %cc-elf-base dataoff))      ; p_paddr
    (%cc-img-u64! img 152 datalen)          ; p_filesz
    (%cc-img-u64! img 160 (if (= datalen 0) %cc-elf-pagesize datalen))
    (%cc-img-u64! img 168 %cc-elf-pagesize) ; p_align

    (%cc-img-bytes! img %cc-elf-codeoff code)
    (%cc-img-bytes! img dataoff data)
    (%cc-img-write! img path total)
    total))
