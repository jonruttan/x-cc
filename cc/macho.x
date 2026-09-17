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
; The signature is a SuperBlob holding one CodeDirectory, big-endian, which
; hashes every 4096-byte page below the signature's own offset, the last one
; short.  Every byte in that range is final before the pages are hashed.

(def %cc-macho-vmbase 0x100000000)
(def %cc-macho-segalign 16384)         ; the arm64 page
(def %cc-macho-ncmds 16)
(def %cc-macho-sizeofcmds 656)
(def %cc-macho-codeoff 688)            ; the code follows the load commands
(def %cc-macho-ident "cc")

(def %cc-macho-round-up
  (fn (_ n align) (let ((m (+ n (- align 1)))) (- m (% m align)))))

; V as a two-byte ULEB128, for 128 <= V < 16384
(def %cc-macho-uleb2
  (fn (_ v) (list (| 128 (& v 127)) (& (>> v 7) 127))))

; LC_SEGMENT_64, with NSECTS section headers to follow
(def %cc-macho-segment!
  (fn (_ img at name vmaddr vmsize fileoff filesize prot nsects)
    (do (%cc-img-u32! img at 0x19)
        (%cc-img-u32! img (+ at 4) (+ 72 (* 80 nsects)))
        (%cc-img-ascii! img (+ at 8) name)
        (%cc-img-u64! img (+ at 24) vmaddr)
        (%cc-img-u64! img (+ at 32) vmsize)
        (%cc-img-u64! img (+ at 40) fileoff)
        (%cc-img-u64! img (+ at 48) filesize)
        (%cc-img-u32! img (+ at 56) prot)
        (%cc-img-u32! img (+ at 60) prot)
        (%cc-img-u32! img (+ at 64) nsects))))

; a load command whose body is an offset and a size in the file
(def %cc-macho-data-cmd!
  (fn (_ img at cmd off size)
    (do (%cc-img-u32! img at cmd)
        (%cc-img-u32! img (+ at 4) 16)
        (%cc-img-u32! img (+ at 8) off)
        (%cc-img-u32! img (+ at 12) size))))

(def %cc-macho-hexval
  (fn (_ c) (if (<= c 57) (- c 48) (if (<= c 70) (- c 55) (- c 87)))))

; the first N bytes a hex digest spells, into the image from AT
(def %cc-macho-put-hex!
  (fn (_ img at h n)
    (let ((go (fn (self i)
                (if (>= i n) ()
                  (do (%cc-img-u8! img (+ at i)
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
          (set! %cc-macho-zero-hex (sha256-hex-n (first (%cc-img-new 4096)) 4096))
          ())
        %cc-macho-zero-hex)))

; BYTES is the code, entry first.
; Writes the executable to PATH and answers its size in bytes.
(def %cc-macho-write!
  (fn (_ path bytes)
    (def vmbase %cc-macho-vmbase)
    (def codeoff %cc-macho-codeoff)
    (def codelen (length bytes))
    (def textsize (%cc-macho-round-up (+ codeoff codelen) %cc-macho-segalign))
    ; the link-edit data, in the order ld writes it
    (def fixups textsize)
    (def trie (+ textsize 56))
    (def starts (+ textsize 104))
    (def symoff (+ textsize 112))
    (def stroff (+ textsize 144))
    (def sigoff (+ textsize 176))
    (def idlen (+ (byte-len %cc-macho-ident) 1))
    (def nslots (/ (+ sigoff 4095) 4096))
    (def hashoff (+ 88 idlen))
    (def cdlen (+ hashoff (* nslots 32)))
    (def siglen (+ 20 cdlen))
    (def total (+ sigoff siglen))
    (def img (%cc-img-new total))

    ; mach_header_64
    (%cc-img-u32! img 0 0xFEEDFACF)
    (%cc-img-u32! img 4 0x0100000C)        ; CPU_TYPE_ARM64
    (%cc-img-u32! img 12 2)                ; MH_EXECUTE
    (%cc-img-u32! img 16 %cc-macho-ncmds)
    (%cc-img-u32! img 20 %cc-macho-sizeofcmds)
    (%cc-img-u32! img 24 0x200085)         ; NOUNDEFS DYLDLINK TWOLEVEL PIE

    ; the load commands
    (%cc-macho-segment! img 32 "__PAGEZERO" 0 vmbase 0 0 0 0)
    (%cc-macho-segment! img 104 "__TEXT" vmbase textsize 0 textsize 5 1)
    (%cc-img-ascii! img 176 "__text")
    (%cc-img-ascii! img 192 "__TEXT")
    (%cc-img-u64! img 208 (+ vmbase codeoff))
    (%cc-img-u64! img 216 codelen)
    (%cc-img-u32! img 224 codeoff)
    (%cc-img-u32! img 228 2)               ; aligned to 4
    (%cc-img-u32! img 240 0x80000400)      ; PURE_INSTRUCTIONS SOME_INSTRUCTIONS
    (%cc-macho-segment! img 256 "__LINKEDIT" (+ vmbase textsize)
      (%cc-macho-round-up (- total textsize) %cc-macho-segalign)
      textsize (- total textsize) 1 0)
    (%cc-macho-data-cmd! img 328 0x80000034 fixups 56)   ; LC_DYLD_CHAINED_FIXUPS
    (%cc-macho-data-cmd! img 344 0x80000033 trie 48)     ; LC_DYLD_EXPORTS_TRIE
    (%cc-img-u32! img 360 0x02)            ; LC_SYMTAB
    (%cc-img-u32! img 364 24)
    (%cc-img-u32! img 368 symoff)
    (%cc-img-u32! img 372 2)
    (%cc-img-u32! img 376 stroff)
    (%cc-img-u32! img 380 32)
    (%cc-img-u32! img 384 0x0B)            ; LC_DYSYMTAB
    (%cc-img-u32! img 388 80)
    (%cc-img-u32! img 404 2)               ; two defined external symbols
    (%cc-img-u32! img 408 2)               ; no undefined ones after them
    (%cc-img-u32! img 464 0x0E)            ; LC_LOAD_DYLINKER
    (%cc-img-u32! img 468 32)
    (%cc-img-u32! img 472 12)
    (%cc-img-ascii! img 476 "/usr/lib/dyld")
    (%cc-img-u32! img 496 0x1B)            ; LC_UUID, filled in once the code is in
    (%cc-img-u32! img 500 24)
    (%cc-img-u32! img 520 0x32)            ; LC_BUILD_VERSION: macOS, 12.0, no tools
    (%cc-img-u32! img 524 24)
    (%cc-img-u32! img 528 1)
    (%cc-img-u32! img 532 0x000C0000)
    (%cc-img-u32! img 536 0x000C0000)
    (%cc-img-u32! img 544 0x2A)            ; LC_SOURCE_VERSION
    (%cc-img-u32! img 548 16)
    (%cc-img-u32! img 560 0x80000028)      ; LC_MAIN
    (%cc-img-u32! img 564 24)
    (%cc-img-u64! img 568 codeoff)
    (%cc-img-u32! img 584 0x0C)            ; LC_LOAD_DYLIB
    (%cc-img-u32! img 588 56)
    (%cc-img-u32! img 592 24)
    (%cc-img-u32! img 596 2)
    (%cc-img-u32! img 600 0x00010000)
    (%cc-img-u32! img 604 0x00010000)
    (%cc-img-ascii! img 608 "/usr/lib/libSystem.B.dylib")
    (%cc-macho-data-cmd! img 640 0x26 starts 8)          ; LC_FUNCTION_STARTS
    (%cc-macho-data-cmd! img 656 0x29 symoff 0)          ; LC_DATA_IN_CODE
    (%cc-macho-data-cmd! img 672 0x1D sigoff siglen)     ; LC_CODE_SIGNATURE

    ; the code
    (%cc-img-bytes! img codeoff bytes)

    ; chained fixups: the header, and a start table for three segments
    ; with no fixups in any of them
    (%cc-img-u32! img (+ fixups 4) 0x20)   ; starts
    (%cc-img-u32! img (+ fixups 8) 0x30)   ; imports
    (%cc-img-u32! img (+ fixups 12) 0x30)  ; symbols
    (%cc-img-u32! img (+ fixups 20) 1)     ; DYLD_CHAINED_IMPORT
    (%cc-img-u32! img (+ fixups 32) 3)

    ; the exports trie: __mh_execute_header at 0, _start at the entry
    (%cc-img-bytes! img trie (list 0 1 0x5F 0 18 0 0 0 0 2 0 0 0 3 0))
    (%cc-img-bytes! img (+ trie 15) (%cc-macho-uleb2 codeoff))
    (%cc-img-bytes! img (+ trie 17) (list 0 0 2))
    (%cc-img-ascii! img (+ trie 20) "_mh_execute_header")
    (%cc-img-u8! img (+ trie 39) 9)
    (%cc-img-ascii! img (+ trie 40) "start")
    (%cc-img-u8! img (+ trie 46) 13)

    ; function starts: the entry
    (%cc-img-bytes! img starts (%cc-macho-uleb2 codeoff))

    ; the symbol table and its strings
    (%cc-img-u32! img symoff 2)            ; __mh_execute_header
    (%cc-img-u8! img (+ symoff 4) 0x0F)    ; N_SECT N_EXT
    (%cc-img-u8! img (+ symoff 5) 1)
    (%cc-img-u16! img (+ symoff 6) 0x10)   ; REFERENCED_DYNAMICALLY
    (%cc-img-u64! img (+ symoff 8) vmbase)
    (%cc-img-u32! img (+ symoff 16) 22)    ; _start
    (%cc-img-u8! img (+ symoff 20) 0x0F)
    (%cc-img-u8! img (+ symoff 21) 1)
    (%cc-img-u64! img (+ symoff 24) (+ vmbase codeoff))
    (%cc-img-u8! img stroff 0x20)
    (%cc-img-ascii! img (+ stroff 2) "__mh_execute_header")
    (%cc-img-ascii! img (+ stroff 22) "_start")

    ; Signing digests every page of the file.  Pure x digests 2.4KB a second
    ; and the compiled engine costs about 4.5s to build, so it repays itself
    ; within the first few executables a process writes.
    (sha256-jit!)

    ; the UUID: sixteen bytes of a digest of the header, commands and code
    (%cc-macho-put-hex! img 504 (sha256-hex-n (first img) (+ codeoff codelen)) 16)

    ; the signature
    (def cd (+ sigoff 20))
    (%cc-img-be32! img sigoff 0xFADE0CC0)  ; embedded signature
    (%cc-img-be32! img (+ sigoff 4) siglen)
    (%cc-img-be32! img (+ sigoff 8) 1)
    (%cc-img-be32! img (+ sigoff 16) 20)   ; slot 0: the CodeDirectory
    (%cc-img-be32! img cd 0xFADE0C02)
    (%cc-img-be32! img (+ cd 4) cdlen)
    (%cc-img-be32! img (+ cd 8) 0x20400)
    (%cc-img-be32! img (+ cd 12) 2)        ; adhoc
    (%cc-img-be32! img (+ cd 16) hashoff)
    (%cc-img-be32! img (+ cd 20) 88)       ; identifier offset
    (%cc-img-be32! img (+ cd 28) nslots)
    (%cc-img-be32! img (+ cd 32) sigoff)   ; code limit
    (%cc-img-u8! img (+ cd 36) 32)         ; hash size
    (%cc-img-u8! img (+ cd 37) 2)          ; SHA-256
    (%cc-img-u8! img (+ cd 39) 12)         ; 4096-byte pages
    (%cc-img-be64! img (+ cd 72) textsize) ; executable segment limit
    (%cc-img-be64! img (+ cd 80) 1)        ; main binary
    (%cc-img-ascii! img (+ cd 88) %cc-macho-ident)

    ; The digest takes a prefix, not an offset.  Page zero is a prefix of the
    ; image as it stands; a zero page between the code and the link-edit data
    ; has a known digest; any other page is copied to a scratch buffer.
    (def code-end (%cc-macho-round-up (+ codeoff codelen) 4096))
    (def scratch (%cc-img-new 4096))
    (def page-hex
      (fn (_ k)
        (let ((off (* k 4096)))
          (match
            ((= k 0) (sha256-hex-n (first img) 4096))
            ((if (>= off code-end) (<= (+ off 4096) textsize) #f)
              (%cc-macho-zero-page-hex))
            (#t (let ((n (if (< (- sigoff off) 4096) (- sigoff off) 4096)))
                  (do (%cc-macho-copy! (rest scratch) (rest img) off 0 n)
                      (sha256-hex-n (first scratch) n))))))))
    (def hash-pages
      (fn (self k)
        (if (>= k nslots) ()
          (do (%cc-macho-put-hex! img (+ cd (+ hashoff (* k 32))) (page-hex k) 32)
              (self (+ k 1))))))
    (hash-pages 0)

    (%cc-img-write! img path total)
    total))
