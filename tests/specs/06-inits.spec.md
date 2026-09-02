# @weight 2

Non-literal inits in the compile-asm eligible class.  An accumulator's
entry value may be any expression over the PARAMETERS: decl inits,
pre-loop assignments and the for-INIT fold in order into a map (each
later init substitutes the earlier ones away), and a non-literal init
pads as its own tiny lane function over the params, applied to the
actual args at the call boundary -- once, at entry, native.  Every
expectation is an oracle row from /usr/bin/cc.

## inits over the parameters

### a decl init computed from the parameter

```cc
(display (cc-build-run "#include <stdio.h>\nint upto2n(int n) { int lim = n * 2; int s = 0; int i; for (i = 1; i <= lim; i++) s = s + i; return s; }\nint main() { printf(\"%d\\n\", upto2n(5)); return 0; }"))
```
---
```output
native upto2n
interp main
55
0
```

### the pre-loop assignment graduates: countdown from n

`i = n;` between the decls and the loop was the recorded refusal.

```cc
(display (cc-build-run "#include <stdio.h>\nint cd(int n) { int t = 0; int i; i = n; while (i > 0) { t = t + i; i = i - 1; } return t; }\nint main() { printf(\"%d\\n\", cd(50)); return 0; }"))
```
---
```output
native cd
interp main
1275
0
```

### sequential inits: a later init reads an earlier one

```cc
(display (cc-build-run "#include <stdio.h>\nint seq2(int n) { int a = n; int b = a + 1; int s = 0; while (a < b + 3) { s = s + a; a = a + 1; } return s; }\nint main() { printf(\"%d\\n\", seq2(3)); return 0; }"))
```
---
```output
native seq2
interp main
18
0
```

### a for-INIT from the parameter, counting down

```cc
(display (cc-build-run "#include <stdio.h>\nint down(int n) { int p = 1; int i; for (i = n; i > 0; i--) p = p * 2; return p; }\nint main() { printf(\"%d\\n\", down(10)); return 0; }"))
```
---
```output
native down
interp main
1024
0
```

## the refusal

### an init that calls a function stays interpreted

```cc
(display (cc-build-run "#include <stdio.h>\nint tri(int n) { int s = 0; int i; for (i = 1; i <= n; i++) s = s + i; return s; }\nint viacall(int n) { int s = tri(n); int i; for (i = 0; i < n; i++) s = s + 1; return s; }\nint main() { printf(\"%d %d\\n\", viacall(4), tri(4)); return 0; }"))
```
---
```output
native tri
interp viacall
interp main
14 10
0
```

## twin agreement across a sweep

### the padded init agrees with the interpreted twin on every input

```cc
(display (cc-build-run "#include <stdio.h>\nint cd(int n) { int t = 0; int i; i = n; while (i > 0) { t = t + i; i = i - 1; } return t; }\nint main() { int i; for (i = 0; i < 8; i++) printf(\"%d \", cd(i)); putchar(10); return 0; }"))
```
---
```output
native cd
interp main
0 1 3 6 10 15 21 28 
0
```
