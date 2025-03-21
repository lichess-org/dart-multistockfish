# The Flutter tooling requires that developers have CMake 3.10 or later
# installed. You should not increase this version, as doing so will cause
# the plugin to fail to compile for some customers of the plugin.
cmake_minimum_required(VERSION 3.10)

project(fairy_stockfish_library VERSION 0.1.0 LANGUAGES CXX)

file(GLOB_RECURSE cppPaths "../ios/Fairy-Stockfish-2b5d9512/src/*.cpp")

list(FILTER cppPaths EXCLUDE REGEX "(pyffish|ffishjs).cpp")

add_library(
  fairy_stockfish
  SHARED
  ../ios/Classes/fairy_stockfish.cpp
  ${cppPaths}
)

set_target_properties(fairy_stockfish PROPERTIES
  PUBLIC_HEADER fairy_stockfish.h
  OUTPUT_NAME "fairy_stockfish"
)

target_compile_definitions(fairy_stockfish PUBLIC DART_SHARED_LIB)

if (ANDROID)
  # Support Android 15 16k page size
  target_link_options(fairy_stockfish PRIVATE "-Wl,-z,max-page-size=16384")

  if(ANDROID_ABI STREQUAL arm64-v8a)
    if (CMAKE_BUILD_TYPE STREQUAL "Debug")
      target_compile_options(fairy_stockfish PRIVATE -std=c++17 -DNNUE_EMBEDDING_OFF -DUSE_PTHREADS -DIS_64BIT -DUSE_POPCNT -DUSE_NEON)
    else()
      target_compile_options(fairy_stockfish PRIVATE -std=c++17 -fno-exceptions -DNNUE_EMBEDDING_OFF -DUSE_PTHREADS -DNDEBUG -O3 -DIS_64BIT -DUSE_POPCNT -DUSE_NEON)
    endif()
  else()
    if (CMAKE_BUILD_TYPE STREQUAL "Debug")
      target_compile_options(fairy_stockfish PRIVATE -std=c++17 -DNNUE_EMBEDDING_OFF -DUSE_PTHREADS)
    else()
      target_compile_options(fairy_stockfish PRIVATE -std=c++17 -fno-exceptions -DNNUE_EMBEDDING_OFF -DUSE_PTHREADS -DNDEBUG -O3)
    endif()
  endif()
endif()
