; # x-cc -- a C compiler on x-lang
;
; ## cc/base.x -- the compiler, assembled
;
; @author [Jon Ruttan](jonruttan@gmail.com)
; @copyright 2026 Jon Ruttan
; @license MIT No Attribution (MIT-0)

(import cc/prims)

(provide cc/base cc-version cc-preprocess cc-lex cc-parse cc-run
  cc-build-run cc-argv cc-main %cc-repl-print)

(def cc-version "0.1.0")

; token lists render bare, the arc's usual twenty lines
(def %cc-write ())
(def %cc-x-write write)
(def %cc-write-items
  (fn (_ v)
    (%cc-write (first v))
    (if (null? (rest v))
      ()
      (if (pair? (rest v))
        (%seq (display " ") (%cc-write-items (rest v)))
        (%seq (display " . ") (%cc-write (rest v)))))))
(set! %cc-write
  (fn (_ v)
    (if (pair? v)
      (%seq (display "(") (%seq (%cc-write-items v) (display ")")))
      (if (symbol? v) (display v) (%cc-x-write v)))))
(def write %cc-write)

(def %cc-repl-print
  (fn (_ result)
    (unless (null? result) (%cc-write result))
    (newline)))

(include-once "./pp.x")
(include-once "./lex.x")
(include-once "./parse.x")
(include-once "./eval.x")
(include-once "./build.x")
(include-once "./cli.x")
