# The Flutter tooling requires that developers have CMake 3.10 or later
# installed. You should not increase this version, as doing so will cause
# the plugin to fail to compile for some customers of the plugin.
cmake_minimum_required(VERSION 3.10)

project(multistockfish_chess_library VERSION 0.1.0 LANGUAGES CXX)

file(GLOB_RECURSE sf17Paths "../ios/Stockfish17/src/*.cpp")
file(GLOB_RECURSE sf11Paths "Stockfish11/src/*.cpp")

if(ANDROID_ABI STREQUAL arm64-v8a)
  add_library(
    multistockfish_chess
    SHARED
    ../ios/Classes/stockfish_nnue.cpp
    ${sf17Paths}
  )
else()
  add_library(
    multistockfish_chess
    SHARED
    stockfish_hce.cpp
    ${sf11Paths}
  )
endif()

set_target_properties(multistockfish_chess PROPERTIES
  PUBLIC_HEADER multistockfish_chess.h
  OUTPUT_NAME "multistockfish_chess"
)

target_compile_definitions(multistockfish_chess PUBLIC DART_SHARED_LIB)

# Support Android 15 16k page size
target_link_options(multistockfish_chess PRIVATE "-Wl,-z,max-page-size=16384")

if(ANDROID_ABI STREQUAL arm64-v8a)
  if (CMAKE_BUILD_TYPE STREQUAL "Debug")
    target_compile_options(multistockfish_chess PRIVATE -std=c++17 -DUSE_PTHREADS -DIS_64BIT -DUSE_POPCNT -DUSE_NEON=8)
  else()
    target_compile_options(multistockfish_chess PRIVATE -std=c++17 -fno-exceptions -DUSE_PTHREADS -DNDEBUG -funroll-loops -O3 -DIS_64BIT -DUSE_POPCNT -DUSE_NEON=8)
  endif()
  file(DOWNLOAD https://tests.stockfishchess.org/api/nn/nn-1111cefa1111.nnue ${CMAKE_BINARY_DIR}/nn-1111cefa1111.nnue)
  file(DOWNLOAD https://tests.stockfishchess.org/api/nn/nn-37f18f62d772.nnue ${CMAKE_BINARY_DIR}/nn-37f18f62d772.nnue)

else()

  if (CMAKE_BUILD_TYPE STREQUAL "Debug")
    target_compile_options(multistockfish_chess PRIVATE -std=c++11)
  else()
    target_compile_options(multistockfish_chess PRIVATE -std=c++11 -fno-exceptions -DNDEBUG -O3)
  endif()
endif()
