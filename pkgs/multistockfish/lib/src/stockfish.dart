import 'dart:async';
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';

import 'package:flutter/foundation.dart';
import 'package:logging/logging.dart';

import 'bindings.dart';
import 'stockfish_diagnostics.dart';
import 'stockfish_flavor.dart';
import 'stockfish_state.dart';

final _logger = Logger('Stockfish');

/// Zone key for overriding bindings factory in tests.
@visibleForTesting
const stockfishBindingsFactoryKey = #_stockfishBindingsFactory;

/// Zone key for overriding isolate spawning in tests.
@visibleForTesting
const stockfishSpawnIsolatesKey = #_stockfishSpawnIsolates;

/// Timeout duration to consider engine start failed.
const kStartTimeout = Duration(seconds: 5);

/// How long an engine that failed to start is given to exit after being asked
/// to quit, before it is abandoned.
const kQuitTimeout = Duration(seconds: 5);

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
  static const latestBigNNUE = 'nn-c288c895ea92.nnue';

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

  /// The engine currently owning the state, or null when none is running.
  _RunningEngine? _engine;

  Future<void>? _pendingStart;
  Future<void>? _pendingQuit;

  Stockfish._();

  /// The current state of the underlying C++ engine.
  ValueListenable<StockfishState> get state => _state;

  /// The standard output stream.
  Stream<String> get stdout => _stdoutController.stream;

  /// A snapshot of what the native engine is doing.
  ///
  /// Cheap to read at any time, including while the engine is wedged — the
  /// values are atomics published by the native shim, not a round trip through
  /// the engine. Attach it to any report of an engine that would not start or
  /// would not quit.
  StockfishDiagnostics get diagnostics {
    final bindings = _bindings;
    return StockfishDiagnostics(
      phase: StockfishPhase.fromCode(bindings.phase()),
      step: bindings.phaseStep(),
      elapsed: Duration(milliseconds: bindings.phaseElapsedMs()),
      lastError: bindings.lastError(),
    );
  }

  /// The standard input sink.
  ///
  /// A failed write is logged at [Level.SEVERE] along with [diagnostics] rather
  /// than thrown, so that a broken engine does not turn every command site into
  /// a try/catch. The write never blocks: if the engine has stopped reading its
  /// input, this reports the failure instead of hanging the calling isolate.
  set stdin(String line) {
    final stateValue = _state.value;
    if (stateValue != StockfishState.ready) {
      throw StateError('Stockfish is not ready ($stateValue)');
    }

    _write(line);
  }

  /// Sends a line to the engine, returning the native write result.
  ///
  /// Negative values are failures described by [describeWriteCode]. They are
  /// logged here so that every caller reports them the same way, and returned
  /// so that callers who cannot simply carry on — [quit] in particular — can
  /// act on them.
  int _write(String line) {
    _logger.finest('[stdin] $line');

    final written = _bindings.stdinWrite('$line\n');
    if (written < 0) {
      _logger.severe(
        'Failed to send "$line" to the engine: ${describeWriteCode(written)}. '
        '$diagnostics',
      );
    }
    return written;
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
    late final _RunningEngine engine;
    engine = _RunningEngine(
      onExit: (exitCode) {
        if (identical(_engine, engine)) _engine = null;
        _onEngineExit(exitCode);
      },
      onStdout: _stdoutController.sink.add,
    );
    _engine = engine;

    final success = await _spawnIsolates(
      engine.mainPort.sendPort,
      engine.stdoutPort.sendPort,
      _flavor,
    );

    if (!success) {
      _logger.severe('Failed to spawn isolates');
      _engine = null;
      engine.dispose();
      _state._setValue(StockfishState.error);
      throw Exception('Failed to spawn isolates');
    }

    _state._setValue(StockfishState.starting);

    try {
      // Wait for the engine to be ready by checking the first non-empty line (usually its name).
      await stdout.firstWhere((line) => line.isNotEmpty).timeout(kStartTimeout);

      _state._setValue(StockfishState.ready);

      // Switch to the engine to UCI protocol
      stdin = 'uci';
      await stdout.firstWhere((line) => line == "uciok").timeout(kStartTimeout);
    } on TimeoutException {
      // Read the diagnostics before asking the engine to quit: doing so moves
      // it on to another phase and would erase the evidence of where it stalled.
      final stalledAt = diagnostics;
      _logger.severe(
        'The engine (${_flavor.name}) did not become ready in time '
        '(${kStartTimeout.inSeconds}s). $stalledAt',
      );
      await _abandonEngine(engine);
      _state._setValue(StockfishState.error);
      throw TimeoutException(
        'Stockfish (${_flavor.name}) did not become ready in time. $stalledAt',
        kStartTimeout,
      );
    }

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
  ///
  /// It is safe to call [quit] multiple times; subsequent calls will wait for the first to complete.
  Future<void> quit() {
    if (_pendingQuit != null) {
      return _pendingQuit!;
    }

    switch (_state.value) {
      case StockfishState.initial:
      case StockfishState.error:
        return Future.value();
      case StockfishState.starting:
      case StockfishState.ready:
        return _pendingQuit = _doQuit().whenComplete(() => _pendingQuit = null);
    }
  }

  Future<void> _doQuit() {
    final completer = Completer<void>();
    void onStateChange() {
      switch (_state.value) {
        case StockfishState.ready:
          _requestQuit();
        case StockfishState.initial:
        case StockfishState.error:
          _state.removeListener(onStateChange);
          completer.complete();
        default:
          break;
      }
    }

    _state.addListener(onStateChange);
    _requestQuit();
    return completer.future;
  }

  /// Asks a ready engine to quit.
  ///
  /// If the command cannot be delivered the engine is unreachable, so it will
  /// never report an exit. Waiting for one would hang [quit] forever, so the
  /// engine is declared failed instead — which is what it is.
  void _requestQuit() {
    if (_state.value != StockfishState.ready) return;

    if (_write('quit') < 0) {
      _logger.severe(
        'The engine could not be asked to quit and will never report an exit. '
        'Giving up on a clean shutdown. $diagnostics',
      );
      _state._setValue(StockfishState.error);
    }
  }

  /// Asks an engine that failed to start to quit, and waits for it to exit.
  ///
  /// Waiting matters: [start] may be called again as soon as it throws, and an
  /// engine still winding down would otherwise report its exit while its
  /// successor is running, resetting the state of a perfectly healthy engine.
  ///
  /// An engine that does not exit within [kQuitTimeout] is given up on, but it
  /// is disposed all the same so that whatever it sends afterwards is dropped.
  Future<void> _abandonEngine(_RunningEngine engine) async {
    _write('quit');
    try {
      await engine.exited.future.timeout(kQuitTimeout);
    } on TimeoutException {
      _logger.severe(
        'The engine did not exit in time (${kQuitTimeout.inSeconds}s) after a '
        'failed start. $diagnostics '
        'Until this process is restarted, further start() calls will be refused '
        'by the native library, because the engine keeps its state in process '
        'globals that the stuck engine still owns.',
      );
    } finally {
      if (identical(_engine, engine)) _engine = null;
      engine.dispose();
    }
  }

  void _onEngineExit(int exitCode) {
    if (exitCode == 0) {
      _logger.fine('The engine exited cleanly.');
    } else {
      _logger.severe(
        'The engine exited with code $exitCode: '
        '${describeMainExitCode(exitCode)}. $diagnostics',
      );
    }

    _state._setValue(
      exitCode == 0 ? StockfishState.initial : StockfishState.error,
    );
  }
}

/// The ports of a single engine, and its lifetime.
///
/// Each engine gets its own ports so that closing them is enough to make an
/// abandoned engine invisible to the [Stockfish] singleton.
class _RunningEngine {
  _RunningEngine({
    required void Function(int exitCode) onExit,
    required void Function(String line) onStdout,
  }) {
    mainPort.listen((message) {
      _logger.fine('The main isolate sent $message');
      dispose();
      onExit(message is int ? message : 1);
    });

    stdoutPort.listen((message) {
      if (message is String) {
        _logger.finest('[stdout] $message');
        onStdout(message);
      } else {
        _logger.fine('The stdout isolate sent $message');
      }
    });
  }

  final mainPort = ReceivePort('Stockfish main isolate port');
  final stdoutPort = ReceivePort('Stockfish stdout isolate port');

  /// Completes when the engine has exited, or when it is disposed.
  final exited = Completer<void>();

  bool _disposed = false;

  /// Stops listening to this engine's isolates.
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    mainPort.close();
    stdoutPort.close();
    if (!exited.isCompleted) exited.complete();
  }
}

// On iOS/macOS, each flavor's native package may be distributed either via
// CocoaPods (built into its own `$libName.framework`, dynamically loaded and
// linked into the app at launch) or via Swift Package Manager (whose local
// package integration statically merges the object code straight into the
// app binary instead of producing a separate framework). DynamicLibrary.open
// only works for the former, but DynamicLibrary.process() resolves symbols
// from *both*: dynamically linked frameworks are eagerly loaded into the
// process at launch just like statically linked code is, so their exported
// symbols are equally visible process-wide. Using it uniformly means this
// code doesn't need to know which distribution mechanism produced a given
// flavor, and keeps working as flavors migrate from one to the other.
//
// This relies on every flavor's exported C symbols being unique process-wide
// (see [StockfishBindingsFFI]'s symbolPrefix) since a process-wide lookup
// can't otherwise distinguish between multiple co-loaded flavors that
// happen to export identically-named functions.
DynamicLibrary _openDynamicLibrary(String libName) {
  if (Platform.isMacOS || Platform.isIOS) {
    return DynamicLibrary.process();
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
        symbolPrefix: 'sf16',
      );
      return _sf16Bindings!;
    case StockfishFlavor.variant:
      _fairyBindings ??= StockfishBindingsFFI(
        _openDynamicLibrary('multistockfish_variant'),
        symbolPrefix: 'variant',
      );
      return _fairyBindings!;
  }
}

void _isolateMain(_IsolateArgs args) {
  final (mainPort, flavor) = args;
  final bindings = _getBindings(flavor);
  final exitCode = bindings.main();
  mainPort.send(exitCode);

  // Logging from a spawned isolate does not reach the root logger's listeners,
  // so the exit code is reported by _onEngineExit on the main isolate instead.
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
    _logger.severe(
      'Failed to initialize the ${flavor.name} engine (init returned '
      '$initResult): ${describeInitCode(initResult)}. '
      'phase=${StockfishPhase.fromCode(bindings.phase()).name} '
      'step=${bindings.phaseStep()} '
      'for ${bindings.phaseElapsedMs()}ms'
      '${bindings.lastError() == null ? '' : '; native error: ${bindings.lastError()}'}',
    );
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
