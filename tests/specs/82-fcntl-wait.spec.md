# @weight 1
# @timeout-scale 2

fcntl.h's flags and sys/wait.h's status macros, as each platform's C
library spells them: what x-os's launcher includes.  open, openat, fcntl
and ioctl, and syscall, take their arguments past the fixed ones on the
stack on arm64 macOS, where both a compiled call and run put them,
through the trampoline; elsewhere it is an ordinary call.  The
program's output is what /usr/bin/cc prints for the same source.

## the headers

### open's flags, a child's exit status and the signal that ended another

```cc
(def src "#include <stdio.h>\n#include <fcntl.h>\n#include <unistd.h>\n#include <signal.h>\n#include <sys/wait.h>\nint main(void) {\n  int fd, st; char buf[16]; long n; pid_t p;\n  fd = creat(\"/tmp/xcc-spec82.txt\", 0644);\n  write(fd, \"one\\n\", 4); close(fd);\n  fd = open(\"/tmp/xcc-spec82.txt\", O_WRONLY | O_APPEND);\n  write(fd, \"two\\n\", 4); close(fd);\n  fd = open(\"/tmp/xcc-spec82.txt\", O_RDONLY);\n  n = read(fd, buf, sizeof buf - 1); buf[n] = 0; close(fd);\n  printf(\"%s%d\\n\", buf, open(\"/tmp/xcc-spec82-none\", O_RDONLY) < 0);\n  p = fork();\n  if (p == 0) _exit(5);\n  waitpid(p, &st, 0);\n  printf(\"%d %d %d\\n\", WIFEXITED(st), WEXITSTATUS(st), WIFSIGNALED(st));\n  p = fork();\n  if (p == 0) { kill(getpid(), SIGTERM); _exit(0); }\n  waitpid(p, &st, 0);\n  printf(\"%d %d %d\\n\", WIFEXITED(st), WIFSIGNALED(st), WTERMSIG(st));\n  return 0;\n}\n")
(display (list (cc-run src) (cc-exe-run src)))
```
---
```output
one
two
1
1 5 0
0 1 15
one
two
1
1 5 0
0 1 15
(0 0)
```

### open with a mode, and syscall with seven arguments as x-engine-c's x-cli.c makes it

On arm64 macOS a variadic function's arguments past its fixed ones go on
the stack -- open's mode, and every one of syscall's past its number -- and
on x86-64 a seventh argument does.

```cc
(def src "#include <stdio.h>\n#include <fcntl.h>\n#include <unistd.h>\n#include <sys/stat.h>\n#include <sys/syscall.h>\nint main(void) {\n  struct stat st; int fd; long p[7], r;\n  unlink(\"/tmp/xcc-spec82-mode\");\n  fd = open(\"/tmp/xcc-spec82-mode\", O_WRONLY | O_CREAT | O_TRUNC, 0640);\n  close(fd);\n  stat(\"/tmp/xcc-spec82-mode\", &st);\n  printf(\"%o\\n\", st.st_mode & 0777);\n  fflush(stdout);\n  p[0] = SYS_write; p[1] = 1; p[2] = (long)\"seven\\n\"; p[3] = 6; p[4] = p[5] = p[6] = 0;\n#pragma GCC diagnostic push\n#pragma GCC diagnostic ignored \"-Wdeprecated-declarations\"\n  r = syscall(p[0], p[1], p[2], p[3], p[4], p[5], p[6]);\n#pragma GCC diagnostic pop\n  printf(\"%ld\\n\", r);\n  return 0;\n}\n")
(display (list (cc-run src) (cc-exe-run src)))
```
---
```output
640
seven
6
640
seven
6
(0 0)
```
