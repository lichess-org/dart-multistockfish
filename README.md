# multistockfish

Multiple flavors of Stockfish Engine.

This plugin provides the following Stockfish engines:

* [Stockfish 16](https://stockfishchess.org), with embedded NNUE (38MB)
* [Stockfish 17.1](https://stockfishchess.org), without embedded NNUE
* [Fairy-Stockfish](https://fairy-stockfish.github.io), for chess variants

## Usage

### Start engine

`Stockfish` is a singleton. Access it via `Stockfish.instance` and call `start()` to run the engine.

> [!NOTE]
> When using the `StockfishFlavor.latestNoNNUE` flavor, you need to download the `.nnue` files before
> starting an evaluation, since it is not embedded in the binary.

```dart
import 'package:multistockfish/multistockfish.dart';

final stockfish = Stockfish.instance;

// state is a ValueListenable<StockfishState>
print(stockfish.state.value); // StockfishState.initial

// start the engine (defaults to StockfishFlavor.sf16)
await stockfish.start();
print(stockfish.state.value); // StockfishState.ready

// to change flavor, quit first then start with new configuration
await stockfish.quit();
await stockfish.start(
  flavor: StockfishFlavor.variant,
  variant: 'atomic',
);

// for latestNoNNUE flavor, NNUE file paths are required
await stockfish.quit();
await stockfish.start(
  flavor: StockfishFlavor.latestNoNNUE,
  bigNetPath: '/path/to/big.nnue',
  smallNetPath: '/path/to/small.nnue',
);
```

### UCI command

Wait until the state is ready before sending commands.

```dart
stockfish.stdin = 'isready';
stockfish.stdin = 'go movetime 3000';
stockfish.stdin = 'go infinite';
stockfish.stdin = 'stop';
```

Engine output is directed to a `Stream<String>`, add a listener to process results.

```dart
stockfish.stdout.listen((line) {
  // do something useful
  print(line);
});
```
