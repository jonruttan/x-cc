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
; Any other directive refuses loudly; function-like macros, #ifdef and
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
    (if (string=? dname "include")
      ()
      (if (string=? dname "define")
        (let ((n0 (skip d1)))
          (def n1 (word n0))
          (if (= n0 n1)
            (Err raise (lit cc) "cc: #define needs a name" ())
            (if (if (< n1 end) (= (byte-at line n1) 40) #f)   ; (
              (Err raise (lit cc)
                "cc: function-like macros are not built yet" ())
              (pair (substring line n0 n1)
                (substring line (skip n1) end)))))
        (Err raise (lit cc)
          (string-append "cc: unsupported directive #" dname) ())))))

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
(def cc-preprocess
  (fn (_ src)
    (def lines (%cc-split-lines (%cc-strip-comments src)))
    (def go
      (fn (self ls macros acc)
        (if (null? ls)
          (pair (%cc-join-nl (reverse acc)) (reverse macros))
          (let ((line (first ls)))
            (def hash (%cc-hash-at line))
            (if (< hash 0)
              (self (rest ls) macros (pair line acc))
              (let ((m (%cc-directive
                         (substring line (+ hash 1) (byte-len line)))))
                (self (rest ls)
                  (if (null? m) macros (pair m macros))
                  (pair "" acc))))))))
    (go lines () ())))

(def %cc-join-nl
  (fn (self ls)
    (if (null? ls) ""
      (if (null? (rest ls)) (first ls)
        (string-append (first ls)
          (string-append "\n" (self (rest ls))))))))
