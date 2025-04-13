import 'dart:async';

import 'package:flutter/material.dart';

class OutputWidget extends StatefulWidget {
  final Stream<String> stdout;

  const OutputWidget(this.stdout, {super.key});

  @override
  State<StatefulWidget> createState() => _OutputState();
}

class _OutputState extends State<OutputWidget> {
  final items = <_OutputItem>[];

  late StreamSubscription subscription;

  @override
  void initState() {
    super.initState();
    _subscribe();
  }

  @override
  void didUpdateWidget(OutputWidget oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.stdout != oldWidget.stdout) {
      subscription.cancel();
      _subscribe();
    }
  }

  @override
  void dispose() {
    subscription.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ListView.builder(itemBuilder: _buildItem, itemCount: items.length);
  }

  void _subscribe() {
    subscription = widget.stdout.listen((line) {
      items.insert(0, _OutputItem.line(line));
      setState(() {});
    });
  }

  Widget _buildItem(BuildContext context, int index) {
    final item = items[index];
    final line = item.line;
    if (line != null) {
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 8),
        child: Text(line),
      );
    }

    return const SizedBox.shrink();
  }
}

class _OutputItem {
  final String? line;

  _OutputItem.line(this.line);
}
