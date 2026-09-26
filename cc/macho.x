; # x-cc -- a C compiler on x-lang
;
; ## cc/macho.x -- the macOS executable container
;
; @author [Jon Ruttan](jonruttan@gmail.com)
; @copyright 2026 Jon Ruttan
; @license MIT No Attribution (MIT-0)
;
; An arm64 Mach-O executable, ad-hoc signed, with the load commands `ld`
; writes for a program that links nothing: dyld as the loader, libSystem
; named as a dependency, LC_MAIN for the entry, and the link-edit data --
; chained fixups with nothing to fix, an exports trie, a symbol table.  The
; kernel refuses a static executable and dyld refuses one that names no
; libSystem, although the program never calls into it: its runtime is
; system calls.
;
; Three segments carry it: __TEXT holds the header, the load commands and
; the code; __DATA follows on the next page, readable and writable, and
; holds the globals and the string literals, then runs on zero-filled
; through the heap when the program has one; __LINKEDIT holds the rest.
;
; The signature is a SuperBlob holding one CodeDirectory, big-endian, which
; hashes every 4096-byte page below the signature's own offset, the last one
; short.  Every byte in that range is final before the pages are hashed.
(module cc/macho)

(import cc/prims byte-at byte-len length sha256-hex-n sha256-jit! word-ref
  word-set!)
(import cc/image img-new img-u8! img-u16! img-u32! img-u64! img-be32! img-be64!
  img-bytes! img-ascii! img-write!)

(def %cc-macho-vmbase 0x100000000)
(def %cc-macho-segalign 16384)         ; the arm64 page
(def %cc-macho-ncmds 17)
(def %cc-macho-sizeofcmds 728)
(def %cc-macho-codeoff 760)            ; the code follows the load commands
(def %cc-macho-ident "cc")

(def %cc-macho-round-up
  (fn (_ n align) (let ((m (+ n (- align 1)))) (- m (% m align)))))

; Where the data goes, as a distance from the start of the code: the next
; page after the code, since a segment starts on one.  The generator asks for
; this to reach the data from the entry, and the writer lays it there.
(def macho-data-at
  (fn (_ codelen)
    (- (%cc-macho-round-up (+ %cc-macho-codeoff codelen) %cc-macho-segalign)
       %cc-macho-codeoff)))

; V as a two-byte ULEB128, for 128 <= V < 16384
(def %cc-macho-uleb2
  (fn (_ v) (list (| 128 (& v 127)) (& (>> v 7) 127))))

; LC_SEGMENT_64, with NSECTS section headers to follow
(def %cc-macho-segment!
  (fn (_ img at name vmaddr vmsize fileoff filesize prot nsects)
    (do (img-u32! img at 0x19)
        (img-u32! img (+ at 4) (+ 72 (* 80 nsects)))
        (img-ascii! img (+ at 8) name)
        (img-u64! img (+ at 24) vmaddr)
        (img-u64! img (+ at 32) vmsize)
        (img-u64! img (+ at 40) fileoff)
        (img-u64! img (+ at 48) filesize)
        (img-u32! img (+ at 56) prot)
        (img-u32! img (+ at 60) prot)
        (img-u32! img (+ at 64) nsects))))

; a load command whose body is an offset and a size in the file
(def %cc-macho-data-cmd!
  (fn (_ img at cmd off size)
    (do (img-u32! img at cmd)
        (img-u32! img (+ at 4) 16)
        (img-u32! img (+ at 8) off)
        (img-u32! img (+ at 12) size))))

(def %cc-macho-hexval
  (fn (_ c) (if (<= c 57) (- c 48) (if (<= c 70) (- c 55) (- c 87)))))

; the first N bytes a hex digest spells, into the image from AT
(def %cc-macho-put-hex!
  (fn (_ img at h n)
    (let ((go (fn (self i)
                (if (>= i n) ()
                  (do (img-u8! img (+ at i)
                        (+ (* 16 (%cc-macho-hexval (+ 0 (byte-at h (* 2 i)))))
                           (%cc-macho-hexval (+ 0 (byte-at h (+ (* 2 i) 1))))))
                      (self (+ i 1)))))))
      (go 0))))

; N bytes from SRC at OFF to DST, eight at a time
(def %cc-macho-copy!
  (fn (self dst src off i n)
    (if (>= i n) ()
      (do (word-set! dst i (word-ref src (+ off i)))
          (self dst src off (+ i 8) n)))))

; The digest of an all-zero page, computed once.  Every page between the end
; of the code and the link-edit data is zero, and a small program is mostly
; those.
(def %cc-macho-zero-hex ())
(def %cc-macho-zero-page-hex
  (fn (_)
    (do (if (null? %cc-macho-zero-hex)
          (set! %cc-macho-zero-hex (sha256-hex-n (first (img-new 4096)) 4096))
          ())
        %cc-macho-zero-hex)))

; CODE is the code, entry first; DATA the bytes of the data segment; HEAP
; how many bytes __DATA runs on past the data, at the data's next
; sixteen-byte boundary, which the kernel maps zero-filled.
; Writes the executable to PATH and answers its size in bytes.
(def macho-write!
  (fn (_ path code data heap)
    (def vmbase %cc-macho-vmbase)
    (def codeoff %cc-macho-codeoff)
    (def codelen (length code))
    (def datalen (length data))
    ; __TEXT ends where the data begins, and the data takes whole pages: a
    ; program with none still gets one, so every executable has the segment.
    (def dataoff (+ codeoff (macho-data-at codelen)))
    (def textsize dataoff)
    (def datasize
      (%cc-macho-round-up (if (= datalen 0) 1 datalen) %cc-macho-segalign))
    ; in memory the data runs on through the heap, so the link-edit data is
    ; mapped past it, where its file offset alone would not put it
    (def datavm
      (if (= heap 0) datasize
        (%cc-macho-round-up (+ (%cc-macho-round-up datalen 16) heap) %cc-macho-segalign)))
    (def linkedit (+ dataoff datasize))
    ; the link-edit data, in the order ld writes it
    (def fixups linkedit)
    (def trie (+ linkedit 56))
    (def starts (+ linkedit 104))
    (def symoff (+ linkedit 112))
    (def stroff (+ linkedit 144))
    (def sigoff (+ linkedit 176))
    (def idlen (+ (byte-len %cc-macho-ident) 1))
    (def nslots (/ (+ sigoff 4095) 4096))
    (def hashoff (+ 88 idlen))
    (def cdlen (+ hashoff (* nslots 32)))
    (def siglen (+ 20 cdlen))
    (def total (+ sigoff siglen))
    (def img (img-new total))

    ; mach_header_64
    (img-u32! img 0 0xFEEDFACF)
    (img-u32! img 4 0x0100000C)        ; CPU_TYPE_ARM64
    (img-u32! img 12 2)                ; MH_EXECUTE
    (img-u32! img 16 %cc-macho-ncmds)
    (img-u32! img 20 %cc-macho-sizeofcmds)
    (img-u32! img 24 0x200085)         ; NOUNDEFS DYLDLINK TWOLEVEL PIE

    ; the load commands
    (%cc-macho-segment! img 32 "__PAGEZERO" 0 vmbase 0 0 0 0)
    (%cc-macho-segment! img 104 "__TEXT" vmbase textsize 0 textsize 5 1)
    (img-ascii! img 176 "__text")
    (img-ascii! img 192 "__TEXT")
    (img-u64! img 208 (+ vmbase codeoff))
    (img-u64! img 216 codelen)
    (img-u32! img 224 codeoff)
    (img-u32! img 228 2)               ; aligned to 4
    (img-u32! img 240 0x80000400)      ; PURE_INSTRUCTIONS SOME_INSTRUCTIONS
    (%cc-macho-segment! img 256 "__DATA" (+ vmbase dataoff) datavm
      dataoff datasize 3 0)                ; read and write
    (%cc-macho-segment! img 328 "__LINKEDIT" (+ vmbase (+ dataoff datavm))
      (%cc-macho-round-up (- total linkedit) %cc-macho-segalign)
      linkedit (- total linkedit) 1 0)
    (%cc-macho-data-cmd! img 400 0x80000034 fixups 56)   ; LC_DYLD_CHAINED_FIXUPS
    (%cc-macho-data-cmd! img 416 0x80000033 trie 48)     ; LC_DYLD_EXPORTS_TRIE
    (img-u32! img 432 0x02)            ; LC_SYMTAB
    (img-u32! img 436 24)
    (img-u32! img 440 symoff)
    (img-u32! img 444 2)
    (img-u32! img 448 stroff)
    (img-u32! img 452 32)
    (img-u32! img 456 0x0B)            ; LC_DYSYMTAB
    (img-u32! img 460 80)
    (img-u32! img 476 2)               ; two defined external symbols
    (img-u32! img 480 2)               ; no undefined ones after them
    (img-u32! img 536 0x0E)            ; LC_LOAD_DYLINKER
    (img-u32! img 540 32)
    (img-u32! img 544 12)
    (img-ascii! img 548 "/usr/lib/dyld")
    (img-u32! img 568 0x1B)            ; LC_UUID, filled in once the code is in
    (img-u32! img 572 24)
    (img-u32! img 592 0x32)            ; LC_BUILD_VERSION: macOS, 12.0, no tools
    (img-u32! img 596 24)
    (img-u32! img 600 1)
    (img-u32! img 604 0x000C0000)
    (img-u32! img 608 0x000C0000)
    (img-u32! img 616 0x2A)            ; LC_SOURCE_VERSION
    (img-u32! img 620 16)
    (img-u32! img 632 0x80000028)      ; LC_MAIN
    (img-u32! img 636 24)
    (img-u64! img 640 codeoff)
    (img-u32! img 656 0x0C)            ; LC_LOAD_DYLIB
    (img-u32! img 660 56)
    (img-u32! img 664 24)
    (img-u32! img 668 2)
    (img-u32! img 672 0x00010000)
    (img-u32! img 676 0x00010000)
    (img-ascii! img 680 "/usr/lib/libSystem.B.dylib")
    (%cc-macho-data-cmd! img 712 0x26 starts 8)          ; LC_FUNCTION_STARTS
    (%cc-macho-data-cmd! img 728 0x29 symoff 0)          ; LC_DATA_IN_CODE
    (%cc-macho-data-cmd! img 744 0x1D sigoff siglen)     ; LC_CODE_SIGNATURE

    ; the code, then the data a page later
    (img-bytes! img codeoff code)
    (img-bytes! img dataoff data)

    ; chained fixups: the header, and a start table for three segments
    ; with no fixups in any of them
    (img-u32! img (+ fixups 4) 0x20)   ; starts
    (img-u32! img (+ fixups 8) 0x30)   ; imports
    (img-u32! img (+ fixups 12) 0x30)  ; symbols
    (img-u32! img (+ fixups 20) 1)     ; DYLD_CHAINED_IMPORT
    (img-u32! img (+ fixups 32) 3)

    ; the exports trie: __mh_execute_header at 0, _start at the entry
    (img-bytes! img trie (list 0 1 0x5F 0 18 0 0 0 0 2 0 0 0 3 0))
    (img-bytes! img (+ trie 15) (%cc-macho-uleb2 codeoff))
    (img-bytes! img (+ trie 17) (list 0 0 2))
    (img-ascii! img (+ trie 20) "_mh_execute_header")
    (img-u8! img (+ trie 39) 9)
    (img-ascii! img (+ trie 40) "start")
    (img-u8! img (+ trie 46) 13)

    ; function starts: the entry
    (img-bytes! img starts (%cc-macho-uleb2 codeoff))

    ; the symbol table and its strings
    (img-u32! img symoff 2)            ; __mh_execute_header
    (img-u8! img (+ symoff 4) 0x0F)    ; N_SECT N_EXT
    (img-u8! img (+ symoff 5) 1)
    (img-u16! img (+ symoff 6) 0x10)   ; REFERENCED_DYNAMICALLY
    (img-u64! img (+ symoff 8) vmbase)
    (img-u32! img (+ symoff 16) 22)    ; _start
    (img-u8! img (+ symoff 20) 0x0F)
    (img-u8! img (+ symoff 21) 1)
    (img-u64! img (+ symoff 24) (+ vmbase codeoff))
    (img-u8! img stroff 0x20)
    (img-ascii! img (+ stroff 2) "__mh_execute_header")
    (img-ascii! img (+ stroff 22) "_start")

    ; Signing digests every page of the file.  Pure x digests 2.4KB a second
    ; and the compiled engine costs about 4.5s to build, so it repays itself
    ; within the first few executables a process writes.
    (sha256-jit!)

    ; the UUID: sixteen bytes of a digest of the header, commands and code
    (%cc-macho-put-hex! img 576 (sha256-hex-n (first img) (+ codeoff codelen)) 16)

    ; the signature
    (def cd (+ sigoff 20))
    (img-be32! img sigoff 0xFADE0CC0)  ; embedded signature
    (img-be32! img (+ sigoff 4) siglen)
    (img-be32! img (+ sigoff 8) 1)
    (img-be32! img (+ sigoff 16) 20)   ; slot 0: the CodeDirectory
    (img-be32! img cd 0xFADE0C02)
    (img-be32! img (+ cd 4) cdlen)
    (img-be32! img (+ cd 8) 0x20400)
    (img-be32! img (+ cd 12) 2)        ; adhoc
    (img-be32! img (+ cd 16) hashoff)
    (img-be32! img (+ cd 20) 88)       ; identifier offset
    (img-be32! img (+ cd 28) nslots)
    (img-be32! img (+ cd 32) sigoff)   ; code limit
    (img-u8! img (+ cd 36) 32)         ; hash size
    (img-u8! img (+ cd 37) 2)          ; SHA-256
    (img-u8! img (+ cd 39) 12)         ; 4096-byte pages
    (img-be64! img (+ cd 72) textsize) ; executable segment limit
    (img-be64! img (+ cd 80) 1)        ; main binary
    (img-ascii! img (+ cd 88) %cc-macho-ident)

    ; The digest takes a prefix, not an offset.  Page zero is a prefix of the
    ; image as it stands; a page of the padding that follows the code, or the
    ; data, has a known digest; any other page is copied to a scratch buffer.
    (def code-end (%cc-macho-round-up (+ codeoff codelen) 4096))
    (def data-end (%cc-macho-round-up (+ dataoff datalen) 4096))
    (def padding? (fn (_ off from to) (if (>= off from) (<= (+ off 4096) to) #f)))
    (def scratch (img-new 4096))
    (def page-hex
      (fn (_ k)
        (let ((off (* k 4096)))
          (match
            ((= k 0) (sha256-hex-n (first img) 4096))
            ((padding? off code-end dataoff) (%cc-macho-zero-page-hex))
            ((padding? off data-end linkedit) (%cc-macho-zero-page-hex))
            (#t (let ((n (if (< (- sigoff off) 4096) (- sigoff off) 4096)))
                  (do (%cc-macho-copy! (rest scratch) (rest img) off 0 n)
                      (sha256-hex-n (first scratch) n))))))))
    (def hash-pages
      (fn (self k)
        (if (>= k nslots) ()
          (do (%cc-macho-put-hex! img (+ cd (+ hashoff (* k 32))) (page-hex k) 32)
              (self (+ k 1))))))
    (hash-pages 0)

    (img-write! img path total)
    total))

(provide cc/macho macho-write! macho-data-at)
