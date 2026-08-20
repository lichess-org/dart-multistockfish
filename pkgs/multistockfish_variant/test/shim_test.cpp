// Host integration test for the multistockfish native shim (variant flavour).
//
// Exercises exactly the P1 hardening: the re-entry guard, pipe reuse across a
// restart, no descriptor leak, and the non-blocking stdin write.
//
// All diagnostics go to stderr, because stockfish_variant_main() dup2s the
// engine's pipe onto the process's stdout.

#include <chrono>
#include <condition_variable>
#include <cstdio>
#include <cstring>
#include <fcntl.h>
#include <mutex>
#include <string>
#include <thread>
#include <unistd.h>

extern "C" {
int stockfish_variant_init();
int stockfish_variant_main();
ssize_t stockfish_variant_stdin_write(char *data);
char *stockfish_variant_stdout_read();
int stockfish_variant_phase();
const char *stockfish_variant_phase_step();
long long stockfish_variant_phase_elapsed_ms();
int stockfish_variant_last_error(char *buffer, int size);
}

#define SF_PHASE_INITIALIZED 2
#define SF_PHASE_UCI_LOOP 5
#define SF_PHASE_EXITED 7

static int g_failures = 0;

static void check(bool ok, const char *what)
{
  fprintf(stderr, "%s %s\n", ok ? "  ok  " : "  FAIL", what);
  if (!ok)
    g_failures++;
}

// ---------------------------------------------------------------------------

static std::mutex g_mutex;
static std::condition_variable g_cv;
static std::string g_output;

static void reader_thread()
{
  while (true)
  {
    char *line = stockfish_variant_stdout_read();
    if (line == nullptr)
      return;
    {
      std::lock_guard<std::mutex> lock(g_mutex);
      g_output += line;
    }
    g_cv.notify_all();
  }
}

static bool wait_for_output(const char *needle, int timeout_ms = 15000)
{
  std::unique_lock<std::mutex> lock(g_mutex);
  return g_cv.wait_for(lock, std::chrono::milliseconds(timeout_ms), [&] {
    return g_output.find(needle) != std::string::npos;
  });
}

static void reset_output()
{
  std::lock_guard<std::mutex> lock(g_mutex);
  g_output.clear();
}

static ssize_t send(const char *command)
{
  char buf[512];
  snprintf(buf, sizeof(buf), "%s", command);
  return stockfish_variant_stdin_write(buf);
}

// Mirrors how Dart calls it: the caller owns the destination buffer.
static const char *last_error()
{
  static char buffer[512];
  return stockfish_variant_last_error(buffer, sizeof(buffer)) > 0 ? buffer : nullptr;
}

static int open_fd_count()
{
  int count = 0;
  for (int fd = 0; fd < 512; fd++)
    if (fcntl(fd, F_GETFD) != -1)
      count++;
  return count;
}

// One full lifecycle: init, boot, uci handshake, quit, and a clean exit.
static void run_engine_session(const char *label, int *exit_code)
{
  fprintf(stderr, "\n-- %s --\n", label);

  reset_output();
  std::thread reader(reader_thread);
  std::thread engine([exit_code] { *exit_code = stockfish_variant_main(); });

  check(wait_for_output("Fairy-Stockfish"), "engine announces itself");

  check(send("uci\n") > 0, "uci accepted by the input pipe");
  check(wait_for_output("uciok"), "engine answers uciok");
  check(stockfish_variant_phase() == SF_PHASE_UCI_LOOP, "phase is uciLoop");
  fprintf(stderr, "  ..  step=%s\n", stockfish_variant_phase_step());

  check(send("quit\n") > 0, "quit accepted by the input pipe");
  engine.join();
  reader.join();

  check(*exit_code == 0, "engine exits with 0");
  check(stockfish_variant_phase() == SF_PHASE_EXITED, "phase is exited");
}

int main()
{
  const int fds_at_start = open_fd_count();

  fprintf(stderr, "\n-- init --\n");
  check(stockfish_variant_init() == 0, "init succeeds");
  check(stockfish_variant_phase() == SF_PHASE_INITIALIZED, "phase is initialized");

  int exit_code = -99;

  // --- session 1, with the re-entry guard probed while it is alive ---------
  {
    reset_output();
    std::thread reader(reader_thread);
    std::thread engine([&exit_code] { exit_code = stockfish_variant_main(); });

    check(wait_for_output("Fairy-Stockfish"), "engine announces itself");

    check(stockfish_variant_init() == -2, "init is refused while running");
    check(
        last_error() != nullptr && strstr(last_error(), "still running") != nullptr,
        "init explains why it refused");
    fprintf(stderr, "  ..  %s\n", last_error());

    check(stockfish_variant_main() == -1, "a second main() is refused");
    fprintf(stderr, "  ..  %s\n", last_error());

    check(send("uci\n") > 0, "uci accepted");
    check(wait_for_output("uciok"), "engine answers uciok");

    check(send("quit\n") > 0, "quit accepted");
    engine.join();
    reader.join();
    check(exit_code == 0, "engine exits with 0");
    check(stockfish_variant_phase() == SF_PHASE_EXITED, "phase is exited");
  }

  const int fds_after_first = open_fd_count();

  // --- session 2: a restart, which used to allocate a second pair of pipes -
  check(stockfish_variant_init() == 0, "init succeeds again after a clean exit");
  run_engine_session("restart", &exit_code);

  const int fds_after_second = open_fd_count();
  fprintf(stderr, "\n-- descriptors --\n");
  fprintf(stderr, "  ..  start=%d after 1st=%d after 2nd=%d\n", fds_at_start,
          fds_after_first, fds_after_second);
  check(fds_after_second == fds_after_first, "a restart leaks no descriptors");

  // --- the input pipe fills instead of blocking forever --------------------
  fprintf(stderr, "\n-- non-blocking write --\n");
  std::string filler(1024, 'x');
  filler[filler.size() - 1] = '\n';
  ssize_t result = 0;
  int writes = 0;
  const auto started = std::chrono::steady_clock::now();
  for (; writes < 500; writes++)
  {
    result = stockfish_variant_stdin_write(const_cast<char *>(filler.c_str()));
    if (result < 0)
      break;
  }
  const auto elapsed = std::chrono::duration_cast<std::chrono::seconds>(
                           std::chrono::steady_clock::now() - started)
                           .count();

  fprintf(stderr, "  ..  gave up after %d writes in %llds, result=%zd\n", writes,
          (long long)elapsed, result);
  check(result < 0, "a write to an unread pipe reports failure");
  check(result == -3 || result == -4, "and reports it as a full pipe");
  check(
      last_error() != nullptr && strstr(last_error(), "not reading") != nullptr,
      "with an error naming the cause");
  fprintf(stderr, "  ..  %s\n", last_error());

  fprintf(stderr, "\n%s (%d failure(s))\n", g_failures == 0 ? "PASS" : "FAIL",
          g_failures);
  return g_failures == 0 ? 0 : 1;
}
