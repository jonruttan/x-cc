; # x-cc -- a C compiler on x-lang
;
; ## cc/base.x -- the compiler, assembled
;
; @author [Jon Ruttan](jonruttan@gmail.com)
; @copyright 2026 Jon Ruttan
; @license MIT No Attribution (MIT-0)
;
; Not scoped: this file is the lang's seam.  It sets symbols to write bare
; so token lists print as the specs read them, and defines the REPL printer
; run.x installs, which has to be the root's.

(provide cc/base cc-version cc-lex cc-source-name! cc-pp-options!
  cc-parse cc-run cc-run-with
  cc-compile-unit cc-target cc-link cc-link-image
  cc-compile cc-compile-image cc-exe-run cc-exe-run-with cc-main
  cc-cli-plan cc-cli-objects cc-refusal cc-usage
  %cc-repl-print)

(def cc-version "0.1.0")

(import cc/prims)
(import x/repl/lang)

; Token lists render bare: Lang symbols-bare! writes symbols without x's
; quote, for write and write-to-str alike.
(Lang symbols-bare!)

(def %cc-repl-print
  (fn (_ result)
    (unless (null? result) (write result))
    (newline)))

; Each part is a scoped module that imports what it uses from the others;
; these imports bind the lang's public names in the root, where run.x and
; the spec harness reach them.
(import cc/pp cc-lex cc-source-name! cc-pp-options!)
(import cc/parse cc-parse)
(import cc/eval cc-run cc-run-with)
(import cc/gen cc-compile-unit cc-target)
(import cc/link cc-link cc-link-image cc-compile cc-compile-image cc-exe-run cc-exe-run-with)
(import cc/cli cc-main cc-cli-plan cc-cli-objects cc-refusal cc-usage)
