## 0.1.0

Initial version.

Stockfish 19 with a ~1.1MB embedded NNUE, replacing the retired
`multistockfish_sf16` package (Stockfish 16, 38MB embedded net).

- The engine carries the `p_hm` feature-set patch on top of the `sf_19` release,
  which is what makes the small net possible. See `UPDATING.md`.
- The net (`nn-61e7af4bb97d.nnue`) is embedded with `INCBIN`, so this package is
  built without `-flto`: Xcode's LTO path cannot resolve the `.incbin`
  directive.
