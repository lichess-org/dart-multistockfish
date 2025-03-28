import 'dart:async';
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';

import 'package:flutter/foundation.dart';
import 'package:logging/logging.dart';

import 'bindings.dart';
import 'stockfish_flavor.dart';
import 'stockfish_state.dart';

final _logger = Logger('Stockfish');

/// A Dart wrapper around the Stockfish chess engine.
///
/// The engine is started in a separate isolate.
///
/// Different flavors of Stockfish can be used by specifying the [flavor].
class Stockfish {
  /// Creates a new Stockfish engine.
  ///
  /// Throws a [StateError] if an active instance is being used.
  /// Owner must [dispose] it before a new instance can be created.
  factory Stockfish({
    /// The flavor of Stockfish to use.
    StockfishFlavor flavor = StockfishFlavor.chess,

    /// Full path to the small net file for NNUE evaluation.
    String? smallNetPath,

    /// Full path to the big net file for NNUE evaluation.
    String? bigNetPath,
  }) {
    if (_instance != null) {
      throw StateError('Multiple instances are not supported.');
    }

    _instance = Stockfish._(
      flavor,
      smallNetPath: smallNetPath,
      bigNetPath: bigNetPath,
    );
    return _instance!;
  }

  static Stockfish? _instance;

  /// The flavor of Stockfish.
  final StockfishFlavor flavor;

  /// Full path to the small net file for NNUE evaluation.
  final String? smallNetPath;

  /// Full path to the big net file for NNUE evaluation.
  final String? bigNetPath;

  StockfishBindings get _bindings => _getBindings(flavor);

  final _state = _StockfishState();
  final _stdoutController = StreamController<String>.broadcast();
  final _mainPort = ReceivePort();
  final _stdoutPort = ReceivePort();

  late StreamSubscription _mainSubscription;
  late StreamSubscription _stdoutSubscription;

  Stockfish._(this.flavor, {this.smallNetPath, this.bigNetPath}) {
    _mainSubscription = _mainPort.listen(
      (message) => _cleanUp(message is int ? message : 1),
    );

    _stdoutSubscription = _stdoutPort.listen((message) {
      if (message is String) {
        _logger.finest('[stdout] $message');
        _stdoutController.sink.add(message);
      } else {
        _logger.fine('The stdout isolate sent $message');
      }
    });

    compute(
      _spawnIsolates,
      _ComputeArgs([_mainPort.sendPort, _stdoutPort.sendPort], flavor),
    ).then(
      (success) {
        final state = success ? StockfishState.starting : StockfishState.error;

        _logger.fine('The init isolate reported $state');

        _state._setValue(state);

        // Wait for the engine to be ready by checking the first non-empty line (usually its name).
        stdout
            .firstWhere((line) => line.isNotEmpty)
            .timeout(const Duration(seconds: 3))
            .then(
              (_) {
                // The engine is ready.
                _state._setValue(StockfishState.ready);

                if (bigNetPath != null && smallNetPath != null) {
                  stdin = 'setoption name EvalFile value $bigNetPath';
                  stdin = 'setoption name EvalFileSmall value $smallNetPath';
                }
              },
              onError: (error) {
                _logger.severe('The engine did not start in time: $error');
                _cleanUp(1);
              },
            );
      },
      onError: (error) {
        _logger.severe('The init isolate encountered an error $error');
        _cleanUp(1);
      },
    );
  }

  /// The current state of the underlying C++ engine.
  ValueListenable<StockfishState> get state => _state;

  /// The standard output stream.
  Stream<String> get stdout => _stdoutController.stream;

  /// The standard input sink.
  set stdin(String line) {
    final stateValue = _state.value;
    if (stateValue != StockfishState.ready) {
      throw StateError('Stockfish is not ready ($stateValue)');
    }

    _logger.finest('[stdin] $line');

    _bindings.stdinWrite('$line\n');
  }

  /// Stops the C++ engine.
  void dispose() {
    stdin = 'quit';
  }

  void _cleanUp(int exitCode) {
    _stdoutController.close();

    _mainSubscription.cancel();
    _stdoutSubscription.cancel();

    _state._setValue(
      exitCode == 0 ? StockfishState.disposed : StockfishState.error,
    );

    _instance = null;
  }
}

DynamicLibrary _openDynamicLibrary(String libName) {
  if (Platform.isMacOS || Platform.isIOS) {
    return DynamicLibrary.open('$libName.framework/$libName');
  }
  if (Platform.isAndroid || Platform.isLinux) {
    return DynamicLibrary.open('lib$libName.so');
  }
  throw UnsupportedError('Unknown platform: ${Platform.operatingSystem}');
}

StockfishBindings? _nnueBindings;
StockfishBindings? _fairyBindings;

StockfishBindings _getBindings(StockfishFlavor flavor) {
  switch (flavor) {
    case StockfishFlavor.chess:
      _nnueBindings ??= StockfishBindings(
        _openDynamicLibrary('multistockfish_chess'),
      );
      return _nnueBindings!;
    case StockfishFlavor.variant:
      _fairyBindings ??= StockfishBindings(
        _openDynamicLibrary('multistockfish_fairy'),
      );
      return _fairyBindings!;
  }
}

void _isolateMain(_IsolateArgs args) {
  final (mainPort, flavor) = (args.sendPort, args.flavor);
  final bindings = _getBindings(flavor);
  final exitCode = bindings.main();
  mainPort.send(exitCode);

  _logger.fine('nativeMain returns $exitCode');
}

void _isolateStdout(_IsolateArgs args) {
  final (stdoutPort, flavor) = (args.sendPort, args.flavor);
  final bindings = _getBindings(flavor);

  String previous = '';

  while (true) {
    final stdout = bindings.stdoutRead();

    if (stdout == null) {
      _logger.fine('nativeStdoutRead returns NULL');
      return;
    }

    final data = previous + stdout;
    final lines = data.split('\n');
    previous = lines.removeLast();
    for (final line in lines) {
      stdoutPort.send(line);
    }
  }
}

Future<bool> _spawnIsolates(_ComputeArgs args) async {
  final (ports, flavor) = (args.mainAndStdout, args.flavor);
  final bindings = _getBindings(flavor);

  final initResult = bindings.init();
  if (initResult != 0) {
    _logger.severe('initResult=$initResult');
    return false;
  }

  try {
    await Isolate.spawn(_isolateStdout, _IsolateArgs(ports[1], flavor));
  } catch (error) {
    _logger.severe('Failed to spawn stdout isolate: $error');
    return false;
  }

  try {
    await Isolate.spawn(_isolateMain, _IsolateArgs(ports[0], flavor));
  } catch (error) {
    _logger.severe('Failed to spawn main isolate: $error');
    return false;
  }

  return true;
}

class _ComputeArgs {
  final List<SendPort> mainAndStdout;
  final StockfishFlavor flavor;

  const _ComputeArgs(this.mainAndStdout, this.flavor);
}

class _IsolateArgs {
  final SendPort sendPort;
  final StockfishFlavor flavor;

  const _IsolateArgs(this.sendPort, this.flavor);
}

class _StockfishState extends ChangeNotifier
    implements ValueListenable<StockfishState> {
  StockfishState _value = StockfishState.initial;

  @override
  StockfishState get value => _value;

  _setValue(StockfishState v) {
    if (v == _value) return;
    _value = v;
    notifyListeners();
  }
}
