#!/usr/bin/env bash
# Builds and runs the fd-leak reproducer both ways and asserts that the original
# body fails and the shipped fix passes.
set -u

here="$(cd "$(dirname "$0")" && pwd)"
src="$here/fd_leak_test.c"
cc=${CC:-cc}
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

echo "### Original (buggy) — expecting FAIL"
"$cc" -O0 -Wall "$src" -o "$tmp/orig" || exit 2
"$tmp/orig"
orig=$?
echo

echo "### Fixed (-DFD_LEAK_FIXED) — expecting PASS"
"$cc" -O0 -Wall -DFD_LEAK_FIXED "$src" -o "$tmp/fixed" || exit 2
"$tmp/fixed"
fixed=$?
echo

if [ "$orig" -ne 0 ] && [ "$fixed" -eq 0 ]; then
  echo "OK: original fails (exit $orig), fixed passes (exit $fixed)"
  exit 0
fi
echo "UNEXPECTED: original exit=$orig (want non-zero), fixed exit=$fixed (want 0)"
exit 1
