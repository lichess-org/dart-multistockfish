import 'dart:ffi' as ffi;

import 'package:ffi/ffi.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:multistockfish/src/bindings.dart';

/// Copies [bytes] into native memory, NUL-terminated, as the shim's buffer holds
/// them.
ffi.Pointer<ffi.Uint8> nativeBytes(List<int> bytes) {
  final pointer = calloc<ffi.Uint8>(bytes.length + 1);
  pointer.asTypedList(bytes.length + 1)
    ..setAll(0, bytes)
    ..[bytes.length] = 0;
  return pointer;
}

void main() {
  group('decodeEngineChunk', () {
    test('decodes ordinary engine output', () {
      final pointer = nativeBytes('info depth 20 score cp 31\n'.codeUnits);
      addTearDown(() => calloc.free(pointer));

      expect(decodeEngineChunk(pointer), 'info depth 20 score cp 31\n');
    });

    test('survives a multi-byte character split across two chunks', () {
      // "é" is 0xC3 0xA9. A chunk boundary can fall between them, and the engine
      // is only ever read a slice at a time — so this is a byte stream, not a
      // string, and half a character is a legitimate thing to be handed.
      final head = nativeBytes([...'info string caf'.codeUnits, 0xC3]);
      final tail = nativeBytes([0xA9, ...'\n'.codeUnits]);
      addTearDown(() => calloc.free(head));
      addTearDown(() => calloc.free(tail));

      // The point is that neither throws: an exception here would land in the
      // reader isolate's loop and kill the only thing draining the engine's pipe.
      expect(decodeEngineChunk(head), startsWith('info string caf'));
      expect(decodeEngineChunk(tail), endsWith('\n'));
    });

    test('survives bytes that are not UTF-8 at all', () {
      final pointer = nativeBytes([...'info '.codeUnits, 0xFF, 0xFE, 0x0A]);
      addTearDown(() => calloc.free(pointer));

      expect(decodeEngineChunk(pointer), startsWith('info '));
    });

    test('stops at the terminator, not at the end of the buffer', () {
      // The shim hands back a 4096-byte buffer with the output NUL-terminated
      // part way through it; everything past the NUL is the previous read's.
      final pointer = calloc<ffi.Uint8>(64);
      addTearDown(() => calloc.free(pointer));
      final view = pointer.asTypedList(64)..fillRange(0, 64, 0x78);
      view.setAll(0, 'uciok\n'.codeUnits);
      view[6] = 0;

      expect(decodeEngineChunk(pointer), 'uciok\n');
    });
  });
}
