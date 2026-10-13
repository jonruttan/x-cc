# @weight 1
# @timeout-scale 2

The POSIX headers: dirent.h, sys/stat.h and unistd.h, with each
platform's struct dirent and struct stat; signal.h, whose handler the C
library calls.  Each case runs under `run`, then compiled, and shows both
outputs and both statuses; the expectation is what the same source prints
through /usr/bin/cc, on macOS and on glibc alike.

## POSIX headers

### a directory listed with readdir, sorted with qsort, and each file's stat

```cc
(def src "#include <stdio.h>\n#include <stdlib.h>\n#include <string.h>\n#include <dirent.h>\n#include <sys/stat.h>\n#include <unistd.h>\nstatic int by_name(const void *a, const void *b) {\n  return strcmp(*(char *const *)a, *(char *const *)b);\n}\nint main(void) {\n  char d[64], path[128], *seen[8];\n  const char *names[] = { \"pear\", \"apple\", \"fig\" };\n  int i, n = 0;\n  struct dirent *e;\n  struct stat st;\n  snprintf(d, sizeof d, \"/tmp/xcc-dirent-%d\", (int)getpid());\n  mkdir(d, 0755);\n  for (i = 0; i < 3; i++) {\n    FILE *fp;\n    snprintf(path, sizeof path, \"%s/%s\", d, names[i]);\n    fp = fopen(path, \"w\");\n    fprintf(fp, \"%*s\", (i + 1) * 10, \"x\");\n    fclose(fp);\n  }\n  DIR *dp = opendir(d);\n  while ((e = readdir(dp)) != NULL)\n    if (e->d_name[0] != '.') seen[n++] = strdup(e->d_name);\n  closedir(dp);\n  qsort(seen, n, sizeof seen[0], by_name);\n  for (i = 0; i < n; i++) {\n    snprintf(path, sizeof path, \"%s/%s\", d, seen[i]);\n    if (stat(path, &st) == 0)\n      printf(\"%s %ld %d %d %d\\n\", seen[i], (long)st.st_size, S_ISREG(st.st_mode), S_ISDIR(st.st_mode), st.st_mtime > 0);\n    unlink(path);\n    free(seen[i]);\n  }\n  stat(d, &st);\n  printf(\"%d %d %d\\n\", S_ISDIR(st.st_mode), access(d, R_OK | X_OK), rmdir(d));\n  return n;\n}\n")
(display (list (cc-run src) (cc-exe-run src)))
```
---
```output
apple 20 1 0 1
fig 30 1 0 1
pear 10 1 0 1
1 0 0
apple 20 1 0 1
fig 30 1 0 1
pear 10 1 0 1
1 0 0
(3 3)
```

### a signal handler set, raised, replaced by SIG_IGN, and handed back

The handler is put back to SIG_DFL at the end: run shares the x process's
handlers, and the compiled program, started from it, keeps an ignored one.

```cc
(def src "#include <stdio.h>\n#include <signal.h>\nstatic volatile sig_atomic_t hits;\nstatic int last;\nstatic void on_usr1(int sig) { hits++; last = sig; }\nint main(void) {\n  void (*old)(int) = signal(SIGUSR1, on_usr1);\n  printf(\"%d\\n\", old == SIG_DFL);\n  raise(SIGUSR1);\n  raise(SIGUSR1);\n  printf(\"%d %d\\n\", (int)hits, last == SIGUSR1);\n  old = signal(SIGUSR1, SIG_IGN);\n  raise(SIGUSR1);\n  printf(\"%d %d\\n\", (int)hits, old == on_usr1);\n  signal(SIGUSR1, SIG_DFL);\n  return (int)hits;\n}\n")
(display (list (cc-run src) (cc-exe-run src)))
```
---
```output
1
2 1
2 1
1
2 1
2 1
(2 2)
```
