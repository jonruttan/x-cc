; # x-cc -- a C compiler on x-lang
;
; ## tests/harness.x -- what the spec harness adds to the dialect
;
; @author [Jon Ruttan](jonruttan@gmail.com)
; @copyright 2026 Jon Ruttan
; @license MIT No Attribution (MIT-0)
;
; The lang kit's generator writes tests/lib/harness.gen.x: the dialect
; lang.xon declares, the bundle's root on the import path, then this file.
; It is run.x less the part that starts the lang: the compiler, and the REPL
; printer that shows a token list bare.
(import cc/base)
(set! %repl-print %cc-repl-print)
