#include <iostream>
#include <stdio.h>
#include <unistd.h>

#include "Stockfish11/src/bitboard.h"
#include "Stockfish11/src/position.h"
#include "Stockfish11/src/search.h"
#include "Stockfish11/src/thread.h"
#include "Stockfish11/src/tt.h"
#include "Stockfish11/src/uci.h"
#include "Stockfish11/src/endgame.h"
#include "Stockfish11/src/syzygy/tbprobe.h"

#include "stockfish_hce.h"

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

namespace PSQT {
  void init();
}

namespace StockfishHCE
{
  int main(int argc, char* argv[]) {

    std::cout << engine_info() << std::endl;

    UCI::init(Options);
    PSQT::init();
    Bitboards::init();
    Position::init();
    Bitbases::init();
    Endgames::init();
    Threads.set(Options["Threads"]);
    Search::clear(); // After threads are up

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

  int argc = 1;
  char *argv[] = {""};
  int exitCode = StockfishHCE::main(argc, argv);

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
