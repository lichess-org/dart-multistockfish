import 'dart:async';
import 'dart:isolate';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:logging/logging.dart';
import 'package:multistockfish/multistockfish.dart';
import 'package:multistockfish/src/bindings.dart';

/// Mock implementation of [StockfishBindings] for testing.
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
  MockEngine(this._mainPort, this._stdoutPort);

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
  void exit(int code) {
    if (_exited) return;
    _exited = true;
    _mainPort.send(code);
  }
}

/// Controller for simulating engine behavior in tests.
class MockEngineController {
  final MockStockfishBindings bindings = MockStockfishBindings();

  /// Every engine spawned so far, in spawn order.
  final List<MockEngine> engines = [];

  /// The most recently spawned engine.
  MockEngine get engine => engines.last;

  /// Engines spawned but not yet exited.
  int get liveEngines => engines.where((e) => e.isAlive).length;

  /// The high-water mark of [liveEngines].
  int maxLiveEngines = 0;

  /// Makes engines exit shortly after they are sent the `quit` command.
  ///
  /// Off by default so that tests drive exits explicitly. The exit is
  /// asynchronous, like a real engine's, so that enabling this exercises the
  /// window during which the engine has been told to quit but is still alive.
  void exitOnQuit({Duration after = Duration.zero}) {
    bindings.onStdin = (input) {
      if (input.trim() != 'quit') return;
      final engine = engines.lastWhere((e) => e.isAlive);
      Future.delayed(after, () => engine.exit(0));
    };
  }

  /// Simulates the engine starting up by writing its version to stdout
  /// and responding to the "uci" command with "uciok".
  Future<void> simulateStartup({String engineName = 'Stockfish 16'}) async {
    emitStdout(engineName);

    // Yield so that `Stockfish.instance.start()` writes the "uci" command to stdin
    await Future.delayed(Duration.zero);
    expect(bindings.stdinCalls.lastOrNull, 'uci\n');
    emitStdout('uciok');
  }

  /// Simulates the latest engine outputting a line to stdout.
  void emitStdout(String line) {
    engines.lastOrNull?.emitStdout(line);
  }

  /// Simulates the latest engine exiting with the given code.
  void exit(int code) {
    engines.lastOrNull?.exit(code);
  }

  /// The spawn isolates override function for zone injection.
  Future<bool> spawnIsolates(
    SendPort mainPort,
    SendPort stdoutPort,
    StockfishFlavor flavor,
  ) async {
    if (bindings.initReturnValue != 0) {
      return false;
    }

    engines.add(MockEngine(mainPort, stdoutPort));
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
        // Clean up by simulating engine exit to reset state
        controller.exit(0);
        await Future.delayed(Duration.zero);
      }
    },
    zoneValues: {
      stockfishBindingsFactoryKey:
          (StockfishFlavor flavor) => controller.bindings,
      stockfishSpawnIsolatesKey: controller.spawnIsolates,
    },
  );
}

void main() {
  group('Stockfish.instance', () {
    test('is a singleton', () {
      expect(Stockfish.instance, same(Stockfish.instance));
    });

    test('starts in initial state', () async {
      final controller = MockEngineController();

      await runWithMockStockfish(controller, () async {
        expect(Stockfish.instance.state.value, StockfishState.initial);
        expect(Stockfish.instance.flavor, StockfishFlavor.sf16);
      });
    });
  });

  group('Stockfish.start', () {
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

        // Try to start again - should throw
        expect(() => stockfish.start(), throwsStateError);
      });
    });

    test('returns same Future when start is already in progress', () async {
      final controller = MockEngineController();

      await runWithMockStockfish(controller, () async {
        final stockfish = Stockfish.instance;

        // Start the engine but don't await yet
        final startFuture1 = stockfish.start();

        // Yield to let async code run
        await Future.delayed(Duration.zero);
        expect(stockfish.state.value, StockfishState.starting);

        final startFuture2 = stockfish.start();

        expect(startFuture2, same(startFuture1));

        controller.simulateStartup();

        // Both should complete successfully
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

          // Start the engine (first caller)
          final startFuture1 = stockfish.start();
          startFuture1.catchError((e) {
            error1 = e;
            return null;
          });

          // Flush microtasks to let start() begin
          async.flushMicrotasks();

          // Call start again while in progress (second caller)
          final startFuture2 = stockfish.start();
          startFuture2.catchError((e) {
            error2 = e;
            return null;
          });

          // Both should be the same future
          expect(startFuture2, same(startFuture1));

          // Don't emit stdout - simulate timeout, then let the engine be
          // given up on
          async.elapse(
            kStartTimeout + kQuitTimeout + const Duration(seconds: 1),
          );

          // Both callers should receive the same error
          expect(error1, isA<TimeoutException>());
          expect(error2, isA<TimeoutException>());
          expect(stockfish.state.value, StockfishState.error);

          // Clean up
          controller.exit(0);
          async.flushMicrotasks();
        });
      });
    });

    test('can restart after quit', () async {
      final controller = MockEngineController();

      await runWithMockStockfish(controller, () async {
        final stockfish = Stockfish.instance;

        // First start
        final startFuture1 = stockfish.start();
        controller.simulateStartup();
        await startFuture1;
        expect(stockfish.state.value, StockfishState.ready);

        // Quit
        final quitFuture = stockfish.quit();
        controller.exit(0);
        await quitFuture;
        expect(stockfish.state.value, StockfishState.initial);

        // Restart
        final startFuture2 = stockfish.start();
        controller.simulateStartup();
        await startFuture2;
        expect(stockfish.state.value, StockfishState.ready);
      });
    });

    test('throws and sets error state when init fails', () async {
      final controller = MockEngineController();
      controller.bindings.initReturnValue = 1;

      await runWithMockStockfish(controller, () async {
        final stockfish = Stockfish.instance;

        await expectLater(stockfish.start(), throwsException);
        expect(stockfish.state.value, StockfishState.error);
      });
    });

    test('can restart after error', () async {
      final controller = MockEngineController();
      controller.bindings.initReturnValue = 1;

      await runWithMockStockfish(controller, () async {
        final stockfish = Stockfish.instance;

        // First start fails
        await expectLater(stockfish.start(), throwsException);
        expect(stockfish.state.value, StockfishState.error);

        // Fix the error and restart
        controller.bindings.initReturnValue = 0;
        final startFuture = stockfish.start();
        controller.simulateStartup();
        await startFuture;
        expect(stockfish.state.value, StockfishState.ready);
      });
    });

    test('throws TimeoutException when engine does not respond', () async {
      final controller = MockEngineController();

      await runWithMockStockfish(controller, () {
        fakeAsync((async) {
          Object? caughtError;

          Stockfish.instance.start().catchError((e) {
            caughtError = e;
            return null;
          });

          // Flush microtasks to let start() begin
          async.flushMicrotasks();

          // Advance time past the start timeout, then past the grace period
          // the failed engine is given to exit
          async.elapse(
            kStartTimeout + kQuitTimeout + const Duration(seconds: 1),
          );

          expect(caughtError, isA<TimeoutException>());
          expect(Stockfish.instance.state.value, StockfishState.error);

          // Clean up
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

          Stockfish.instance.start().catchError((e) {
            caughtError = e;
            return null;
          });

          async.flushMicrotasks();
          async.elapse(kStartTimeout + const Duration(seconds: 1));

          // The engine has been told to quit, but start() does not report
          // failure while the engine may still be winding down: letting the
          // caller retry now would run two engines at once.
          expect(controller.bindings.stdinCalls, contains('quit\n'));
          expect(caughtError, isNull);
          expect(Stockfish.instance.state.value, StockfishState.starting);

          async.elapse(kQuitTimeout);

          expect(caughtError, isA<TimeoutException>());
          expect(Stockfish.instance.state.value, StockfishState.error);
        });
      });
    });

    test(
      'a failed start does not leave an engine behind for the next one',
      () async {
        final controller = MockEngineController()..exitOnQuit();

        await runWithMockStockfish(controller, () {
          fakeAsync((async) {
            for (var attempt = 0; attempt < 3; attempt++) {
              Stockfish.instance.start().catchError((_) => null);
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
      },
    );

    test('an engine abandoned after a failed start cannot disturb the next '
        'one', () async {
      final controller = MockEngineController();

      await runWithMockStockfish(controller, () async {
        final stockfish = Stockfish.instance;

        // A first start times out, and the engine never honours the quit
        // command, so it is eventually given up on.
        fakeAsync((async) {
          stockfish.start().catchError((_) => null);
          async.flushMicrotasks();
          async.elapse(
            kStartTimeout + kQuitTimeout + const Duration(seconds: 1),
          );
          expect(stockfish.state.value, StockfishState.error);
        });

        final abandoned = controller.engines.single;
        expect(abandoned.isAlive, isTrue);

        // The next engine starts normally.
        final startFuture = stockfish.start();
        await controller.simulateStartup();
        await startFuture;
        expect(stockfish.state.value, StockfishState.ready);

        // The abandoned engine finally comes back to life. Nothing it says
        // may reach the engine that replaced it.
        abandoned.emitStdout('too late');
        abandoned.exit(0);
        await Future.delayed(Duration.zero);

        expect(stockfish.state.value, StockfishState.ready);
        stockfish.stdin = 'isready';

        final quitFuture = stockfish.quit();
        controller.exit(0);
        await quitFuture;
        expect(stockfish.state.value, StockfishState.initial);
      });
    });

    test('configures flavor correctly', () async {
      final controller = MockEngineController();

      await runWithMockStockfish(controller, () async {
        final stockfish = Stockfish.instance;
        final startFuture = stockfish.start(
          flavor: StockfishFlavor.variant,
          variant: 'atomic',
        );

        controller.simulateStartup();
        await startFuture;

        expect(stockfish.flavor, StockfishFlavor.variant);
        expect(stockfish.variant, 'atomic');
      });
    });

    test('sends UCI_Variant option for variant flavor', () async {
      final controller = MockEngineController();

      await runWithMockStockfish(controller, () async {
        final stockfish = Stockfish.instance;
        final startFuture = stockfish.start(
          flavor: StockfishFlavor.variant,
          variant: 'atomic',
        );

        controller.simulateStartup(engineName: 'Fairy-Stockfish');

        await startFuture;

        expect(
          controller.bindings.stdinCalls,
          contains('setoption name UCI_Variant value atomic\n'),
        );
      });
    });

    test('sends NNUE paths for latestNoNNUE flavor', () async {
      final controller = MockEngineController();

      await runWithMockStockfish(controller, () async {
        final stockfish = Stockfish.instance;
        final startFuture = stockfish.start(
          flavor: StockfishFlavor.latestNoNNUE,
          bigNetPath: '/path/to/big.nnue',
          smallNetPath: '/path/to/small.nnue',
        );

        controller.simulateStartup(engineName: 'Stockfish 17');

        await startFuture;

        expect(
          controller.bindings.stdinCalls,
          contains('setoption name EvalFile value /path/to/big.nnue\n'),
        );
        expect(
          controller.bindings.stdinCalls,
          contains('setoption name EvalFileSmall value /path/to/small.nnue\n'),
        );
      });
    });
  });

  group('Stockfish.quit', () {
    test('completes immediately when already in initial state', () async {
      final controller = MockEngineController();

      await runWithMockStockfish(controller, () async {
        final stockfish = Stockfish.instance;
        expect(stockfish.state.value, StockfishState.initial);

        // Should complete immediately
        await stockfish.quit();
        expect(stockfish.state.value, StockfishState.initial);
      });
    });

    test('sends quit command when ready and returns to initial', () async {
      final controller = MockEngineController();

      await runWithMockStockfish(controller, () async {
        final stockfish = Stockfish.instance;
        final startFuture = stockfish.start();

        controller.simulateStartup();
        await startFuture;

        final quitFuture = stockfish.quit();

        // Simulate engine exiting
        controller.exit(0);

        await quitFuture;

        expect(controller.bindings.stdinCalls, contains('quit\n'));
        expect(stockfish.state.value, StockfishState.initial);
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

        // Simulate engine becoming ready
        controller.simulateStartup();
        await Future.delayed(Duration.zero);

        // Now quit should be sent
        expect(controller.bindings.stdinCalls, contains('quit\n'));

        // Simulate engine exiting
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

        controller.simulateStartup();
        await startFuture;

        // Call quit multiple times concurrently
        final quitFuture1 = stockfish.quit();
        final quitFuture2 = stockfish.quit();
        final quitFuture3 = stockfish.quit();

        // All should be the same future
        expect(quitFuture2, same(quitFuture1));
        expect(quitFuture3, same(quitFuture1));

        // Only one quit command should be sent
        expect(
          controller.bindings.stdinCalls.where((c) => c == 'quit\n').length,
          equals(1),
        );

        // Simulate engine exiting
        controller.exit(0);

        // All futures should complete
        await Future.wait([quitFuture1, quitFuture2, quitFuture3]);
        expect(stockfish.state.value, StockfishState.initial);
      });
    });
  });

  group('Stockfish.stdin', () {
    test('throws StateError when not ready', () async {
      final controller = MockEngineController();

      await runWithMockStockfish(controller, () async {
        final stockfish = Stockfish.instance;

        expect(() => stockfish.stdin = 'uci', throwsStateError);
      });
    });

    test('writes to bindings when ready', () async {
      final controller = MockEngineController();

      await runWithMockStockfish(controller, () async {
        final stockfish = Stockfish.instance;
        final startFuture = stockfish.start();

        controller.simulateStartup();
        await startFuture;

        stockfish.stdin = 'uci';
        stockfish.stdin = 'isready';

        expect(controller.bindings.stdinCalls, contains('uci\n'));
        expect(controller.bindings.stdinCalls, contains('isready\n'));
      });
    });
  });

  group('Stockfish.stdout', () {
    test('emits lines from engine', () async {
      final controller = MockEngineController();

      await runWithMockStockfish(controller, () async {
        final stockfish = Stockfish.instance;
        final lines = <String>[];
        stockfish.stdout.listen(lines.add);

        final startFuture = stockfish.start();

        controller.emitStdout('Stockfish 16');
        controller.emitStdout('id name Stockfish');
        controller.emitStdout('uciok');

        await startFuture;
        await Future.delayed(Duration.zero);

        expect(
          lines,
          containsAll(['Stockfish 16', 'id name Stockfish', 'uciok']),
        );
      });
    });

    test('persists across restarts', () async {
      final controller = MockEngineController();

      await runWithMockStockfish(controller, () async {
        final stockfish = Stockfish.instance;
        final lines = <String>[];
        stockfish.stdout.listen(lines.add);

        // First session
        final startFuture1 = stockfish.start();
        controller.simulateStartup(engineName: 'Session 1');
        await startFuture1;

        final quitFuture = stockfish.quit();
        controller.exit(0);
        await quitFuture;

        // Second session - same listener should receive events
        final startFuture2 = stockfish.start();
        controller.simulateStartup(engineName: 'Session 2');
        await startFuture2;

        await Future.delayed(Duration.zero);

        expect(lines, containsAll(['Session 1', 'Session 2']));
      });
    });
  });

  group('Stockfish.state', () {
    test('notifies listeners on state changes', () async {
      final controller = MockEngineController();

      await runWithMockStockfish(controller, () async {
        final stockfish = Stockfish.instance;
        final states = <StockfishState>[];

        stockfish.state.addListener(() {
          states.add(stockfish.state.value);
        });

        final startFuture = stockfish.start();
        controller.simulateStartup();
        await startFuture;

        final quitFuture = stockfish.quit();
        controller.exit(0);
        await quitFuture;

        expect(states, [
          StockfishState.starting,
          StockfishState.ready,
          StockfishState.initial,
        ]);
      });
    });

    test(
      'transitions to error state on engine crash and can restart',
      () async {
        final controller = MockEngineController();

        await runWithMockStockfish(controller, () async {
          final stockfish = Stockfish.instance;
          final states = <StockfishState>[];

          stockfish.state.addListener(() {
            states.add(stockfish.state.value);
          });

          // Start the engine
          final startFuture = stockfish.start();
          controller.simulateStartup();
          await startFuture;
          expect(stockfish.state.value, StockfishState.ready);

          // Simulate engine crash (non-zero exit code)
          controller.exit(1);
          await Future.delayed(Duration.zero);

          expect(stockfish.state.value, StockfishState.error);
          expect(states, [
            StockfishState.starting,
            StockfishState.ready,
            StockfishState.error,
          ]);

          // Should be able to restart after crash
          final restartFuture = stockfish.start();
          controller.simulateStartup();
          await restartFuture;

          expect(stockfish.state.value, StockfishState.ready);
        });
      },
    );
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

  group('Stockfish.diagnostics', () {
    test('reports what the native library publishes', () async {
      final controller = MockEngineController();
      controller.bindings
        ..phaseReturnValue = StockfishPhase.engineBooting.code
        ..phaseStepReturnValue = 'nnue'
        ..phaseElapsedMsReturnValue = 7000
        ..lastErrorReturnValue = 'init: discarded 3 stale byte(s)';

      await runWithMockStockfish(controller, () {
        final diagnostics = Stockfish.instance.diagnostics;

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

          Stockfish.instance.start().catchError((e) {
            caughtError = e;
            return null;
          });

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

    test('logs a failed stdin write instead of throwing', () async {
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
        final stockfish = Stockfish.instance;
        final startFuture = stockfish.start();
        await controller.simulateStartup();
        await startFuture;

        // The input pipe stayed full: the engine has stopped reading.
        controller.bindings.stdinWriteReturnValue = -3;
        controller.bindings.phaseReturnValue = StockfishPhase.uciLoop.code;

        // Must not throw — a broken engine should not turn every command site
        // into a try/catch.
        expect(() => stockfish.stdin = 'go movetime 1000', returnsNormally);

        final severe = records.where((r) => r.level >= Level.SEVERE);
        expect(severe, isNotEmpty);
        expect(severe.last.message, contains('go movetime 1000'));
        expect(severe.last.message, contains('stopped reading'));

        // Nothing was written, so the command stream is still coherent and the
        // engine stays usable.
        expect(stockfish.state.value, StockfishState.ready);
      });
    });

    test('a partial write fails the engine so later commands throw', () async {
      final controller = MockEngineController();

      await runWithMockStockfish(controller, () async {
        final stockfish = Stockfish.instance;
        final startFuture = stockfish.start();
        await controller.simulateStartup();
        await startFuture;

        // Half a command reached the pipe: everything sent afterwards would
        // concatenate onto that fragment.
        controller.bindings.stdinWriteReturnValue =
            StockfishWriteResult.partial;

        stockfish.stdin = 'go movetime 1000';

        expect(stockfish.state.value, StockfishState.error);
        expect(
          () => stockfish.stdin = 'stop',
          throwsStateError,
          reason: 'the session is over; commands must not keep flowing',
        );
      });
    });

    test('can restart after a partial write kills the session', () async {
      final controller = MockEngineController();

      await runWithMockStockfish(controller, () async {
        final stockfish = Stockfish.instance;
        final startFuture = stockfish.start();
        await controller.simulateStartup();
        await startFuture;

        controller.bindings.stdinWriteReturnValue =
            StockfishWriteResult.partial;
        stockfish.stdin = 'go movetime 1000';
        expect(stockfish.state.value, StockfishState.error);

        // A restart is the documented recovery, and start() accepts the error
        // state.
        controller.bindings.stdinWriteReturnValue = 0;
        controller.exit(0);
        await Future<void>.delayed(Duration.zero);

        final restartFuture = stockfish.start();
        await controller.simulateStartup();
        await restartFuture;

        expect(stockfish.state.value, StockfishState.ready);
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
  });
}
