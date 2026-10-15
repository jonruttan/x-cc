# @weight 2
# @timeout-scale 4

C99's variable-length arrays: locals of one and two dimensions, their
dimensions taken once where they are declared; a parameter `m[n][n]` and
one `g[][cols]`; one declared in a loop's body, whose room each time round
takes the last time's place; sizeof of one and of a row; a row as a
pointer.  The case runs under `run`, then compiled, and shows both outputs
and both statuses; the expectation is what the same source prints through
/usr/bin/cc, on macOS and on glibc alike.

## variable-length arrays

### locals, parameters, sizeof, rows, and one declared two thousand times in a loop

```cc
(def src "#include <stdio.h>\nstatic long trace(int n, int m[n][n]) {\n  long t = 0;\n  for (int i = 0; i < n; i++) t += m[i][i];\n  return t;\n}\nstatic int sum_rows(int rows, int cols, int g[][cols], int *out) {\n  int total = 0;\n  for (int r = 0; r < rows; r++) {\n    int acc[cols];\n    for (int c = 0; c < cols; c++) acc[c] = g[r][c] * (c + 1);\n    out[r] = 0;\n    for (int c = 0; c < cols; c++) out[r] += acc[c];\n    total += out[r];\n  }\n  return total;\n}\nint main(void) {\n  int n = 4;\n  int a[n], b[n * 2];\n  int grid[n][n];\n  for (int i = 0; i < n; i++) { a[i] = i * i; for (int j = 0; j < n; j++) grid[i][j] = i * n + j; }\n  for (int i = 0; i < n * 2; i++) b[i] = 100 - i;\n  int out[n];\n  int tot = sum_rows(n, n, grid, out);\n  n = 99;\n  printf(\"%d %d %d %d | %d %d\\n\", a[0], a[1], a[2], a[3], b[0], b[7]);\n  printf(\"%zu %zu %zu %zu\\n\", sizeof a, sizeof b / sizeof b[0], sizeof grid, sizeof grid[1]);\n  printf(\"%ld %d %d %d %d %d\\n\", trace(4, grid), tot, out[0], out[3], grid[2][3], *(grid[3] + 1));\n  long big = 0;\n  for (int k = 1; k <= 2000; k++) { char buf[k * 64]; buf[k * 64 - 1] = (char)k; big += buf[k * 64 - 1] & 1; }\n  printf(\"%ld\\n\", big);\n  return (int)trace(4, grid);\n}\n")
(display (list (cc-run src) (cc-exe-run src)))
```
---
```output
0 1 4 9 | 100 93
16 8 64 16
30 320 20 140 11 13
1000
0 1 4 9 | 100 93
16 8 64 16
30 320 20 140 11 13
1000
(30 30)
```

### refused where C has none: a global, and a struct's field

```cc
(def a (guard (e (e msg)) (cc-run "int n = 3;\nint g[n];\nint main(void) { return 0; }\n")))
(def b (guard (e (e msg)) (cc-run "int main(void) { int n = 2; struct s { int f[n]; } v; return 0; }\n")))
(display (list a b))
```
---
```output
(cc: parse: line 2: expected a constant expression cc: parse: line 1: expected a constant expression)
```
