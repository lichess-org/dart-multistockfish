import 'dart:ffi' as ffi;
import 'package:ffi/ffi.dart';
import 'package:logging/logging.dart';

final _logger = Logger('Stockfish');

/// Abstract interface for Stockfish native bindings.
abstract class StockfishBindings {
  /// Initializes the Stockfish engine.
  int init();

  /// Runs the Stockfish engine.
  int main();

  /// Writes to the Stockfish engine's stdin.
  int stdinWrite(String input);

  /// Reads from the Stockfish engine's stdout.
  String? stdoutRead();
}

/// FFI implementation of [StockfishBindings].
///
/// Every native package built by this plugin (`multistockfish_chess`,
/// `multistockfish_sf16`, `multistockfish_variant`) exports its own copy of the
/// same four `stockfish_*` C functions. On platforms where several of these
/// native libraries can end up resolving symbols from the same process-wide
/// namespace (notably iOS, where a Swift Package Manager-built plugin is
/// statically linked into the app binary instead of loaded from its own
/// framework), identically-named exports would collide. [symbolPrefix] lets
/// each flavor other than the default look up its own uniquely-named symbols
/// (e.g. `stockfish_sf16_init`) to avoid that collision.
class StockfishBindingsFFI implements StockfishBindings {
  /// The symbols are looked up in [dynamicLibrary], using names prefixed by
  /// `stockfish_<symbolPrefix>_` (or just `stockfish_` when [symbolPrefix] is
  /// null).
  StockfishBindingsFFI(ffi.DynamicLibrary dynamicLibrary, {String? symbolPrefix})
    : _lookup = dynamicLibrary.lookup,
      _prefix = symbolPrefix == null ? 'stockfish_' : 'stockfish_${symbolPrefix}_';

  /// Holds the symbol lookup function.
  final ffi.Pointer<T> Function<T extends ffi.NativeType>(String symbolName)
  _lookup;

  final String _prefix;

  @override
  int init() {
    return _init();
  }

  @override
  int main() {
    return _main();
  }

  @override
  int stdinWrite(String input) {
    final inputPtr = input.toNativeUtf8();
    final result = _stdinWrite(inputPtr);
    calloc.free(inputPtr);
    return result;
  }

  @override
  String? stdoutRead() {
    final pointer = _stdoutRead();

    if (pointer.address == 0) {
      _logger.fine('nativeStdoutRead returns NULL');
      return null;
    }
    return pointer.toDartString();
  }

  late final _initPtr = _lookup<ffi.NativeFunction<ffi.Int32 Function()>>(
    '${_prefix}init',
  );
  late final _init = _initPtr.asFunction<int Function()>();

  late final _mainPtr = _lookup<ffi.NativeFunction<ffi.Int32 Function()>>(
    '${_prefix}main',
  );
  late final _main = _mainPtr.asFunction<int Function()>();

  late final _stdinWritePtr =
      _lookup<ffi.NativeFunction<ffi.IntPtr Function(ffi.Pointer<Utf8>)>>(
        '${_prefix}stdin_write',
      );
  late final _stdinWrite =
      _stdinWritePtr.asFunction<int Function(ffi.Pointer<Utf8>)>();

  late final _stdoutReadPtr =
      _lookup<ffi.NativeFunction<ffi.Pointer<Utf8> Function()>>(
        '${_prefix}stdout_read',
      );
  late final _stdoutRead =
      _stdoutReadPtr.asFunction<ffi.Pointer<Utf8> Function()>();
}
