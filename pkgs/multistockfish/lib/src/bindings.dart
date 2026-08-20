import 'dart:ffi' as ffi;
import 'package:ffi/ffi.dart';
import 'package:logging/logging.dart';

final _logger = Logger('Stockfish');

/// Abstract interface for Stockfish native bindings.
abstract class StockfishBindings {
  /// Initializes the Stockfish engine.
  ///
  /// Returns 0 on success, or a negative code described by `describeInitCode`.
  int init();

  /// Runs the Stockfish engine.
  ///
  /// Returns the engine's exit code, or a negative code described by
  /// `describeMainExitCode`.
  int main();

  /// Writes to the Stockfish engine's stdin.
  ///
  /// Returns the number of bytes written, or a negative code described by
  /// `describeWriteCode`. This call never blocks indefinitely: if the engine
  /// has stopped reading, it gives up and reports the failure instead.
  int stdinWrite(String input);

  /// Reads from the Stockfish engine's stdout.
  String? stdoutRead();

  /// The engine's current lifecycle phase, as a `SF_PHASE_*` code.
  ///
  /// Returns -1 when the native library does not expose diagnostics.
  int phase();

  /// A short name for the step within the current phase.
  ///
  /// Returns an empty string when the native library does not expose
  /// diagnostics.
  String phaseStep();

  /// Milliseconds spent on the current step.
  int phaseElapsedMs();

  /// The most recent error reported by the native library, if any.
  String? lastError();
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
  StockfishBindingsFFI(
    ffi.DynamicLibrary dynamicLibrary, {
    String? symbolPrefix,
  }) : _lookup = dynamicLibrary.lookup,
       _prefix =
           symbolPrefix == null ? 'stockfish_' : 'stockfish_${symbolPrefix}_';

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

  @override
  int phase() => _phase?.call() ?? -1;

  @override
  String phaseStep() {
    final pointer = _phaseStep?.call();
    if (pointer == null || pointer.address == 0) return '';
    return pointer.toDartString();
  }

  @override
  int phaseElapsedMs() => _phaseElapsedMs?.call() ?? 0;

  @override
  String? lastError() {
    final pointer = _lastError?.call();
    if (pointer == null || pointer.address == 0) return null;
    return pointer.toDartString();
  }

  /// Looks a symbol up, returning null when it is missing.
  ///
  /// The diagnostic symbols were added after the first release of the native
  /// packages. An app pinned to an older one should lose the diagnostics, not
  /// crash on the first lookup, so these are resolved leniently while the four
  /// core symbols stay strict.
  ffi.Pointer<T>? _tryLookup<T extends ffi.NativeType>(String symbolName) {
    try {
      return _lookup<T>(symbolName);
    } catch (error) {
      _logger.info(
        'Native diagnostics unavailable: could not resolve $symbolName ($error). '
        'Update the native plugin packages to get engine phase reporting.',
      );
      return null;
    }
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

  late final _phase =
      _tryLookup<ffi.NativeFunction<ffi.Int32 Function()>>(
        '${_prefix}phase',
      )?.asFunction<int Function()>();

  late final _phaseStep =
      _tryLookup<ffi.NativeFunction<ffi.Pointer<Utf8> Function()>>(
        '${_prefix}phase_step',
      )?.asFunction<ffi.Pointer<Utf8> Function()>();

  late final _phaseElapsedMs =
      _tryLookup<ffi.NativeFunction<ffi.Int64 Function()>>(
        '${_prefix}phase_elapsed_ms',
      )?.asFunction<int Function()>();

  late final _lastError =
      _tryLookup<ffi.NativeFunction<ffi.Pointer<Utf8> Function()>>(
        '${_prefix}last_error',
      )?.asFunction<ffi.Pointer<Utf8> Function()>();
}
