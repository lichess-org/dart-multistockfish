// The FFI entry points of the variant flavour (Fairy-Stockfish):
// stockfish_variant_init(), stockfish_variant_main() and so on, declared in sfapi.h,
// which every flavour shares.

#define SF_SYMBOL(name) stockfish_variant_##name
#include "sfapi.h"
