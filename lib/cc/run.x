; # x-cc -- a C compiler on x-lang
;
; ## lib/cc/run.x -- the entry, the module cc/run
;
; @description A C compiler front end and evaluator: `x -l cc -- run
;   prog.c` executes C.  The engine's compile-asm lane is the backend.
; @author [Jon Ruttan](jonruttan@gmail.com)
; @copyright 2026 Jon Ruttan
; @license MIT No Attribution (MIT-0)
;
; Importing it sets the session up and starts nothing; main runs the
; command the operands name, and with none leaves the prompt to the wrapper.
(module cc/run)
(import cc/base)

(set! %lang-name "CC")
(set! %lang-version cc-version)
(set! %repl-prompt "cc> ")
(set! %repl-print %cc-repl-print)

(def main
  (fn (_)
    (let ((ops (rest (Sys args (lit program)))))
      (unless (null? ops) (cc-main ops)))))

(provide cc/run main)
