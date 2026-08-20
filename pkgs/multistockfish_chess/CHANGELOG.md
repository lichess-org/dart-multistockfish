## 0.5.0

- Give the engine its own input and output streams, bound straight to this
  library's pipe, instead of redirecting the process's `stdin` and `stdout` onto
  it. Two flavours can now be resident at the same time without their output
  landing in one channel, and the host application keeps its own `stdout` while
  an engine is running.
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
- Report an error instead of running when the engine's streams cannot be bound
  to the pipe, when the engine throws,
  or when the output pipe reaches end of file (which previously spun the reader).

## 0.4.0

- Migrate to Swift Package Manager.

## 0.3.0

- Update Stockfish to version 18.

## 0.2.1

- Fix Pod target configuration.

## 0.2.0

- Use last Stockfish as well on armv7 devices.
- Do not embed NNUE files in the app bundle.

## 0.1.0

Initial version.
