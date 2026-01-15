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
/// Different flavors of Stockfish can be used by specifying the [flavor].
class Stockfish {
  /// Creates a new Stockfish engine.
  ///
  /// If another instance is currently running, it will be stopped first.
  ///
  /// When [flavor] is [StockfishFlavor.latestNoNNUE], [smallNetPath] and [bigNetPath] must be provided.
  static Future<Stockfish> create({
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
  }) async {
    assert(
      flavor != StockfishFlavor.latestNoNNUE ||
          (smallNetPath != null && bigNetPath != null),
      'NNUE evaluation requires smallNetPath and bigNetPath',
    );

    if (_instance != null) {
      switch (_instance!._state.value) {
        case StockfishState.initial:
          _instance!._cleanUp(0);
        case StockfishState.disposed:
        case StockfishState.error:
          break;
        case StockfishState.starting:
        case StockfishState.ready:
          await _instance!.quit();
      }
    }

    _instance = Stockfish._(
      flavor,
      variant: variant,
      smallNetPath: smallNetPath,
      bigNetPath: bigNetPath,
    );
    return _instance!;
  }

  /// The default big NNUE file for evaluation of [StockfishFlavor.latestNoNNUE].
  static const latestBigNNUE = 'nn-1c0000000000.nnue';

  /// The default small NNUE file for evaluation of [StockfishFlavor.latestNoNNUE].
  static const latestSmallNNUE = 'nn-37f18f62d772.nnue';

  static Stockfish? _instance;

  /// The flavor of Stockfish.
  final StockfishFlavor flavor;

  /// The variant of chess. (Only for [StockfishFlavor.variant]).
  final String? variant;

  /// Full path to the small net file for NNUE evaluation.
  final String? smallNetPath;

  /// Full path to the big net file for NNUE evaluation.
  final String? bigNetPath;

  StockfishBindings get _bindings => _getBindings(flavor);

  final _state = _StockfishState();
  final _stdoutController = StreamController<String>.broadcast();
  final _mainPort = ReceivePort();
  final _stdoutPort = ReceivePort();

  bool _initializationInProgress = false;

  late StreamSubscription _mainSubscription;
  late StreamSubscription _stdoutSubscription;

  Stockfish._(this.flavor, {this.variant, this.smallNetPath, this.bigNetPath}) {
    _mainSubscription = _mainPort.listen((message) {
      _logger.fine('The main isolate sent $message');
      _cleanUp(message is int ? message : 1);
    });

    _stdoutSubscription = _stdoutPort.listen((message) {
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
  /// Throws a [TimeoutException] if the engine does not become ready in time.
  Future<void> start() async {
    if (_initializationInProgress) {
      _logger.warning('Initialization is already in progress.');
      return;
    }

    if (_state.value == StockfishState.disposed) {
      throw StateError('Stockfish has been disposed.');
    }

    if (_state.value != StockfishState.initial) {
      _logger.warning('Stockfish has already been started.');
      return;
    }

    _initializationInProgress = true;

    try {
      final success = await _spawnIsolates(
        _mainPort.sendPort,
        _stdoutPort.sendPort,
        flavor,
      );

      if (!success) {
        _logger.severe('Failed to spawn isolates');
        _cleanUp(1);
        return;
      }

      _state._setValue(StockfishState.starting);

      // Wait for the engine to be ready by checking the first non-empty line (usually its name).
      await stdout
          .firstWhere((line) => line.isNotEmpty)
          .timeout(const Duration(seconds: 10));

      _state._setValue(StockfishState.ready);

      if (flavor == StockfishFlavor.variant && variant != null) {
        stdin = 'setoption name UCI_Variant value $variant';
      }

      if (flavor == StockfishFlavor.latestNoNNUE &&
          bigNetPath != null &&
          smallNetPath != null) {
        stdin = 'setoption name EvalFile value $bigNetPath';
        stdin = 'setoption name EvalFileSmall value $smallNetPath';
      }
    } on TimeoutException {
      _cleanUp(1);
      _logger.severe('The engine did not become ready in time.');
      rethrow;
    } catch (error) {
      _cleanUp(1);
      _logger.severe('The engine failed to start: $error.');
      rethrow;
    } finally {
      _initializationInProgress = false;
    }
  }

  /// Quits the C++ engine.
  ///
  /// Returns a [Future] that completes when the engine has exited.
  ///
  /// After calling this method, the instance cannot be used anymore.
  Future<void> quit() async {
    switch (_state.value) {
      case StockfishState.disposed:
      case StockfishState.error:
        return;
      case StockfishState.initial:
        _cleanUp(0);
        return;
      case StockfishState.starting:
      case StockfishState.ready:
        final completer = Completer<void>();
        void onStateChange() {
          switch (_state.value) {
            case StockfishState.ready:
              stdin = 'quit';
            case StockfishState.disposed:
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

  void _cleanUp(int exitCode) {
    _stdoutController.close();

    _mainSubscription.cancel();
    _stdoutSubscription.cancel();

    _state._setValue(
      exitCode == 0 ? StockfishState.disposed : StockfishState.error,
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
