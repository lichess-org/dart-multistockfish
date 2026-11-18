// The FFI entry points of the chess flavour (Stockfish 19, NNUE loaded from a file):
// stockfish_init(), stockfish_main() and so on, declared in sfapi.h,
// which every flavour shares.

#define SF_SYMBOL(name) stockfish_##name
#include "sfapi.h"
