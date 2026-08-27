## 0.4.0

- **Breaking:** the engine no longer redirects the process's `stdin` and
  `stdout` onto its pipe. Each library now reads and writes streams of its own,
  bound straight to its own pipe. Two flavours can therefore be resident at the
  same time without their output landing in one channel, and the host
  application keeps its own `stdout` while an engine is running.
- `SF_MAIN_DUP2_FAILED` is now reported when the engine's input and output cannot
  be attached to its pipes. Every constant keeps its name and its value; only the
  mechanism behind that failure changed.

## 0.3.1

- Fix `Failed to lookup symbol 'stockfish_variant_init'` on iOS in archived (Release/TestFlight/
  App Store) builds. Under Swift Package Manager the library is linked
  statically into the app binary, and Xcode's archive step strips that binary
  with its default "All Symbols" style, which removed the plugin's exports from
  the symbol table and the exports trie. The entry points are now weak
  definitions, which `strip` preserves.

## 0.3.0

- Refuse to run a second engine while one is still alive, instead of racing it
  over the engine's process-global state.
- Reuse the communication pipes across restarts instead of allocating a new pair
  each time, which leaked two file descriptors per start.
- Never block in `stdin_write`: the input pipe is non-blocking, so a write to an
  engine that has stopped reading now reports a failure instead of hanging the
  calling thread.
- Discard anything left in either pipe by a previous run.
- Report failures through `last_error()`, and the engine's lifecycle position
  through `phase()`, `phase_step()` and `phase_elapsed_ms()`, so an engine that
  will not start or will not quit can say where it is stuck.
- Report an error instead of running when `dup2` fails, when the engine throws,
  or when the output pipe reaches end of file (which previously spun the reader).

## 0.2.0

- Migrate to Swift Package Manager.

## 0.1.1

- Fix Pod target configuration.

## 0.1.0

Initial version.
