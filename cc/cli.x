; # x-cc -- a C compiler on x-lang
;
; ## cc/cli.x -- the command line
;
; @author [Jon Ruttan](jonruttan@gmail.com)
; @copyright 2026 Jon Ruttan
; @license MIT No Attribution (MIT-0)
;
;   x -l cc -- run FILE.c
;
; `run` is the evaluator; `build` is reserved for the compile-asm
; backend to come.  The exit status is the program's own.

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

(def cc-main
  (fn (_ raw-args)
    (def argv (cc-argv raw-args))
    (if (if (pair? argv) (string=? (first argv) "run") #f)
      (if (null? (rest argv))
        (do (file-write 2 "usage: cc run FILE.c\n") (sys-exit 2))
        (let ((path (first (rest argv))))
          (if (file-exists? path)
            (sys-exit (cc-run (file-read-all path)))
            (do (file-write 2
                  (string-append "cc: no such file: "
                    (string-append path "\n")))
                (sys-exit 2)))))
      (do (file-write 2 "usage: cc run FILE.c   (build: pending)\n")
          (sys-exit 2)))))
