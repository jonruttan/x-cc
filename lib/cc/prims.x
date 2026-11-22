; # x-cc -- a C compiler on x-lang
;
; ## cc/prims.x -- the platform layer
;
; @author [Jon Ruttan](jonruttan@gmail.com)
; @copyright 2026 Jon Ruttan
; @license MIT No Attribution (MIT-0)
;
; Performance rules throughout: byte doors per character, Vector for the
; O(1) memory the pointer model needs, no defs at depth in anything hot.
;
; A scoped module: these names are the bundle's, and a file that uses one
; imports it, so none of them is bound in the root beside another lang's.
(module cc/prims)

(import x/sys/file)
(import x/sys/proc)
(import x/type/vector)
(import x/codec/sha256)
(import x/tool/profile eval-count)
(import x/core/doors char->int int->char str-byte-ref str-byte-len str-make str->ptr
  ptr->int ptr-ref-word ptr-set-word! int->ptr ptr-set! ptr-ref
  int+ int- int* int< int<< int>> int& int|)

; The type handle this file asks convert for, fetched by name through the
; platform's public door and private to this module.
(def %string (Type named STRING))

(def char->integer char->int)
(def integer->char int->char)
(def byte-at str-byte-ref)
(def byte-len str-byte-len)

(def string-length (fn (_ s) (Str8 length s)))
(def substring (fn (_ s a b) (Str8 sub a (- b a) s)))
(def string=? (fn (_ a b) (str=? a b)))

(def %cvt (prim-ref (lit convert) (lit to)))
(def list->string (fn (_ l) (if (null? l) "" (%cvt l %string))))
(def convert (fn (_ v target . extra) (apply %cvt (pair v (pair target extra)))))

(def string-append (fn (_ . ss) (Str8 join "" ss)))
(def string-concat (fn (_ ss) (Str8 join "" ss)))

(def length (fn (_ l) (List length l)))
(def reverse (fn (_ l) (%cc-rev l ())))
; L reversed onto the front of ACC, in one pass: (append (reverse l) acc)
(def reverse-onto (fn (_ l acc) (%cc-rev l acc)))
(def %cc-rev
  (fn (self l acc)
    (if (null? l) acc (self (rest l) (pair (first l) acc)))))
(def append (fn (_ a b) (List append a b)))
(def map (fn (_ f l) (List map f l)))
(def filter (fn (_ p l) (List filter p l)))
(def set-first! %set-first!)

(def vec-make (fn (_ n fill) (Vector make n fill)))
(def vec-ref (fn (_ v i) (Vector ref i v)))
(def vec-set! (fn (_ v i x) (Vector set! i x v)))

; raw memory: a string is the buffer, its data pointer the base that
; the interpreter (ptr ref-word/set-word!, one prim per access) and
; compile-asm's %mem-ref-at/%mem-set-at! (the base as an int) share
(def mem-make str-make)
(def mem-ptr str->ptr)
(def ptr-int ptr->int)
(def word-ref ptr-ref-word)
(def word-set! ptr-set-word!)
; one byte at an offset; the str namespace has a byte reader and no writer
(def mem-set-byte! (fn (_ p i b) (ptr-set! p i (& b 255) 1)))
(def mem-ref-byte (fn (_ p i) (ptr-ref p i 1)))
; N bytes from the pointer SRC to the pointer DST at AT: a word at a time,
; then the bytes past the last whole word
(def mem-copy!
  (fn (_ dst at src n)
    (def words (fn (self i) (if (fx< n (fx+ i 8)) i (self (%mem-copy-word! dst at src i)))))
    (def bytes (fn (self i) (if (fx< i n) (self (%mem-copy-byte! dst at src i)) ())))
    (bytes (words 0))))
(def %mem-copy-word!
  (fn (_ dst at src i) (word-set! dst (fx+ at i) (word-ref src i)) (fx+ i 8)))
(def %mem-copy-byte!
  (fn (_ dst at src i) (mem-set-byte! dst (fx+ at i) (mem-ref-byte src i)) (fx+ i 1)))
; W bytes at an offset, W one of 1 2 4 8; a read is zero-extended, so a
; signed type sign-extends it itself
(def mem-ref-at ptr-ref)
(def mem-set-at! ptr-set!)
; N bytes from a pointer, each set to B: one C memset
(def mem-fill! (prim-ref (lit mem) (lit set)))
; an address as a pointer
(def int-ptr int->ptr)

; the heap's live objects -- a walk of the whole heap -- and a collection
; of what is not live; there is no automatic one
(def heap-count (fn (_) (Heap count)))
(def heap-collect (fn (_) (Heap collect)))
; the evaluations the engine has made, a counter it keeps: a clock that does
; not grow with the heap, though a read costs about a thousand evaluations
(def evals (fn (_) (eval-count)))

; The engine's integer prims, for what run does at every step: an address,
; an offset, a width, a C integer's value.  They cost no heap objects where
; the platform's operators cost 9 to 366 a use, since those check their
; operands and promote past a machine word.  These do neither -- a nil
; operand crashes the engine and a result past a word wraps, as a C long
; does -- so they take only what is an integer by construction.  There is
; no > or >=: a > b is (fx< b a), and a >= b is (not (fx< a b)).
(def fx+ int+)
(def fx- int-)
(def fx* int*)
(def fx< int<)
(def fx<< int<<)
(def fx>> int>>)
(def fx& int&)
(def fx| int|)
; there is no exclusive or among them: the bits in either but not both
(def fx^ (fn (_ x y) (fx- (fx| x y) (fx& x y))))

; the first N bytes of a buffer, digested
(def sha256-hex-n (fn (_ s n) (Sha256 hex-n s n)))
; build the compiled digest engine once; pure x carries on if it cannot
(def sha256-jit! (fn (_) (Sha256 jit!)))

; run argv as a child: (status . stdout)
(def proc-capture (fn (_ argv) (Proc capture argv)))

(def file-read-all (fn (_ path) (File read-all path)))
(def file-exists? (fn (_ path) (File exists? path)))
; up to N bytes from FD into BUF, a string; how many, 0 at the end
(def file-read (fn (_ fd buf n) (File read fd buf n)))
; PATH opened for reading: its fd, or below zero; FD moved to OFFSET; FD closed
(def file-open-read (fn (_ path) (File open path (lit rdonly))))
(def file-seek (fn (_ fd offset) (File seek fd offset)))
(def file-close (fn (_ fd) (File close fd)))
(def file-write
  (fn (_ fd s) (File write fd s (string-length s))))
; N bytes of a buffer to PATH, created or truncated, mode 0755
(def file-write-exec!
  (fn (_ path buf n)
    (def fd (File open path (list (lit wronly) (lit creat) (lit trunc)) 493))
    (if (< fd 0)
      (Err raise (lit cc) (string-append "cc: cannot write " path) ())
      (do (File write fd buf n) (File close fd)))))
; the text S to PATH, created or truncated, mode 0644
(def file-write-text!
  (fn (_ path s)
    (def fd (File open path (list (lit wronly) (lit creat) (lit trunc)) 420))
    (if (< fd 0)
      (Err raise (lit cc) (string-append "cc: cannot write " path) ())
      (do (File write fd s (string-length s)) (File close fd)))))
(def sys-exit (fn (_ n) (Sys exit n)))
(def sys-getenv (fn (_ n) (Sys getenv n)))

; x's own write.  cc/base rebinds the root's to print token lists bare, and
; loads this module first so the one kept here is the original, which is
; what an error or a value outside the C program is printed with.
(def x-write write)

(provide cc/prims
  char->integer integer->char byte-at byte-len
  string-length substring string-append string-concat string=?
  list->string convert length reverse reverse-onto append map filter set-first!
  vec-make vec-ref vec-set!
  mem-make mem-ptr ptr-int word-ref word-set! mem-set-byte! mem-ref-byte mem-copy!
  mem-ref-at mem-set-at! mem-fill! int-ptr heap-count heap-collect evals fx+ fx- fx* fx< fx<< fx>>
  fx& fx| fx^
  fx& fx| fx^
  file-close file-open-read file-read file-read-all file-seek file-exists? file-write
  file-write-exec! file-write-text!
  sha256-hex-n sha256-jit! proc-capture
  sys-exit sys-getenv x-write)
