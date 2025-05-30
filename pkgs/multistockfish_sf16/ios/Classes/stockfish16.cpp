#include <iostream>
#include <stdio.h>
#include <unistd.h>

#include "../Stockfish16/src/bitboard.h"
#include "../Stockfish16/src/endgame.h"
#include "../Stockfish16/src/position.h"
#include "../Stockfish16/src/psqt.h"
#include "../Stockfish16/src/search.h"
#include "../Stockfish16/src/syzygy/tbprobe.h"
#include "../Stockfish16/src/thread.h"
#include "../Stockfish16/src/tt.h"
#include "../Stockfish16/src/uci.h"

#include "stockfish16.h"

// https://jineshkj.wordpress.com/2006/12/22/how-to-capture-stdin-stdout-and-stderr-of-child-program/
#define NUM_PIPES 2
#define PARENT_WRITE_PIPE 0
#define PARENT_READ_PIPE 1
#define READ_FD 0
#define WRITE_FD 1
#define PARENT_READ_FD (pipes[PARENT_READ_PIPE][READ_FD])
#define PARENT_WRITE_FD (pipes[PARENT_WRITE_PIPE][WRITE_FD])
#define CHILD_READ_FD (pipes[PARENT_WRITE_PIPE][READ_FD])
#define CHILD_WRITE_FD (pipes[PARENT_READ_PIPE][WRITE_FD])

namespace Stockfish16Init {
  using namespace Stockfish16;

  int main(int argc, char* argv[]) {
    std::cout << engine_info() << std::endl;

    CommandLine::init(argc, argv);
    UCI::init(Options);
    Tune::init();
    PSQT::init();
    Bitboards::init();
    Position::init();
    Bitbases::init();
    Endgames::init();
    Threads.set(size_t(Options["Threads"]));
    Search::clear(); // After threads are up
    Eval::NNUE::init();

    UCI::loop(argc, argv);

    Threads.set(0);
    return 0;
  }
}

const char *QUITOK = "quitok\n";
int pipes[NUM_PIPES][2];
char buffer[80];

int stockfish_init()
{
  pipe(pipes[PARENT_READ_PIPE]);
  pipe(pipes[PARENT_WRITE_PIPE]);

  return 0;
}

int stockfish_main()
{
  dup2(CHILD_READ_FD, STDIN_FILENO);
  dup2(CHILD_WRITE_FD, STDOUT_FILENO);

  // close unused pipe fds
  close(CHILD_READ_FD);
  close(CHILD_WRITE_FD);

  int argc = 1;
  char *argv[] = {""};
  int exitCode = Stockfish16Init::main(argc, argv);

  std::cout << QUITOK << std::flush;

  return exitCode;
}

ssize_t stockfish_stdin_write(char *data)
{
  return write(PARENT_WRITE_FD, data, strlen(data));
}

char *stockfish_stdout_read()
{
  ssize_t count = read(PARENT_READ_FD, buffer, sizeof(buffer) - 1);
  if (count < 0)
  {
    return NULL;
  }

  buffer[count] = 0;
  if (strcmp(buffer, QUITOK) == 0)
  {
    return NULL;
  }

  return buffer;
}
