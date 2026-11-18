// The shim of the chess flavour (Stockfish 19, NNUE loaded from a file).
//
// Everything but the engine's own main is shared by every flavour and lives in
// sfshim.h; see there for what a flavour has to provide.

#include <utility>

#include "Stockfish/src/attacks.h"
#include "Stockfish/src/bitboard.h"
#include "Stockfish/src/misc.h"
#include "Stockfish/src/position.h"
#include "Stockfish/src/types.h"
#include "Stockfish/src/uci.h"
#include "Stockfish/src/tune.h"

#include "./include/multistockfish_chess/stockfish_nnue.h"
#include "sfshim.h"

// Mirrors upstream's src/main.cpp, with each step reported so that a start that
// never completes can be pinned down from the outside.
static int engine_main(int argc, char *argv[])
{
  using namespace Stockfish;

  sfio::out() << engine_info() << std::endl;

  set_step("bitboards");
  // Stockfish 19 moved the attack-table initialisation out of Bitboards into
  // its own Attacks namespace; it is still the same one-time table build.
  Attacks::init();
  set_step("position");
  Position::init();

  {
    set_step("uci_engine");
    // Stockfish 19's UCIEngine takes a CommandLine rather than argc/argv.
    // Built as a named variable because `UCIEngine uci(CommandLine(argc,
    // argv))` would parse as a function declaration.
    auto cli = CommandLine(argc, argv);
    UCIEngine uci(std::move(cli));

    set_step("tune");
    Tune::init(uci.engine_options());

    set_phase(SF_PHASE_UCI_LOOP, "uci_loop");
    uci.loop();

    // Leaving this scope destroys the engine, which waits for any search
    // still in flight before joining its threads. That is where a wedged
    // engine hangs, so the phase is set before the destructor runs.
    set_phase(SF_PHASE_SHUTTING_DOWN, "engine_teardown");
  }

  return 0;
}
