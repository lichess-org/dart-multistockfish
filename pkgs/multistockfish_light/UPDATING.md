# Updating the vendored Stockfish

The engine under `ios/multistockfish_light/Sources/multistockfish_light/StockfishLight/`
is a copy of upstream Stockfish, currently the `sf_19` release. It is **not**
pristine: it carries three separate modifications, all of which have to be
re-applied whenever the copy is refreshed.

1. **The private-I/O patch**, which is byte-identical to the one
   `multistockfish_chess` carries. It is documented in full in
   [`../multistockfish_chess/UPDATING.md`](../multistockfish_chess/UPDATING.md)
   — read that first, it is not repeated here.
2. **The small-net feature-set patch**, which is what makes this package
   different from `multistockfish_chess`.
3. **A namespace rename**, so this engine can be linked alongside
   `multistockfish_chess` in one binary.

The shim (`stockfish_light.cpp`) also mirrors upstream's `src/main.cpp`; see the
chess package's "The shim also tracks upstream's entry point" section.

## 2. The small-net feature-set patch

Upstream's Stockfish 19 evaluates with a ~94MB network (`nn-1a298aa575a0.nnue`,
98,511,183 bytes). That is far too large to embed in a mobile app, and the whole
point of this package is a net that ships inside the binary.

Note that `tests.stockfishchess.org` serves the nets compressed, so the
`Content-Length` of a download is *not* the file size — it reports ~79MB for
this one. Measure the net on disk after downloading.

The patch replaces upstream's feature set (`half_ka_v2_hm` + `full_threats` +
`pp_3wide`) with a single much smaller one, `p_hm` ("simple mirrored piece
square"), and points `EvalFileDefaultName` at the matching net. The net that
goes with it is **`nn-61e7af4bb97d.nnue`, ~1.1MB**, committed under
`Sources/multistockfish_light/nnue/`.

The patch is not upstream's. It comes from:

    https://github.com/niklasf/Stockfish/commit/81348d3fb4f68bda5c442e7459de78ab00acbc55

authored by sscg13 and rebased by Niklas Fiekas. Per its commit message it
tested at **+9.75 ± 2.7 Elo over 20,000 games against `sf18-15mb`** (the
reference build named there), so the feature-set change is not only a size
reduction. The rebase onto the release was separately checked for
non-regression against the original branch.

### Re-applying it

That commit is written against a development snapshot, not against a release, so
it has to be rebased onto whichever `sf_N` tag is being vendored. Let git do it:

```bash
git clone https://github.com/official-stockfish/Stockfish.git sf && cd sf
git remote add niklasf https://github.com/niklasf/Stockfish.git
git fetch niklasf 81348d3fb4f68bda5c442e7459de78ab00acbc55

git checkout -b light sf_19          # or the tag being vendored
git cherry-pick 81348d3fb4f68bda5c442e7459de78ab00acbc55
```

For `sf_19` this applied with no conflicts: the commit's base was only six
commits behind the tag.

**Verify the rebase before trusting it.** The commit message ends with a
`Bench: <nodes>` line, which is a deterministic node count — build and compare:

```bash
cd src && make -j build ARCH=apple-silicon   # or your ARCH
./stockfish bench 2>&1 | tail -3
```

`Nodes searched` must equal the `Bench:` value in the commit message
(2793281 for the `sf_19` rebase). If it does not, the rebase changed engine
behaviour and must be resolved by hand rather than shipped.

Note that this standalone build is only possible *before* the private-I/O patch
is applied — afterwards the engine references `sfio::in()`/`sfio::out()`, which
only exist next to the shim. So do the feature-set rebase and the bench check
first, then apply the private-I/O patch.

## 3. The namespace rename

On iOS every flavour is statically linked into one app binary, so two engines
both living in `namespace Stockfish` would collide. This package's engine is
compiled into `namespace StockfishLight` instead, and `sfio_config.h` names the
same namespace so that `sfio::in()`/`sfio::out()` resolve to this flavour's
streams.

The rename is mechanical, and only two forms are identifiers:

```bash
cd ios/multistockfish_light/Sources/multistockfish_light/StockfishLight/src

# 1. qualified names
grep -rn 'Stockfish::' . --include='*.cpp' --include='*.h'
# 2. namespace declarations, `using namespace`, and `} // namespace Stockfish`
grep -rn 'namespace Stockfish\b' . --include='*.cpp' --include='*.h'
```

Rewrite exactly those two: `Stockfish::` → `StockfishLight::` and
`namespace Stockfish` → `namespace StockfishLight`.

Everything else that matches the bare word `Stockfish` is prose, a licence
header, the `"Stockfish " << version` banner, or a URL, and must be **left
alone**. After the rename, the only remaining bare `Stockfish` occurrences
should be the four upstream URLs:

```bash
grep -rn 'Stockfish\(::\|[^L ,]\|$\)' . --include='*.cpp' --include='*.h'
```

A missed identifier is a compile error, not a silent bug, so the build is the
real check here.

## The embedded net

`nnue/network.cpp`'s `INCBIN(EmbeddedNNUE, EvalFileDefaultName)` compiles the net
into the library, so — unlike `multistockfish_chess` — this package must **not**
be built with `-DNNUE_EMBEDDING_OFF`.

Two consequences worth knowing before changing build flags:

- **No LTO.** `.incbin` is an inline-assembly directive, and Xcode's LTO bitcode
  path does not run the integrated-assembler step it needs; any `-flto` mode
  fails with "Could not find incbin file". Both the podspec and `Package.swift`
  carry this as a comment.
- **The net is found via an include path**, not the working directory, which
  differs between SwiftPM, CocoaPods and Xcode. `Package.swift` adds a `nnue`
  `headerSearchPath` for exactly this. Android's CMake build instead downloads
  the net into `CMAKE_BINARY_DIR`, which is where its assembler runs.

When the net changes, update all four of: `EvalFileDefaultName` (via the
feature-set patch), the committed file under `nnue/`, the `file(DOWNLOAD ...)`
URL **and its `EXPECTED_HASH`** in `android/CMakeLists.txt`, the podspec's
"Download nnue" script phase, and the `nnue/nn-....nnue` exclude in
`Package.swift`.

## Verifying the result

From the repository root:

```bash
# Fast: the shim's own behaviour, against a real engine. Covers all three
# flavours, since the shim is identical across them.
pkgs/multistockfish_variant/test/run_shim_test.sh

# Slow (compiles two engines): links multistockfish_light and Fairy-Stockfish
# into one binary, the way iOS does, and searches on both at once. This is the
# test that fails if a flavour is still writing to a shared stream, and the one
# that catches a botched namespace rename.
test/run_two_flavours_test.sh
```

Both must print `PASS`.
