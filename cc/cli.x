; # x-cc -- a C compiler on x-lang
;
; ## cc/cli.x -- the command line
;
; @author [Jon Ruttan](jonruttan@gmail.com)
; @copyright 2026 Jon Ruttan
; @license MIT No Attribution (MIT-0)
;
;   x -l cc -- [-c] [-o OUT] [-D NAME[=VALUE]] [-U NAME] [-I DIR] FILE...
;   x -l cc -- run FILE.c [FILE.c ...] [ARG ...]
;   x -l cc -- --help
;
; The first line is cc's own: the FILEs, C files and objects, are built into
; an executable at OUT, a.out when no -o is given: each C file is compiled
; to an object (cc/gen) and the objects linked (cc/link).  -c writes each
; FILE.c's object to FILE.o instead, under the -D, -U and -I before it,
; which a later line links as it links what it compiles itself.
; -fsyntax-only reads the files and stops; -dumpmachine names the target.  cc's options
; that ask for nothing x-cc does differently are taken and ignored: -O, -g,
; -W, -f, -m and -l with whatever follows, -std=, -ansi, -pedantic, -w,
; -MD, -MMD, -MP, -MF FILE, -MT and -MQ TARGET, -L DIR, -static, -s,
; -pipe and -pthread.  Of the linker's -Wl, words, the executable exports
; the names an -exported_symbols_list FILE lists, or with -export_dynamic,
; --export-dynamic, -E or -rdynamic every function and global, for dlsym to
; find, and nothing without them, as GNU ld; the rest are ignored.  `build`
; before the FILEs is the same line.
;
; `run` interprets the program, the first FILE.c its name and the ARGs after
; the files in its argv, and exits with its status; the files are the words
; up to the first that does not end in .c.
(module cc/cli)

(import cc/prims append byte-at byte-len file-exists? file-read-all file-write filter
  map reverse string-append substring string=? sys-exit x-write heap-collect)
(import cc/eval cc-run-with)
(import cc/gen cc-compile-unit cc-target)
(import cc/link cc-link)
(import cc/parse cc-parse)
(import cc/pp cc-lex cc-source-name! cc-pp-options!)
(import x/tool/link link-write! link-read)
(import x/sys/opts Opts)

; The options, declared once: what --help prints and what a refusal prints.
; cc's options are not getopt's -- -Wall is one option, not four -- so the
; line is read by cc-cli-plan, not by Opts parse.  busybox has no cc, so the
; text is this bundle's, laid out as busybox lays its help text out.
(def cc-options
  (Opts declare "cc" "[-c] [-o OUT] [-D NAME[=VALUE]] [-I DIR] FILE...\nor: cc run FILE.c... [ARG]..."
    "Build a C program into an executable, or run it"
    (list
      (Opts flag "-c" "Compile each FILE.c into an object, FILE.o, to build from")
      (Opts arg "-o" "OUT" "Write the executable, or the one -c makes, to OUT")
      (Opts arg "-D" "NAME[=VALUE]" "Define NAME as VALUE, or as 1")
      (Opts arg "-U" "NAME" "Undefine NAME")
      (Opts arg "-I" "DIR" "Look for #include files in DIR too")
      (Opts flag "-fsyntax-only" "Read the files and stop"))))

; The help text: what --help prints on stdout, and a refusal on stderr.
(def cc-usage (fn (_) (Opts usage cc-options)))

; does S end in .c
(def %cc-c-file?
  (fn (_ s)
    (def n (byte-len s))
    (if (> n 2) (string=? (substring s (- n 2) n) ".c") #f)))

; does S start with P
(def %cc-prefix?
  (fn (_ s p)
    (if (>= (byte-len s) (byte-len p)) (string=? (substring s 0 (byte-len p)) p) #f)))

(def %cc-cli-valued (list "-o" "-D" "-U" "-I" "-MF" "-MT" "-MQ" "-L"))
(def %cc-cli-ignored-prefixes (list "-O" "-g" "-W" "-f" "-m" "-l" "-std="))
(def %cc-cli-ignored
  (list "-ansi" "-pedantic" "-pedantic-errors" "-w" "-MD" "-MMD" "-MP" "-static" "-s"
    "-pipe" "-pthread"))

(def %cc-cli-member?
  (fn (self s ss) (if (null? ss) #f (if (string=? s (first ss)) #t (self s (rest ss))))))
(def %cc-cli-prefix-of
  (fn (self s ps) (match ((null? ps) ()) ((%cc-prefix? s (first ps)) (first ps)) (#t (self s (rest ps))))))

; the NAME a -D or -U value S names: up to its = or its (
(def %cc-cli-macro-name
  (fn (_ s)
    (def go
      (fn (self i)
        (match
          ((= i (byte-len s)) s)
          ((if (= (byte-at s i) #\=) #t (= (byte-at s i) #\()) (substring s 0 i))
          (#t (self (+ i 1))))))
    (go 0)))

; the #define text of a -D value S: NAME=VALUE as NAME VALUE, NAME as NAME 1
(def %cc-cli-define
  (fn (_ s)
    (def go
      (fn (self i)
        (match
          ((= i (byte-len s)) (string-append s " 1"))
          ((= (byte-at s i) #\=)
            (string-append (substring s 0 i) " " (substring s (+ i 1) (byte-len s))))
          (#t (self (+ i 1))))))
    (go 0)))

; ARGV to what the line asks: (help), (run PATHS ARGS), (machine), (MODE
; FILES OUT DIRS DEFINES EXPORTS) -- MODE build, compile or check, OUT nil
; for -c without -o, DIRS each ending in /, DEFINES each a #define's text,
; EXPORTS each a symbol list's path or `all` -- or
; (refuse TOK), TOK the option refused, nil for a line that is only wrong in
; shape.  run's files are its words up to the first not ending in .c, and the
; words after them the program's, never parsed.
(def cc-cli-plan
  (fn (_ argv)
    (def files
      (fn (self ws acc)
        (if (if (null? ws) #f (%cc-c-file? (first ws)))
          (self (rest ws) (pair (first ws) acc))
          (pair (reverse acc) ws))))
    (match
      ((Opts help? cc-options argv) (list (lit help)))
      ((null? argv) (list (lit refuse) ()))
      ((string=? (first argv) "run")
        (match
          ((null? (rest argv)) (list (lit refuse) ()))
          ; a first word not ending in .c is still the program's one file
          ((not (%cc-c-file? (first (rest argv))))
            (list (lit run) (list (first (rest argv))) (rest (rest argv))))
          (#t (let ((fs (files (rest argv) ()))) (list (lit run) (first fs) (rest fs))))))
      ((string=? (first argv) "build") (%cc-cli-line (rest argv)))
      (#t (%cc-cli-line argv)))))

; S cut at each comma
(def %cc-cli-commas
  (fn (_ s)
    (def go
      (fn (self i from acc)
        (match
          ((= i (byte-len s)) (reverse (pair (substring s from i) acc)))
          ((= (byte-at s i) #\,) (self (+ i 1) (+ i 1) (pair (substring s from i) acc)))
          (#t (self (+ i 1) from acc)))))
    (go 0 0 ())))

; What the linker's words in WS ask to export, as cc-cli-plan's EXPORTS:
; -exported_symbols_list FILE, ld64's, names FILE, and -export_dynamic,
; --export-dynamic, -E and -rdynamic ask for every function and global,
; `all`.  Answers (EXPORTS . REST), REST the other words; EXPORTS is
; `refuse` when a list names no file.
(def %cc-cli-exports
  (fn (_ ws)
    (def linker
      (fn (self ws acc rest-ws)
        (match
          ((null? ws) (pair (reverse acc) (reverse rest-ws)))
          ((string=? (first ws) "-rdynamic")
            (self (rest ws) (pair "-export_dynamic" acc) rest-ws))
          ((%cc-prefix? (first ws) "-Wl,")
            (self (rest ws)
              (append (reverse (%cc-cli-commas (substring (first ws) 4 (byte-len (first ws))))) acc)
              rest-ws))
          (#t (self (rest ws) acc (pair (first ws) rest-ws))))))
    (def split (linker ws () ()))
    (def go
      (fn (self ls acc)
        (match
          ((null? ls) (reverse acc))
          ((string=? (first ls) "-exported_symbols_list")
            (if (null? (rest ls)) (lit refuse)
              (self (rest (rest ls)) (pair (first (rest ls)) acc))))
          ((%cc-cli-member? (first ls) (list "-export_dynamic" "--export-dynamic" "-E"))
            (self (rest ls)
              (if (null? (filter (fn (_ e) (eq? e (lit all))) acc)) (pair (lit all) acc) acc)))
          (#t (self (rest ls) acc)))))
    (pair (go (first split) ()) (rest split))))

; cc's own line WS, as cc-cli-plan answers it.  The linker's words come out
; first, as EXPORTS (%cc-cli-exports).
(def %cc-cli-line
  (fn (_ ws)
    (def ex (%cc-cli-exports ws))
    (if (eq? (first ex) (lit refuse)) (list (lit refuse) ())
      (let ((plan (%cc-cli-words (rest ex))))
        (if (if (eq? (first plan) (lit refuse)) #t (eq? (first plan) (lit machine))) plan
          (append plan (list (first ex))))))))

; cc's line WS without the linker's words.  A value is the rest of its
; word, or the next word; the last -o is kept; DEFINES are (NAME . TEXT),
; a -U dropping the ones before it of its name.
(def %cc-cli-words
  (fn (_ ws)
    (def go
      (fn (self ws mode fs out dirs defines)
        (if (null? ws)
          (match
            ((null? fs) (list (lit refuse) ()))
            ; one -o for the objects of several files
            ((if (eq? mode (lit compile)) (if (null? out) #f (not (null? (rest fs)))) #f)
              (list (lit refuse) ()))
            (#t (list mode (reverse fs)
                  (if (if (null? out) (eq? mode (lit build)) #f) "a.out" out)
                  (reverse dirs) (map (fn (_ d) (rest d)) (reverse defines)))))
          (let ((w (first ws)))
            (def opt (%cc-cli-prefix-of w %cc-cli-valued))
            (match
              ((string=? w "-dumpmachine") (list (lit machine)))
              ((string=? w "-c") (self (rest ws) (lit compile) fs out dirs defines))
              ((string=? w "-fsyntax-only") (self (rest ws) (lit check) fs out dirs defines))
              ((%cc-cli-member? w %cc-cli-ignored) (self (rest ws) mode fs out dirs defines))
              ((not (null? opt))
                ; the value and the words after it, or nil when there is none
                (let ((v (if (string=? w opt)
                           (if (null? (rest ws)) () (pair (first (rest ws)) (rest (rest ws))))
                           (pair (substring w (byte-len opt) (byte-len w)) (rest ws)))))
                  (def s (if (null? v) "" (first v)))
                  (match
                    ((if (= (byte-len s) 0) #t (if (string=? opt "-D") (string=? (%cc-cli-macro-name s) "") #f))
                      (list (lit refuse) opt))
                    ((string=? opt "-o") (self (rest v) mode fs s dirs defines))
                    ((string=? opt "-I")
                      (self (rest v) mode fs out
                        (pair (if (= (byte-at s (- (byte-len s) 1)) #\/) s (string-append s "/")) dirs)
                        defines))
                    ((string=? opt "-D")
                      (self (rest v) mode fs out dirs
                        (pair (pair (%cc-cli-macro-name s) (%cc-cli-define s)) defines)))
                    ((string=? opt "-U")
                      (self (rest v) mode fs out dirs
                        (filter (fn (_ d) (not (string=? (first d) s))) defines)))
                    (#t (self (rest v) mode fs out dirs defines)))))
              ((not (null? (%cc-cli-prefix-of w %cc-cli-ignored-prefixes)))
                (self (rest ws) mode fs out dirs defines))
              ((if (> (byte-len w) 1) (= (byte-at w 0) #\-) #f) (list (lit refuse) w))
              (#t (self (rest ws) mode (pair w fs) out dirs defines)))))))
    (go ws (lit build) () () () ())))

; the source PATHS give: one file's text, named for __FILE__; or several,
; each (PATH . TEXT)
(def %cc-cli-source
  (fn (_ paths)
    (if (null? (rest paths))
      (do (cc-source-name! (first paths)) (file-read-all (first paths)))
      (map (fn (_ p) (pair p (file-read-all p))) paths))))

; the object of the C file at PATH for TARGET: cc-compile-unit takes a
; list of (PATH . TEXT), one unit here
(def %cc-cli-unit
  (fn (_ p target)
    (cc-compile-unit (list (pair p (file-read-all p))) target)))

; the object of each of PATHS for TARGET: a C file's compiled, an object
; file's read -- what a build line links
(def cc-cli-objects
  (fn (_ paths target)
    ; reading an object's records makes some thirty times its bytes in
    ; garbage, which nothing else collects
    (map (fn (_ p)
           (let ((o (if (%cc-c-file? p) (%cc-cli-unit p target) (link-read p))))
             (heap-collect)
             o))
      paths)))

; the first of PATHS that is not a file, or nil
(def %cc-cli-missing
  (fn (self paths)
    (match
      ((null? paths) ())
      ((file-exists? (first paths)) (self (rest paths)))
      (#t (first paths)))))

; is the file at PATH an object file: its first line names the format
(def %cc-cli-object-file?
  (fn (_ path)
    (def text (file-read-all path))
    (if (>= (byte-len text) 9) (string=? (substring text 0 9) "x-object ") #f)))

; the first of PATHS that is neither a C file nor an object, or nil
(def %cc-cli-foreign
  (fn (self paths)
    (match
      ((null? paths) ())
      ((%cc-c-file? (first paths)) (self (rest paths)))
      ((%cc-cli-object-file? (first paths)) (self (rest paths)))
      (#t (first paths)))))

; the object -c writes for PATH when no -o is given: its name, in the
; working directory, with .o for .c
(def %cc-cli-object-name
  (fn (_ path)
    (def go
      (fn (self i)
        (match ((< i 0) 0) ((= (byte-at path i) #\/) (+ i 1)) (#t (self (- i 1))))))
    (string-append (substring path (go (- (byte-len path) 1)) (- (byte-len path) 2)) ".o")))

; the target cc -dumpmachine names, or nil off the platforms x-cc builds for
(def %cc-cli-machine
  (fn (_)
    (match
      ((if os-darwin? arch-arm64? #f) "arm64-apple-darwin")
      ((if os-linux? arch-x86-64? #f) "x86_64-linux")
      ((if os-linux? arch-arm64? #f) "aarch64-linux")
      (#t ()))))

; What is wrong with TOK, in musl getopt's words, as every bundle here refuses
; an option: an option that takes a value with none after it requires an
; argument; a long option, or one of a single dash and several letters, as
; cc's are, is named whole without its dashes; else its letter.
(def cc-refusal
  (fn (_ tok)
    (def end (byte-len tok))
    (match
      ((%cc-cli-member? tok %cc-cli-valued)
        (string-append "option requires an argument: " (substring tok 1 end)))
      ((if (> end 2) (= (byte-at tok 1) #\-) #f)
        (string-append "unrecognized option: " (substring tok 2 end)))
      (#t (string-append "unrecognized option: " (substring tok 1 end))))))

; The C names an exported-symbols list TEXT names: a name a line, its
; spaces trimmed, its leading _ (Mach-O's) taken off; a blank line or one
; starting # is none.
(def %cc-cli-symbols
  (fn (_ text)
    (def n (byte-len text))
    (def blank? (fn (_ c) (if (= c 32) #t (if (= c 9) #t (= c 13)))))
    (def line
      (fn (_ from to)
        (def a ((fn (self i) (if (if (< i to) (blank? (byte-at text i)) #f) (self (+ i 1)) i)) from))
        (def b ((fn (self i) (if (if (> i a) (blank? (byte-at text (- i 1))) #f) (self (- i 1)) i)) to))
        (match
          ((= a b) ())
          ((= (byte-at text a) 35) ())   ; #
          ((= (byte-at text a) 95) (substring text (+ a 1) b))   ; _
          (#t (substring text a b)))))
    (def go
      (fn (self i from acc)
        (match
          ((>= i n)
            (let ((l (line from n))) (reverse (if (null? l) acc (pair l acc)))))
          ((= (byte-at text i) 10)
            (let ((l (line from i))) (self (+ i 1) (+ i 1) (if (null? l) acc (pair l acc)))))
          (#t (self (+ i 1) from acc)))))
    (go 0 0 ())))

; what EXPORTS asks cc-compile for: nil, `all`, or the names its lists give
(def %cc-cli-export-names
  (fn (_ exports)
    (match
      ((null? exports) ())
      ((not (null? (filter (fn (_ e) (eq? e (lit all))) exports))) (lit all))
      (#t (let ((go (fn (self es)
                      (if (null? es) ()
                        (append (%cc-cli-symbols (file-read-all (first es))) (self (rest es)))))))
            (go exports))))))

; THUNK's status, 0, or 1 when it raises, with LABEL and the error on stdout
(def %cc-cli-try
  (fn (_ label thunk)
    (guard (e (do (display label) (x-write e) (newline) 1))
      (do (thunk) 0))))

; Run the operands, (Sys args 'program) past the engine's path, and DO NOT
; RETURN.  --help prints the help text, and 0; a refused line prints musl
; getopt's line, when an option is to blame, then the usage text, on stderr,
; and 2.
(def cc-main
  (fn (_ operands)
    (def plan (cc-cli-plan operands))
    (def label (first plan))
    (def paths (if (null? (rest plan)) () (first (rest plan))))
    (match
      ((eq? label (lit help))
        (do (file-write 1 (cc-usage)) (sys-exit 0)))
      ((eq? label (lit refuse))
        (do (if (null? (first (rest plan))) ()
              (file-write 2
                (string-append "cc: " (string-append (cc-refusal (first (rest plan))) "\n"))))
            (file-write 2 (cc-usage))
            (sys-exit 2)))
      ((eq? label (lit machine))
        (let ((m (%cc-cli-machine)))
          (if (null? m) (sys-exit 1) (do (file-write 1 (string-append m "\n")) (sys-exit 0)))))
      ((not (null? (%cc-cli-missing paths)))
        (do (file-write 2 (string-append "cc: no such file: " (%cc-cli-missing paths) "\n"))
            (sys-exit 2)))
      ((eq? label (lit run))
        (let ((src (%cc-cli-source paths)))
          (sys-exit (cc-run-with src (lit caller) (pair (first paths) (first (rest (rest plan))))))))
      ((not (null? (%cc-cli-foreign paths)))
        (do (file-write 2
              (string-append "cc: " (%cc-cli-foreign paths) ": neither C nor an x-cc object\n"))
            (sys-exit 2)))
      (#t
        (let ((out (first (rest (rest plan)))))
          (cc-pp-options! (first (rest (rest (rest plan)))) (first (rest (rest (rest (rest plan))))))
          (sys-exit
            (match
              ((eq? label (lit compile))
                (%cc-cli-try "cc: compile failed: "
                  (fn (_)
                    (let ((target (cc-target)))
                      (map (fn (_ p)
                             (link-write! (if (null? out) (%cc-cli-object-name p) out)
                               (%cc-cli-unit p target)))
                        paths)))))
              ((eq? label (lit check))
                (%cc-cli-try "cc: check failed: "
                  (fn (_)
                    (map (fn (_ p) (cc-parse (cc-lex (list (pair p (file-read-all p))))))
                      (filter %cc-c-file? paths)))))
              (#t
                (%cc-cli-try "cc: build failed: "
                  (fn (_)
                    (let ((target (cc-target)))
                      (cc-link (cc-cli-objects paths target) target out
                        (%cc-cli-export-names (first (rest (rest (rest (rest (rest plan)))))))))))))))))))

(provide cc/cli cc-main cc-cli-plan cc-cli-objects cc-refusal cc-usage)
