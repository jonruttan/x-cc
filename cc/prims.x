; # x-cc -- a C compiler on x-lang
;
; ## cc/prims.x -- the platform layer
;
; @author [Jon Ruttan](jonruttan@gmail.com)
; @copyright 2026 Jon Ruttan
; @license MIT No Attribution (MIT-0)
;
; The arc's rules throughout: byte doors per character, Vector for the
; O(1) memory the pointer model needs, no defs at depth in anything hot.

(import x/sys/file)
(import x/type/vector)

(provide cc/prims
  char->integer integer->char byte-at byte-len
  string-length substring string-append string-concat string=?
  list->string convert length reverse append map filter set-first!
  vec-make vec-ref vec-set!
  mem-make mem-ptr ptr-int word-ref word-set!
  file-read-all file-exists? file-write
  sys-exit sys-getenv)

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

(def file-read-all (fn (_ path) (File read-all path)))
(def file-exists? (fn (_ path) (File exists? path)))
(def file-write
  (fn (_ fd s) (File write fd s (string-length s))))
(def sys-exit (fn (_ n) (Sys exit n)))
(def sys-getenv (fn (_ n) (Sys getenv n)))
