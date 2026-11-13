// Native threads for the engine and for the reader of its output.
//
// The engine's UCI loop and the read of its output pipe both block for as long
// as the engine lives. Run from a Dart isolate, each of them pins that isolate
// inside an FFI call, and the Dart VM cannot bring an isolate that is in native
// code to the safepoint a hot reload needs: the reload waits for the call to
// return, which it never does while the engine is alive. Running both on threads
// of this library's own leaves every Dart isolate free, and the results are
// handed back through callbacks that never block their caller (on the Dart side,
// `NativeCallable.listener`s).
//
// Header only and identical in every flavour, like sfio: each shim includes it
// and wires it to its own entry points.

#pragma once

#include <new>
#include <pthread.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

namespace sfthreads {

// Receives the engine's exit code, once, when its main() returns.
typedef void (*ExitCallback)(int32_t exit_code);

// Receives each chunk of output, as a NUL-terminated copy allocated with
// malloc() that the callee owns and must free(). NULL, delivered once and last,
// means the reader has let go of the pipe.
typedef void (*OutputCallback)(char *chunk);

// The engine's main() runs the UCI loop: command parsing, position setup, and
// the shallow recursion of `perft` and `bench`. The search itself runs on
// threads the engine creates with a stack of their own. 2MB is a margin over
// the default of about 1MB on Android, set explicitly because a thread created
// without a size gets only 512KB on Apple platforms. It is address space, not
// memory: only the pages the thread touches are committed.
static const size_t kEngineStackSize = 2 * 1024 * 1024;

struct EngineArgs
{
  int (*main)();
  ExitCallback on_exit;
};

struct ReaderArgs
{
  char *(*read)();
  OutputCallback on_output;
};

static void *run_engine(void *raw)
{
  EngineArgs args = *static_cast<EngineArgs *>(raw);
  delete static_cast<EngineArgs *>(raw);

  args.on_exit(static_cast<int32_t>(args.main()));
  return NULL;
}

static void *run_reader(void *raw)
{
  ReaderArgs args = *static_cast<ReaderArgs *>(raw);
  delete static_cast<ReaderArgs *>(raw);

  for (;;)
  {
    char *chunk = args.read();
    if (chunk == NULL)
      break;

    // The read returns a buffer it reuses on the next call, which runs as soon
    // as this one is handed over, so the callee gets a copy of its own.
    char *copy = strdup(chunk);
    if (copy != NULL)
      args.on_output(copy);
  }

  args.on_output(NULL);
  return NULL;
}

// Starts a detached thread running [routine], with [stack_size] bytes of stack
// when it is non-zero. Returns false if the thread could not be created, in
// which case [routine] never runs.
static bool spawn_detached(void *(*routine)(void *), void *arg, size_t stack_size)
{
  pthread_attr_t attr;
  if (pthread_attr_init(&attr) != 0)
    return false;

  pthread_attr_setdetachstate(&attr, PTHREAD_CREATE_DETACHED);
  if (stack_size > 0)
    pthread_attr_setstacksize(&attr, stack_size);

  pthread_t thread;
  const bool started = pthread_create(&thread, &attr, routine, arg) == 0;
  pthread_attr_destroy(&attr);
  return started;
}

// Starts the reader of the engine's output on a thread of its own.
static bool spawn_reader(char *(*read)(), OutputCallback on_output)
{
  ReaderArgs *args = new (std::nothrow) ReaderArgs{read, on_output};
  if (args == NULL)
    return false;
  if (spawn_detached(run_reader, args, 0))
    return true;
  delete args;
  return false;
}

// Starts the engine's main() on a thread of its own.
static bool spawn_engine(int (*main)(), ExitCallback on_exit)
{
  EngineArgs *args = new (std::nothrow) EngineArgs{main, on_exit};
  if (args == NULL)
    return false;
  if (spawn_detached(run_engine, args, kEngineStackSize))
    return true;
  delete args;
  return false;
}

} // namespace sfthreads
