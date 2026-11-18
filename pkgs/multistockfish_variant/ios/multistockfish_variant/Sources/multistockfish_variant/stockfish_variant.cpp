// The shim of the variant flavour (Fairy-Stockfish).
//
// Everything but the engine's own main is shared by every flavour and lives in
// sfshim.h; see there for what a flavour has to provide.

#include "Fairy-Stockfish-2b5d9512/src/bitboard.h"
#include "Fairy-Stockfish-2b5d9512/src/endgame.h"
#include "Fairy-Stockfish-2b5d9512/src/position.h"
#include "Fairy-Stockfish-2b5d9512/src/psqt.h"
#include "Fairy-Stockfish-2b5d9512/src/search.h"
#include "Fairy-Stockfish-2b5d9512/src/syzygy/tbprobe.h"
#include "Fairy-Stockfish-2b5d9512/src/thread.h"
#include "Fairy-Stockfish-2b5d9512/src/tt.h"
#include "Fairy-Stockfish-2b5d9512/src/uci.h"
#include "Fairy-Stockfish-2b5d9512/src/piece.h"
#include "Fairy-Stockfish-2b5d9512/src/variant.h"
#include "Fairy-Stockfish-2b5d9512/src/xboard.h"

#include "./include/multistockfish_variant/stockfish_variant.h"
#include "sfshim.h"

// Mirrors upstream's src/main.cpp, with each step reported so that a start that
// never completes can be pinned down from the outside.
static int engine_main(int argc, char *argv[])
{
  using namespace FairyStockfish;

  sfio::out() << engine_info() << std::endl;

  set_step("piece_map");
  pieceMap.init();
  set_step("variants");
  variants.init();
  set_step("command_line");
  CommandLine::init(argc, argv);
  set_step("uci_options");
  UCI::init(Options);
  set_step("tune");
  Tune::init();
  set_step("psqt");
  PSQT::init(variants.find(Options["UCI_Variant"])->second);
  set_step("bitboards");
  Bitboards::init();
  set_step("position");
  Position::init();
  set_step("bitbases");
  Bitbases::init();
  set_step("endgames");
  Endgames::init();
  set_step("thread_pool");
  Threads.set(size_t(Options["Threads"]));
  set_step("search_clear");
  Search::clear(); // After threads are up
  set_step("nnue");
  Eval::NNUE::init();

  set_phase(SF_PHASE_UCI_LOOP, "uci_loop");
  UCI::loop(argc, argv);

  // Everything past this point is the teardown that can hang: set(0) waits
  // for the search to finish and then joins every thread.
  set_phase(SF_PHASE_SHUTTING_DOWN, "thread_pool_teardown");
  Threads.set(0);
  set_step("variants_teardown");
  variants.clear_all();
  pieceMap.clear_all();
  delete XBoard::stateMachine;
  return 0;
}
