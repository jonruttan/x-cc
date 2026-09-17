; # x-cc -- a C compiler on x-lang
;
; ## cc/cli.x -- the command line
;
; @author [Jon Ruttan](jonruttan@gmail.com)
; @copyright 2026 Jon Ruttan
; @license MIT No Attribution (MIT-0)
;
;   x -l cc -- run FILE.c
;   x -l cc -- build FILE.c [-o OUT]
;
; `run` interprets the program and exits with its status.  `build` compiles
; it to an executable at OUT, a.out when no -o is given.

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
    (def mode
      (if (null? argv) ()
        (if (string=? (first argv) "run") (lit run)
          (if (string=? (first argv) "build") (lit build) ()))))
    (def usage "usage: cc run FILE.c | cc build FILE.c [-o OUT]\n")
    (if (null? mode)
      (do (file-write 2 usage) (sys-exit 2))
      (if (null? (rest argv))
        (do (file-write 2 usage) (sys-exit 2))
        (let ((path (first (rest argv))))
          (if (file-exists? path)
            (sys-exit
              (if (eq? mode (lit build))
                (let ((opts (rest (rest argv))))
                  (def out
                    (if (if (pair? opts)
                          (if (string=? (first opts) "-o") (pair? (rest opts)) #f)
                          #f)
                      (first (rest opts))
                      "a.out"))
                  (guard (e (do (display "cc: build failed: ") (%cc-x-write e)
                                (newline) 1))
                    (do (cc-compile (file-read-all path) out) 0)))
                (cc-run (file-read-all path))))
            (do (file-write 2
                  (string-append "cc: no such file: "
                    (string-append path "\n")))
                (sys-exit 2))))))))
