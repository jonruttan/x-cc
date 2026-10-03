; # x-cc -- a C compiler on x-lang
;
; ## cc/cli.x -- the command line
;
; @author [Jon Ruttan](jonruttan@gmail.com)
; @copyright 2026 Jon Ruttan
; @license MIT No Attribution (MIT-0)
;
;   x -l cc -- run FILE.c [ARG ...]
;   x -l cc -- build FILE.c [-o OUT]
;   x -l cc -- --help
;
; `run` interprets the program, FILE.c its name and the ARGs after it in
; its argv, and exits with its status.  `build` compiles it to an
; executable at OUT, a.out when no -o is given.
(module cc/cli)

(import cc/prims byte-at byte-len file-exists? file-read-all file-write filter
  string-append substring
  string=? sys-exit x-write)
(import cc/eval cc-run-with)
(import cc/gen cc-compile)
(import x/sys/opts Opts)

(def %cc-cli-engine-flag?
  (fn (_ s)
    (if (string=? s "--quiet") #t
      (if (string=? s "--batch") #t
        (if (string=? s "--no-color") #t (string=? s "--verbose"))))))

(def cc-argv
  (fn (_ raw)
    (def ops
      (filter (fn (_ a) (not (%cc-cli-engine-flag? a)))
        (if (pair? raw) (rest raw) ())))
    (if (if (pair? ops) (string=? (first ops) "--") #f)
      (rest ops)
      ops)))

; The options, declared once: what --help prints, what a refusal prints, and
; what build's tail is parsed against.  busybox has no cc, so the text is this
; bundle's, laid out as busybox lays its help text out.
(def cc-options
  (Opts declare "cc" "run FILE.c [ARG]...\nor: cc build [-o OUT] FILE.c"
    "Run a C program, or build it into an executable"
    (list
      (Opts arg "-o" "OUT" "Build: write the executable to OUT (default a.out)"))))

; The help text: what --help prints on stdout, and a refusal on stderr.
(def cc-usage (fn (_) (Opts usage cc-options)))

; ARGV to what the line asks: (help), (run PATH ARGS), (build PATH OUT), or
; (refuse TOK) -- TOK the option refused, nil for a line that is only wrong in
; shape.  run's words after FILE.c are the program's, never parsed; build's
; tail takes -o anywhere, a second -o keeping the last.
(def cc-cli-plan
  (fn (_ argv)
    (match
      ((Opts help? cc-options argv) (list (lit help)))
      ((null? argv) (list (lit refuse) ()))
      ((string=? (first argv) "run")
        (if (null? (rest argv)) (list (lit refuse) ())
          (list (lit run) (first (rest argv)) (rest (rest argv)))))
      ((string=? (first argv) "build")
        (let ((o (Opts parse cc-options (rest argv))))
          (match
            ((not (null? (Opts unknown o))) (list (lit refuse) (Opts unknown o)))
            ((if (pair? (Opts operands o)) (null? (rest (Opts operands o))) #f)
              (list (lit build) (first (Opts operands o)) (Opts value o "-o" "a.out")))
            (#t (list (lit refuse) ())))))
      (#t (list (lit refuse) ())))))

; What is wrong with TOK, in musl getopt's words, as every bundle here refuses
; an option: in a short cluster the first letter cc does not take is
; unrecognized, and -o with nothing after it requires an argument; a long
; option is named without its dashes.
(def cc-refusal
  (fn (_ tok)
    (def end (byte-len tok))
    (match
      ((if (> end 2) (= (byte-at tok 1) #\-) #f)
        (string-append "unrecognized option: " (substring tok 2 end)))
      ((string=? tok "-o") "option requires an argument: o")
      (#t (string-append "unrecognized option: " (substring tok 1 2))))))

; Run the command line and DO NOT RETURN.  --help prints the help text, and 0;
; a refused line prints musl getopt's line, when an option is to blame, then
; the usage text, on stderr, and 2.
(def cc-main
  (fn (_ raw-args)
    (def plan (cc-cli-plan (cc-argv raw-args)))
    (def label (first plan))
    (match
      ((eq? label (lit help))
        (do (file-write 1 (cc-usage)) (sys-exit 0)))
      ((eq? label (lit refuse))
        (do (if (null? (first (rest plan))) ()
              (file-write 2
                (string-append "cc: " (string-append (cc-refusal (first (rest plan))) "\n"))))
            (file-write 2 (cc-usage))
            (sys-exit 2)))
      ((not (file-exists? (first (rest plan))))
        (do (file-write 2
              (string-append "cc: no such file: "
                (string-append (first (rest plan)) "\n")))
            (sys-exit 2)))
      ((eq? label (lit build))
        (sys-exit
          (guard (e (do (display "cc: build failed: ") (x-write e) (newline) 1))
            (do (cc-compile (file-read-all (first (rest plan))) (first (rest (rest plan)))) 0))))
      (#t
        (sys-exit
          (cc-run-with (file-read-all (first (rest plan))) (lit caller)
            (pair (first (rest plan)) (first (rest (rest plan))))))))))

(provide cc/cli cc-argv cc-main cc-cli-plan cc-refusal cc-usage)
