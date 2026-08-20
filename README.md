[![Tests](https://github.com/lichess-org/dart-multistockfish/workflows/Test/badge.svg)](https://github.com/lichess-org/dart-multistockfish/actions?query=workflow%3A%22Test%22)
[![pub package](https://img.shields.io/pub/v/multistockfish.svg)](https://pub.dev/packages/multistockfish)
[![package publisher](https://img.shields.io/pub/publisher/multistockfish.svg)](https://pub.dev/packages/multistockfish/publisher)
[![Discord](https://img.shields.io/discord/280713822073913354?label=Discord&logo=discord&style=flat)](https://discord.com/channels/280713822073913354/807722604478988348)

# multistockfish

Multiple flavors of Stockfish Engine.

This plugin provides the following Stockfish engines:

* [Stockfish 16](https://stockfishchess.org), with embedded NNUE (38MB)
* [Stockfish 18](https://stockfishchess.org), without embedded NNUE
* [Fairy-Stockfish](https://fairy-stockfish.github.io), for chess variants

## Usage

### Start an engine

An engine is a handle you create and dispose. `Stockfish.create()` starts one
and completes when it is ready for commands.

> [!NOTE]
> When using the `StockfishFlavor.latestNoNNUE` flavor, you need to download the `.nnue` files before
> starting an evaluation, since it is not embedded in the binary.

```dart
import 'package:multistockfish/multistockfish.dart';

// defaults to StockfishFlavor.sf16
final stockfish = await Stockfish.create();

// state is a ValueListenable<StockfishState>
print(stockfish.state.value); // StockfishState.ready

// for latestNoNNUE, NNUE file paths are required
final latest = await Stockfish.create(
  flavor: StockfishFlavor.latestNoNNUE,
  bigNetPath: '/path/to/big.nnue',
  smallNetPath: '/path/to/small.nnue',
);
```

### One engine per flavor

**The handle is the flavor.** At most one engine per `StockfishFlavor` can be
live at a time: `create()` throws a `StateError` while another engine of the
same flavor holds the slot, and `dispose()` frees it. Engines of *different*
flavors are independent and can run side by side, each with its own `stdin`,
`stdout`, `state` and `diagnostics`.

```dart
// An NNUE engine for analysis and a Fairy-Stockfish opponent, at the same time.
final analysis = await Stockfish.create(flavor: StockfishFlavor.sf16);
final opponent = await Stockfish.create(
  flavor: StockfishFlavor.variant,
  variant: 'crazyhouse',
);

// Refused: sf16 is taken until `analysis` is disposed.
await Stockfish.create(flavor: StockfishFlavor.sf16); // throws StateError
```

Note that a slot stays taken until `dispose()` is called, *including* after the
engine has died on its own — the handle is the caller's to release.

### UCI command

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

### Quit / Hot reload

There are two active isolates per running Stockfish engine. That interferes
with Flutter's hot reload feature so you need to dispose your engines before
attempting to reload.

`dispose()` sends the UCI `quit` command, waits for the engine to exit and frees
its flavor's slot. An engine that will not exit is given up on rather than
waited for forever.

```dart
await stockfish.dispose();

// the stdout stream is closed, and the handle stays dead
print(stockfish.state.value); // StockfishState.disposed
```
