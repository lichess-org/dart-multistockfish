# The Flutter tooling requires that developers have CMake 3.10 or later
# installed. You should not increase this version, as doing so will cause
# the plugin to fail to compile for some customers of the plugin.
cmake_minimum_required(VERSION 3.10)

project(stockfish_nnue_library VERSION 0.1.0 LANGUAGES CXX)

file(GLOB_RECURSE cppPaths "../ios/Stockfish17/src/*.cpp")
add_library(
  stockfish_nnue
  SHARED
  ../ios/Classes/stockfish_nnue.cpp
  ${cppPaths}
)

set_target_properties(stockfish_nnue PROPERTIES
  PUBLIC_HEADER stockfish_nnue.h
  OUTPUT_NAME "stockfish_nnue"
)

target_compile_definitions(stockfish_nnue PUBLIC DART_SHARED_LIB)

if (ANDROID)
  # Support Android 15 16k page size
  target_link_options(stockfish_nnue PRIVATE "-Wl,-z,max-page-size=16384")

  if(ANDROID_ABI STREQUAL arm64-v8a)
    if (CMAKE_BUILD_TYPE STREQUAL "Debug")
      target_compile_options(stockfish_nnue PRIVATE -std=c++17 -DUSE_PTHREADS -DIS_64BIT -DUSE_POPCNT -DUSE_NEON=8)
    else()
      target_compile_options(stockfish_nnue PRIVATE -std=c++17 -fno-exceptions -DUSE_PTHREADS -DNDEBUG -O3 -DIS_64BIT -DUSE_POPCNT -DUSE_NEON=8)
    endif()
  else()
    if (CMAKE_BUILD_TYPE STREQUAL "Debug")
      target_compile_options(stockfish_nnue PRIVATE -std=c++17 -DUSE_PTHREADS)
    else()
      target_compile_options(stockfish_nnue PRIVATE -std=c++17 -fno-exceptions -DUSE_PTHREADS -DNDEBUG -O3)
    endif()
  endif()
endif()

file(DOWNLOAD https://tests.stockfishchess.org/api/nn/nn-1111cefa1111.nnue ${CMAKE_BINARY_DIR}/nn-1111cefa1111.nnue)
file(DOWNLOAD https://tests.stockfishchess.org/api/nn/nn-37f18f62d772.nnue ${CMAKE_BINARY_DIR}/nn-37f18f62d772.nnue)
