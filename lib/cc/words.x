; # x-cc -- a C compiler on x-lang
;
; ## cc/words.x -- C's keywords, punctuators and name bytes
;
; @author [Jon Ruttan](jonruttan@gmail.com)
; @copyright 2026 Jon Ruttan
; @license MIT No Attribution (MIT-0)
;
; The words both readers of C share: cc/tokens, which reads C for the
; compiler, and cc/syntax, which colours it.  Data only, importing nothing,
; so a process colouring a file loads it without the compiler.

(module cc/words)

; Every C89 keyword, C99's _Bool, inline and restrict, and C11's
; _Static_assert, so the parser refuses the unimplemented ones by name rather
; than reading them as identifiers.
(def cc-keywords
  (list "auto" "break" "case" "char" "const" "continue" "default" "do"
        "double" "else" "enum" "extern" "float" "for" "goto" "if" "int"
        "long" "register" "return" "short" "signed" "sizeof" "static"
        "struct" "switch" "typedef" "union" "unsigned" "void" "volatile"
        "while" "_Bool" "inline" "restrict" "_Static_assert"))

; C's punctuators, the longest that matches
(def cc-ops
  (list "[" "]" "(" ")" "{" "}" "." "->" "++" "--" "&" "*" "+" "-" "~" "!"
        "/" "%" "<<" ">>" "<" ">" "<=" ">=" "==" "!=" "^" "|" "&&" "||"
        "?" ":" ";" "..." "=" "*=" "/=" "%=" "+=" "-=" "<<=" ">>=" "&="
        "^=" "|=" "," "#" "##"))

; A name's first byte and the bytes after it
(def cc-name-start (list (pair 97 122) (pair 65 90) 95))
(def cc-name-rest (list (pair 97 122) (pair 65 90) (pair 48 57) 95))

(provide cc/words cc-keywords cc-ops cc-name-start cc-name-rest)
