; # x-cc -- a C compiler on x-lang
;
; ## cc/real.x -- the real floating types, float and double
;
; @author [Jon Ruttan](jonruttan@gmail.com)
; @copyright 2026 Jon Ruttan
; @license MIT No Attribution (MIT-0)
;
; A double is its IEEE bits, and a float its single's 32 bits, zero above:
; an integer to everything that moves them, since only the operations on
; them know them for what they are.  The operations are the platform's
; (libm-fn in x/num/float), machine code made the first time a run needs
; each, since a state image cannot carry it.  run works in these, and the
; compiler works a constant out with them (cc/eval.x, cc/gen.x).
;
; A float's + - * / are the double's, rounded to a single: a double holds
; every bit the single's rounding looks at, so the answer is the one a
; single-precision operation gives.
(module cc/real)

(import cc/prims string-append string=?)
(import x/num/float libm-fn)

(def %cc-real-oops
  (fn (_ msg)
    (Err raise (lit cc) (string-append "cc: run: " msg) ())))

(def %cc-real-stubs ())     ; ((key . operation) ...)

; the operation LABEL, or the library's function NAME called as LABEL says
(def real-stub
  (fn (_ label name)
    (def key (if (null? name) label (string-append label name)))
    (def go
      (fn (self es)
        (match
          ((null? es) ())
          ((string=? (first (first es)) key) (rest (first es)))
          (#t (self (rest es))))))
    (def hit (go %cc-real-stubs))
    (if (not (null? hit)) hit
      (let ((f (libm-fn (lit %cc-real-stub) label name)))
        (do (set! %cc-real-stubs (pair (pair key f) %cc-real-stubs)) f)))))

(def %cc-d2 (fn (_ label a b) ((real-stub label ()) a b)))
(def %cc-d1 (fn (_ label a) ((real-stub label ()) a)))

(def real? (fn (_ k) (if (eq? k (lit double)) #t (eq? k (lit float)))))

(def %cc-top-bit (<< 1 63))
(def %cc-low-63 0x7FFFFFFFFFFFFFFF)     ; every bit but a double's sign
(def %cc-float-sign 0x80000000)
(def %cc-float-low 0x7FFFFFFF)          ; every bit but a float's sign
(def %cc-two-63 0x43E0000000000000)     ; 2^63 as a double
(def %cc-one 0x3FF0000000000000)        ; 1.0

; the double BITS as a single, rounded to nearest: a float constant's value,
; rounded from its double -- which differs from rounding its digits straight
; to a single only where the double falls exactly halfway between two singles
(def single (fn (_ bits) (%cc-d1 "d->f" bits)))

; --- conversions ---------------------------------------------------------------

; V of the integer C type K as a double: an unsigned long past the signed
; range converts halved, its last bit kept so it rounds as C does, and
; doubled
(def %cc-int->double
  (fn (_ v k)
    (if (if (eq? k (lit ulong)) (< v 0) #f)
      (let ((h (%cc-d1 "i->d" (| (& (>> v 1) %cc-low-63) (& v 1)))))
        (%cc-d2 "d+d" h h))
      (%cc-d1 "i->d" v))))

; V of the integer C type K as a float, in one rounding: an unsigned long
; past the signed range converts halved, its last bit kept, and doubled,
; which is exact
(def %cc-int->float
  (fn (_ v k)
    (if (if (eq? k (lit ulong)) (< v 0) #f)
      (let ((h (%cc-d1 "f->d" (%cc-d1 "i->f" (| (& (>> v 1) %cc-low-63) (& v 1))))))
        (%cc-d1 "d->f" (%cc-d2 "d+d" h h)))
      (%cc-d1 "i->f" v))))

; the double V as an integer of C type K, toward zero, not yet cut to K's
; width: an unsigned long at 2^63 or past it converts less 2^63 and takes
; the top bit back
(def %cc-double->int
  (fn (_ v k)
    (if (if (eq? k (lit ulong)) (not (%cc-d2 "d<d" v %cc-two-63)) #f)
      (^ (%cc-d1 "d->i" (%cc-d2 "d-d" v %cc-two-63)) %cc-top-bit)
      (%cc-d1 "d->i" v))))

; V of the C type FROM as the C type TO takes it where C converts, when
; either is real: TO's bits when TO is real, else the integer toward zero,
; for the caller to cut to TO's width.  Any other V is as it was.
(def convert-real
  (fn (_ v from to)
    (match
      ((eq? to (lit double))
        (match
          ((eq? from (lit double)) v)
          ((eq? from (lit float)) (%cc-d1 "f->d" v))
          (#t (%cc-int->double v from))))
      ((eq? to (lit float))
        (match
          ((eq? from (lit float)) v)
          ((eq? from (lit double)) (%cc-d1 "d->f" v))
          (#t (%cc-int->float v from))))
      ((eq? from (lit double)) (%cc-double->int v to))
      ((eq? from (lit float)) (%cc-double->int (%cc-d1 "f->d" v) to))
      (#t v))))

; --- operations ----------------------------------------------------------------

; OP on the doubles X and Y
(def double-arith
  (fn (_ op x y)
    (match
      ((string=? op "+") (%cc-d2 "d+d" x y))
      ((string=? op "-") (%cc-d2 "d-d" x y))
      ((string=? op "*") (%cc-d2 "d*d" x y))
      ((string=? op "/") (%cc-d2 "d/d" x y))
      (#t (%cc-real-oops (string-append "the operator " op " on a double"))))))

; OP on X and Y, both of the real C type K
(def real-arith
  (fn (_ op x y k)
    (if (eq? k (lit double)) (double-arith op x y)
      (if (if (string=? op "+") #t
            (if (string=? op "-") #t (if (string=? op "*") #t (string=? op "/"))))
        (%cc-d1 "d->f" (double-arith op (%cc-d1 "f->d" x) (%cc-d1 "f->d" y)))
        (%cc-real-oops (string-append "the operator " op " on a float"))))))

; the comparison OP of X and Y, both of the real C type K: false for a NaN
; on either side but for !=
(def real-compare
  (fn (_ op a b k)
    (def x (if (eq? k (lit float)) (%cc-d1 "f->d" a) a))
    (def y (if (eq? k (lit float)) (%cc-d1 "f->d" b) b))
    (match
      ((string=? op "<") (%cc-d2 "d<d" x y))
      ((string=? op ">") (%cc-d2 "d<d" y x))
      ((string=? op "<=") (if (%cc-d2 "d<d" x y) #t (%cc-d2 "d=d" x y)))
      ((string=? op ">=") (if (%cc-d2 "d<d" y x) #t (%cc-d2 "d=d" x y)))
      ((string=? op "==") (%cc-d2 "d=d" x y))
      (#t (not (%cc-d2 "d=d" x y))))))

; V of the real C type K, negated: its sign bit flipped
(def real-negate
  (fn (_ v k) (^ v (if (eq? k (lit float)) %cc-float-sign %cc-top-bit))))

; is V of the real C type K zero, of either sign
(def real-zero?
  (fn (_ v k) (= (& v (if (eq? k (lit float)) %cc-float-low %cc-low-63)) 0)))

; V of the real C type K moved by 1.0, up or down as OP, + or -, says
(def real-step
  (fn (_ v k op)
    (if (eq? k (lit float))
      (%cc-d1 "d->f" (double-arith op (%cc-d1 "f->d" v) %cc-one))
      (double-arith op v %cc-one))))

(provide cc/real convert-real double-arith real-arith real-compare real-negate
  real-step real-stub real-zero? real? single)
