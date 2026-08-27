// The deprecated singleton is still part of this release, and its behaviour is
// still covered below.
// ignore_for_file: deprecated_member_use_from_same_package

import 'dart:async';
import 'dart:isolate';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:logging/logging.dart';
import 'package:multistockfish/multistockfish.dart';
import 'package:multistockfish/src/bindings.dart';

/// Mock implementation of [StockfishBindings] for testing.
///
/// One per flavor, as in production: each native library has its own pipes,
/// its own diagnostics and its own idea of whether a write succeeded.
class MockStockfishBindings implements StockfishBindings {
  final List<String> stdinCalls = [];
  int initReturnValue = 0;
  int mainReturnValue = 0;
  void Function(String input)? onStdin;

  /// The value [stdinWrite] reports. Negative values simulate a native write
  /// failure, e.g. an input pipe that stayed full.
  int stdinWriteReturnValue = 0;

  /// The phase, step and error the mocked native library reports.
  int phaseReturnValue = StockfishPhase.uciLoop.code;
  String phaseStepReturnValue = 'uci_loop';
  int phaseElapsedMsReturnValue = 0;
  String? lastErrorReturnValue;

  @override
  int init() => initReturnValue;

  @override
  int main() => mainReturnValue;

  @override
  int stdinWrite(String input) {
    stdinCalls.add(input);
    onStdin?.call(input);
    return stdinWriteReturnValue;
  }

  @override
  String? stdoutRead() => null;

  @override
  int phase() => phaseReturnValue;

  @override
  String phaseStep() => phaseStepReturnValue;

  @override
  int phaseElapsedMs() => phaseElapsedMsReturnValue;

  @override
  String? lastError() => lastErrorReturnValue;
}

/// A single simulated engine, holding the ports it was spawned with.
///
/// Each engine keeps its own ports, mirroring production, so that a test can
/// make an old engine talk after a new one has been spawned.
class MockEngine {
  MockEngine(this.flavor, this._mainPort, this._stdoutPort);

  /// The flavor this engine was spawned for.
  final StockfishFlavor flavor;

  final SendPort _mainPort;
  final SendPort _stdoutPort;

  bool _exited = false;

  /// Whether this engine is still running.
  bool get isAlive => !_exited;

  /// Simulates the engine outputting a line to stdout.
  void emitStdout(String line) {
    _stdoutPort.send(line);
  }

  /// Simulates the engine exiting with the given code.
  ///
  /// Exiting twice is a no-op, as it is for a real process.
  ///
  /// The reader stops too: a real engine writes the quit marker on its way out,
  /// and the isolate reading its pipe returns as soon as it sees it. The handle
  /// waits for both, so a mock that reported only the exit would leave every
  /// teardown sitting on the reader timeout.
  void exit(int code) {
    if (_exited) return;
    _exited = true;
    _mainPort.send(code);
    _stdoutPort.send(null);
  }

  /// Simulates an engine that exits without its reader ever letting go — one
  /// wedged somewhere that never writes the quit marker.
  void exitWithoutStoppingReader(int code) {
    if (_exited) return;
    _exited = true;
    _mainPort.send(code);
  }

  /// Simulates the reader isolate seeing the quit marker and returning.
  void stopReader() {
    _stdoutPort.send(null);
  }
}

/// Controller for simulating engine behavior in tests.
class MockEngineController {
  final Map<StockfishFlavor, MockStockfishBindings> _bindings = {};

  /// Every engine spawned so far, in spawn order.
  final List<MockEngine> engines = [];

  /// The high-water mark of [liveEngines].
  int maxLiveEngines = 0;

  Duration? _exitOnQuitAfter;

  /// The mocked native library of [flavor].
  MockStockfishBindings bindingsFor(StockfishFlavor flavor) =>
      _bindings.putIfAbsent(
        flavor,
        () =>
            MockStockfishBindings()
              ..onStdin = (input) => _onStdin(flavor, input),
      );

  /// The mocked native library of the default flavor.
  MockStockfishBindings get bindings => bindingsFor(StockfishFlavor.sf16);

  /// The most recently spawned engine.
  MockEngine get engine => engines.last;

  /// The most recently spawned engine of [flavor], alive or not.
  MockEngine engineOf(StockfishFlavor flavor) =>
      engines.lastWhere((e) => e.flavor == flavor);

  /// Engines spawned but not yet exited.
  int get liveEngines => engines.where((e) => e.isAlive).length;

  MockEngine? _liveEngineOf(StockfishFlavor flavor) =>
      engines.where((e) => e.flavor == flavor && e.isAlive).lastOrNull;

  /// Makes engines exit shortly after they are sent the `quit` command.
  ///
  /// Off by default so that tests drive exits explicitly. The exit is
  /// asynchronous, like a real engine's, so that enabling this exercises the
  /// window during which the engine has been told to quit but is still alive.
  void exitOnQuit({Duration after = Duration.zero}) {
    _exitOnQuitAfter = after;
  }

  void _onStdin(StockfishFlavor flavor, String input) {
    final after = _exitOnQuitAfter;
    if (after == null || input.trim() != 'quit') return;
    final engine = _liveEngineOf(flavor);
    if (engine == null) return;
    Future.delayed(after, () => engine.exit(0));
  }

  /// Simulates the [flavor] engine starting up by writing its version to
  /// stdout and responding to the "uci" command with "uciok".
  Future<void> simulateStartup({
    StockfishFlavor flavor = StockfishFlavor.sf16,
    String engineName = 'Stockfish 16',
  }) async {
    emitStdout(engineName, flavor: flavor);

    // Yield so that the engine being started writes the "uci" command to stdin
    await Future.delayed(Duration.zero);
    expect(bindingsFor(flavor).stdinCalls.lastOrNull, 'uci\n');
    emitStdout('uciok', flavor: flavor);
  }

  /// Simulates the latest live engine of [flavor] outputting a line.
  void emitStdout(String line, {StockfishFlavor? flavor}) {
    final engine = flavor == null ? engines.lastOrNull : _liveEngineOf(flavor);
    engine?.emitStdout(line);
  }

  /// Simulates the latest engine exiting with the given code.
  void exit(int code) {
    engines.lastOrNull?.exit(code);
  }

  /// Simulates every engine still running exiting with the given code.
  void exitAll(int code) {
    for (final engine in engines.where((e) => e.isAlive).toList()) {
      engine.exit(code);
    }
  }

  /// The spawn isolates override function for zone injection.
  Future<bool> spawnIsolates(
    SendPort mainPort,
    SendPort stdoutPort,
    StockfishFlavor flavor,
  ) async {
    if (bindingsFor(flavor).initReturnValue != 0) {
      return false;
    }

    engines.add(MockEngine(flavor, mainPort, stdoutPort));
    if (liveEngines > maxLiveEngines) maxLiveEngines = liveEngines;

    return true;
  }
}

/// Runs [body] with mock Stockfish bindings and isolate spawning.
///
/// The [controller] can be used to simulate engine behavior during the test.
/// Ensures cleanup happens within the zone context.
Future<T> runWithMockStockfish<T>(
  MockEngineController controller,
  FutureOr<T> Function() body,
) {
  return runZoned(
    () async {
      try {
        return await body();
      } finally {
        // Nothing may leak into the next test: the per-flavor slots and the
        // singleton are process-wide. Exiting the engines first keeps the
        // cleanup from waiting out a quit timeout.
        controller.exitAll(0);
        await Future.delayed(Duration.zero);
        for (final engine in Stockfish.debugLiveEngines.values.toList()) {
          if (identical(engine, Stockfish.instance)) {
            await engine.quit();
          } else {
            await engine.dispose();
          }
        }
      }
    },
    zoneValues: {
      stockfishBindingsFactoryKey: controller.bindingsFor,
      stockfishSpawnIsolatesKey: controller.spawnIsolates,
    },
  );
}

/// Creates an engine of [flavor] and drives its startup.
Future<Stockfish> createEngine(
  MockEngineController controller, {
  StockfishFlavor flavor = StockfishFlavor.sf16,
  String? variant,
  String engineName = 'Stockfish 16',
}) async {
  final future = Stockfish.create(flavor: flavor, variant: variant);
  await controller.simulateStartup(flavor: flavor, engineName: engineName);
  return future;
}

void main() {
  group('Stockfish.create', () {
    test('returns an engine that is ready for commands', () async {
      final controller = MockEngineController();

      await runWithMockStockfish(controller, () async {
        final engine = await createEngine(controller);

        expect(engine.state.value, StockfishState.ready);
        expect(engine.flavor, StockfishFlavor.sf16);

        engine.stdin = 'isready';
        expect(controller.bindings.stdinCalls, contains('isready\n'));
      });
    });

    test('refuses a second engine of the same flavor', () async {
      final controller = MockEngineController()..exitOnQuit();

      await runWithMockStockfish(controller, () async {
        final engine = await createEngine(controller);

        await expectLater(
          Stockfish.create(flavor: StockfishFlavor.sf16),
          throwsStateError,
        );

        // Only the first engine was ever spawned.
        expect(controller.engines, hasLength(1));

        // The slot is the engine's to give back.
        await engine.dispose();
        final replacement = await createEngine(controller);
        expect(replacement.state.value, StockfishState.ready);
        expect(controller.engines, hasLength(2));
      });
    });

    test('refuses a second engine while the first is still starting', () async {
      final controller = MockEngineController();

      await runWithMockStockfish(controller, () async {
        final first = Stockfish.create(flavor: StockfishFlavor.sf16);

        await expectLater(
          Stockfish.create(flavor: StockfishFlavor.sf16),
          throwsStateError,
          reason:
              'the slot is claimed before the engine is spawned, so two '
              'concurrent creates cannot both reach the native library',
        );

        await controller.simulateStartup();
        expect((await first).state.value, StockfishState.ready);
      });
    });

    test('runs two flavors at once, each with its own I/O and state', () async {
      final controller = MockEngineController()..exitOnQuit();

      await runWithMockStockfish(controller, () async {
        final analysis = await createEngine(controller);
        final opponent = await createEngine(
          controller,
          flavor: StockfishFlavor.variant,
          variant: 'crazyhouse',
          engineName: 'Fairy-Stockfish',
        );

        expect(controller.liveEngines, 2);
        expect(analysis.state.value, StockfishState.ready);
        expect(opponent.state.value, StockfishState.ready);
        expect(opponent.variant, 'crazyhouse');

        final analysisLines = <String>[];
        final opponentLines = <String>[];
        analysis.stdout.listen(analysisLines.add);
        opponent.stdout.listen(opponentLines.add);

        analysis.stdin = 'go depth 20';
        opponent.stdin = 'go movetime 500';

        controller.emitStdout(
          'info depth 20 score cp 31',
          flavor: StockfishFlavor.sf16,
        );
        controller.emitStdout('bestmove e2e4', flavor: StockfishFlavor.variant);
        await Future.delayed(Duration.zero);

        // Neither engine's traffic appears on the other's channel.
        expect(analysisLines, ['info depth 20 score cp 31']);
        expect(opponentLines, ['bestmove e2e4']);
        expect(
          controller.bindingsFor(StockfishFlavor.sf16).stdinCalls,
          contains('go depth 20\n'),
        );
        expect(
          controller.bindingsFor(StockfishFlavor.sf16).stdinCalls,
          isNot(contains('go movetime 500\n')),
        );
        expect(
          controller.bindingsFor(StockfishFlavor.variant).stdinCalls,
          contains('go movetime 500\n'),
        );

        // Disposing one leaves the other alone.
        await analysis.dispose();

        expect(analysis.state.value, StockfishState.disposed);
        expect(opponent.state.value, StockfishState.ready);
        opponent.stdin = 'stop';
        expect(
          controller.bindingsFor(StockfishFlavor.variant).stdinCalls,
          contains('stop\n'),
        );
      });
    });

    test('throws and frees the slot when init fails', () async {
      final controller = MockEngineController();
      controller.bindings.initReturnValue = 1;

      await runWithMockStockfish(controller, () async {
        await expectLater(Stockfish.create(), throwsException);
        expect(Stockfish.debugLiveEngines, isEmpty);

        // The flavor is available again once the cause is fixed.
        controller.bindings.initReturnValue = 0;
        final engine = await createEngine(controller);
        expect(engine.state.value, StockfishState.ready);
      });
    });

    test('throws TimeoutException when the engine does not respond', () async {
      final controller = MockEngineController();

      await runWithMockStockfish(controller, () {
        fakeAsync((async) {
          Object? caughtError;

          Stockfish.create().then<void>(
            (_) {},
            onError: (Object e) => caughtError = e,
          );

          async.flushMicrotasks();
          async.elapse(
            kStartTimeout + kQuitTimeout + const Duration(seconds: 1),
          );

          expect(caughtError, isA<TimeoutException>());
          expect(
            Stockfish.debugLiveEngines,
            isEmpty,
            reason: 'a failed create must not keep the flavor to itself',
          );

          controller.exit(0);
          async.flushMicrotasks();
        });
      });
    });

    test('a start that times out quits the engine and waits for it', () async {
      final controller = MockEngineController();

      await runWithMockStockfish(controller, () {
        fakeAsync((async) {
          Object? caughtError;

          Stockfish.create().then<void>(
            (_) {},
            onError: (Object e) => caughtError = e,
          );

          async.flushMicrotasks();
          async.elapse(kStartTimeout + const Duration(seconds: 1));

          // The engine has been told to quit, but create() does not report
          // failure while the engine may still be winding down: letting the
          // caller retry now would run two engines at once.
          expect(controller.bindings.stdinCalls, contains('quit\n'));
          expect(caughtError, isNull);
          expect(Stockfish.debugLiveEngines, isNotEmpty);

          async.elapse(kQuitTimeout);

          expect(caughtError, isA<TimeoutException>());
          expect(Stockfish.debugLiveEngines, isEmpty);
        });
      });
    });

    test('reports an engine that exits during startup, without waiting out '
        'the timeout', () async {
      final controller = MockEngineController();

      await runWithMockStockfish(controller, () async {
        final future = Stockfish.create();

        // The native library refused to run a second engine while the last one
        // is still wedged, so main() returns immediately.
        await Future.delayed(Duration.zero);
        controller.engine.exit(-1);

        await expectLater(
          future.timeout(
            const Duration(seconds: 1),
            onTimeout:
                () => fail('create() waited for an engine that had exited'),
          ),
          throwsA(
            isA<Exception>().having(
              (e) => e.toString(),
              'message',
              allOf(contains('exited while starting'), contains('-1')),
            ),
          ),
        );

        expect(Stockfish.debugLiveEngines, isEmpty);
      });
    });

    test('a failed start does not leave an engine behind for the next '
        'one', () async {
      final controller = MockEngineController()..exitOnQuit();

      await runWithMockStockfish(controller, () {
        fakeAsync((async) {
          for (var attempt = 0; attempt < 3; attempt++) {
            Stockfish.create().then<void>((_) {}, onError: (Object _) {});
            async.flushMicrotasks();
            async.elapse(
              kStartTimeout + kQuitTimeout + const Duration(seconds: 1),
            );
          }

          expect(controller.engines, hasLength(3));
          expect(controller.maxLiveEngines, 1);
          expect(controller.liveEngines, 0);
        });
      });
    });

    test('an engine abandoned after a failed start cannot disturb the next '
        'one', () async {
      final controller = MockEngineController();

      await runWithMockStockfish(controller, () async {
        // A first create times out, and the engine never honours the quit
        // command, so it is eventually given up on.
        fakeAsync((async) {
          Stockfish.create().then<void>((_) {}, onError: (Object _) {});
          async.flushMicrotasks();
          async.elapse(
            kStartTimeout + kQuitTimeout + const Duration(seconds: 1),
          );
        });

        final abandoned = controller.engines.single;
        expect(abandoned.isAlive, isTrue);

        // The next engine starts normally.
        final engine = await createEngine(controller);
        expect(engine.state.value, StockfishState.ready);

        // The abandoned engine finally comes back to life. Nothing it says
        // may reach the engine that replaced it.
        abandoned.emitStdout('too late');
        abandoned.exit(0);
        await Future.delayed(Duration.zero);

        expect(engine.state.value, StockfishState.ready);
        engine.stdin = 'isready';
      });
    });

    test('sends UCI_Variant option for variant flavor', () async {
      final controller = MockEngineController();

      await runWithMockStockfish(controller, () async {
        await createEngine(
          controller,
          flavor: StockfishFlavor.variant,
          variant: 'atomic',
          engineName: 'Fairy-Stockfish',
        );

        expect(
          controller.bindingsFor(StockfishFlavor.variant).stdinCalls,
          contains('setoption name UCI_Variant value atomic\n'),
        );
      });
    });

    test('sends NNUE paths for latestNoNNUE flavor', () async {
      final controller = MockEngineController();

      await runWithMockStockfish(controller, () async {
        final future = Stockfish.create(
          flavor: StockfishFlavor.latestNoNNUE,
          bigNetPath: '/path/to/big.nnue',
          smallNetPath: '/path/to/small.nnue',
        );
        await controller.simulateStartup(
          flavor: StockfishFlavor.latestNoNNUE,
          engineName: 'Stockfish 18',
        );
        final engine = await future;

        expect(engine.bigNetPath, '/path/to/big.nnue');
        expect(engine.smallNetPath, '/path/to/small.nnue');

        final calls =
            controller.bindingsFor(StockfishFlavor.latestNoNNUE).stdinCalls;
        expect(
          calls,
          contains('setoption name EvalFile value /path/to/big.nnue\n'),
        );
        expect(
          calls,
          contains('setoption name EvalFileSmall value /path/to/small.nnue\n'),
        );
      });
    });
  });

  group('Stockfish.dispose', () {
    test('quits the engine, waits for it and frees the flavor', () async {
      final controller = MockEngineController();

      await runWithMockStockfish(controller, () async {
        final engine = await createEngine(controller);
        final states = <StockfishState>[];
        engine.state.addListener(() => states.add(engine.state.value));

        final disposeFuture = engine.dispose();
        expect(controller.bindings.stdinCalls, contains('quit\n'));
        expect(
          Stockfish.debugLiveEngines,
          isNotEmpty,
          reason: 'the slot is held until the engine has actually exited',
        );

        controller.exit(0);
        await disposeFuture;

        expect(engine.state.value, StockfishState.disposed);
        expect(states, [StockfishState.disposed]);
        expect(Stockfish.debugLiveEngines, isEmpty);
      });
    });

    test('closes the stdout stream and refuses further commands', () async {
      final controller = MockEngineController()..exitOnQuit();

      await runWithMockStockfish(controller, () async {
        final engine = await createEngine(controller);

        var done = false;
        engine.stdout.listen(null, onDone: () => done = true);

        await engine.dispose();
        await Future.delayed(Duration.zero);

        expect(done, isTrue);
        expect(() => engine.stdin = 'isready', throwsStateError);
      });
    });

    test('concurrent calls share the first one', () async {
      final controller = MockEngineController();

      await runWithMockStockfish(controller, () async {
        final engine = await createEngine(controller);

        final dispose1 = engine.dispose();
        final dispose2 = engine.dispose();
        expect(dispose2, same(dispose1));

        expect(
          controller.bindings.stdinCalls.where((c) => c == 'quit\n').length,
          1,
        );

        controller.exit(0);
        await Future.wait([dispose1, dispose2]);

        // Disposing a disposed engine is a no-op, not a second quit.
        await engine.dispose();
        expect(
          controller.bindings.stdinCalls.where((c) => c == 'quit\n').length,
          1,
        );
      });
    });

    test('completes on an engine that has already died', () async {
      final controller = MockEngineController();

      await runWithMockStockfish(controller, () async {
        final engine = await createEngine(controller);

        controller.exit(1);
        await Future.delayed(Duration.zero);
        expect(engine.state.value, StockfishState.error);

        await engine.dispose().timeout(
          const Duration(seconds: 2),
          onTimeout: () => fail('dispose() hung on a dead engine'),
        );

        expect(
          engine.state.value,
          StockfishState.error,
          reason: 'disposing a failed engine is not what went wrong',
        );
        expect(Stockfish.debugLiveEngines, isEmpty);
      });
    });

    test('abandons an engine that will not exit, and frees the flavor '
        'anyway', () async {
      final controller = MockEngineController();

      await runWithMockStockfish(controller, () async {
        final engine = await createEngine(controller);

        fakeAsync((async) {
          var disposed = false;
          engine.dispose().then((_) => disposed = true);

          async.flushMicrotasks();
          expect(disposed, isFalse);

          async.elapse(kQuitTimeout + const Duration(seconds: 1));
          expect(disposed, isTrue);
        });

        expect(engine.state.value, StockfishState.disposed);
        expect(Stockfish.debugLiveEngines, isEmpty);

        // The wedged engine keeps running, but nothing it sends is delivered.
        final zombie = controller.engines.single;
        expect(zombie.isAlive, isTrue);
        zombie.emitStdout('too late');
        zombie.exit(0);
        await Future.delayed(Duration.zero);
        expect(engine.state.value, StockfishState.disposed);
      });
    });

    test(
      'waits for the reader to let go of the pipe before it returns',
      () async {
        final controller = MockEngineController();

        await runWithMockStockfish(controller, () async {
          final engine = await createEngine(controller);

          var disposed = false;
          unawaited(engine.dispose().then((_) => disposed = true));
          await pumpEventQueue();

          // The engine is gone, but its reader is still blocked on the pipe: it
          // only learns of the exit from the quit marker the engine wrote on its
          // way out.
          controller.engine.exitWithoutStoppingReader(0);
          await pumpEventQueue();
          expect(
            disposed,
            isFalse,
            reason:
                'returning here would let the next create() drain the pipe out '
                'from under a reader that has not stopped',
          );

          // The reader wakes, sees the marker and returns.
          controller.engine.stopReader();
          await pumpEventQueue();
          expect(disposed, isTrue);
        });
      },
    );

    test('does not wait forever for a reader that never stops', () async {
      final controller = MockEngineController();

      await runWithMockStockfish(controller, () async {
        final engine = await createEngine(controller);

        // Real time rather than fakeAsync: the exit below travels over a
        // ReceivePort, which only the real event loop delivers.
        final elapsed = Stopwatch()..start();
        final disposal = engine.dispose();
        await pumpEventQueue();
        controller.engine.exitWithoutStoppingReader(0);

        await disposal.timeout(
          kReaderStopTimeout * 3,
          onTimeout:
              () =>
                  fail('dispose() hung waiting for a reader that never stops'),
        );
        elapsed.stop();

        expect(
          elapsed.elapsed,
          greaterThanOrEqualTo(
            kReaderStopTimeout - const Duration(milliseconds: 100),
          ),
          reason: 'it should have given the reader its full window first',
        );
        expect(engine.state.value, StockfishState.disposed);
        expect(Stockfish.debugLiveEngines, isEmpty);
      });
    });

    test('does not wait for the reader of an engine that never exited', () async {
      final controller = MockEngineController();

      await runWithMockStockfish(controller, () async {
        final engine = await createEngine(controller);

        fakeAsync((async) {
          var disposed = false;
          engine.dispose().then((_) => disposed = true);

          // The engine is wedged: it never exits, so it never writes the marker
          // and its reader is never going to stop. Waiting for one would add
          // kReaderStopTimeout to a teardown that has already given up.
          async.elapse(kQuitTimeout + const Duration(milliseconds: 1));
          expect(disposed, isTrue);
        });
      });
    });

    test('gives up instead of hanging when quit cannot be delivered', () async {
      final controller = MockEngineController();

      await runWithMockStockfish(controller, () async {
        final engine = await createEngine(controller);

        // The engine has stopped reading, so it will never see "quit" and will
        // never report an exit.
        controller.bindings.stdinWriteReturnValue = -3;

        await engine.dispose().timeout(
          const Duration(seconds: 2),
          onTimeout:
              () => fail('dispose() hung waiting for an unreachable engine'),
        );

        expect(engine.state.value, StockfishState.disposed);
        expect(Stockfish.debugLiveEngines, isEmpty);
      });
    });
  });

  group('Stockfish.stdin', () {
    test('writes to its own flavor bindings', () async {
      final controller = MockEngineController();

      await runWithMockStockfish(controller, () async {
        final engine = await createEngine(controller);

        engine.stdin = 'uci';
        engine.stdin = 'isready';

        expect(controller.bindings.stdinCalls, contains('uci\n'));
        expect(controller.bindings.stdinCalls, contains('isready\n'));
      });
    });

    test('logs a failed write instead of throwing', () async {
      final controller = MockEngineController();
      final records = <LogRecord>[];

      final previousLevel = Logger.root.level;
      Logger.root.level = Level.ALL;
      final subscription = Logger.root.onRecord.listen(records.add);
      addTearDown(() {
        subscription.cancel();
        Logger.root.level = previousLevel;
      });

      await runWithMockStockfish(controller, () async {
        final engine = await createEngine(controller);

        // The input pipe stayed full: the engine has stopped reading.
        controller.bindings.stdinWriteReturnValue = -3;
        controller.bindings.phaseReturnValue = StockfishPhase.uciLoop.code;

        // Must not throw — a broken engine should not turn every command site
        // into a try/catch.
        expect(() => engine.stdin = 'go movetime 1000', returnsNormally);

        final severe = records.where((r) => r.level >= Level.SEVERE);
        expect(severe, isNotEmpty);
        expect(severe.last.message, contains('go movetime 1000'));
        expect(severe.last.message, contains('stopped reading'));

        // Nothing was written, so the command stream is still coherent and the
        // engine stays usable.
        expect(engine.state.value, StockfishState.ready);
      });
    });

    test('a partial write fails the engine so later commands throw', () async {
      final controller = MockEngineController();

      await runWithMockStockfish(controller, () async {
        final engine = await createEngine(controller);

        // Half a command reached the pipe: everything sent afterwards would
        // concatenate onto that fragment.
        controller.bindings.stdinWriteReturnValue =
            StockfishWriteResult.partial;

        engine.stdin = 'go movetime 1000';

        expect(engine.state.value, StockfishState.error);
        expect(
          () => engine.stdin = 'stop',
          throwsStateError,
          reason: 'the session is over; commands must not keep flowing',
        );
      });
    });

    test('a new engine is the recovery from a partial write', () async {
      final controller = MockEngineController();

      await runWithMockStockfish(controller, () async {
        final engine = await createEngine(controller);

        controller.bindings.stdinWriteReturnValue =
            StockfishWriteResult.partial;
        engine.stdin = 'go movetime 1000';
        expect(engine.state.value, StockfishState.error);

        controller.bindings.stdinWriteReturnValue = 0;
        final disposeFuture = engine.dispose();
        controller.exit(0);
        await disposeFuture;

        final replacement = await createEngine(controller);
        expect(replacement.state.value, StockfishState.ready);
      });
    });
  });

  group('Stockfish.stdout', () {
    test('emits lines from its engine', () async {
      final controller = MockEngineController();

      await runWithMockStockfish(controller, () async {
        final engine = await createEngine(controller);
        final lines = <String>[];
        engine.stdout.listen(lines.add);

        controller.emitStdout('info depth 12');
        controller.emitStdout('bestmove e2e4');
        await Future.delayed(Duration.zero);

        expect(lines, ['info depth 12', 'bestmove e2e4']);
      });
    });

    test(
      'onStdout sees the startup output stdout has already missed',
      () async {
        final controller = MockEngineController();

        await runWithMockStockfish(controller, () async {
          final fromCreate = <String>[];
          final future = Stockfish.create(onStdout: fromCreate.add);
          await controller.simulateStartup();
          final engine = await future;

          // create() only completes once the engine is ready, so a listener
          // attached to stdout here is already too late for the banner.
          final fromStdout = <String>[];
          engine.stdout.listen(fromStdout.add);
          await Future.delayed(Duration.zero);

          expect(fromCreate, ['Stockfish 16', 'uciok']);
          expect(fromStdout, isEmpty);

          // It keeps receiving for the engine's whole life, though.
          controller.emitStdout('bestmove e2e4');
          await Future.delayed(Duration.zero);
          expect(fromCreate, contains('bestmove e2e4'));
          expect(fromStdout, ['bestmove e2e4']);
        });
      },
    );
  });

  group('Stockfish.state', () {
    test('a crash is an error the handle does not recover from', () async {
      final controller = MockEngineController();

      await runWithMockStockfish(controller, () async {
        final engine = await createEngine(controller);
        final states = <StockfishState>[];
        engine.state.addListener(() => states.add(engine.state.value));

        controller.exit(1);
        await Future.delayed(Duration.zero);

        expect(engine.state.value, StockfishState.error);
        expect(states, [StockfishState.error]);
        expect(() => engine.stdin = 'isready', throwsStateError);

        // The engine is gone, so its flavor is free: a replacement does not
        // have to wait for the dead handle to be disposed.
        expect(Stockfish.debugLiveEngines, isEmpty);
        final replacement = await createEngine(controller);
        expect(replacement.state.value, StockfishState.ready);
      });
    });

    test('an engine sent `quit` ends as disposed, not as an error', () async {
      final controller = MockEngineController();

      await runWithMockStockfish(controller, () async {
        final engine = await createEngine(controller);
        final states = <StockfishState>[];
        engine.state.addListener(() => states.add(engine.state.value));

        // Quitting over stdin is a supported way to stop an engine, and the
        // engine exits cleanly: nothing failed.
        engine.stdin = 'quit';
        controller.exit(0);
        await Future.delayed(Duration.zero);

        expect(engine.state.value, StockfishState.disposed);
        expect(states, [StockfishState.disposed]);
        expect(Stockfish.debugLiveEngines, isEmpty);

        // Disposing afterwards is a no-op that completes.
        await engine.dispose().timeout(
          const Duration(seconds: 2),
          onTimeout: () => fail('dispose() hung on an engine that had quit'),
        );
        expect(engine.state.value, StockfishState.disposed);
      });
    });
  });

  group('Stockfish.diagnostics', () {
    test('reports what its flavor library publishes', () async {
      final controller = MockEngineController();
      controller.bindingsFor(StockfishFlavor.variant)
        ..phaseReturnValue = StockfishPhase.engineBooting.code
        ..phaseStepReturnValue = 'nnue'
        ..phaseElapsedMsReturnValue = 7000
        ..lastErrorReturnValue = 'init: discarded 3 stale byte(s)';

      await runWithMockStockfish(controller, () async {
        final engine = await createEngine(
          controller,
          flavor: StockfishFlavor.variant,
          engineName: 'Fairy-Stockfish',
        );

        final diagnostics = engine.diagnostics;
        expect(diagnostics.phase, StockfishPhase.engineBooting);
        expect(diagnostics.step, 'nnue');
        expect(diagnostics.elapsed, const Duration(seconds: 7));
        expect(diagnostics.lastError, 'init: discarded 3 stale byte(s)');
        expect(diagnostics.looksStuck, isTrue);
      });
    });

    test('says where a start stalled when it times out', () async {
      final controller = MockEngineController();
      controller.bindings
        ..phaseReturnValue = StockfishPhase.engineBooting.code
        ..phaseStepReturnValue = 'nnue'
        ..phaseElapsedMsReturnValue = 6000;

      await runWithMockStockfish(controller, () {
        fakeAsync((async) {
          Object? caughtError;

          Stockfish.create().then<void>(
            (_) {},
            onError: (Object e) => caughtError = e,
          );

          async.flushMicrotasks();
          async.elapse(
            kStartTimeout + kQuitTimeout + const Duration(seconds: 1),
          );

          expect(caughtError, isA<TimeoutException>());
          expect(caughtError.toString(), contains('phase=engineBooting'));
          expect(caughtError.toString(), contains('step=nnue'));

          controller.exit(0);
          async.flushMicrotasks();
        });
      });
    });
  });

  group('StockfishPhase', () {
    test('maps native codes, and unknown ones to unknown', () {
      expect(StockfishPhase.fromCode(0), StockfishPhase.idle);
      expect(StockfishPhase.fromCode(5), StockfishPhase.uciLoop);
      expect(StockfishPhase.fromCode(6), StockfishPhase.shuttingDown);
      expect(StockfishPhase.fromCode(-1), StockfishPhase.unknown);
      expect(StockfishPhase.fromCode(42), StockfishPhase.unknown);
    });

    test('marks transitional phases, but not resting or terminal ones', () {
      expect(StockfishPhase.engineBooting.isTransient, isTrue);
      expect(StockfishPhase.shuttingDown.isTransient, isTrue);
      expect(StockfishPhase.uciLoop.isTransient, isFalse);
      expect(StockfishPhase.exited.isTransient, isFalse);
      expect(StockfishPhase.unknown.isTransient, isFalse);
    });
  });

  group('StockfishDiagnostics', () {
    StockfishDiagnostics diagnostics({
      required StockfishPhase phase,
      required Duration elapsed,
      String step = 'step',
      String? lastError,
    }) => StockfishDiagnostics(
      phase: phase,
      step: step,
      elapsed: elapsed,
      lastError: lastError,
    );

    test('flags a transitional phase that has lasted too long as stuck', () {
      expect(
        diagnostics(
          phase: StockfishPhase.shuttingDown,
          elapsed: const Duration(seconds: 30),
        ).looksStuck,
        isTrue,
      );
    });

    test(
      'does not flag a brief transition, or a long rest in the UCI loop',
      () {
        expect(
          diagnostics(
            phase: StockfishPhase.shuttingDown,
            elapsed: const Duration(milliseconds: 20),
          ).looksStuck,
          isFalse,
        );
        expect(
          diagnostics(
            phase: StockfishPhase.uciLoop,
            elapsed: const Duration(hours: 1),
          ).looksStuck,
          isFalse,
        );
      },
    );

    test('describes the phase, step, duration and native error', () {
      final text =
          diagnostics(
            phase: StockfishPhase.shuttingDown,
            step: 'thread_pool_teardown',
            elapsed: const Duration(seconds: 12),
            lastError: 'main: refused',
          ).toString();

      expect(text, contains('phase=shuttingDown'));
      expect(text, contains('step=thread_pool_teardown'));
      expect(text, contains('12000ms'));
      expect(text, contains('STUCK'));
      expect(text, contains('main: refused'));
    });
  });

  group('native code descriptions', () {
    test('name the failure a wedged restart produces', () {
      expect(describeInitCode(-2), contains('never exited'));
      expect(describeMainExitCode(-1), contains('already running'));
    });

    test('distinguish a rejected write from a corrupting one', () {
      expect(describeWriteCode(-3), contains('stopped reading'));
      expect(describeWriteCode(-4), contains('corrupt'));
      expect(describeWriteCode(12), contains('12 bytes'));
    });
  });

  group('Stockfish.instance (deprecated)', () {
    test('is a singleton that starts in the initial state', () async {
      final controller = MockEngineController();

      await runWithMockStockfish(controller, () async {
        expect(Stockfish.instance, same(Stockfish.instance));
        expect(Stockfish.instance.state.value, StockfishState.initial);
        expect(Stockfish.instance.flavor, StockfishFlavor.sf16);
      });
    });

    test('cannot be disposed', () async {
      final controller = MockEngineController();

      await runWithMockStockfish(controller, () async {
        expect(() => Stockfish.instance.dispose(), throwsStateError);
      });
    });

    test('transitions to ready state on successful start', () async {
      final controller = MockEngineController();

      await runWithMockStockfish(controller, () async {
        final stockfish = Stockfish.instance;
        final startFuture = stockfish.start();

        // Yield to let async code run
        await Future.delayed(Duration.zero);
        expect(stockfish.state.value, StockfishState.starting);

        await controller.simulateStartup();

        await startFuture;
        expect(stockfish.state.value, StockfishState.ready);
      });
    });

    test('throws StateError when already running', () async {
      final controller = MockEngineController();

      await runWithMockStockfish(controller, () async {
        final stockfish = Stockfish.instance;
        final startFuture = stockfish.start();

        controller.simulateStartup();
        await startFuture;

        expect(stockfish.state.value, StockfishState.ready);
        expect(() => stockfish.start(), throwsStateError);
      });
    });

    test('returns same Future when start is already in progress', () async {
      final controller = MockEngineController();

      await runWithMockStockfish(controller, () async {
        final stockfish = Stockfish.instance;

        final startFuture1 = stockfish.start();

        await Future.delayed(Duration.zero);
        expect(stockfish.state.value, StockfishState.starting);

        final startFuture2 = stockfish.start();
        expect(startFuture2, same(startFuture1));

        controller.simulateStartup();

        await Future.wait([startFuture1, startFuture2]);
        expect(stockfish.state.value, StockfishState.ready);
      });
    });

    test('concurrent start calls all receive error on failure', () async {
      final controller = MockEngineController();

      await runWithMockStockfish(controller, () {
        fakeAsync((async) {
          Object? error1;
          Object? error2;

          final stockfish = Stockfish.instance;

          final startFuture1 = stockfish.start();
          startFuture1.catchError((Object e) => error1 = e);

          async.flushMicrotasks();

          final startFuture2 = stockfish.start();
          startFuture2.catchError((Object e) => error2 = e);

          expect(startFuture2, same(startFuture1));

          async.elapse(
            kStartTimeout + kQuitTimeout + const Duration(seconds: 1),
          );

          expect(error1, isA<TimeoutException>());
          expect(error2, isA<TimeoutException>());
          expect(stockfish.state.value, StockfishState.error);

          controller.exit(0);
          async.flushMicrotasks();
        });
      });
    });

    test('can restart after quit, keeping its stdout listeners', () async {
      final controller = MockEngineController();

      await runWithMockStockfish(controller, () async {
        final stockfish = Stockfish.instance;
        final lines = <String>[];
        final subscription = stockfish.stdout.listen(lines.add);
        addTearDown(subscription.cancel);

        final startFuture1 = stockfish.start();
        await controller.simulateStartup(engineName: 'Session 1');
        await startFuture1;
        expect(stockfish.state.value, StockfishState.ready);

        final quitFuture = stockfish.quit();
        expect(controller.bindings.stdinCalls, contains('quit\n'));
        controller.exit(0);
        await quitFuture;
        expect(stockfish.state.value, StockfishState.initial);

        final startFuture2 = stockfish.start();
        await controller.simulateStartup(engineName: 'Session 2');
        await startFuture2;
        expect(stockfish.state.value, StockfishState.ready);

        await Future.delayed(Duration.zero);
        expect(lines, containsAll(['Session 1', 'Session 2']));
      });
    });

    test('can restart after an error', () async {
      final controller = MockEngineController();
      controller.bindings.initReturnValue = 1;

      await runWithMockStockfish(controller, () async {
        final stockfish = Stockfish.instance;

        await expectLater(stockfish.start(), throwsException);
        expect(stockfish.state.value, StockfishState.error);

        controller.bindings.initReturnValue = 0;
        final startFuture = stockfish.start();
        await controller.simulateStartup();
        await startFuture;
        expect(stockfish.state.value, StockfishState.ready);
      });
    });

    test('waits for ready state before sending quit when starting', () async {
      final controller = MockEngineController();

      await runWithMockStockfish(controller, () async {
        final stockfish = Stockfish.instance;
        stockfish.start(); // Don't await

        await Future.delayed(Duration.zero);
        expect(stockfish.state.value, StockfishState.starting);

        final quitFuture = stockfish.quit();

        // quit not yet sent
        expect(controller.bindings.stdinCalls, isNot(contains('quit\n')));

        await controller.simulateStartup();
        await Future.delayed(Duration.zero);

        expect(controller.bindings.stdinCalls, contains('quit\n'));

        controller.exit(0);
        await quitFuture;
        expect(stockfish.state.value, StockfishState.initial);
      });
    });

    test('returns same Future when quit is already in progress', () async {
      final controller = MockEngineController();

      await runWithMockStockfish(controller, () async {
        final stockfish = Stockfish.instance;
        final startFuture = stockfish.start();
        await controller.simulateStartup();
        await startFuture;

        final quitFuture1 = stockfish.quit();
        final quitFuture2 = stockfish.quit();
        expect(quitFuture2, same(quitFuture1));

        expect(
          controller.bindings.stdinCalls.where((c) => c == 'quit\n').length,
          1,
        );

        controller.exit(0);
        await Future.wait([quitFuture1, quitFuture2]);
        expect(stockfish.state.value, StockfishState.initial);
      });
    });

    test('quit completes immediately when already in initial state', () async {
      final controller = MockEngineController();

      await runWithMockStockfish(controller, () async {
        final stockfish = Stockfish.instance;
        expect(stockfish.state.value, StockfishState.initial);

        await stockfish.quit();
        expect(stockfish.state.value, StockfishState.initial);
      });
    });

    test(
      'a quit that cannot be delivered gives up instead of hanging',
      () async {
        final controller = MockEngineController();

        await runWithMockStockfish(controller, () async {
          final stockfish = Stockfish.instance;
          final startFuture = stockfish.start();
          await controller.simulateStartup();
          await startFuture;

          // The engine has stopped reading, so it will never see "quit" and will
          // never report an exit.
          controller.bindings.stdinWriteReturnValue = -3;

          await stockfish.quit().timeout(
            const Duration(seconds: 2),
            onTimeout:
                () => fail('quit() hung waiting for an unreachable engine'),
          );

          expect(stockfish.state.value, StockfishState.error);
        });
      },
    );

    test(
      'transitions to error state on engine crash and can restart',
      () async {
        final controller = MockEngineController();

        await runWithMockStockfish(controller, () async {
          final stockfish = Stockfish.instance;
          final states = <StockfishState>[];
          stockfish.state.addListener(() => states.add(stockfish.state.value));

          final startFuture = stockfish.start();
          await controller.simulateStartup();
          await startFuture;
          expect(stockfish.state.value, StockfishState.ready);

          controller.exit(1);
          await Future.delayed(Duration.zero);

          expect(stockfish.state.value, StockfishState.error);
          expect(states, [
            StockfishState.starting,
            StockfishState.ready,
            StockfishState.error,
          ]);

          final restartFuture = stockfish.start();
          await controller.simulateStartup();
          await restartFuture;

          expect(stockfish.state.value, StockfishState.ready);
        });
      },
    );

    test('competes for the same flavor slot as create()', () async {
      final controller = MockEngineController()..exitOnQuit();

      await runWithMockStockfish(controller, () async {
        final engine = await createEngine(controller);

        // The singleton cannot take a flavor a handle already holds...
        expect(() => Stockfish.instance.start(), throwsStateError);

        await engine.dispose();

        final startFuture = Stockfish.instance.start();
        await controller.simulateStartup();
        await startFuture;

        // ...and a handle cannot take one the singleton holds.
        await expectLater(Stockfish.create(), throwsStateError);

        // A different flavor is unaffected.
        final variant = await createEngine(
          controller,
          flavor: StockfishFlavor.variant,
          engineName: 'Fairy-Stockfish',
        );
        expect(variant.state.value, StockfishState.ready);
        await variant.dispose();
      });
    });
  });
}
