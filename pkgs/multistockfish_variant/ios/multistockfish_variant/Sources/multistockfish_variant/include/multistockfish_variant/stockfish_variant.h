#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>

#if _WIN32
#include <windows.h>
#else
#include <pthread.h>
#include <unistd.h>
#endif

#if _WIN32
#define FFI_PLUGIN_EXPORT __declspec(dllexport)
#else
#define FFI_PLUGIN_EXPORT
#endif

// ---------------------------------------------------------------------------
// Phases reported by stockfish_variant_phase().
//
// These numbers are part of the FFI contract and are mirrored by
// StockfishPhase on the Dart side; keep the two in step. The same numbering is
// used by every flavour of the plugin.
// ---------------------------------------------------------------------------
#define SF_PHASE_IDLE 0           // library loaded, init() not called yet
#define SF_PHASE_INITIALIZING 1   // creating the pipes
#define SF_PHASE_INITIALIZED 2    // pipes ready, waiting for main()
#define SF_PHASE_REDIRECTING 3    // inside main(), redirecting the descriptors
#define SF_PHASE_ENGINE_BOOTING 4 // engine global init (tables, NNUE, threads)
#define SF_PHASE_UCI_LOOP 5       // inside UCI::loop, accepting commands
#define SF_PHASE_SHUTTING_DOWN 6  // loop returned, joining the thread pool
#define SF_PHASE_EXITED 7         // main() returned cleanly
#define SF_PHASE_FAILED 8         // init or main failed

// Error codes returned by stockfish_variant_init().
#define SF_INIT_PIPE_FAILED (-1)
#define SF_INIT_ALREADY_RUNNING (-2)
#define SF_INIT_FCNTL_FAILED (-3)

// Error codes returned by stockfish_variant_main(). Non-negative values are the
// engine's own exit code.
#define SF_MAIN_ALREADY_RUNNING (-1)
#define SF_MAIN_NOT_INITIALIZED (-2)
#define SF_MAIN_DUP2_FAILED (-3)
#define SF_MAIN_ENGINE_THREW (-4)

// Error codes returned by stockfish_variant_stdin_write(). Non-negative values
// are the number of bytes written.
#define SF_WRITE_NOT_INITIALIZED (-1)
#define SF_WRITE_FAILED (-2)
#define SF_WRITE_PIPE_FULL (-3)
#define SF_WRITE_PARTIAL (-4)

#ifdef __cplusplus
extern "C" __attribute__((visibility("default"))) __attribute__((used))
#endif
FFI_PLUGIN_EXPORT int stockfish_variant_init();

#ifdef __cplusplus
extern "C" __attribute__((visibility("default"))) __attribute__((used))
#endif
FFI_PLUGIN_EXPORT int stockfish_variant_main();

#ifdef __cplusplus
extern "C" __attribute__((visibility("default"))) __attribute__((used))
#endif
FFI_PLUGIN_EXPORT ssize_t stockfish_variant_stdin_write(char *data);

#ifdef __cplusplus
extern "C" __attribute__((visibility("default"))) __attribute__((used))
#endif
FFI_PLUGIN_EXPORT char * stockfish_variant_stdout_read();

/// The engine's current lifecycle phase, as one of the SF_PHASE_* values.
#ifdef __cplusplus
extern "C" __attribute__((visibility("default"))) __attribute__((used))
#endif
FFI_PLUGIN_EXPORT int stockfish_variant_phase();

/// A short name for the step within the current phase, e.g. "nnue" or
/// "thread_pool_teardown". Always a string literal, never NULL.
#ifdef __cplusplus
extern "C" __attribute__((visibility("default"))) __attribute__((used))
#endif
FFI_PLUGIN_EXPORT const char * stockfish_variant_phase_step();

/// Milliseconds spent in the current step. A large value while the engine is
/// booting or shutting down is the signature of a wedged engine.
#ifdef __cplusplus
extern "C" __attribute__((visibility("default"))) __attribute__((used))
#endif
FFI_PLUGIN_EXPORT long long stockfish_variant_phase_elapsed_ms();

/// The most recent error message, or NULL if nothing has failed yet.
#ifdef __cplusplus
extern "C" __attribute__((visibility("default"))) __attribute__((used))
#endif
FFI_PLUGIN_EXPORT const char * stockfish_variant_last_error();
