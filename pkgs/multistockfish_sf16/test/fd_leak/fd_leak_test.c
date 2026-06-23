// Pass/fail reproducer for the stockfish_init() fd leak. See README.md.
//
// The real stockfish_init() can't be linked here (its translation unit pulls in
// all of Stockfish), so this exercises the same pipe/dup2/close logic. With
// -DFD_LEAK_FIXED the body mirrors ios/Classes/stockfish16.cpp (must stay in
// sync); without it, the original buggy body is compiled.

#include <fcntl.h>
#include <stdio.h>
#include <string.h>
#include <sys/resource.h>
#include <unistd.h>

// ---- verbatim from the shim --------------------------------------------------
#define NUM_PIPES 2
#define PARENT_WRITE_PIPE 0
#define PARENT_READ_PIPE 1
#define READ_FD 0
#define WRITE_FD 1
#define PARENT_READ_FD (pipes[PARENT_READ_PIPE][READ_FD])
#define PARENT_WRITE_FD (pipes[PARENT_WRITE_PIPE][WRITE_FD])
#define CHILD_READ_FD (pipes[PARENT_WRITE_PIPE][READ_FD])
#define CHILD_WRITE_FD (pipes[PARENT_READ_PIPE][WRITE_FD])

int pipes[NUM_PIPES][2];
int pipes_open = 0;

int stockfish_init()
{
#ifdef FD_LEAK_FIXED
  // --- fixed: mirrors ios/Classes/stockfish16.cpp -----------------------------
  if (pipes_open)
  {
    close(PARENT_READ_FD);
    close(PARENT_WRITE_FD);
    pipes_open = 0;
  }

  if (pipe(pipes[PARENT_READ_PIPE]) != 0)
  {
    return -1;
  }
  if (pipe(pipes[PARENT_WRITE_PIPE]) != 0)
  {
    close(pipes[PARENT_READ_PIPE][READ_FD]);
    close(pipes[PARENT_READ_PIPE][WRITE_FD]);
    return -1;
  }

  pipes_open = 1;
  return 0;
#else
  // --- original (buggy) body --------------------------------------------------
  pipe(pipes[PARENT_READ_PIPE]);
  pipe(pipes[PARENT_WRITE_PIPE]);

  return 0;
#endif
}

// Models stockfish_main()'s fd bookkeeping: it closes the child ends (the dup2
// onto STDIN/STDOUT is omitted as it would corrupt fd accounting in a loop). The
// parent ends are left open -- that is the live engine's pipe.
void stockfish_main_close_child_ends()
{
  close(CHILD_READ_FD);
  close(CHILD_WRITE_FD);
}
// -----------------------------------------------------------------------------

static int count_open_fds(void)
{
  struct rlimit rl;
  getrlimit(RLIMIT_NOFILE, &rl);
  int max = (int)rl.rlim_cur;
  if (max > 4096) max = 4096;
  int n = 0;
  for (int fd = 0; fd < max; fd++)
  {
    if (fcntl(fd, F_GETFD) != -1) n++;
  }
  return n;
}

// Experiment A: with normal limits, repeated start/quit cycles must not grow the
// fd table. Returns 0 on PASS.
static int experiment_a(void)
{
  const int cycles = 40;
  const int base = count_open_fds();

  for (int i = 0; i < cycles; i++)
  {
    stockfish_init();
    stockfish_main_close_child_ends();
  }

  const int after = count_open_fds();
  const int growth = after - base;

  printf("[A] %d start/quit cycles: fd %d -> %d (growth %d, %.2f/cycle)\n",
         cycles, base, after, growth, growth / (double)cycles);

  // The fixed code keeps at most the single live pipe pair (+2) regardless of
  // cycle count. The buggy code leaks the 2 parent ends every cycle (~+2N).
  if (growth <= 4)
  {
    printf("[A] PASS: no per-cycle leak\n");
    return 0;
  }
  printf("[A] FAIL: leaking ~%.0f fds/cycle across %d cycles\n",
         growth / (double)cycles, cycles);
  return 1;
}

// Experiment B: under an fd ceiling (forced by holding fds open), a pipe()
// failure must reach the caller. The buggy code ignores pipe()'s return and
// reports success, so the Dart `initResult != 0` guard is blind. Returns 0 on
// PASS.
static int experiment_b(void)
{
  // Clean slate from experiment A.
  for (int fd = 3; fd < 4096; fd++) close(fd);
  pipes_open = 0;

  struct rlimit rl;
  getrlimit(RLIMIT_NOFILE, &rl);
  const struct rlimit saved = rl;
  rl.rlim_cur = 32;
  if (setrlimit(RLIMIT_NOFILE, &rl) != 0)
  {
    printf("[B] SKIP: could not lower RLIMIT_NOFILE\n");
    return 0;
  }

  // Saturate the descriptor table, then free exactly one slot so the next
  // pipe() (which needs two descriptors) is guaranteed to fail with EMFILE.
  int held[64];
  int n = 0;
  while (n < 64)
  {
    int fd = dup(1);
    if (fd < 0) break;
    held[n++] = fd;
  }
  if (n >= 1)
  {
    close(held[n - 1]);
    n--;
  }

  const int rc = stockfish_init();
  const int fdValid = (fcntl(PARENT_WRITE_FD, F_GETFD) != -1);

  for (int i = 0; i < n; i++) close(held[i]);
  setrlimit(RLIMIT_NOFILE, &saved);

  printf("[B] under EMFILE, stockfish_init() returned %d (pipe fds valid: %s)\n",
         rc, fdValid ? "yes" : "no");

#ifdef FD_LEAK_FIXED
  if (rc != 0)
  {
    printf("[B] PASS: pipe() failure surfaces to the caller\n");
    return 0;
  }
  printf("[B] FAIL: init() hid a pipe() failure\n");
  return 1;
#else
  if (rc == 0 && !fdValid)
  {
    printf("[B] original: init() reported success (0) despite pipe() failing"
           " -- the latent silent-failure bug\n");
  }
  // Informational for the buggy build; experiment A is the hard failure.
  return 0;
#endif
}

int main(void)
{
#ifdef FD_LEAK_FIXED
  printf("== stockfish_init fd-leak test (FIXED build) ==\n");
#else
  printf("== stockfish_init fd-leak test (ORIGINAL build) ==\n");
#endif
  int failures = 0;
  failures += experiment_a();
  failures += experiment_b();

  if (failures == 0)
  {
    printf("RESULT: PASS\n");
    return 0;
  }
  printf("RESULT: FAIL (%d experiment(s) failed)\n", failures);
  return 1;
}
