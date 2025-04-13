# multistockfish

Multiple flavors of Stockfish Engine.

This plugin provides the following Stockfish engines:

* [Official Stockfish](https://stockfishchess.org) engine for chess and chess 960
    * Stockfish 17.1 is packaged for armv8
    * Stockfish 11 (handcrafted evaluation) is packaged for armv7
* [Fairy-Stockfish](https://fairy-stockfish.github.io) for chess variants

## Usage

### Init engine

> [!WARNING]
> Only one instance can be created at a time. The `Stockfish()` constructor
> will throw a StateError if called while another instance is running.

```dart
import 'package:multistockfish/multistockfish.dart';

// create a new instance
final stockfish = Stockfish();

// state is a ValueListenable<StockfishState>
print(stockfish.state.value); # StockfishState.starting

// the engine takes a few moment to start
await Future.delayed(...)
print(stockfish.state.value); # StockfishState.ready
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

### Dispose / Hot reload

There are two active isolates when Stockfish engine is running. That interferes with Flutter's hot reload feature so you need to dispose it before attempting to reload.

```dart
// sends the UCI quit command
stockfish.stdin = 'quit';

// or even easier...
stockfish.dispose();
```
