; # x-cc -- a C compiler on x-lang
;
; ## cc/base.x -- the compiler, assembled
;
; @author [Jon Ruttan](jonruttan@gmail.com)
; @copyright 2026 Jon Ruttan
; @license MIT No Attribution (MIT-0)
;
; Not scoped: this file is the lang's seam.  It rebinds `write` so token
; lists print bare, and defines the REPL printer run.x installs, and both
; have to be the root's.

(provide cc/base cc-version cc-lex cc-parse cc-run cc-run-with
  cc-compile cc-compile-image cc-exe-run cc-exe-run-with cc-argv cc-main
  %cc-repl-print)

(def cc-version "0.1.0")

; before the rebind below, so the write cc/prims keeps is x's own
(import cc/prims)

; token lists render bare
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

; Each part is a scoped module that imports what it uses from the others;
; these imports bind the lang's public names in the root, where run.x and
; the spec harness reach them.
(import cc/pp cc-lex)
(import cc/parse cc-parse)
(import cc/eval cc-run cc-run-with)
(import cc/gen cc-compile cc-compile-image cc-exe-run cc-exe-run-with)
(import cc/cli cc-argv cc-main)
