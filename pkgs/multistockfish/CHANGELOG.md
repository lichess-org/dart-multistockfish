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
