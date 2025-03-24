import 'dart:ffi' as ffi;
import 'package:ffi/ffi.dart';
import 'package:logging/logging.dart';

final _logger = Logger('Stockfish');

class StockfishBindings {
  /// The symbols are looked up in [dynamicLibrary].
  StockfishBindings(ffi.DynamicLibrary dynamicLibrary)
    : _lookup = dynamicLibrary.lookup;

  /// Holds the symbol lookup function.
  final ffi.Pointer<T> Function<T extends ffi.NativeType>(String symbolName)
  _lookup;

  /// Initializes the Stockfish engine.
  int init() {
    return _init();
  }

  /// Runs the Stockfish engine.
  int main() {
    return _main();
  }

  /// Writes to the Stockfish engine's stdin.
  int stdinWrite(String input) {
    final inputPtr = input.toNativeUtf8();
    final result = _stdinWrite(inputPtr);
    calloc.free(inputPtr);
    return result;
  }

  /// Reads from the Stockfish engine's stdout.
  String? stdoutRead() {
    final pointer = _stdoutRead();

    if (pointer.address == 0) {
      _logger.fine('nativeStdoutRead returns NULL');
      return null;
    }
    return pointer.toDartString();
  }

  late final _initPtr = _lookup<ffi.NativeFunction<ffi.Int32 Function()>>(
    'stockfish_init',
  );
  late final _init = _initPtr.asFunction<int Function()>();

  late final _mainPtr = _lookup<ffi.NativeFunction<ffi.Int32 Function()>>(
    'stockfish_main',
  );
  late final _main = _mainPtr.asFunction<int Function()>();

  late final _stdinWritePtr =
      _lookup<ffi.NativeFunction<ffi.IntPtr Function(ffi.Pointer<Utf8>)>>(
        'stockfish_stdin_write',
      );
  late final _stdinWrite =
      _stdinWritePtr.asFunction<int Function(ffi.Pointer<Utf8>)>();

  late final _stdoutReadPtr =
      _lookup<ffi.NativeFunction<ffi.Pointer<Utf8> Function()>>(
        'stockfish_stdout_read',
      );
  late final _stdoutRead =
      _stdoutReadPtr.asFunction<ffi.Pointer<Utf8> Function()>();
}
