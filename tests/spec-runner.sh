#!/bin/sh
# # x-cc -- POSIX cc on x-lang
#
# ## tests/spec-runner.sh -- the bundle's runner
#
# @description Sources the PLATFORM's spec runner; vendors nothing.
# @author [Jon Ruttan](jonruttan@gmail.com)
# @copyright 2026 Jon Ruttan
# @license MIT No Attribution (MIT-0)
#
# NOT ONE PATH INTO THE X-LANG SOURCE TREE.  Everything here comes from x
# itself: --share-dir says which tree x reads from (repo root in a checkout,
# share/x installed) and --engine-path says where the engine is.
#
# Set X to point at a particular x; otherwise the one on PATH is used.
set -e

BUNDLE="$(cd "$(dirname "$0")/.." && pwd)"
X="${X:-x}"

command -v "$X" >/dev/null 2>&1 || {
	echo "x-cc: no x on PATH.  Set X=/path/to/x.sh and retry." >&2
	exit 1
}

X_ROOT="$("$X" --share-dir)"
X_BIN="${X_BIN:-$("$X" --engine-path)}"

# REQUIRED FROM AN INSTALLED TREE: the runner finds its harness from the
# directory holding the ENGINE, which is only true in a checkout.
SPEC_RUNNER_DIR="$X_ROOT/tests"
export SPEC_RUNNER_DIR

# The harness is GENERATED, never committed: it embeds two absolute paths
# that are facts of this machine, not of the bundle.
sh "$BUNDLE/tests/gen-harness.sh" "$X_ROOT" "$BUNDLE"

LANG_LIB="$BUNDLE/tests/lib/harness.gen.x"
# SPEC_PATH is env-overridable so a single spec file can be run in isolation.
SPEC_PATH="${SPEC_PATH:-$BUNDLE/tests/specs}"

# THE SUITE BOOTS FROM A STATE IMAGE OF THE HARNESS, when the platform can
# write one.  tools/dev/image-build.sh images a child that loaded the harness
# and keys that image on everything it depends on -- the harness, the
# platform's lib/, its engine, and cc/ (the KEY-PATH) -- so an edit to any of
# them rewrites it, and a current one is skipped.  Each spec file then loads
# the image instead of booting the platform from source.
#  THE WRITER IS A CHECKOUT TOOL.  An installed tree has no image-build.sh,
# and a library holding words no image can carry is refused; both say so on
# stderr and the suite boots from source exactly as it did before.
#  AND A PROBE FOR THE FIX, NOT FOR A VERSION.  A platform whose Ansi.install
# moves a REPL printer it does not own takes this bundle's %repl-print away
# when the image loads (x-lang#655) -- a few specs then differ in how a value
# prints, or, worse, none do and the suite passes on the platform's printer.
# The fix carries `Ansi repl-own`; ask the platform for it rather than for a
# version, and boot from source on one that answers no.
#  IMG=0 IS THE CONTROL -- the same suite from source, for when the image is
# the suspect.  One file per process there too, so the boot is the only thing
# that differs between the two runs.
if [ "${IMG:-1}" = 0 ]; then
	SPEC_BATCH="${SPEC_BATCH:-1}"; export SPEC_BATCH
else
	_builder="$X_ROOT/tools/dev/image-build.sh"
	_probe="${TMPDIR:-/tmp}/x-imgprobe.$$.x"
	printf '(Ansi repl-own)\n' > "$_probe"
	_keeps_printer=0
	"$X" -f "$_probe" >/dev/null 2>&1 && _keeps_printer=1
	rm -f "$_probe"
	if [ ! -f "$_builder" ]; then
		echo "x-cc: no image writer at $_builder (not a checkout) -- the suite boots from source" >&2
	elif [ "$_keeps_printer" = 0 ]; then
		echo "x-cc: the platform moves a REPL printer it does not own (x-lang#655) -- the suite boots from source" >&2
	elif X_BIN="$X_BIN" sh "$_builder" "$LANG_LIB" "$BUNDLE/tests/lib/.images" "$BUNDLE/cc"; then
		X_IMG_DIR="$BUNDLE/tests/lib/.images"; export X_IMG_DIR
	else
		echo "x-cc: no state image -- the suite boots from source" >&2
	fi
fi

# NO COLLECT AT THE SNIPPET SEAM (x-lang#568/#572): the per-seam heap collect
# killed x-ash's and x-python's suites; x-cc sets the same knob for the same
# reason rather than rediscovering it.
export SPEC_SEAM_COLLECT=0

# AND THEREFORE A HIGHER CEILING, which is the other half of that knob rather
# than an unrelated setting.  Nothing collects between snippets, so a batch's
# allocation is the SUM of its snippets -- and this bundle's are the most
# allocating in the fleet: every `build` case compiles C to native through the
# engine's compile lane, and since x-engine-c v0.2.2 the lane KEEPS the bytes
# it emits rather than recompiling them.  That is a deliberate trade (a warm
# process never recompiles) and it is retained memory all the same.
#
# The platform's default is 300,000,000 objects.  Measured on this suite
# against v0.2.2: 300M gives 17 failures, 330M gives 14, and 380M gives none --
# all of them `allocation limit exceeded`, never a wrong answer.  600M is that
# measured floor with roughly half again on top, which is the headroom
# a number like this wants: enough that a case growing a little does not turn
# into a mystery, small enough to still be a guard.  The ceiling exists because
# a runaway here takes the machine down, so raising it is not free and it is
# not raised further than the measurement asks.
#
# Overridable, like the platform's own: an operator narrowing this down wants
# to move it without editing the file.
export X_ALLOC_LIMIT_OBJS="${X_ALLOC_LIMIT_OBJS:-600000000}"

. "$X_ROOT/tests/spec-runner.sh"
