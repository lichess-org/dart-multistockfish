import 'dart:async';
import 'dart:isolate';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:multistockfish/multistockfish.dart';
import 'package:multistockfish/src/bindings.dart';

/// Mock implementation of [StockfishBindings] for testing.
class MockStockfishBindings implements StockfishBindings {
  final List<String> stdinCalls = [];
  int initReturnValue = 0;
  int mainReturnValue = 0;

  @override
  int init() => initReturnValue;

  @override
  int main() => mainReturnValue;

  @override
  int stdinWrite(String input) {
    stdinCalls.add(input);
    return 0;
  }

  @override
  String? stdoutRead() => null;
}

/// Controller for simulating engine behavior in tests.
class MockEngineController {
  final MockStockfishBindings bindings = MockStockfishBindings();

  SendPort? _mainPort;
  SendPort? _stdoutPort;

  /// Simulates the engine outputting a line to stdout.
  void emitStdout(String line) {
    _stdoutPort?.send(line);
  }

  /// Simulates the engine exiting with the given code.
  void exit(int code) {
    _mainPort?.send(code);
  }

  /// The spawn isolates override function for zone injection.
  Future<bool> spawnIsolates(
    SendPort mainPort,
    SendPort stdoutPort,
    StockfishFlavor flavor,
  ) async {
    _mainPort = mainPort;
    _stdoutPort = stdoutPort;

    if (bindings.initReturnValue != 0) {
      return false;
    }

    return true;
  }
}

/// Runs [body] with mock Stockfish bindings and isolate spawning.
///
/// The [controller] can be used to simulate engine behavior during the test.
/// Ensures cleanup happens within the zone context.
Future<T> runWithMockStockfish<T>(
  MockEngineController controller,
  Future<T> Function() body,
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

        // Simulate engine outputting its name
        controller.emitStdout('Stockfish 16');

        await startFuture;
        expect(stockfish.state.value, StockfishState.ready);
      });
    });

    test('throws StateError when already running', () async {
      final controller = MockEngineController();

      await runWithMockStockfish(controller, () async {
        final stockfish = Stockfish.instance;
        final startFuture = stockfish.start();

        controller.emitStdout('Stockfish 16');
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

        controller.emitStdout('Stockfish 16');

        // Both should complete successfully
        await Future.wait([startFuture1, startFuture2]);
        expect(stockfish.state.value, StockfishState.ready);
      });
    });

    test('concurrent start calls all receive error on failure', () {
      fakeAsync((async) {
        final controller = MockEngineController();
        Object? error1;
        Object? error2;

        runZoned(
          () {
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

            // Don't emit stdout - simulate timeout
            async.elapse(const Duration(seconds: 11));

            // Both callers should receive the same error
            expect(error1, isA<TimeoutException>());
            expect(error2, isA<TimeoutException>());
            expect(stockfish.state.value, StockfishState.error);

            // Clean up
            controller.exit(0);
            async.flushMicrotasks();
          },
          zoneValues: {
            stockfishBindingsFactoryKey:
                (StockfishFlavor flavor) => controller.bindings,
            stockfishSpawnIsolatesKey: controller.spawnIsolates,
          },
        );
      });
    });

    test('can restart after quit', () async {
      final controller = MockEngineController();

      await runWithMockStockfish(controller, () async {
        final stockfish = Stockfish.instance;

        // First start
        final startFuture1 = stockfish.start();
        controller.emitStdout('Stockfish 16');
        await startFuture1;
        expect(stockfish.state.value, StockfishState.ready);

        // Quit
        final quitFuture = stockfish.quit();
        controller.exit(0);
        await quitFuture;
        expect(stockfish.state.value, StockfishState.initial);

        // Restart
        final startFuture2 = stockfish.start();
        controller.emitStdout('Stockfish 16');
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
        controller.emitStdout('Stockfish 16');
        await startFuture;
        expect(stockfish.state.value, StockfishState.ready);
      });
    });

    test('throws TimeoutException when engine does not respond', () {
      fakeAsync((async) {
        final controller = MockEngineController();
        Object? caughtError;

        runZoned(
          () {
            Stockfish.instance.start().catchError((e) {
              caughtError = e;
            });

            // Flush microtasks to let start() begin
            async.flushMicrotasks();

            // Advance time past the 10 second timeout
            async.elapse(const Duration(seconds: 11));

            expect(caughtError, isA<TimeoutException>());
            expect(Stockfish.instance.state.value, StockfishState.error);
          },
          zoneValues: {
            stockfishBindingsFactoryKey:
                (StockfishFlavor flavor) => controller.bindings,
            stockfishSpawnIsolatesKey: controller.spawnIsolates,
          },
        );
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

        controller.emitStdout('Fairy-Stockfish');
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

        controller.emitStdout('Fairy-Stockfish');

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

        controller.emitStdout('Stockfish 17');

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

        controller.emitStdout('Stockfish 16');
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
        controller.emitStdout('Stockfish 16');
        await Future.delayed(Duration.zero);

        // Now quit should be sent
        expect(controller.bindings.stdinCalls, contains('quit\n'));

        // Simulate engine exiting
        controller.exit(0);

        await quitFuture;
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

        controller.emitStdout('Stockfish 16');
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
        controller.emitStdout('Session 1');
        await startFuture1;

        final quitFuture = stockfish.quit();
        controller.exit(0);
        await quitFuture;

        // Second session - same listener should receive events
        final startFuture2 = stockfish.start();
        controller.emitStdout('Session 2');
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
        controller.emitStdout('Stockfish 16');
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
  });
}
