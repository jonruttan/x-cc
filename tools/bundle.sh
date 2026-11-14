#!/bin/sh
# # x-cc -- a C compiler on x-lang
#
# ## tools/bundle.sh -- roll the release tarball, and print the pin it needs
#
# @description Builds x-cc-<tag>.tar.gz from a clean tree and prints the
#   (bundle ...) row a consumer's lang.pin.xon must carry.
# @author [Jon Ruttan](jonruttan@gmail.com)
# @copyright 2026 Jon Ruttan
# @license MIT No Attribution (MIT-0)
#
# Usage: sh tools/bundle.sh [TAG] [OUTDIR]
#
# The tarball is built from the tag with `git archive`, not from the working
# tree, so its contents are exactly what is committed. It is byte-reproducible:
# git archive stamps each entry with the commit's time, and gzip is passed -n
# so it records no timestamp of its own.
set -e

cd "$(cd "$(dirname "$0")/.." && pwd)"

TAG="${1:-$(git describe --tags --exact-match 2>/dev/null || echo HEAD)}"
OUT="${2:-dist}"
NAME="x-cc-$TAG"

git rev-parse --verify "$TAG" >/dev/null 2>&1 || {
	echo "bundle: no such commit or tag: $TAG" >&2
	exit 1
}

mkdir -p "$OUT"
# The prefix is a plain directory name so the archive unpacks into one place.
#
# The version stamp is added at roll time: a version row in lang.xon would be
# true only at the tagged commit, so the tag names the version and the archive
# carries it as a file the checkout does not have, matching what `make install`
# writes from git describe. git archive --add-file (2.38+) keeps entries sorted
# and stamped with the commit's time; the one thing it takes from the local
# file is its mode, which is pinned so different umasks produce the same bytes.
STAMP=$(mktemp -d)/version
trap 'rm -rf "$(dirname "$STAMP")"' EXIT
printf '%s\n' "$TAG" > "$STAMP"
chmod 644 "$STAMP"

# Probe with the real stamp, not /dev/null: git rejects a non-regular file,
# which looks the same as not supporting the option and would drop the stamp
# from every tarball.
if git archive "--add-file=$STAMP" --format=tar "$TAG" >/dev/null 2>&1; then
	ADD_STAMP="--add-file=$STAMP"
else
	ADD_STAMP=""
	echo "bundle: git $(git --version | sed 's/.* //') has no --add-file (needs 2.38);" >&2
	echo "  the tarball will carry no version stamp, so a consumer's" >&2
	echo "  (requires-lang \"...\" \"$TAG\") cannot be checked against it." >&2
fi

git archive --format=tar --prefix="$NAME/" $ADD_STAMP "$TAG" \
	| gzip -n -9 > "$OUT/$NAME.tar.gz"

if command -v shasum >/dev/null 2>&1; then
	DG=$(shasum -a 256 "$OUT/$NAME.tar.gz" | cut -d' ' -f1)
else
	DG=$(sha256sum "$OUT/$NAME.tar.gz" | cut -d' ' -f1)
fi
printf '%s  %s\n' "$DG" "$NAME.tar.gz" > "$OUT/$NAME.tar.gz.sha256"

DECLARED=$(sed -n 's/^(lang "\(.*\)")$/\1/p' lang.xon)
URL="https://github.com/jonruttan/x-cc/releases/download/$TAG/$NAME.tar.gz"

# The pin is a published artifact: `x --install-lang <url>` fetches this file,
# reads the digest and tarball URL out of it, and installs, so a release is
# installable without cloning anything.
{
	printf '(lang "%s")\n' "$DECLARED"
	printf '(release "%s")\n' "$TAG"
	printf '(bundle "sha256:%s" "%s")\n' "$DG" "$URL"
	printf '(source "https://github.com/jonruttan/x-cc.git")\n'
} > "$OUT/lang.pin.xon"

echo "bundle: $OUT/$NAME.tar.gz"
echo "bundle: $OUT/lang.pin.xon"
echo "bundle: $DG"
echo
echo "Install it with:"
echo "  x --install-lang https://github.com/jonruttan/x-cc/releases/download/$TAG/lang.pin.xon"
echo
echo "Or pin it, by putting $OUT/lang.pin.xon in your project:"
echo
sed 's/^/  /' "$OUT/lang.pin.xon"
