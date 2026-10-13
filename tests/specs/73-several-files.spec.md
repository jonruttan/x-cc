# @weight 1
# @timeout-scale 2

A program of several files: each preprocessed on its own, `#include "..."`
read from its file's directory (an include guard keeps a second one out),
its file-scope `static` names its own -- two files' `count` and `area` are
four objects -- and a global one file defines and the others declare
`extern`.  The case runs under `run`, then compiled, and shows both outputs
and both statuses; the expectation is what /usr/bin/cc prints for the same
files.

## several files

### a shared header, static helpers of one name in two files, an extern global

```cc
(def hdr "#ifndef SHAPE_H\n#define SHAPE_H\nstruct shape { const char *name; int (*area)(const struct shape *); int w, h; };\nextern int shapes_made;\nstruct shape make_rect(int w, int h);\nstruct shape make_tri(int w, int h);\nint total_area(const struct shape *s, int n);\n#define MAX_SHAPES 4\n#endif\n")
(def fd (File open "/tmp/xcc-spec73-shape.h" (list 'wronly 'creat 'trunc) 420))
(File write fd hdr (Str8 length hdr))
(File close fd)
(def main "#include <stdio.h>\n#include \"xcc-spec73-shape.h\"\nint rects(void);\nint tris(void);\nstatic int count = 7;\nint total_area(const struct shape *s, int n) {\n  int t = 0;\n  for (int i = 0; i < n; i++) t += s[i].area(&s[i]);\n  return t;\n}\nint main(void) {\n  struct shape all[MAX_SHAPES];\n  all[0] = make_rect(3, 4); all[1] = make_tri(6, 5); all[2] = make_rect(2, 2); all[3] = make_tri(4, 4);\n  for (int i = 0; i < MAX_SHAPES; i++) printf(\"%s %d\\n\", all[i].name, all[i].area(&all[i]));\n  printf(\"%d %d %d %d %d\\n\", total_area(all, MAX_SHAPES), shapes_made, rects(), tris(), count);\n  return shapes_made;\n}\n")
(def rect "#include \"xcc-spec73-shape.h\"\n#include \"xcc-spec73-shape.h\"\nstatic int count;\nstatic int area(const struct shape *s) { return s->w * s->h; }\nint shapes_made;\nstruct shape make_rect(int w, int h) { struct shape s = { \"rect\", area, w, h }; count++; shapes_made++; return s; }\nint rects(void) { return count; }\n")
(def tri "#include \"xcc-spec73-shape.h\"\nstatic int count = 100;\nstatic int area(const struct shape *s) { return s->w * s->h / 2; }\nstruct shape make_tri(int w, int h) { struct shape s = { \"tri\", area, w, h }; count++; shapes_made++; return s; }\nint tris(void) { return count; }\n")
(def units (list (pair "/tmp/xcc-spec73-main.c" main) (pair "/tmp/xcc-spec73-rect.c" rect)
                 (pair "/tmp/xcc-spec73-tri.c" tri)))
(display (list (cc-run units) (cc-exe-run units)))
```
---
```output
rect 12
tri 15
rect 4
tri 8
39 4 2 102 7
rect 12
tri 15
rect 4
tri 8
39 4 2 102 7
(4 4)
```

### a header in a directory that includes one above it, and a typedef two files declare

`#include "../common.h"` in `lib/vec.h` names the file from `lib/`, as
from either file that includes `lib/vec.h`; `common.h`'s typedef comes
once into each file, so twice into the program.

```cc
(def put
  (fn (_ path text)
    (def fd (File open path (list 'wronly 'creat 'trunc) 420))
    (File write fd text (Str8 length text))
    (File close fd)))
(if (File exists? "/tmp/xcc-spec73") () (File mkdir "/tmp/xcc-spec73"))
(if (File exists? "/tmp/xcc-spec73/lib") () (File mkdir "/tmp/xcc-spec73/lib"))
(put "/tmp/xcc-spec73/common.h" "#ifndef COMMON_H\n#define COMMON_H\n#define SQ(x) ((x) * (x))\ntypedef long coord;\n#endif\n")
(put "/tmp/xcc-spec73/lib/vec.h" "#ifndef VEC_H\n#define VEC_H\n#include \"../common.h\"\nstruct vec { coord x, y; };\nstruct vec vec_add(struct vec a, struct vec b);\ncoord vec_dot(struct vec a, struct vec b);\ncoord vec_len2(struct vec a);\nextern int vec_ops;\n#endif\n")
(def units (list (pair "/tmp/xcc-spec73/main.c" "#include <stdio.h>\n#include \"lib/vec.h\"\nstatic coord mul(coord a, coord b) { return a * b + 1; }\nint main(void) {\n  struct vec a = { 3, 4 }, b = { 2, 5 };\n  struct vec t = vec_add(a, b);\n  printf(\"%ld %ld %ld %ld %ld %d\\n\", (long)t.x, (long)t.y, (long)vec_dot(a, b), (long)vec_len2(a), (long)mul(2, 3), vec_ops);\n  return vec_ops;\n}\n")
                 (pair "/tmp/xcc-spec73/lib/vec.c" "#include \"vec.h\"\nint vec_ops;\nstatic coord mul(coord a, coord b) { vec_ops++; return a * b; }\nstruct vec vec_add(struct vec a, struct vec b) { struct vec r; r.x = a.x + b.x; r.y = a.y + b.y; vec_ops++; return r; }\ncoord vec_dot(struct vec a, struct vec b) { return mul(a.x, b.x) + mul(a.y, b.y); }\ncoord vec_len2(struct vec a) { return SQ(a.x) + SQ(a.y); }\n")))
(display (list (cc-run units) (cc-exe-run units)))
```
---
```output
5 9 26 25 7 3
5 9 26 25 7 3
(3 3)
```
