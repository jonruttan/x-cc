#!/bin/sh
# tests/card-run.sh FILE -- run one program of docs/card.md, for the bundle
# kit's card check.  X is the x under test; the input is on standard input.
# `run` takes its program's files by their .c ending, so FILE is copied to
# one.
d=$(mktemp -d) || exit 1
trap 'rm -rf "$d"' EXIT
cp "$1" "$d/card.c" || exit 1
"${X:-x}" -l cc -- run "$d/card.c"
