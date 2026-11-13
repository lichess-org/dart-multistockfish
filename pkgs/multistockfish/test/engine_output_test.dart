import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:multistockfish/src/engine_output.dart';

void main() {
  group('EngineOutputDecoder', () {
    test('splits a chunk into the lines it completes', () {
      final decoder = EngineOutputDecoder();

      expect(decoder.add(utf8.encode('info depth 20 score cp 31\nuciok\n')), [
        'info depth 20 score cp 31',
        'uciok',
      ]);
    });

    test('keeps blank lines', () {
      final decoder = EngineOutputDecoder();

      expect(decoder.add(utf8.encode('a\n\nb\n')), ['a', '', 'b']);
    });

    test('carries an unfinished line over to the next chunk', () {
      final decoder = EngineOutputDecoder();

      expect(decoder.add(utf8.encode('bestmove e2')), isEmpty);
      expect(decoder.add(utf8.encode('e4 ponder e7e5\n')), [
        'bestmove e2e4 ponder e7e5',
      ]);
    });

    test('reassembles a multi-byte character split across two chunks', () {
      final decoder = EngineOutputDecoder();

      // "é" is 0xC3 0xA9. A read of the pipe can stop between them, so this is
      // a byte stream, not a string, and half a character is a legitimate thing
      // to be handed.
      expect(decoder.add([...utf8.encode('info string caf'), 0xC3]), isEmpty);
      expect(decoder.add([0xA9, ...utf8.encode('\n')]), ['info string café']);
    });

    test('survives bytes that are not UTF-8 at all', () {
      final decoder = EngineOutputDecoder();

      final lines = decoder.add([...utf8.encode('info '), 0xFF, 0xFE, 0x0A]);

      expect(lines, hasLength(1));
      expect(lines.single, startsWith('info '));
    });
  });
}
