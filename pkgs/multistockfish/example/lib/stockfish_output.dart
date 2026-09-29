import 'package:flutter/material.dart';

/// The engine console: an append-only log that outlives the engines writing to
/// it.
///
/// Deliberately not a [Stream]. A broadcast stream drops whatever is in flight
/// when a listener goes away, and it drops everything while there is no
/// listener at all, so a console built on one loses lines to widget rebuilds
/// and to the gap before the first `listen`. Appending to a list cannot.
class ConsoleLog extends ChangeNotifier {
  final List<String> _lines = [];

  /// The lines received so far, newest first.
  List<String> get lines => List.unmodifiable(_lines);

  void add(String line) {
    _lines.insert(0, line);
    notifyListeners();
  }

  void clear() {
    _lines.clear();
    notifyListeners();
  }
}

class OutputWidget extends StatelessWidget {
  final ConsoleLog log;

  const OutputWidget(this.log, {super.key});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: log,
      builder: (context, _) {
        final lines = log.lines;
        return ListView.builder(
          itemCount: lines.length,
          itemBuilder:
              (context, index) => Padding(
                padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 8),
                child: Text(lines[index]),
              ),
        );
      },
    );
  }
}
