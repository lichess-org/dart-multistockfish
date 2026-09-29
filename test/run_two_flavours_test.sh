#!/usr/bin/env bash
#
# Builds multistockfish_light and Fairy-Stockfish into a single host binary and
# runs both engines at once, which is what private engine I/O exists to make
# possible.
#
# It links the two flavours together on purpose: that is how iOS builds them
# under Swift Package Manager, so this also checks that their symbols do not
# collide. Android loads them as separate .so files, which is strictly easier.
#
# This one takes a few minutes, because it compiles two whole engines. For the
# shim's own behaviour -- the re-entry guard, pipe reuse, non-blocking writes --
# pkgs/multistockfish_variant/test/run_shim_test.sh is much quicker and covers
# all three flavours, since the shim is identical across them.
#
# Usage: test/run_two_flavours_test.sh

set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$here/.."
light="$root/pkgs/multistockfish_light/ios/multistockfish_light/Sources/multistockfish_light"
variant="$root/pkgs/multistockfish_variant/ios/multistockfish_variant/Sources/multistockfish_variant"

out="$(mktemp -d)"
trap 'rm -rf "$out"' EXIT
mkdir -p "$out/light" "$out/variant"

CXX="${CXX:-clang++}"
common=(-std=c++17 -O1 -DUSE_PTHREADS -DIS_64BIT -DUSE_POPCNT -DNDEBUG -Wno-writable-strings -c)

# The two flavours need different NNUE flags -- light embeds its network with
# .incbin, Fairy-Stockfish is built without one -- so they cannot share a single
# compiler invocation. Compile each to objects, then link them together.
#
# src/universal is skipped for the same reason the shipped builds exclude it:
# those files belong to upstream's macOS universal-binary build and do not link
# into a normal one.
echo "Building light..."
for f in "$light/stockfish_light.cpp" "$light/sfio.cpp" \
         $(find "$light/StockfishLight/src" -name '*.cpp' ! -name 'main.cpp' \
             -not -path '*/universal/*'); do
  "$CXX" "${common[@]}" \
    -I"$light" -I"$light/StockfishLight/src" \
    -I"$light/include/multistockfish_light" -I"$light/nnue" \
    -o "$out/light/$(echo "${f#$light/}" | tr / _).o" "$f"
done

echo "Building variant..."
for f in "$variant/stockfish_variant.cpp" "$variant/sfio.cpp" \
         $(find "$variant/Fairy-Stockfish-2b5d9512/src" -name '*.cpp' \
             ! -name 'main.cpp' ! -name 'pyffish.cpp' ! -name 'ffishjs.cpp'); do
  "$CXX" "${common[@]}" -DNNUE_EMBEDDING_OFF \
    -I"$variant" -I"$variant/Fairy-Stockfish-2b5d9512/src" \
    -I"$variant/include/multistockfish_variant" \
    -o "$out/variant/$(echo "${f#$variant/}" | tr / _).o" "$f"
done

echo "Linking both flavours into one binary..."
"$CXX" -std=c++17 -O1 -o "$out/two_flavours_test" \
  "$here/two_flavours_test.cpp" "$out"/light/*.o "$out"/variant/*.o

echo "Running..."
# stdout is left alone on purpose: one of the things this checks is that the
# engines no longer take the process's stdout over, so anything appearing on
# stdout here would itself be a failure.
"$out/two_flavours_test" 2>&1 >/dev/null
