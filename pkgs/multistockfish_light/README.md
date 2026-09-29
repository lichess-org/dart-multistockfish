A package internal to [multistockfish](https://github.com/lichess-org/dart-multistockfish).

It provides only the C++ dynamic library interface to Stockfish, and not the
dart bindings.

This is Stockfish 19 built with the `p_hm` ("simple mirrored piece square")
feature set in place of upstream's, which shrinks the evaluation network from
~94MB to ~1.1MB. The net is compiled into the library, so this flavour needs no
download to evaluate — unlike `multistockfish_chess`, which is the same engine
version with upstream's full-size net left out of the binary.

See `UPDATING.md` for how the vendored engine is patched and refreshed.
