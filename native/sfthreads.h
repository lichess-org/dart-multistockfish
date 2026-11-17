// Native threads for the engine and for the reader of its output.
//
// The engine's UCI loop and the read of its output pipe both block for as long
// as the engine lives. Run from a Dart isolate, each of them pins that isolate
// inside an FFI call, and the Dart VM cannot bring an isolate that is in native
// code to the safepoint a hot reload needs: the reload waits for the call to
// return, which it never does while the engine is alive. Running both on threads
// of this library's own leaves every Dart isolate free.
//
// The threads report by posting to Dart ports with Dart_PostCObject, whose
// address the Dart side passes in (`NativeApi.postCObject`), so no part of the
// Dart SDK has to be compiled into this library. Posting to a port that has been
// closed, or whose isolate is gone -- after a hot restart, say -- is defined: the
// post returns false and nothing happens. A callback into a dead isolate would
// have no such guarantee, which is why these are ports and not callbacks.
//
// Header only and identical in every flavour, like sfio: each shim includes it
// and wires it to its own entry points.

#pragma once

#include <atomic>
#include <new>
#include <pthread.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

namespace sfthreads {

// ---------------------------------------------------------------------------
// The part of the Dart native API used here, mirrored from the SDK's
// include/dart_native_api.h and include/dart_api.h rather than vendored: only
// three message types are posted, and the struct and both enums are versioned
// by DART_API_DL_MAJOR_VERSION, which only ever appends to them.
// ---------------------------------------------------------------------------

typedef int64_t DartPort;

enum
{
  kDartCObjectNull = 0,      // Dart_CObject_kNull
  kDartCObjectInt64 = 3,     // Dart_CObject_kInt64
  kDartCObjectTypedData = 7, // Dart_CObject_kTypedData
};

enum
{
  kDartTypedDataUint8 = 2, // Dart_TypedData_kUint8
};

// Dart_CObject. The union is padded to the size of its largest member in the
// SDK (as_external_typed_data: an enum, a length and three pointers), because
// the VM is free to read the whole struct.
struct DartCObject
{
  int32_t type;
  union
  {
    int64_t as_int64;
    struct
    {
      int32_t type;
      intptr_t length; // in elements, which for Uint8 is bytes
      const uint8_t *values;
    } as_typed_data;
    void *reserved[5];
  } value;
};

// Dart_PostCObject. The message is copied before it returns, including the
// bytes of typed data, so the caller keeps ownership of everything it passed.
typedef bool (*PostCObject)(DartPort port, void *message);

static void post_null(PostCObject post, DartPort port)
{
  DartCObject message;
  memset(&message, 0, sizeof(message));
  message.type = kDartCObjectNull;
  post(port, &message);
}

static void post_int64(PostCObject post, DartPort port, int64_t value)
{
  DartCObject message;
  memset(&message, 0, sizeof(message));
  message.type = kDartCObjectInt64;
  message.value.as_int64 = value;
  post(port, &message);
}

// Arrives in Dart as a Uint8List. Bytes rather than a string, because a chunk is
// a slice of a byte stream and may end part way through a UTF-8 sequence: the
// Dart side decodes it together with the chunks around it.
static void post_bytes(PostCObject post, DartPort port, const char *bytes, size_t length)
{
  DartCObject message;
  memset(&message, 0, sizeof(message));
  message.type = kDartCObjectTypedData;
  message.value.as_typed_data.type = kDartTypedDataUint8;
  message.value.as_typed_data.length = static_cast<intptr_t>(length);
  message.value.as_typed_data.values = reinterpret_cast<const uint8_t *>(bytes);
  post(port, &message);
}

// ---------------------------------------------------------------------------
// Threads
// ---------------------------------------------------------------------------

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
  PostCObject post;
  DartPort exit_port;
};

struct ReaderArgs
{
  char *(*read)();
  PostCObject post;
  DartPort output_port;
  std::atomic<bool> *running;
};

// Posts the engine's exit code, once, when its main() returns.
static void *run_engine(void *raw)
{
  EngineArgs args = *static_cast<EngineArgs *>(raw);
  delete static_cast<EngineArgs *>(raw);

  const int exit_code = args.main();
  post_int64(args.post, args.exit_port, exit_code);
  return NULL;
}

// Posts each chunk of output, then null, once and last, when the read reports
// the end of the engine's output.
static void *run_reader(void *raw)
{
  ReaderArgs args = *static_cast<ReaderArgs *>(raw);
  delete static_cast<ReaderArgs *>(raw);

  for (;;)
  {
    const char *chunk = args.read();
    if (chunk == NULL)
      break;
    post_bytes(args.post, args.output_port, chunk, strlen(chunk));
  }

  // Cleared before the null is posted, so that whoever receives it can start
  // the next engine straight away without being refused.
  args.running->store(false, std::memory_order_release);
  post_null(args.post, args.output_port);
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

// Starts the reader of the engine's output on a thread of its own. [running]
// must already be true; the reader clears it when it stops. Returns false, and
// leaves [running] alone, if the thread could not be created.
static bool spawn_reader(char *(*read)(), PostCObject post, DartPort output_port,
                         std::atomic<bool> *running)
{
  ReaderArgs *args = new (std::nothrow) ReaderArgs{read, post, output_port, running};
  if (args == NULL)
    return false;
  if (spawn_detached(run_reader, args, 0))
    return true;
  delete args;
  return false;
}

// Starts the engine's main() on a thread of its own.
static bool spawn_engine(int (*main)(), PostCObject post, DartPort exit_port)
{
  EngineArgs *args = new (std::nothrow) EngineArgs{main, post, exit_port};
  if (args == NULL)
    return false;
  if (spawn_detached(run_engine, args, kEngineStackSize))
    return true;
  delete args;
  return false;
}

} // namespace sfthreads
