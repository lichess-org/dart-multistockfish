#!/usr/bin/env bash
#
# Builds sf16 and Fairy-Stockfish into a single host binary and runs both
# engines at once, which is what private engine I/O exists to make possible.
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
sf16="$root/pkgs/multistockfish_sf16/ios/multistockfish_sf16/Sources/multistockfish_sf16"
variant="$root/pkgs/multistockfish_variant/ios/multistockfish_variant/Sources/multistockfish_variant"

out="$(mktemp -d)"
trap 'rm -rf "$out"' EXIT
mkdir -p "$out/sf16" "$out/variant"

CXX="${CXX:-clang++}"
common=(-std=c++17 -O1 -DUSE_PTHREADS -DIS_64BIT -DUSE_POPCNT -DNDEBUG -Wno-writable-strings -c)

# The two flavours need different NNUE flags -- sf16 embeds its network with
# .incbin, Fairy-Stockfish is built without one -- so they cannot share a single
# compiler invocation. Compile each to objects, then link them together.
echo "Building sf16..."
for f in "$sf16/stockfish16.cpp" \
         $(find "$sf16/Stockfish16/src" -name '*.cpp' ! -name 'main.cpp'); do
  "$CXX" "${common[@]}" \
    -I"$sf16" -I"$sf16/Stockfish16/src" -I"$sf16/include/multistockfish_sf16" -I"$sf16/nnue" \
    -o "$out/sf16/$(echo "${f#$sf16/}" | tr / _).o" "$f"
done

echo "Building variant..."
for f in "$variant/stockfish_variant.cpp" \
         $(find "$variant/Fairy-Stockfish-2b5d9512/src" -name '*.cpp' \
             ! -name 'main.cpp' ! -name 'pyffish.cpp' ! -name 'ffishjs.cpp'); do
  "$CXX" "${common[@]}" -DNNUE_EMBEDDING_OFF \
    -I"$variant" -I"$variant/Fairy-Stockfish-2b5d9512/src" \
    -I"$variant/include/multistockfish_variant" \
    -o "$out/variant/$(echo "${f#$variant/}" | tr / _).o" "$f"
done

echo "Linking both flavours into one binary..."
"$CXX" -std=c++17 -O1 -o "$out/two_flavours_test" \
  "$here/two_flavours_test.cpp" "$out"/sf16/*.o "$out"/variant/*.o

echo "Running..."
# stdout is left alone on purpose: one of the things this checks is that the
# engines no longer take the process's stdout over, so anything appearing on
# stdout here would itself be a failure.
"$out/two_flavours_test" 2>&1 >/dev/null
