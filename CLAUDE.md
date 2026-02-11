# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

A Flutter plugin providing multiple flavors of the Stockfish chess engine for Android and iOS:
- **sf16**: Stockfish 16 with embedded NNUE (38MB)
- **latestNoNNUE**: Stockfish 17.1 without embedded NNUE (requires downloading .nnue files)
- **variant**: Fairy-Stockfish for chess variants (3check, crazyhouse, atomic, etc.)

## Development Commands

```bash
# Install dependencies (from repo root)
flutter pub get

# Run the example app
cd pkgs/multistockfish/example && flutter run

# Analyze code
flutter analyze

# Format code
dart format .
```

## Architecture

This is a Dart workspace monorepo with the following structure:

### Package Structure
- **pkgs/multistockfish**: Main Flutter plugin with Dart bindings and public API
- **pkgs/multistockfish_chess**: Native C++ library for Stockfish 17.1 (no embedded NNUE)
- **pkgs/multistockfish_sf16**: Native C++ library for Stockfish 16 (embedded NNUE)
- **pkgs/multistockfish_variant**: Native C++ library for Fairy-Stockfish (variants)

### Key Files in pkgs/multistockfish/lib/
- `src/stockfish.dart`: Main `Stockfish` class - singleton, manages isolates for engine communication
- `src/bindings.dart`: FFI bindings to native C++ libraries
- `src/stockfish_flavor.dart`: Enum defining engine variants
- `src/stockfish_state.dart`: Engine lifecycle states (initial, starting, ready, error)

### Engine Communication Pattern
The engine runs in separate isolates:
1. Main isolate calls native `stockfish_init()` and `stockfish_main()`
2. Stdout isolate continuously polls `stockfish_stdout_read()`
3. Commands sent via `stockfish_stdin_write()` from any thread

### Important Constraints
- `Stockfish` is a singleton - use `Stockfish.instance`
- Call `start()` to run the engine with configuration (flavor, variant, NNUE paths)
- `start()` throws `StateError` if engine is already running - call `quit()` first
- After `quit()`, state returns to `initial` and engine can be restarted
- The `stdout` stream persists across restarts - listeners don't need to re-subscribe
- For `latestNoNNUE` flavor, NNUE files must be downloaded and paths provided to `start()`

### Native Plugin Build
Each native package uses CMakeLists.txt (Android) and podspec (iOS) to build the Stockfish C++ source. The ios/ directories contain the full Stockfish source code.
