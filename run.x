; # x-cc -- a C compiler on x-lang
;
; ## run.x -- THE entry
;
; @description A C compiler front end and evaluator: `x -l cc -- run
;   prog.c` executes C.  The self-hosting arc's compiler tier, slice
;   one; the engine's compile-asm lane is the intended backend.
; @author [Jon Ruttan](jonruttan@gmail.com)
; @copyright 2026 Jon Ruttan
; @license MIT No Attribution (MIT-0)
(import cc/base)

(set! %lang-name "CC")
(set! %lang-version cc-version)
(set! %repl-prompt "cc> ")
(set! %repl-print %cc-repl-print)

(unless (null? (cc-argv args))
  (cc-main args))
