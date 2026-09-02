; # x-cc -- a C compiler on x-lang
;
; ## cc/pp.x -- the preprocessor, the honest subset
;
; @author [Jon Ruttan](jonruttan@gmail.com)
; @copyright 2026 Jon Ruttan
; @license MIT No Attribution (MIT-0)
;
; Comments strip first (string- and char-aware), then the # lines:
; #include drops (the runtime provides the library the tests use),
; object-like #define records a macro the LEXER splices token-wise --
; substitution never touches text, so strings are safe by construction.
; Function-like macros are collected here as (NAME %fn (PARAMS) . BODY)
; and expanded in the lexer.  #ifdef/#ifndef/#else/#endif/#undef and the
; #if forms a build header needs (0, 1, defined) select lines.  Any
; other directive refuses loudly; # and ## in a macro body, #elif and
; friends are recorded pendings.

; comments to spaces; strings and char constants pass untouched
(def %cc-strip-comments
  (fn (_ src)
    (def end (byte-len src))
    ; mode: 0 code, 1 string, 2 char, 3 line comment, 4 block comment
    (def go
      (fn (self i mode acc)
        (if (>= i end) (string-concat (reverse acc))
          (let ((b (byte-at src i)))
            (if (= mode 3)                                 ; // ... eol
              (if (= b 10)
                (self (+ i 1) 0 (pair "\n" acc))
                (self (+ i 1) 3 acc))
              (if (= mode 4)                               ; /* ... */
                (if (if (= b 42)
                      (if (< (+ i 1) end) (= (byte-at src (+ i 1)) 47) #f)
                      #f)
                  (self (+ i 2) 0 (pair " " acc))
                  (self (+ i 1) 4 acc))
                (if (= mode 1)                             ; "..."
                  (if (= b 92)
                    (self (+ i 2)
                      1 (pair (substring src i (+ i 2)) acc))
                    (self (+ i 1)
                      (if (= b 34) 0 1)
                      (pair (substring src i (+ i 1)) acc)))
                  (if (= mode 2)                           ; '...'
                    (if (= b 92)
                      (self (+ i 2)
                        2 (pair (substring src i (+ i 2)) acc))
                      (self (+ i 1)
                        (if (= b 39) 0 2)
                        (pair (substring src i (+ i 1)) acc)))
                    ; code
                    (if (if (= b 47)
                          (if (< (+ i 1) end)
                            (= (byte-at src (+ i 1)) 47) #f)
                          #f)
                      (self (+ i 2) 3 acc)
                      (if (if (= b 47)
                            (if (< (+ i 1) end)
                              (= (byte-at src (+ i 1)) 42) #f)
                            #f)
                        (self (+ i 2) 4 acc)
                        (self (+ i 1)
                          (if (= b 34) 1 (if (= b 39) 2 0))
                          (pair (substring src i (+ i 1)) acc))))))))))))
    (go 0 0 ())))

(def %cc-ws-only?
  (fn (_ s a b)
    (def go
      (fn (self i)
        (if (>= i b) #t
          (let ((c (byte-at s i)))
            (if (if (= c 32) #t (= c 9)) (self (+ i 1)) #f)))))
    (go a)))

; one # line: nil (dropped), or a (name . body) macro
(def %cc-directive
  (fn (_ line)
    (def end (byte-len line))
    (def skip
      (fn (self i)
        (if (>= i end) i
          (let ((c (byte-at line i)))
            (if (if (= c 32) #t (= c 9)) (self (+ i 1)) i)))))
    (def word
      (fn (self i)
        (if (>= i end) i
          (let ((c (byte-at line i)))
            (if (if (if (>= c 97) (<= c 122) #f) #t
                  (if (if (>= c 65) (<= c 90) #f) #t
                    (if (if (>= c 48) (<= c 57) #f) #t (= c 95))))
              (self (+ i 1))
              i)))))
    (def d0 (skip 0))
    (def d1 (word d0))
    (def dname (substring line d0 d1))
    (def arg (%cc-trim-ws (substring line (skip d1) end)))
    (if (string=? dname "include")
      (list (lit include))
    (if (string=? dname "ifdef") (pair (lit ifdef) arg)
    (if (string=? dname "ifndef") (pair (lit ifndef) arg)
    (if (string=? dname "else") (list (lit else))
    (if (string=? dname "endif") (list (lit endif))
    (if (string=? dname "undef") (pair (lit undef) arg)
    (if (string=? dname "if") (pair (lit if) arg)
    (if (string=? dname "elif")
      (Err raise (lit cc) "cc: #elif is not built yet" ())
      (if (string=? dname "define")
        (let ((n0 (skip d1)))
          (def n1 (word n0))
          (if (= n0 n1)
            (Err raise (lit cc) "cc: #define needs a name" ())
            (if (if (< n1 end) (= (byte-at line n1) 40) #f)   ; (
              ; function-like: NAME(P, Q) BODY -> (NAME %fn (P Q) . BODY);
              ; the lexer collects the arguments and substitutes.  The #
              ; and ## operators are the recorded pending.
              (let ((params
                      (let ((go (fn (self i start acc)
                                  (if (>= i end) (Err raise (lit cc) "cc: unterminated macro parameter list" ())
                                    (let ((c (byte-at line i)))
                                      (if (if (= c 44) #t (= c 41))          ; , or )
                                        (let ((w0 (skip start)))
                                          (def w1 (word w0))
                                          (def acc2 (if (= w1 w0) acc (pair (substring line w0 w1) acc)))
                                          (if (= c 41) (pair (reverse acc2) (+ i 1))
                                            (self (+ i 1) (+ i 1) acc2)))
                                        (self (+ i 1) start acc)))))))
                        (go (+ n1 1) (+ n1 1) ()))))
                (def body (substring line (skip (rest params)) end))
                (def hashy
                  (let ((go (fn (self i)
                              (if (>= i (byte-len body)) #f
                                (if (= (byte-at body i) 35) #t (self (+ i 1)))))))
                    (go 0)))
                (if hashy
                  (Err raise (lit cc) "cc: # and ## in macros are not built yet" ())
                  (pair (lit define)
                    (pair (substring line n0 n1)
                      (pair (lit %fn) (pair (first params) body))))))
              (pair (lit define)
                (pair (substring line n0 n1)
                  (substring line (skip n1) end))))))
        (Err raise (lit cc)
          (string-append "cc: unsupported directive #" dname) ()))))))))))))

(def %cc-trim-ws
  (fn (_ s)
    (def end (byte-len s))
    (def ws? (fn (_ c) (if (= c 32) #t (if (= c 9) #t (= c 13)))))
    (def z (let ((go (fn (self i) (if (<= i 0) 0 (if (ws? (byte-at s (- i 1))) (self (- i 1)) i))))) (go end)))
    (substring s 0 z)))

(def %cc-defined?
  (fn (_ name macros)
    (def go (fn (self es)
              (if (null? es) #f
                (if (string=? (first (first es)) name) #t (self (rest es))))))
    (go macros)))

; #if takes only what a build header needs: 0, 1, defined(NAME),
; defined NAME, and !defined(...).  Anything else refuses loudly.
(def %cc-if-cond
  (fn (_ text macros)
    (def end (byte-len text))
    (def name-in
      (fn (_ from)
        ; the identifier after `defined`, with or without parentheses
        (def skip (fn (self i) (if (>= i end) i (let ((c (byte-at text i))) (if (if (= c 32) #t (if (= c 40) #t (= c 9))) (self (+ i 1)) i)))))
        (def a (skip from))
        (def word (fn (self i) (if (>= i end) i
                                 (let ((c (byte-at text i)))
                                   (if (if (if (>= c 97) (<= c 122) #f) #t
                                         (if (if (>= c 65) (<= c 90) #f) #t
                                           (if (if (>= c 48) (<= c 57) #f) #t (= c 95))))
                                     (self (+ i 1)) i)))))
        (substring text a (word a))))
    (if (string=? text "0") #f
      (if (string=? text "1") #t
        (if (if (>= end 7) (string=? (substring text 0 7) "defined") #f)
          (%cc-defined? (name-in 7) macros)
          (if (if (>= end 8) (string=? (substring text 0 8) "!defined") #f)
            (not (%cc-defined? (name-in 8) macros))
            (Err raise (lit cc)
              (string-append "cc: unsupported #if condition: " text) ())))))))

; every line, empties kept, trailing newline or not
(def %cc-split-lines
  (fn (_ s)
    (def end (byte-len s))
    (def go
      (fn (self i start acc)
        (if (>= i end)
          (reverse (pair (substring s start end) acc))
          (if (= (byte-at s i) 10)
            (self (+ i 1) (+ i 1) (pair (substring s start i) acc))
            (self (+ i 1) start acc)))))
    (go 0 0 ())))

; the # at a line's head (blanks allowed), or -1
(def %cc-hash-at
  (fn (_ line)
    (def go
      (fn (self j)
        (if (>= j (byte-len line)) (- 0 1)
          (let ((c (byte-at line j)))
            (if (if (= c 32) #t (= c 9))
              (self (+ j 1))
              (if (= c 35) j (- 0 1)))))))
    (go 0)))

; source to (clean-text . macro-alist): comments stripped, # lines
; pulled out and replaced with blanks (token separation kept)
; the walk carries a STACK of conditional flags: a line lives when
; every open conditional is true.  An inactive region still tracks its
; own nesting, so its #endif pairs; its defines and undefs are ignored.
(def cc-preprocess
  (fn (_ src)
    (def lines (%cc-split-lines (%cc-strip-comments src)))
    (def live?
      (fn (self st) (if (null? st) #t (if (first st) (self (rest st)) #f))))
    (def undef
      (fn (_ name macros)
        (filter (fn (_ e) (not (string=? (first e) name))) macros)))
    (def go
      (fn (self ls macros stack acc)
        (if (null? ls)
          (if (not (null? stack))
            (Err raise (lit cc) "cc: unterminated #if" ())
            (pair (%cc-join-nl (reverse acc)) (reverse macros)))
          (let ((line (first ls)))
            (def hash (%cc-hash-at line))
            (def on (live? stack))
            (if (< hash 0)
              (self (rest ls) macros stack (pair (if on line "") acc))
              (let ((m (%cc-directive (substring line (+ hash 1) (byte-len line)))))
                (def k (first m))
                (if (eq? k (lit ifdef))
                  (self (rest ls) macros (pair (if on (%cc-defined? (rest m) macros) #f) stack) (pair "" acc))
                (if (eq? k (lit ifndef))
                  (self (rest ls) macros (pair (if on (not (%cc-defined? (rest m) macros)) #f) stack) (pair "" acc))
                (if (eq? k (lit if))
                  (self (rest ls) macros (pair (if on (%cc-if-cond (rest m) macros) #f) stack) (pair "" acc))
                (if (eq? k (lit else))
                  (if (null? stack) (Err raise (lit cc) "cc: #else without #if" ())
                    (self (rest ls) macros
                      (pair (if (live? (rest stack)) (not (first stack)) #f) (rest stack))
                      (pair "" acc)))
                (if (eq? k (lit endif))
                  (if (null? stack) (Err raise (lit cc) "cc: #endif without #if" ())
                    (self (rest ls) macros (rest stack) (pair "" acc)))
                (if (not on)
                  (self (rest ls) macros stack (pair "" acc))
                (if (eq? k (lit define))
                  (self (rest ls) (pair (rest m) macros) stack (pair "" acc))
                (if (eq? k (lit undef))
                  (self (rest ls) (undef (rest m) macros) stack (pair "" acc))
                  (self (rest ls) macros stack (pair "" acc))))))))))))))))
    (go lines () () ())))

(def %cc-join-nl
  (fn (self ls)
    (if (null? ls) ""
      (if (null? (rest ls)) (first ls)
        (string-append (first ls)
          (string-append "\n" (self (rest ls))))))))
