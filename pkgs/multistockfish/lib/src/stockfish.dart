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

/// Zone key for overriding bindings factory in tests.
@visibleForTesting
const stockfishBindingsFactoryKey = #_stockfishBindingsFactory;

/// Zone key for overriding isolate spawning in tests.
@visibleForTesting
const stockfishSpawnIsolatesKey = #_stockfishSpawnIsolates;

/// A Dart wrapper around the Stockfish chess engine.
///
/// The engine is started in a separate isolate.
///
/// Different flavors of Stockfish can be used by specifying the [flavor] in [start].
///
/// This is a singleton - use [Stockfish.instance] to access it.
class Stockfish {
  /// The singleton instance of Stockfish.
  static final Stockfish instance = Stockfish._();

  /// The default big NNUE file for evaluation of [StockfishFlavor.latestNoNNUE].
  static const latestBigNNUE = 'nn-1c0000000000.nnue';

  /// The default small NNUE file for evaluation of [StockfishFlavor.latestNoNNUE].
  static const latestSmallNNUE = 'nn-37f18f62d772.nnue';

  StockfishFlavor _flavor = StockfishFlavor.sf16;
  String? _variant;
  String? _smallNetPath;
  String? _bigNetPath;

  /// The flavor of Stockfish currently configured.
  StockfishFlavor get flavor => _flavor;

  /// The variant of chess. (Only for [StockfishFlavor.variant]).
  String? get variant => _variant;

  /// Full path to the small net file for NNUE evaluation.
  String? get smallNetPath => _smallNetPath;

  /// Full path to the big net file for NNUE evaluation.
  String? get bigNetPath => _bigNetPath;

  StockfishBindings get _bindings => _getBindings(_flavor);

  final _state = _StockfishState();
  final _stdoutController = StreamController<String>.broadcast();
  final _mainPort = ReceivePort('Stockfish main isolate port');
  final _stdoutPort = ReceivePort('Stockfish stdout isolate port');

  Future<void>? _pendingStart;

  Stockfish._() {
    _mainPort.listen((message) {
      _logger.fine('The main isolate sent $message');
      _onEngineExit(message is int ? message : 1);
    });

    _stdoutPort.listen((message) {
      if (message is String) {
        _logger.finest('[stdout] $message');
        _stdoutController.sink.add(message);
      } else {
        _logger.fine('The stdout isolate sent $message');
      }
    });
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

  /// Starts the C++ engine.
  ///
  /// Returns a [Future] that completes when the engine is ready to accept commands.
  ///
  /// When [flavor] is [StockfishFlavor.latestNoNNUE], [smallNetPath] and [bigNetPath] must be provided.
  ///
  /// Throws a [TimeoutException] if the engine does not become ready in time.
  Future<void> start({
    /// The flavor of Stockfish to use.
    StockfishFlavor flavor = StockfishFlavor.sf16,

    /// The variant of chess to use. (Only for [StockfishFlavor.variant]).
    ///
    /// Example: '3check', 'crazyhouse', 'atomic', 'kingofthehill', 'antichess', 'horde', 'racingkings'.
    String? variant,

    /// Full path to the small net file for NNUE evaluation. Only used for [StockfishFlavor.latestNoNNUE].
    String? smallNetPath,

    /// Full path to the big net file for NNUE evaluation. Only used for [StockfishFlavor.latestNoNNUE].
    String? bigNetPath,
  }) {
    assert(
      flavor != StockfishFlavor.latestNoNNUE ||
          (smallNetPath != null && bigNetPath != null),
      'NNUE evaluation requires smallNetPath and bigNetPath',
    );

    if (_pendingStart != null) {
      return _pendingStart!;
    }

    if (_state.value != StockfishState.initial &&
        _state.value != StockfishState.error) {
      _logger.warning(
        'Attempt to start Stockfish while it is already running.',
      );
      throw StateError(
        'Stockfish is already running. Call quit() before starting again.',
      );
    }

    _flavor = flavor;
    _variant = variant;
    _smallNetPath = smallNetPath;
    _bigNetPath = bigNetPath;

    return _pendingStart = _doStart().whenComplete(() => _pendingStart = null);
  }

  Future<void> _doStart() async {
    final success = await _spawnIsolates(
      _mainPort.sendPort,
      _stdoutPort.sendPort,
      _flavor,
    );

    if (!success) {
      _logger.severe('Failed to spawn isolates');
      _state._setValue(StockfishState.error);
      throw Exception('Failed to spawn isolates');
    }

    _state._setValue(StockfishState.starting);

    try {
      // Wait for the engine to be ready by checking the first non-empty line (usually its name).
      await stdout
          .firstWhere((line) => line.isNotEmpty)
          .timeout(const Duration(seconds: 10));
    } on TimeoutException {
      _state._setValue(StockfishState.error);
      _logger.severe('The engine did not become ready in time.');
      rethrow;
    }

    _state._setValue(StockfishState.ready);

    if (_flavor == StockfishFlavor.variant && _variant != null) {
      stdin = 'setoption name UCI_Variant value $_variant';
    }

    if (_flavor == StockfishFlavor.latestNoNNUE &&
        _bigNetPath != null &&
        _smallNetPath != null) {
      stdin = 'setoption name EvalFile value $_bigNetPath';
      stdin = 'setoption name EvalFileSmall value $_smallNetPath';
    }
  }

  /// Quits the C++ engine.
  ///
  /// Returns a [Future] that completes when the engine has exited.
  ///
  /// After quitting, the engine can be started again with [start].
  Future<void> quit() async {
    switch (_state.value) {
      case StockfishState.initial:
      case StockfishState.error:
        return;
      case StockfishState.starting:
      case StockfishState.ready:
        final completer = Completer<void>();
        void onStateChange() {
          switch (_state.value) {
            case StockfishState.ready:
              stdin = 'quit';
            case StockfishState.initial:
            case StockfishState.error:
              _state.removeListener(onStateChange);
              completer.complete();
            default:
              break;
          }
        }
        _state.addListener(onStateChange);
        if (_state.value == StockfishState.ready) {
          stdin = 'quit';
        }
        return completer.future;
    }
  }

  void _onEngineExit(int exitCode) {
    _state._setValue(
      exitCode == 0 ? StockfishState.initial : StockfishState.error,
    );
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

StockfishBindings? _latestBindings;
StockfishBindings? _sf16Bindings;
StockfishBindings? _fairyBindings;

StockfishBindings _getBindings(StockfishFlavor flavor) {
  // Check for zone override (used in tests)
  final override = Zone.current[stockfishBindingsFactoryKey];
  if (override != null) {
    return (override as StockfishBindings Function(StockfishFlavor))(flavor);
  }

  switch (flavor) {
    case StockfishFlavor.latestNoNNUE:
      _latestBindings ??= StockfishBindingsFFI(
        _openDynamicLibrary('multistockfish_chess'),
      );
      return _latestBindings!;
    case StockfishFlavor.sf16:
      _sf16Bindings ??= StockfishBindingsFFI(
        _openDynamicLibrary('multistockfish_sf16'),
      );
      return _sf16Bindings!;
    case StockfishFlavor.variant:
      _fairyBindings ??= StockfishBindingsFFI(
        _openDynamicLibrary('multistockfish_variant'),
      );
      return _fairyBindings!;
  }
}

void _isolateMain(_IsolateArgs args) {
  final (mainPort, flavor) = args;
  final bindings = _getBindings(flavor);
  final exitCode = bindings.main();
  mainPort.send(exitCode);

  _logger.fine('nativeMain returns $exitCode');
}

void _isolateStdout(_IsolateArgs args) {
  final (stdoutPort, flavor) = args;
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

Future<bool> _spawnIsolates(
  SendPort mainPort,
  SendPort stdoutPort,
  StockfishFlavor flavor,
) async {
  // Check for zone override (used in tests)
  final override = Zone.current[stockfishSpawnIsolatesKey];
  if (override != null) {
    return (override
        as Future<bool> Function(SendPort, SendPort, StockfishFlavor))(
      mainPort,
      stdoutPort,
      flavor,
    );
  }

  final bindings = _getBindings(flavor);

  final initResult = bindings.init();
  if (initResult != 0) {
    _logger.severe('initResult=$initResult');
    return false;
  }

  try {
    await Isolate.spawn(_isolateStdout, (
      stdoutPort,
      flavor,
    ), debugName: 'Stockfish stdout isolate');
  } catch (error) {
    _logger.severe('Failed to spawn stdout isolate: $error');
    return false;
  }

  try {
    await Isolate.spawn(_isolateMain, (
      mainPort,
      flavor,
    ), debugName: 'Stockfish main isolate');
  } catch (error) {
    _logger.severe('Failed to spawn main isolate: $error');
    return false;
  }

  return true;
}

typedef _IsolateArgs = (SendPort sendPort, StockfishFlavor flavor);

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
