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

; The type handle this file asks convert for, fetched by name through the
; platform's public door and private to this module.
(def %string (Type named STRING))

(def char->integer (prim-ref (lit char) (lit ->int)))
(def integer->char (prim-ref (lit int) (lit ->char)))
(def byte-at (prim-ref (lit str) (lit byte-ref)))
(def byte-len (prim-ref (lit str) (lit byte-len)))

(def string-length (fn (_ s) (Str8 length s)))
(def substring (fn (_ s a b) (Str8 sub a (- b a) s)))
(def string=? (fn (_ a b) (str=? a b)))

(def %cvt (prim-ref (lit convert) (lit to)))
(def list->string (fn (_ l) (if (null? l) "" (%cvt l %string))))
(def convert (fn (_ v target . extra) (apply %cvt (pair v (pair target extra)))))

(def string-append (fn (_ . ss) (string-concat ss)))
(def string-concat
  (fn (self ss)
    (if (null? ss)
      ""
      (if (null? (rest ss)) (first ss) (Str8 append (first ss) (self (rest ss)))))))

(def length (fn (_ l) (List length l)))
(def reverse (fn (_ l) (%cc-rev l ())))
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
(def mem-make (prim-ref (lit str) (lit make)))
(def mem-ptr (prim-ref (lit str) (lit ->ptr)))
(def ptr-int (prim-ref (lit ptr) (lit ->int)))
(def word-ref (prim-ref (lit ptr) (lit ref-word)))
(def word-set! (prim-ref (lit ptr) (lit set-word!)))
; one byte at an offset; the str namespace has a byte reader and no writer
(def %cc-ptr-set (prim-ref (lit ptr) (lit set!)))
(def mem-set-byte! (fn (_ p i b) (%cc-ptr-set p i (& b 255) 1)))
(def %cc-ptr-ref (prim-ref (lit ptr) (lit ref)))
(def mem-ref-byte (fn (_ p i) (%cc-ptr-ref p i 1)))
; W bytes at an offset, W one of 1 2 4 8; a read is zero-extended, so a
; signed type sign-extends it itself
(def mem-ref-at (fn (_ p i w) (%cc-ptr-ref p i w)))
(def mem-set-at! (fn (_ p i v w) (%cc-ptr-set p i v w)))

; The engine's integer prims, for what run does at every step: an address,
; an offset, a width, a C integer's value.  They cost no heap objects where
; the platform's operators cost 9 to 366 a use, since those check their
; operands and promote past a machine word.  These do neither -- a nil
; operand crashes the engine and a result past a word wraps, as a C long
; does -- so they take only what is an integer by construction.  There is
; no > or >=: a > b is (fx< b a), and a >= b is (not (fx< a b)).
(def fx+ (prim-ref (lit int) (lit +)))
(def fx- (prim-ref (lit int) (lit -)))
(def fx* (prim-ref (lit int) (lit *)))
(def fx< (prim-ref (lit int) (lit <)))
(def fx<< (prim-ref (lit int) (lit <<)))
(def fx>> (prim-ref (lit int) (lit >>)))

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
(def sys-exit (fn (_ n) (Sys exit n)))
(def sys-getenv (fn (_ n) (Sys getenv n)))

; x's own write.  cc/base rebinds the root's to print token lists bare, and
; loads this module first so the one kept here is the original, which is
; what an error or a value outside the C program is printed with.
(def x-write write)

(provide cc/prims
  char->integer integer->char byte-at byte-len
  string-length substring string-append string-concat string=?
  list->string convert length reverse append map filter set-first!
  vec-make vec-ref vec-set!
  mem-make mem-ptr ptr-int word-ref word-set! mem-set-byte! mem-ref-byte
  mem-ref-at mem-set-at! fx+ fx- fx* fx< fx<< fx>>
  file-close file-open-read file-read file-read-all file-seek file-exists? file-write
  file-write-exec!
  sha256-hex-n sha256-jit! proc-capture
  sys-exit sys-getenv x-write)
