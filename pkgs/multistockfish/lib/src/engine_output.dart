import 'dart:convert';

/// Turns an engine's output, delivered as chunks of UTF-8 bytes, into lines.
///
/// A chunk is a slice of a byte stream, cut wherever a read of the pipe happened
/// to stop, so it can end part way through a line or part way through a
/// multi-byte character. Both are carried over to the next chunk rather than
/// decoded on their own.
///
/// Malformed bytes decode to replacement characters instead of throwing: one
/// garbled character in a line of engine output is a far better outcome than
/// losing the session over it.
class EngineOutputDecoder {
  EngineOutputDecoder() {
    _input = const Utf8Decoder(allowMalformed: true).startChunkedConversion(
      const LineSplitter().startChunkedConversion(_ListSink(_lines)),
    );
  }

  final List<String> _lines = [];
  late final ByteConversionSink _input;

  /// Decodes [chunk] and returns the lines it completed, which may be none.
  List<String> add(List<int> chunk) {
    _input.add(chunk);
    if (_lines.isEmpty) return const [];
    final lines = List.of(_lines);
    _lines.clear();
    return lines;
  }
}

/// Collects what is added to it into [_list].
class _ListSink implements Sink<String> {
  _ListSink(this._list);

  final List<String> _list;

  @override
  void add(String data) => _list.add(data);

  @override
  void close() {}
}
