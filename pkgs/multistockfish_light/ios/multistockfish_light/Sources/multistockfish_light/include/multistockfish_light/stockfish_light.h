// The FFI entry points of the light flavour (Stockfish 19 with a small embedded NNUE):
// stockfish_light_init(), stockfish_light_main() and so on, declared in sfapi.h,
// which every flavour shares.

#define SF_SYMBOL(name) stockfish_light_##name
#include "sfapi.h"
