# @weight 2

Recursion carrying many parameters: five and six of them passed
through, most unchanged in every frame and one that varies.  Every
expectation is an oracle row from /usr/bin/cc.

## many parameters

### five and six parameters carried through recursion, and one that varies

`r5` and `r6` carry parameters that never change across the
recursion, `find` carries an array, a length and a target while only
the index moves, and `vary` changes all five.

```cc
(display (cc-run "#include <stdio.h>\nint r5(int a, int b, int c, int d, int e) { return a == 0 ? b + c + d + e : r5(a - 1, b, c, d, e); }\nint r6(int n, int lo, int hi, int step, int base, int mul) { return n <= 0 ? base : mul * r6(n - 1, lo, hi, step, base, mul) + step; }\nint find(int *a, int n, int x, int i, int miss) { return i >= n ? miss : (a[i] == x ? i : find(a, n, x, i + 1, miss)); }\nint vary(int a, int b, int c, int d, int e) { return a == 0 ? b : vary(a - 1, b + 1, c + 1, d + 1, e + 1); }\nint main() { int arr[5]; arr[0] = 4; arr[1] = 8; arr[2] = 15; arr[3] = 16; arr[4] = 23; printf(\"%d %d %d %d\\n\", r5(3, 1, 2, 3, 4), r6(3, 0, 0, 1, 2, 3), find(arr, 5, 16, 0, -1), vary(3, 1, 1, 1, 1)); return 0; }"))
```
---
```output
10 67 3 4
0
```
