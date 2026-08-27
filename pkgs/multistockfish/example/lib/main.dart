import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:logging/logging.dart';
import 'package:multistockfish/multistockfish.dart';
import 'package:path_provider/path_provider.dart'
    show getApplicationSupportDirectory;

import 'stockfish_output.dart';

const _kDownloadUrl = 'https://tests.stockfishchess.org/api/nn/';
const _kBigNet = Stockfish.latestBigNNUE;
const _kSmallNet = Stockfish.latestSmallNNUE;

final _bigNetUrl = Uri.parse('$_kDownloadUrl$_kBigNet');
final _smallNetUrl = Uri.parse('$_kDownloadUrl$_kSmallNet');

void main() {
  Logger.root.level = Level.ALL;
  Logger.root.onRecord.listen((record) {
    debugPrint(
      '${record.level >= Level.WARNING ? record.level.name : ''} ${record.loggerName}: ${record.message}',
    );
  });

  runApp(const MyApp());
}

typedef NNUEFiles = ({String bigNetPath, String smallNetPath});

class MyApp extends StatefulWidget {
  const MyApp({super.key});
  @override
  State<StatefulWidget> createState() => _AppState();
}

class _AppState extends State<MyApp> {
  Directory? appSupportDirectory;
  StockfishFlavor flavor = StockfishFlavor.sf16;

  /// The most recent engine, kept after it ends so its final state stays on
  /// screen.
  ///
  /// Engines are per-flavor handles now: this app keeps one at a time, but
  /// nothing stops a second flavor from running alongside it.
  Stockfish? engine;

  /// The console, which outlives the engines that write to it.
  ///
  /// An engine's own `stdout` closes when it ends, and does not exist at all
  /// until `create` completes — by which point the banner and the UCI
  /// handshake have already been sent. `onStdout` appends here instead, and
  /// the log keeps every line whatever the widget tree does.
  final _console = ConsoleLog();

  final Completer<NNUEFiles> _nnueFilesCompleter = Completer<NNUEFiles>();

  Future<NNUEFiles> get nnueFiles => _nnueFilesCompleter.future;

  final ValueNotifier<double> _bigNetProgress = ValueNotifier(0.0);
  final ValueNotifier<double> _smallNetProgress = ValueNotifier(0.0);

  ValueListenable<double> get bigNetProgress => _bigNetProgress;
  ValueListenable<double> get smallNetProgress => _smallNetProgress;

  String? variant = '3check';

  NNUEFiles? _nnueFiles;

  /// The engine's native phase, polled rather than listened to: it changes on a
  /// thread Dart does not own, and the whole point is to keep reporting while
  /// the engine is wedged and sending no events at all.
  final ValueNotifier<StockfishDiagnostics?> _diagnostics = ValueNotifier(null);
  Timer? _diagnosticsTimer;
  StockfishPhase? _lastPhase;
  String? _lastStep;

  /// Publishes the engine's phase when it moves, and only then.
  ///
  /// The exception is a transitional phase: there the elapsed time is the whole
  /// signal, because a boot or a shutdown that keeps counting is a wedged
  /// engine. Sitting in the UCI loop or after exit, it is just a number going up.
  void _pollDiagnostics() {
    final engine = this.engine;
    if (engine == null) return;

    final next = engine.diagnostics;
    final moved = next.phase != _lastPhase || next.step != _lastStep;

    if (!moved && !next.phase.isTransient) return;

    _lastPhase = next.phase;
    _lastStep = next.step;
    _diagnostics.value = next;
  }

  static const _variants = [
    '3check',
    'crazyhouse',
    'atomic',
    'kingofthehill',
    'antichess',
    'horde',
    'racingkings',
  ];

  @override
  void initState() {
    super.initState();
    _fetchNNUEFiles();
    _diagnosticsTimer = Timer.periodic(
      const Duration(milliseconds: 500),
      (_) => _pollDiagnostics(),
    );
  }

  @override
  void dispose() {
    _diagnosticsTimer?.cancel();
    _diagnostics.dispose();
    // The engine outlives this widget unless it is released here: it owns two
    // isolates, a native engine and its flavor's slot.
    engine?.dispose();
    _console.dispose();
    super.dispose();
  }

  Future<void> _startStockfish() async {
    // A flavor's slot stays taken until its engine is disposed, including
    // after the engine has died, so anything left over goes first.
    await _disposeStockfish();

    final started = await Stockfish.create(
      flavor: flavor,
      variant: variant,
      bigNetPath: _nnueFiles?.bigNetPath,
      smallNetPath: _nnueFiles?.smallNetPath,
      onStdout: _console.add,
    );
    setState(() => engine = started);
  }

  Future<void> _disposeStockfish() async {
    final running = engine;
    if (running == null) return;
    // The handle is kept, not cleared: its state is the interesting thing to
    // show once it has ended.
    await running.dispose();
    if (mounted) setState(() {});
  }

  /// Sends a command, ignoring it unless the engine can accept one.
  void _send(String command) {
    final running = engine;
    if (running == null || running.state.value != StockfishState.ready) return;
    running.stdin = command;
  }

  Future<void> _restartStockfish() async {
    await _disposeStockfish();
    await _startStockfish();
  }

  /// Rebuilds when the running engine changes state, or when there is none.
  Widget _onEngineState(Widget Function(StockfishState? state) build) {
    final running = engine;
    if (running == null) return build(null);
    return AnimatedBuilder(
      animation: running.state,
      builder: (_, _) => build(running.state.value),
    );
  }

  Future<void> _fetchNNUEFiles() async {
    appSupportDirectory ??= await getApplicationSupportDirectory();
    final bigNet = File('${appSupportDirectory!.path}/$_kBigNet');
    final smallNet = File('${appSupportDirectory!.path}/$_kSmallNet');
    if (await bigNet.exists() && await smallNet.exists()) {
      _nnueFiles = (bigNetPath: bigNet.path, smallNetPath: smallNet.path);
      _nnueFilesCompleter.complete(_nnueFiles);
      return;
    }

    final dir = Directory(appSupportDirectory!.path);
    await for (final entity in dir.list(followLinks: false)) {
      if (entity is File && entity.path.endsWith('.nnue')) {
        debugPrint('Deleting existing nnue ${entity.path}');
        await entity.delete();
      }
    }

    debugPrint('Downloading NNUE files...');
    try {
      await Future.wait([
        downloadFile(
          _bigNetUrl,
          bigNet,
          onProgress: (received, length) {
            _bigNetProgress.value = received / length;
          },
        ),
        downloadFile(
          _smallNetUrl,
          smallNet,
          onProgress: (received, length) {
            _smallNetProgress.value = received / length;
          },
        ),
      ]);
    } catch (e) {
      debugPrint('Failed to download NNUE files: $e');
    }

    _nnueFiles = (bigNetPath: bigNet.path, smallNetPath: smallNet.path);
    _nnueFilesCompleter.complete(_nnueFiles);
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      home: Scaffold(
        appBar: AppBar(title: const Text('Stockfish example app')),
        body: FutureBuilder<NNUEFiles>(
          future: nnueFiles,
          builder: (context, snapshot) {
            return Column(
              children: [
                if (!snapshot.hasData)
                  Padding(
                    padding: const EdgeInsets.all(8.0),
                    child: AnimatedBuilder(
                      animation: bigNetProgress,
                      builder: (_, _) {
                        return Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text('Downloading big NNUE file'),
                            LinearProgressIndicator(
                              value: bigNetProgress.value,
                            ),
                          ],
                        );
                      },
                    ),
                  ),
                if (!snapshot.hasData)
                  Padding(
                    padding: const EdgeInsets.all(8.0),
                    child: AnimatedBuilder(
                      animation: smallNetProgress,
                      builder: (_, _) {
                        return Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text('Downloading small NNUE file'),
                            LinearProgressIndicator(
                              value: smallNetProgress.value,
                            ),
                          ],
                        );
                      },
                    ),
                  ),
                Padding(
                  padding: const EdgeInsets.all(8.0),
                  child: DropdownButton<StockfishFlavor>(
                    onChanged: (value) {
                      setState(() => flavor = value!);
                      if (engine?.state.value == StockfishState.ready) {
                        _restartStockfish();
                      }
                    },
                    value: flavor,
                    items: StockfishFlavor.values
                        .where(
                          (flavor) =>
                              flavor != StockfishFlavor.latestNoNNUE ||
                              snapshot.hasData,
                        )
                        .map(
                          (flavor) => DropdownMenuItem(
                            value: flavor,
                            child: Text(flavor.toString().split('.').last),
                          ),
                        )
                        .toList(growable: false),
                  ),
                ),
                if (flavor == StockfishFlavor.variant)
                  Padding(
                    padding: const EdgeInsets.all(8.0),
                    child: DropdownButton<String>(
                      onChanged: (value) {
                        setState(() => variant = value!);
                        if (engine?.state.value == StockfishState.ready) {
                          _restartStockfish();
                        }
                      },
                      value: variant,
                      items: _variants
                          .map(
                            (variant) => DropdownMenuItem(
                              value: variant,
                              child: Text(variant),
                            ),
                          )
                          .toList(growable: false),
                    ),
                  ),
                Padding(
                  padding: const EdgeInsets.all(8.0),
                  child: _onEngineState(
                    (state) => Text(
                      'stockfish.state=${state ?? 'no engine yet'}',
                      key: const ValueKey('stockfish.state'),
                    ),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 8.0),
                  child: ValueListenableBuilder<StockfishDiagnostics?>(
                    valueListenable: _diagnostics,
                    builder: (context, diagnostics, _) {
                      if (diagnostics == null) return const SizedBox.shrink();
                      return Align(
                        alignment: Alignment.centerLeft,
                        child: Text(
                          diagnostics.toString(),
                          key: const ValueKey('stockfish.diagnostics'),
                          style: TextStyle(
                            fontFamily: 'monospace',
                            fontSize: 11,
                            color:
                                diagnostics.looksStuck
                                    ? Theme.of(context).colorScheme.error
                                    : Theme.of(context).hintColor,
                          ),
                        ),
                      );
                    },
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.all(8.0),
                  child: _onEngineState(
                    (state) => Row(
                      children: [
                        ElevatedButton(
                          onPressed:
                              state == StockfishState.ready ||
                                      state == StockfishState.starting
                                  ? null
                                  : _startStockfish,
                          child: const Text('Start Stockfish'),
                        ),
                        const SizedBox(width: 8),
                        ElevatedButton(
                          onPressed:
                              state == StockfishState.ready
                                  ? _disposeStockfish
                                  : null,
                          child: const Text('Dispose'),
                        ),
                      ],
                    ),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.all(8.0),
                  child: TextField(
                    autocorrect: false,
                    decoration: const InputDecoration(
                      labelText: 'Custom UCI command',
                      hintText: 'go infinite',
                    ),
                    onSubmitted: _send,
                    textInputAction: TextInputAction.send,
                  ),
                ),
                Wrap(
                  children: [
                        'd',
                        'isready',
                        'bench',
                        'go movetime 3000',
                        'stop',
                        'quit',
                      ]
                      .map(
                        (command) => Padding(
                          padding: const EdgeInsets.all(8.0),
                          child: ElevatedButton(
                            onPressed: () => _send(command),
                            child: Text(command),
                          ),
                        ),
                      )
                      .toList(growable: false),
                ),
                Expanded(child: OutputWidget(_console)),
              ],
            );
          },
        ),
      ),
    );
  }
}

Future<void> downloadFile(
  Uri url,
  File file, {
  void Function(int received, int length)? onProgress,
}) async {
  final httpClient = http.Client();

  debugPrint('Downloading $url to ${file.path}');

  final response = await httpClient.send(http.Request('GET', url));
  final sink = file.openWrite();

  int received = 0;

  try {
    await response.stream
        .map((s) {
          received += s.length;
          onProgress?.call(received, response.contentLength!);
          return s;
        })
        .pipe(sink);
  } catch (e) {
    debugPrint('Failed to download file: $e');
  } finally {
    try {
      await sink.flush();
      await sink.close();
    } on FileSystemException catch (e) {
      debugPrint('Failed to save file: $e');
    }
    httpClient.close();
  }
}
