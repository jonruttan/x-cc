#!/bin/sh
# # x-cc -- POSIX cc on x-lang
#
# ## tests/spec-gate.sh -- shim onto the lang kit's gate
#
# @description Sources the PLATFORM's spec-gate; vendors nothing.  Runs the
#   suite and compares its failures to tests/contract/known-failures.txt.
# @author [Jon Ruttan](jonruttan@gmail.com)
# @copyright 2026 Jon Ruttan
# @license MIT No Attribution (MIT-0)
#
# THE PLATFORM SHIPS THE GATE; BUNDLES DO NOT VENDOR IT.  Three bundles once
# carried a byte-identical copy, and a trap bug had to be fixed in all three
# on the same day -- the case that moved it into tools/lang-kit/.  This file
# only says where the bundle is and which x to ask for the kit.
#
# Set X to point at a particular x; X_LANG_KIT overrides the kit location.
set -e

BUNDLE="$(cd "$(dirname "$0")/.." && pwd)"
X="${X:-x}"

KIT="${X_LANG_KIT:-$("$X" --share-dir)/tools/lang-kit}"
[ -f "$KIT/spec-gate.sh" ] || {
	echo "x-cc: no lang kit at $KIT -- set X_LANG_KIT or upgrade x" >&2
	exit 2
}

BUNDLE="$BUNDLE" X="$X" . "$KIT/spec-gate.sh"
