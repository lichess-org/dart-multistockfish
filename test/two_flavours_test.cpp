// Host integration test for private engine I/O, across two flavours at once.
//
// This is the guarantee P2 exists for. Each flavour already keeps its engine
// state to itself -- separate libraries, separate C++ namespaces -- so the only
// thing that ever stopped two of them running side by side was the channel: both
// shims dup2'd their pipe onto the process's fd 0 and fd 1, the second
// redirection won, and the two engines' output arrived interleaved in one place.
//
// Now each library reads and writes streams of its own, bound straight to its
// own pipe. This test links light and Fairy-Stockfish into a single binary -- the
// same way iOS links them under Swift Package Manager -- boots both, searches on
// both at the same time, and checks that neither one's traffic reaches the
// other's channel and that the process keeps its own stdout throughout.
//
// All diagnostics go to stderr, which leaves stdout free to be checked for
// exactly the interference the engines no longer cause.

#include <chrono>
#include <condition_variable>
#include <cstdio>
#include <cstring>
#include <mutex>
#include <string>
#include <sys/stat.h>
#include <thread>
#include <unistd.h>

extern "C" {
int stockfish_light_init();
int stockfish_light_main();
ssize_t stockfish_light_stdin_write(char *data);
char *stockfish_light_stdout_read();

int stockfish_variant_init();
int stockfish_variant_main();
ssize_t stockfish_variant_stdin_write(char *data);
char *stockfish_variant_stdout_read();
}

static int g_failures = 0;

static void check(bool ok, const char *what)
{
  fprintf(stderr, "  %s %s\n", ok ? "ok  " : "FAIL", what);
  if (!ok)
    g_failures++;
}

// Everything one engine has said, and a way to wait for a particular line.
// There is one of these per flavour on purpose: keeping the two apart is the
// whole point of the test.
struct Channel
{
  std::mutex mutex;
  std::condition_variable cv;
  std::string output;

  void push(const char *text)
  {
    {
      std::lock_guard<std::mutex> lock(mutex);
      output += text;
    }
    cv.notify_all();
  }

  bool wait_for(const char *needle, int timeout_ms = 60000)
  {
    std::unique_lock<std::mutex> lock(mutex);
    return cv.wait_for(lock, std::chrono::milliseconds(timeout_ms), [&] {
      return output.find(needle) != std::string::npos;
    });
  }

  bool saw(const char *needle)
  {
    std::lock_guard<std::mutex> lock(mutex);
    return output.find(needle) != std::string::npos;
  }
};

static Channel g_light;
static Channel g_variant;

static void send_light(const char *command)
{
  char buffer[512];
  snprintf(buffer, sizeof(buffer), "%s", command);
  stockfish_light_stdin_write(buffer);
}

static void send_variant(const char *command)
{
  char buffer[512];
  snprintf(buffer, sizeof(buffer), "%s", command);
  stockfish_variant_stdin_write(buffer);
}

int main()
{
  // A dup2 onto fd 1 changes both halves of this, so comparing it across the
  // run is a direct test of whether the engines took the process's stdout over.
  struct stat stdout_before;
  const bool stdout_known = fstat(STDOUT_FILENO, &stdout_before) == 0;

  fprintf(stderr, "\n-- both engines resident --\n");

  check(stockfish_light_init() == 0, "light initializes");
  check(stockfish_variant_init() == 0, "variant initializes");

  std::thread reader_light([] {
    while (char *line = stockfish_light_stdout_read())
      g_light.push(line);
  });
  std::thread reader_variant([] {
    while (char *line = stockfish_variant_stdout_read())
      g_variant.push(line);
  });

  // Before P2 the second of these two would have taken the first one's channel.
  std::thread engine_light([] { stockfish_light_main(); });
  std::thread engine_variant([] { stockfish_variant_main(); });

  check(g_light.wait_for("Stockfish 19"), "light greets on its own channel");
  check(g_variant.wait_for("Fairy-Stockfish"), "variant greets on its own channel");

  send_light("uci\n");
  send_variant("uci\n");
  check(g_light.wait_for("uciok"), "light answers uciok");
  check(g_variant.wait_for("uciok"), "variant answers uciok");

  check(!g_light.saw("Fairy-Stockfish"), "no variant output in the light channel");
  check(!g_variant.saw("Stockfish 19"), "no light output in the variant channel");

  // --- searching on both at the same time ----------------------------------
  fprintf(stderr, "\n-- searching on both at once --\n");

  send_light("position startpos\n");
  send_light("go depth 12\n");

  send_variant("setoption name UCI_Variant value crazyhouse\n");
  send_variant("position startpos\n");
  send_variant("go depth 8\n");

  check(g_light.wait_for("bestmove"), "light returns a bestmove while variant searches");
  check(g_variant.wait_for("bestmove"), "variant returns a bestmove while light searches");

  // The variant list is something only Fairy-Stockfish announces, which makes it
  // a good marker for traffic that must never turn up on the other channel.
  check(g_variant.saw("crazyhouse"), "variant really is the variant engine");
  check(!g_light.saw("crazyhouse"), "the variant's traffic never reached light's channel");

  send_light("quit\n");
  send_variant("quit\n");
  engine_light.join();
  engine_variant.join();
  reader_light.join();
  reader_variant.join();

  // --- and the host kept its own descriptors -------------------------------
  fprintf(stderr, "\n-- the host's stdout --\n");

  struct stat stdout_after;
  const bool still_ours = stdout_known && fstat(STDOUT_FILENO, &stdout_after) == 0
                          && stdout_before.st_dev == stdout_after.st_dev
                          && stdout_before.st_ino == stdout_after.st_ino;
  check(still_ours, "the process kept its own stdout throughout");

  fprintf(stderr, "\n%s (%d failure(s))\n", g_failures == 0 ? "PASS" : "FAIL",
          g_failures);
  return g_failures == 0 ? 0 : 1;
}
