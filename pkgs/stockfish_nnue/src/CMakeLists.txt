# The Flutter tooling requires that developers have CMake 3.10 or later
# installed. You should not increase this version, as doing so will cause
# the plugin to fail to compile for some customers of the plugin.
cmake_minimum_required(VERSION 3.10)

project(stockfish_nnue_library VERSION 0.0.1 LANGUAGES C)

add_library(stockfish_nnue SHARED
  "stockfish_nnue.c"
)

set_target_properties(stockfish_nnue PROPERTIES
  PUBLIC_HEADER stockfish_nnue.h
  OUTPUT_NAME "stockfish_nnue"
)

target_compile_definitions(stockfish_nnue PUBLIC DART_SHARED_LIB)

if (ANDROID)
  # Support Android 15 16k page size
  target_link_options(stockfish_nnue PRIVATE "-Wl,-z,max-page-size=16384")
endif()
