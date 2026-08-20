#!/usr/bin/env bash
#
# Builds and runs the native shim integration test on the host.
#
# The shim is identical across the three flavours, so testing it against
# Fairy-Stockfish covers all of them — and Fairy is the one that builds without
# an NNUE file, which makes it the only flavour that runs unattended.
#
# Usage: pkgs/multistockfish_variant/test/run_shim_test.sh

set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
sources="$here/../ios/multistockfish_variant/Sources/multistockfish_variant"
out="$(mktemp -d)"
trap 'rm -rf "$out"' EXIT

engine_sources=$(
  find "$sources/Fairy-Stockfish-2b5d9512/src" -name '*.cpp' \
    ! -name 'main.cpp' ! -name 'pyffish.cpp' ! -name 'ffishjs.cpp'
)

echo "Building..."
"${CXX:-clang++}" \
  -std=c++17 -O1 \
  -DNNUE_EMBEDDING_OFF -DUSE_PTHREADS -DNDEBUG \
  -Wno-writable-strings \
  -o "$out/shim_test" \
  "$sources/stockfish_variant.cpp" \
  "$here/shim_test.cpp" \
  $engine_sources

echo "Running..."
# The engine dup2s its pipe onto stdout, so the test reports on stderr and the
# engine's own chatter on stdout is discarded.
"$out/shim_test" 2>&1 >/dev/null
