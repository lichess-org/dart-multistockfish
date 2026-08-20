## 0.6.0

**Breaking changes — per-flavour engine handles:**

An engine is now a handle you create and dispose, rather than a process-wide
singleton you start and quit. **The handle is the flavour**: at most one engine
per `StockfishFlavor` can be live at a time, and engines of *different* flavours
are independent and can run side by side — each with its own `stdin`, `stdout`,
`state` and `diagnostics`. Running an NNUE engine for analysis while
Fairy-Stockfish plays an opponent no longer means restarting one to get the
other.

- Add `Stockfish.create()`, which starts an engine of one flavour and completes
  when it is ready for commands, and `dispose()`, which quits it and frees the
  flavour's slot. `create()` throws a `StateError` while another engine of the
  same flavour holds the slot.
- A slot stays taken until `dispose()` is called, *including* after the engine
  has died on its own: the handle is the caller's to release.
- A handle is single use. `state` moves to `StockfishState.error` if the engine
  dies, and to the new `StockfishState.disposed` once `dispose()` completes;
  neither is recoverable on that handle. `stdout` closes on dispose, so it no
  longer persists across a restart — the replacement engine has its own.
- `dispose()` gives up on an engine that will not exit within 5 seconds instead
  of waiting for it forever, and frees the slot regardless.
- `create()` now fails as soon as the engine exits during startup — a start the
  native library refused is reported in milliseconds with the exit code, rather
  than as a timeout five seconds later.
- `Stockfish.instance`, `start()` and `quit()` still work but are deprecated and
  will be removed in the next release. The singleton competes for the same
  per-flavour slots as `create()`, so the two APIs can be mixed during a
  migration without ending up with two engines of one flavour.

**Migration:**

```dart
// Before
final stockfish = Stockfish.instance;
await stockfish.start(flavor: StockfishFlavor.variant, variant: 'atomic');
stockfish.stdin = 'go movetime 1000';
await stockfish.quit();

// After
final stockfish = await Stockfish.create(
  flavor: StockfishFlavor.variant,
  variant: 'atomic',
);
stockfish.stdin = 'go movetime 1000';
await stockfish.dispose();
```

- Add Swift Package Manager support for iOS.

**Engine lifecycle fixes** (in the native packages, via the bumped constraints
below):

- The engine no longer takes the process's `stdin` and `stdout` over. Each
  native library now reads and writes streams of its own, bound directly to its
  pipe, so anything the app writes to `stdout` still goes where it should while
  an engine is running — and two flavours can be resident at once, which
  per-flavour engine handles will build on.
- Restarting after an engine failed to quit no longer corrupts memory. Nothing
  previously stopped a second engine from running over the first one's
  process-global state while it was still tearing its thread pool down; that is
  now refused, and `start` fails with an error saying so.
- Sending a command can no longer freeze the app. The write to the engine was
  blocking, so once the engine stopped reading its input and the pipe filled,
  the calling isolate — usually the platform isolate — blocked forever. It now
  gives up and reports the failure instead.
- Starting the engine no longer leaks two file descriptors each time.
- A restarted engine no longer sees output or commands left over from its
  predecessor.
- The stdout reader no longer spins on a closed pipe.

**Diagnosing an engine that will not start or will not quit:**

- Add `Stockfish.diagnostics`, reporting the native engine's lifecycle phase,
  the step within it, how long it has been there, and the last native error.
  Attach it to reports of an engine that would not start or would not quit.
- Report where a start stalled: the `TimeoutException` thrown by `start` now
  names the phase and step the engine was in when it gave up.
- Log a failed write to the engine at `SEVERE` with the reason and diagnostics,
  rather than discarding the result.
- `quit` no longer waits forever when the engine cannot be reached: if the
  `quit` command itself cannot be delivered, the engine is declared failed
  instead of leaving the returned future pending.
- Log the meaning of a non-zero engine exit code and of an `init` failure.
- A write that corrupts the command stream, or that breaks the channel to the
  engine, now moves `state` to `error` as well as logging. Later commands throw
  instead of piling onto a session the engine can no longer read correctly; a
  write that simply was not delivered leaves the engine usable.

Requires `multistockfish_chess` ^0.5.0, `multistockfish_sf16` ^0.3.0 and
`multistockfish_variant` ^0.3.0.

## 0.5.0

**Breaking changes:**

- `Stockfish.start` now sends the "uci" command to the engine and waits for it to respond with "uciok".
  When using the library, do *not* send "uci" yourself anymore, as that would reset UCI options.

**Migration:**

```dart
// Before
await Stockfish.instance.start(flavor: StockfishFlavor.variant, variant: 'atomic');
// stockfish is ready, enable uci protocol.
Stockfish.instance.stdin = 'uci';

// After
await Stockfish.instance.start(flavor: StockfishFlavor.variant, variant: 'atomic');
// "uci" command has already been sent to `stdin` internally, stockfish is ready and in uci mode.
```

## 0.4.0

- Update latest Stockfish to version 18.

**Breaking changes:**

- `Stockfish` is now a singleton. Use `Stockfish.instance`.
- Configuration (`flavor`, `variant`, `bigNetPath`, `smallNetPath`) moved from the constructor to `start()`.
- Removed `StockfishState.disposed`. After calling `quit()`, the state returns to `initial` and the engine can be restarted.
- `start()` throws a `StateError` if the engine is already running. Call `quit()` first.
- The `stdout` stream now persists across restarts - listeners don't need to re-subscribe.

**Migration:**

```dart
// Before
final stockfish = Stockfish(flavor: StockfishFlavor.variant, variant: 'atomic');
// listen to stockfish state and wait for it to be ready
stockfish.stdin = 'uci';

// After
await Stockfish.instance.start(flavor: StockfishFlavor.variant, variant: 'atomic');
// stockfish is ready
Stockfish.instance.stdin = 'uci';
```

## 0.3.0

- Add Stockfish 16 (embedded NNUE).
- Default engine is now Stockfish 16.

## 0.2.1

- Fix wrong NNUE file for Stockfish 17.1

## 0.2.0

- Use last Stockfish as well on armv7 devices.
- Do not embed NNUE files in the app bundle.

## 0.1.0

Initial release
