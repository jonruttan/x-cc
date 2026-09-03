# @weight 2

Recursion past the lane's four arguments.  A self-call must pass every
parameter the function has, and takes at most four.  But a parameter
that EVERY self-call passes along unchanged holds the same value in
every frame, so it needs no slot: it lives in one scratch cell,
written once at entry, and the self-call passes only the parameters
that actually vary.  A parameter the recursion changes cannot be
hoisted, because each frame would need its own cell -- so a recursion
whose parameters all vary stays interpreted.  Every expectation is an
oracle row from /usr/bin/cc.

## hoisting

### five and six parameters carried through recursion, and one that varies

`r5` hoists one of its four unchanging parameters, `r6` two, and
`find` carries an array, a length and a target while only the index
moves.  `vary` changes all five, so it refuses.

```cc
(display (cc-build-run "#include <stdio.h>\nint r5(int a, int b, int c, int d, int e) { return a == 0 ? b + c + d + e : r5(a - 1, b, c, d, e); }\nint r6(int n, int lo, int hi, int step, int base, int mul) { return n <= 0 ? base : mul * r6(n - 1, lo, hi, step, base, mul) + step; }\nint find(int *a, int n, int x, int i, int miss) { return i >= n ? miss : (a[i] == x ? i : find(a, n, x, i + 1, miss)); }\nint vary(int a, int b, int c, int d, int e) { return a == 0 ? b : vary(a - 1, b + 1, c + 1, d + 1, e + 1); }\nint main() { int arr[5]; arr[0] = 4; arr[1] = 8; arr[2] = 15; arr[3] = 16; arr[4] = 23; printf(\"%d %d %d %d\\n\", r5(3, 1, 2, 3, 4), r6(3, 0, 0, 1, 2, 3), find(arr, 5, 16, 0, -1), vary(3, 1, 1, 1, 1)); return 0; }"))
```
---
```output
native r5
native r6
native find
interp vary
interp main
10 67 3 4
0
```
