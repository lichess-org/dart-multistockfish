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
const _kBigNet = Stockfish.defaultBigNetFile;
const _kSmallNet = Stockfish.defaultSmallNetFile;

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
  late Stockfish stockfish;

  final Completer<NNUEFiles> _nnueFilesCompleter = Completer<NNUEFiles>();

  Future<NNUEFiles> get nnueFiles => _nnueFilesCompleter.future;

  final ValueNotifier<double> _bigNetProgress = ValueNotifier(0.0);
  final ValueNotifier<double> _smallNetProgress = ValueNotifier(0.0);

  ValueListenable<double> get bigNetProgress => _bigNetProgress;
  ValueListenable<double> get smallNetProgress => _smallNetProgress;

  String? variant = '3check';

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
    stockfish = Stockfish(flavor: flavor, variant: variant);
    _fetchNNUEFiles();
  }

  Future<void> _fetchNNUEFiles() async {
    appSupportDirectory ??= await getApplicationSupportDirectory();
    final bigNet = File('${appSupportDirectory!.path}/$_kBigNet');
    final smallNet = File('${appSupportDirectory!.path}/$_kSmallNet');
    if (await bigNet.exists() && await smallNet.exists()) {
      _nnueFilesCompleter.complete((
        bigNetPath: bigNet.path,
        smallNetPath: smallNet.path,
      ));
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

    _nnueFilesCompleter.complete((
      bigNetPath: bigNet.path,
      smallNetPath: smallNet.path,
    ));
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
                  child: AnimatedBuilder(
                    animation: stockfish.state,
                    builder: (_, _) {
                      return DropdownButton<StockfishFlavor>(
                        onChanged:
                            stockfish.state.value == StockfishState.disposed
                                ? (value) {
                                  setState(() {
                                    flavor = value!;
                                    stockfish = Stockfish(
                                      flavor: flavor,
                                      bigNetPath:
                                          snapshot.hasData
                                              ? snapshot.requireData.bigNetPath
                                              : null,
                                      smallNetPath:
                                          snapshot.hasData
                                              ? snapshot
                                                  .requireData
                                                  .smallNetPath
                                              : null,
                                      variant: variant,
                                    );
                                  });
                                }
                                : null,
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
                      );
                    },
                  ),
                ),
                if (flavor == StockfishFlavor.variant)
                  AnimatedBuilder(
                    animation: stockfish.state,
                    builder: (_, _) {
                      return Padding(
                        padding: const EdgeInsets.all(8.0),
                        child: DropdownButton<String>(
                          onChanged:
                              stockfish.state.value == StockfishState.disposed
                                  ? (value) {
                                    setState(() {
                                      variant = value!;
                                      stockfish = Stockfish(
                                        flavor: flavor,
                                        bigNetPath:
                                            snapshot.hasData
                                                ? snapshot
                                                    .requireData
                                                    .bigNetPath
                                                : null,
                                        smallNetPath:
                                            snapshot.hasData
                                                ? snapshot
                                                    .requireData
                                                    .smallNetPath
                                                : null,
                                        variant: variant,
                                      );
                                    });
                                  }
                                  : null,
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
                      );
                    },
                  ),
                Padding(
                  padding: const EdgeInsets.all(8.0),
                  child: AnimatedBuilder(
                    animation: stockfish.state,
                    builder:
                        (_, __) => Text(
                          'stockfish.state=${stockfish.state.value}',
                          key: const ValueKey('stockfish.state'),
                        ),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.all(8.0),
                  child: AnimatedBuilder(
                    animation: stockfish.state,
                    builder:
                        (_, __) => ElevatedButton(
                          onPressed:
                              stockfish.state.value == StockfishState.disposed
                                  ? () {
                                    final newInstance = Stockfish(
                                      flavor: flavor,
                                      variant: variant,
                                    );
                                    setState(() => stockfish = newInstance);
                                  }
                                  : null,
                          child: const Text('Reset Stockfish instance'),
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
                    onSubmitted: (value) => stockfish.stdin = value,
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
                            onPressed: () => stockfish.stdin = command,
                            child: Text(command),
                          ),
                        ),
                      )
                      .toList(growable: false),
                ),
                Expanded(child: OutputWidget(stockfish.stdout)),
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
