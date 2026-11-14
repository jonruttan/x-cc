; # x-cc -- a C compiler on x-lang
;
; ## cc/syntax.x -- the C highlighting grammar
;
; @description The grammar x/tool/syntax colours C files with: comments,
;   strings, character constants, numbers, preprocessor directives, keywords
;   and types.
; @author [Jon Ruttan](jonruttan@gmail.com)
; @copyright 2026 Jon Ruttan
; @license MIT No Attribution (MIT-0)
;
; lang.xon's (grammar c ...) form names this module, and x/tool/syntax
; imports it the first time a file needs the grammar, in whatever process is
; colouring: vi's, a REPL's, an HTML renderer's.  So it imports x-lang
; libraries and cc/words only, never the compiler.  Its keywords, punctuators
; and name bytes are cc/words', the ones cc/tokens reads.
;
; The rules are cc/tokens' read for colouring: every byte is read, and a
; comment, string or character constant still open at the end of the text
; runs to it, as a window onto a file or a line being typed leaves them.  A
; string or character constant may have an L, u, U or u8 prefix.
;
; A # and the name after it is a directive, a keyword when it is one the
; preprocessor knows; any other # is an operator, the name after it its own
; token.  An #include's <header> is a string.  A type's keyword is classed as
; a class, every other keyword as a keyword.  A bracket, a comma or a
; semicolon is punctuation, every other punctuator an operator.

(module cc/syntax)
(import x/type/list)
(import x/type/str)
(import x/reader/lexer)
(import x/tool/syntax)
(import x/core/doors str-byte-ref char->int str-byte-len int+ int-)
(import cc/words cc-keywords cc-ops cc-name-start cc-name-rest)

; The keywords that name a type, or start one
(def cc-syntax-types
  (list "char" "short" "int" "long" "float" "double" "signed" "unsigned"
        "void" "_Bool" "struct" "union" "enum"))

; The directives the preprocessor knows
(def cc-syntax-directives
  (list "define" "undef" "include" "if" "ifdef" "ifndef" "elif" "else"
        "endif" "line" "error" "pragma"))

(def %cc-syntax-blanks (list 32 9 13 10 12 11))
; a header name's bytes: any but > and a newline
(def %cc-syntax-header (list (pair 0 9) (pair 11 61) (pair 63 255) (pair -128 -1)))

(def %cc-syntax-quoted
  (fn (_ tag p q)
    (Lexer nested tag (Str8 append p q) (lit body)
      (list (list (lit body) (char->int (str-byte-ref q 0)) 92 ())) (lit to-end))))

(def cc-syntax-rules
  (fn (_)
    (List append
      (list (Lexer run (lit blank) %cc-syntax-blanks %cc-syntax-blanks)
            (Lexer until (lit comment) "/*" "*/" (lit to-end))
            (Lexer until (lit comment) "//" "\n" (lit to-end))
            (Lexer pattern (lit directive)
              (list (list "#" 1 1) (list " \t" 0 ()) (list cc-name-start 1 1) (list cc-name-rest 0 ())))
            (Lexer pattern (lit include)
              (list (list "#" 1 1) (list " \t" 0 ()) (list cc-name-start 1 1) (list cc-name-rest 0 ())
                    (list " \t" 0 ()) (list "<" 1 1) (list %cc-syntax-header 0 ()) (list ">" 1 1)))
            (Lexer run (lit name) cc-name-start cc-name-rest)
            (Lexer number (lit number) "uUlLfF"))
      (List flat-map
        (fn (_ p) (list (%cc-syntax-quoted (lit string) p "\"") (%cc-syntax-quoted (lit char) p "'")))
        (list "" "L" "u" "U" "u8"))
      (list (Lexer table (lit op) cc-ops)
            (Lexer any (lit plain))))))

(def %cc-syntax-byte (fn (_ s i) (char->int (str-byte-ref s i))))
(def %cc-syntax-blank? (fn (_ b) (if (= b 32) #t (= b 9))))

; The offset of the first byte from I in S that is no blank
(def %cc-syntax-skip
  (fn (self s i)
    (if (if (< i (str-byte-len s)) (%cc-syntax-blank? (%cc-syntax-byte s i)) #f)
      (self s (int+ i 1))
      i)))

; The offset of the first byte from I in S that ends a name
(def %cc-syntax-name-end
  (fn (self s i)
    (if (< i (str-byte-len s))
      (let ((b (%cc-syntax-byte s i)))
        (if (match ((if (>= b 97) (<= b 122) #f) #t) ((if (>= b 65) (<= b 90) #f) #t)
                   ((if (>= b 48) (<= b 57) #f) #t) (#t (= b 95)))
          (self s (int+ i 1))
          i))
      i)))

; A directive's pieces up to its name's end: the # and name one keyword, or a
; # with an unknown name after it an operator and the name plain.
(def %cc-syntax-head
  (fn (_ text)
    (let ((at (%cc-syntax-skip text 1)))
      (let ((end (%cc-syntax-name-end text at)))
        (if (List includes? (Str8 sub at (int- end at) text) cc-syntax-directives)
          (list (list 0 end (lit keyword)))
          (list (list 0 1 (lit operator))))))))

(def %cc-syntax-directive-class (fn (_ text) (%cc-syntax-head text)))

; An #include's head, then its <header> a string
(def %cc-syntax-include-class
  (fn (_ text)
    (let ((at (%cc-syntax-skip text (%cc-syntax-name-end text (%cc-syntax-skip text 1)))))
      (List append (%cc-syntax-head text)
        (list (list at (int- (str-byte-len text) at) (lit string)))))))

(def %cc-syntax-name-class
  (fn (_ text)
    (match
      ((List includes? text cc-syntax-types) (lit class))
      ((List includes? text cc-keywords) (lit keyword))
      (#t ()))))

; ( ) , ; [ ] { }, none the first byte of a longer punctuator
(def %cc-syntax-punct (list 40 41 44 59 91 93 123 125))

(def %cc-syntax-op-class
  (fn (_ text)
    (if (List includes? (%cc-syntax-byte text 0) %cc-syntax-punct) (lit punct) (lit operator))))

; A line starting with a name, a # or a brace at its first column is taken to
; start outside any comment or string, so spans need not read the file from
; its top.
(def %cc-syntax-sync
  (fn (_ s ls)
    (if (>= ls (str-byte-len s)) #f
      (let ((b (%cc-syntax-byte s ls)))
        (match
          ((List includes? b (list 35 95 123 125)) #t)
          ((if (>= b 65) (<= b 90) #f) #t)
          (#t (if (>= b 97) (<= b 122) #f)))))))

(Syntax register!
  (let ((g (Syntax make (lit c) (cc-syntax-rules)
             (list (pair (lit comment) (lit comment))
                   (pair (lit string) (lit string))
                   (pair (lit char) (lit char))
                   (pair (lit number) (lit number))
                   (pair (lit directive) %cc-syntax-directive-class)
                   (pair (lit include) %cc-syntax-include-class)
                   (pair (lit name) %cc-syntax-name-class)
                   (pair (lit op) %cc-syntax-op-class)))))
    (g sync %cc-syntax-sync)
    g))

(provide cc/syntax cc-syntax-rules cc-syntax-types cc-syntax-directives)
