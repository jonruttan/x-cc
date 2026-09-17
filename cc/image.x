; # x-cc -- a C compiler on x-lang
;
; ## cc/image.x -- a byte image for an executable file
;
; @author [Jon Ruttan](jonruttan@gmail.com)
; @copyright 2026 Jon Ruttan
; @license MIT No Attribution (MIT-0)
;
; The writers for each executable format build their file in one zeroed
; buffer and write it out.  An image is (BUF . PTR): the buffer keeps the
; bytes alive, the pointer addresses them.

; a zeroed image of at least N bytes; the capacity is rounded up to eight so
; the zeroing can go a word at a time
(def %cc-img-new
  (fn (_ n)
    (let ((cap (let ((m (+ n 7))) (- m (% m 8)))))
      (let ((buf (mem-make cap)))
        (do (%cc-img-zero! (mem-ptr buf) 0 cap)
            (pair buf (mem-ptr buf)))))))

(def %cc-img-zero!
  (fn (self p i n) (if (>= i n) () (do (word-set! p i 0) (self p (+ i 8) n)))))

(def %cc-img-u8! (fn (_ img at v) (mem-set-byte! (rest img) at v)))

(def %cc-img-u16!
  (fn (_ img at v)
    (do (%cc-img-u8! img at v) (%cc-img-u8! img (+ at 1) (>> v 8)))))

(def %cc-img-u32!
  (fn (_ img at v)
    (do (%cc-img-u16! img at v) (%cc-img-u16! img (+ at 2) (>> v 16)))))

(def %cc-img-u64!
  (fn (_ img at v)
    (do (%cc-img-u32! img at v) (%cc-img-u32! img (+ at 4) (>> v 32)))))

(def %cc-img-be32!
  (fn (_ img at v)
    (do (%cc-img-u8! img at (>> v 24)) (%cc-img-u8! img (+ at 1) (>> v 16))
        (%cc-img-u8! img (+ at 2) (>> v 8)) (%cc-img-u8! img (+ at 3) v))))

(def %cc-img-be64!
  (fn (_ img at v)
    (do (%cc-img-be32! img at (>> v 32)) (%cc-img-be32! img (+ at 4) v))))

; a list of byte values, from AT
(def %cc-img-bytes!
  (fn (self img at bs)
    (if (null? bs) ()
      (do (%cc-img-u8! img at (first bs)) (self img (+ at 1) (rest bs))))))

; a string's bytes, from AT, with no terminator (the image is zeroed)
(def %cc-img-ascii!
  (fn (_ img at s)
    (let ((go (fn (self i)
                (if (>= i (byte-len s)) ()
                  (do (%cc-img-u8! img (+ at i) (+ 0 (byte-at s i)))
                      (self (+ i 1)))))))
      (go 0))))

; the first N bytes of the image to PATH, executable
(def %cc-img-write!
  (fn (_ img path n) (file-write-exec! path (first img) n)))
