## 0.2.0

- Add `stockfish_light_start()`, which runs the engine and the reader of its output on threads
  of the library's own and reports by posting to Dart ports through
  `Dart_PostCObject`, so that no Dart isolate has to block in a native call for
  the engine's lifetime.
- `init()` now also refuses, with `SF_INIT_READER_RUNNING`, while the previous
  engine's reader has not let go of the pipe.

## 0.1.0

Initial version.

Stockfish 19 with a ~1.1MB embedded NNUE, replacing the retired
`multistockfish_sf16` package (Stockfish 16, 38MB embedded net).

- The engine carries the `p_hm` feature-set patch on top of the `sf_19` release,
  which is what makes the small net possible. See `UPDATING.md`.
- The net (`nn-61e7af4bb97d.nnue`) is embedded with `INCBIN`, so this package is
  built without `-flto`: Xcode's LTO path cannot resolve the `.incbin`
  directive.
