# The Flutter tooling requires that developers have CMake 3.10 or later
# installed. You should not increase this version, as doing so will cause
# the plugin to fail to compile for some customers of the plugin.
cmake_minimum_required(VERSION 3.10)

project(multistockfish_chess_library VERSION 0.2.0 LANGUAGES CXX)

file(GLOB_RECURSE sf17Paths "../ios/Stockfish/src/*.cpp")

add_library(
  multistockfish_chess
  SHARED
  ../ios/Classes/stockfish_nnue.cpp
  ${sf17Paths}
)

set_target_properties(multistockfish_chess PROPERTIES
  PUBLIC_HEADER multistockfish_chess.h
  OUTPUT_NAME "multistockfish_chess"
)

target_compile_definitions(multistockfish_chess PUBLIC DART_SHARED_LIB)

# Support Android 15 16k page size
target_link_options(multistockfish_chess PRIVATE "-Wl,-z,max-page-size=16384")

if(ANDROID_ABI STREQUAL arm64-v8a)
  if (CMAKE_BUILD_TYPE STREQUAL "Debug")
    target_compile_options(multistockfish_chess PRIVATE -std=c++17 -DNNUE_EMBEDDING_OFF -DUSE_PTHREADS -DIS_64BIT -DUSE_POPCNT -DUSE_NEON=8)
  else()
    target_compile_options(multistockfish_chess PRIVATE -std=c++17 -DNNUE_EMBEDDING_OFF -fno-exceptions -DUSE_PTHREADS -DNDEBUG -funroll-loops -O3 -DIS_64BIT -DUSE_POPCNT -DUSE_NEON=8)
  endif()

else()

  if (CMAKE_BUILD_TYPE STREQUAL "Debug")
    target_compile_options(multistockfish_chess PRIVATE -std=c++17 -DNNUE_EMBEDDING_OFF -DUSE_PTHREADS)
  else()
    target_compile_options(multistockfish_chess PRIVATE -std=c++17 -DNNUE_EMBEDDING_OFF -DUSE_PTHREADS -fno-exceptions -DNDEBUG -O3)
  endif()
endif()
