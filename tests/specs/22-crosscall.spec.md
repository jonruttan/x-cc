# @weight 2

A compiled function calls another by name.  The lane names a callee
through a free variable holding its prim (x-lang#603), so a caller no
longer has to inline the callee's body: callees are compiled before
their callers, and each native twin gets a door that takes the C
parameters in order -- the twin itself when it already does, and
otherwise a lane function that runs the entry effects and hands the
twin its kept parameters and its accumulators' initial values.

That reaches what inlining cannot express.  A callee with a LOOP has
no single expression to inline, and a RECURSIVE callee cannot be
inlined at all; both are ordinary calls now.  Mutual recursion still
stays interpreted: one of the pair has to compile first, and the door
it would call does not exist yet.  A call takes at most four
arguments, as every call in this lane does.

Every expectation is an oracle row from /usr/bin/cc; the native twins
print what the interpreter prints.

## calling a compiled twin

### a callee with a loop, called twice, and a recursive callee

```cc
(display (cc-build-run "#include <stdio.h>\nint sumto(int n) { int i; int s; s = 0; for (i = 1; i <= n; i++) s = s + i; return s; }\nint twice(int n) { return sumto(n) * 2; }\nint hyp(int a, int b) { return sumto(a) + sumto(b); }\nint fact(int n) { return n < 2 ? 1 : n * fact(n - 1); }\nint viafact(int n) { return fact(n) + 1; }\nint main() { printf(\"%d %d %d %d\\n\", sumto(4), twice(4), hyp(3, 4), viafact(5)); return 0; }"))
```
---
```output
native sumto
native twice
native hyp
native fact
native viafact
interp main
10 20 16 121
0
```

## the refusal

### mutual recursion has no door to call

```cc
(display (cc-build-run "#include <stdio.h>\nint od(int n);\nint ev(int n) { return n == 0 ? 1 : od(n - 1); }\nint od(int n) { return n == 0 ? 0 : ev(n - 1); }\nint main() { printf(\"%d %d\\n\", ev(8), od(8)); return 0; }"))
```
---
```output
interp ev
interp od
interp main
1 0
0
```
