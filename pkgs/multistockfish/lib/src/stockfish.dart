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

/// How long an engine is given to exit after being asked to quit, before it is
/// abandoned.
const kQuitTimeout = Duration(seconds: 5);

/// A live Stockfish engine of one [StockfishFlavor].
///
/// Obtain one with [Stockfish.create], which starts the engine and completes
/// once it is ready for commands, and release it with [dispose].
///
/// **The handle is the flavor.** At most one engine per [StockfishFlavor] can
/// be live at a time: [create] throws a [StateError] while another engine of
/// the same flavor holds the slot, and [dispose] frees it. Engines of
/// *different* flavors are independent and may be live together — an analysis
/// engine and a variant opponent, say — each with its own [stdin], [stdout],
/// [state] and [diagnostics].
///
/// A handle is single-use. Once [dispose] has been called, or the engine has
/// exited on its own, that handle stays dead; call [create] again for a fresh
/// one.
class Stockfish {
  Stockfish._(this._flavor, {bool legacy = false}) : _legacy = legacy;

  /// The engines currently holding their flavor's slot.
  static final Map<StockfishFlavor, Stockfish> _live = {};

  /// The engines currently live, by flavor.
  ///
  /// The slots are process-wide, so a test that leaves one claimed leaks it
  /// into the next test.
  @visibleForTesting
  static Map<StockfishFlavor, Stockfish> get debugLiveEngines =>
      Map.unmodifiable(_live);

  /// The default big NNUE file for evaluation of [StockfishFlavor.latestNoNNUE].
  static const latestBigNNUE = 'nn-c288c895ea92.nnue';

  /// The default small NNUE file for evaluation of [StockfishFlavor.latestNoNNUE].
  static const latestSmallNNUE = 'nn-37f18f62d772.nnue';

  /// Starts an engine of [flavor] and completes when it is ready for commands.
  ///
  /// When [flavor] is [StockfishFlavor.latestNoNNUE], [smallNetPath] and
  /// [bigNetPath] must be provided.
  ///
  /// Throws a [StateError] if an engine of [flavor] is already live — call
  /// [dispose] on it first — and a [TimeoutException] if the engine does not
  /// become ready within [kStartTimeout]. A failed create frees the slot again,
  /// but an engine that also refused to quit keeps its native state, and the
  /// next create for that flavor may be refused by the native library until the
  /// process restarts.
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

    // Claiming the slot before the first await is what makes two concurrent
    // create() calls for one flavor resolve to a refusal rather than to two
    // engines racing each other into the same native globals.
    final engine =
        Stockfish._(flavor)
          .._variant = variant
          .._smallNetPath = smallNetPath
          .._bigNetPath = bigNetPath;
    engine._claimSlot(flavor);

    try {
      await engine._doStart();
    } catch (_) {
      engine._release(StockfishState.error, closeStdout: true);
      rethrow;
    }

    return engine;
  }

  final bool _legacy;

  StockfishFlavor _flavor;
  String? _variant;
  String? _smallNetPath;
  String? _bigNetPath;

  /// The flavor of Stockfish this engine runs.
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
  Future<void>? _pendingDispose;

  /// Whether [dispose] has been called, recorded before anything it does can
  /// make the engine exit, so that [_onEngineExit] knows the exit was asked for.
  bool _disposing = false;

  /// The current state of the underlying C++ engine.
  ///
  /// A handle returned by [create] is [StockfishState.ready]. It moves to
  /// [StockfishState.error] if the engine dies on its own, and to
  /// [StockfishState.disposed] once [dispose] completes; neither is recoverable
  /// on this handle.
  ValueListenable<StockfishState> get state => _state;

  /// The standard output stream.
  ///
  /// Closes when the engine is disposed.
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
  ///
  /// A failure that leaves the session unusable — see
  /// [StockfishWriteResult.isFatal] — additionally moves [state] to
  /// [StockfishState.error], so subsequent commands throw rather than pile onto
  /// a channel the engine can no longer read correctly.
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
  /// so that callers who cannot simply carry on — [dispose] in particular — can
  /// act on them.
  int _write(String line) {
    _logger.finest('[stdin] $line');

    final written = _bindings.stdinWrite('$line\n');
    if (written < 0) {
      _logger.severe(
        'Failed to send "$line" to the engine: ${describeWriteCode(written)}. '
        '$diagnostics',
      );

      if (StockfishWriteResult.isFatal(written)) {
        // The engine can no longer be sent a coherent command stream, so this
        // session is over whatever the engine itself does next. Failing the
        // state here makes the rest of the API refuse work until the caller
        // starts another engine, instead of letting commands accumulate on a
        // broken channel and be answered with nonsense.
        _logger.severe(
          'The engine session is unrecoverable and has been marked failed. '
          'Dispose this engine and create another one.',
        );
        _state._setValue(StockfishState.error);
      }
    }
    return written;
  }

  /// Takes [flavor]'s slot, or throws if another engine still holds it.
  void _claimSlot(StockfishFlavor flavor) {
    if (_live.containsKey(flavor)) {
      throw StateError(
        'A ${flavor.name} engine is already live. Dispose it before creating '
        'another one of the same flavor. (Engines of other flavors are '
        'unaffected and can run alongside it.)',
      );
    }
    _flavor = flavor;
    _live[flavor] = this;
  }

  /// Gives this flavor's slot back, if this engine still holds it.
  void _releaseSlot() {
    if (identical(_live[_flavor], this)) _live.remove(_flavor);
  }

  Future<void> _doStart() async {
    late final _RunningEngine engine;
    engine = _RunningEngine(
      onExit: (exitCode) {
        if (identical(_engine, engine)) _engine = null;
        _onEngineExit(exitCode);
      },
      onStdout: (line) {
        if (!_stdoutController.isClosed) _stdoutController.add(line);
      },
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
      throw Exception('Failed to spawn isolates');
    }

    _state._setValue(StockfishState.starting);

    try {
      // Wait for the engine to be ready by checking the first non-empty line (usually its name).
      await _awaitLine(engine, (line) => line.isNotEmpty);

      _state._setValue(StockfishState.ready);

      // Switch to the engine to UCI protocol
      stdin = 'uci';
      await _awaitLine(engine, (line) => line == 'uciok');
    } on TimeoutException {
      // Read the diagnostics before asking the engine to quit: doing so moves
      // it on to another phase and would erase the evidence of where it stalled.
      final stalledAt = diagnostics;
      _logger.severe(
        'The engine (${_flavor.name}) did not become ready in time '
        '(${kStartTimeout.inSeconds}s). $stalledAt',
      );
      await _quitEngine(engine);
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

  /// Waits for [engine] to print a line matching [test].
  ///
  /// Throws a [TimeoutException] after [kStartTimeout], and gives up as soon as
  /// the engine exits instead: an engine the native library refused to run
  /// reports that in milliseconds, and waiting out the timeout would replace a
  /// precise answer with a vague one.
  Future<void> _awaitLine(
    _RunningEngine engine,
    bool Function(String line) test,
  ) {
    final completer = Completer<void>();

    final subscription = _stdoutController.stream.listen((line) {
      if (!completer.isCompleted && test(line)) completer.complete();
    });

    unawaited(
      engine.exited.future.then((exitCode) {
        if (completer.isCompleted) return;
        completer.completeError(
          Exception(
            'The ${_flavor.name} engine exited while starting '
            '${exitCode == null ? '' : '(code $exitCode: '
                    '${describeMainExitCode(exitCode)}) '}'
            'and will never become ready. $diagnostics',
          ),
        );
      }),
    );

    return completer.future
        .timeout(kStartTimeout)
        .whenComplete(subscription.cancel);
  }

  /// Quits the engine and frees its flavor's slot.
  ///
  /// Completes when the engine has exited. It is safe to call more than once
  /// and safe to call on an engine that has already died; later calls wait for
  /// the first.
  ///
  /// An engine that does not exit within [kQuitTimeout] is abandoned: the slot
  /// is freed and everything the engine sends afterwards is dropped, but it
  /// keeps the native state it is stuck in, so a later [create] for this flavor
  /// may be refused until the process restarts.
  Future<void> dispose() {
    if (_legacy) {
      // Disposing the singleton would close the stdout stream every caller
      // shares and leave no way back, so this is refused rather than honoured.
      throw StateError(
        'Stockfish.instance cannot be disposed: it is a process-wide singleton '
        'and callers share its streams. Use quit(), or migrate to an engine of '
        'your own from Stockfish.create().',
      );
    }
    _disposing = true;
    return _pendingDispose ??= _doDispose();
  }

  Future<void> _doDispose() async {
    final engine = _engine;
    if (engine != null) await _quitEngine(engine);
    _release(StockfishState.disposed, closeStdout: true);
  }

  /// Asks [engine] to quit and waits for it to exit.
  ///
  /// Waiting matters even where the caller has stopped caring: another engine
  /// of this flavor may be created as soon as this returns, and one still
  /// winding down would otherwise report its exit while its successor runs.
  Future<void> _quitEngine(_RunningEngine engine) async {
    if (!engine.exited.isCompleted) {
      if (_write('quit') < 0) {
        _logger.severe(
          'The engine could not be asked to quit and will never report an '
          'exit. Giving up on a clean shutdown. $diagnostics',
        );
      } else {
        try {
          await engine.exited.future.timeout(kQuitTimeout);
        } on TimeoutException {
          _logger.severe(
            'The ${_flavor.name} engine did not exit in time '
            '(${kQuitTimeout.inSeconds}s). $diagnostics '
            'It is abandoned: nothing it sends from now on is delivered, but '
            'until this process is restarted a new ${_flavor.name} engine may '
            'be refused by the native library, because the engine keeps its '
            'state in process globals the stuck one still owns.',
          );
        }
      }
    }

    if (identical(_engine, engine)) _engine = null;
    engine.dispose();
  }

  /// Ends this engine's session: slot returned, ports closed, state published.
  void _release(StockfishState finalState, {required bool closeStdout}) {
    _releaseSlot();
    _engine?.dispose();
    _engine = null;
    _state._setValue(finalState);
    if (closeStdout && !_stdoutController.isClosed) _stdoutController.close();
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

    if (_legacy) {
      _releaseSlot();
      _state._setValue(
        exitCode == 0 ? StockfishState.initial : StockfishState.error,
      );
      return;
    }

    // A handle whose engine is gone is unusable whatever the exit code, so an
    // exit nobody asked for is an error. When dispose() asked for it, it
    // publishes the final state itself.
    if (!_disposing) _state._setValue(StockfishState.error);
  }

  // ---------------------------------------------------------------------------
  // Deprecated singleton facade.
  // ---------------------------------------------------------------------------

  /// The singleton instance of Stockfish.
  @Deprecated(
    'Use Stockfish.create() and dispose() instead: engines are now per-flavor '
    'handles, so several flavors can be live at once and each has its own '
    'state and streams. This singleton will be removed in the next release.',
  )
  static final Stockfish instance = Stockfish._(
    StockfishFlavor.sf16,
    legacy: true,
  );

  /// Starts the C++ engine.
  ///
  /// Returns a [Future] that completes when the engine is ready to accept commands.
  ///
  /// When [flavor] is [StockfishFlavor.latestNoNNUE], [smallNetPath] and [bigNetPath] must be provided.
  ///
  /// Throws a [TimeoutException] if the engine does not become ready in time.
  @Deprecated(
    'Use Stockfish.create() instead, which returns an engine of its own '
    'rather than reconfiguring a shared one.',
  )
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
      _legacy,
      'start() only exists on the deprecated Stockfish.instance. An engine '
      'from Stockfish.create() is already started.',
    );
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

    // The singleton competes for the same per-flavor slots as create(), so a
    // caller half-migrated to handles cannot end up with two engines of one
    // flavor by using both APIs.
    _claimSlot(flavor);

    _variant = variant;
    _smallNetPath = smallNetPath;
    _bigNetPath = bigNetPath;

    return _pendingStart = _legacyStart().whenComplete(
      () => _pendingStart = null,
    );
  }

  Future<void> _legacyStart() async {
    try {
      await _doStart();
    } catch (_) {
      // The singleton survives a failed start and can be started again, so it
      // keeps its stdout stream; only the slot and the state are reset.
      _release(StockfishState.error, closeStdout: false);
      rethrow;
    }
  }

  /// Quits the C++ engine.
  ///
  /// Returns a [Future] that completes when the engine has exited.
  ///
  /// After quitting, the engine can be started again with [start].
  ///
  /// It is safe to call [quit] multiple times; subsequent calls will wait for the first to complete.
  @Deprecated(
    'Use dispose() on an engine from Stockfish.create() instead. Unlike quit(), '
    'it also gives up on an engine that will not exit.',
  )
  Future<void> quit() {
    assert(
      _legacy,
      'quit() only exists on the deprecated Stockfish.instance. Use dispose() '
      'on an engine from Stockfish.create().',
    );

    if (_pendingQuit != null) {
      return _pendingQuit!;
    }

    switch (_state.value) {
      case StockfishState.initial:
      case StockfishState.error:
      case StockfishState.disposed:
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
      _releaseSlot();
      _state._setValue(StockfishState.error);
    }
  }
}

/// The ports of a single engine, and its lifetime.
///
/// Each engine gets its own ports so that closing them is enough to make an
/// abandoned engine invisible to the [Stockfish] handle that started it.
class _RunningEngine {
  _RunningEngine({
    required void Function(int exitCode) onExit,
    required void Function(String line) onStdout,
  }) {
    mainPort.listen((message) {
      _logger.fine('The main isolate sent $message');
      _exitCode = message is int ? message : 1;
      dispose();
      onExit(_exitCode!);
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

  /// Completes when the engine has exited, with its exit code, or with null
  /// when it was disposed without reporting one.
  final exited = Completer<int?>();

  int? _exitCode;
  bool _disposed = false;

  /// Stops listening to this engine's isolates.
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    mainPort.close();
    stdoutPort.close();
    if (!exited.isCompleted) exited.complete(_exitCode);
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
