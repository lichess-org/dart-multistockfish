# The Flutter tooling requires that developers have CMake 3.10 or later
# installed. You should not increase this version, as doing so will cause
# the plugin to fail to compile for some customers of the plugin.
cmake_minimum_required(VERSION 3.10)

project(multistockfish_fairy_library VERSION 0.1.0 LANGUAGES CXX)

file(GLOB_RECURSE cppPaths "../ios/Fairy-Stockfish-2b5d9512/src/*.cpp")

list(FILTER cppPaths EXCLUDE REGEX "(pyffish|ffishjs).cpp")

add_library(
  multistockfish_fairy
  SHARED
  ../ios/Classes/multistockfish_fairy.cpp
  ${cppPaths}
)

set_target_properties(multistockfish_fairy PROPERTIES
  PUBLIC_HEADER multistockfish_fairy.h
  OUTPUT_NAME "multistockfish_fairy"
)

target_compile_definitions(multistockfish_fairy PUBLIC DART_SHARED_LIB)

if (ANDROID)
  # Support Android 15 16k page size
  target_link_options(multistockfish_fairy PRIVATE "-Wl,-z,max-page-size=16384")

  if(ANDROID_ABI STREQUAL arm64-v8a)
    if (CMAKE_BUILD_TYPE STREQUAL "Debug")
      target_compile_options(multistockfish_fairy PRIVATE -std=c++17 -DNNUE_EMBEDDING_OFF -DUSE_PTHREADS -DIS_64BIT -DUSE_POPCNT -DUSE_NEON)
    else()
      target_compile_options(multistockfish_fairy PRIVATE -std=c++17 -fno-exceptions -DNNUE_EMBEDDING_OFF -DUSE_PTHREADS -DNDEBUG -O3 -DIS_64BIT -DUSE_POPCNT -DUSE_NEON)
    endif()
  else()
    if (CMAKE_BUILD_TYPE STREQUAL "Debug")
      target_compile_options(multistockfish_fairy PRIVATE -std=c++17 -DNNUE_EMBEDDING_OFF -DUSE_PTHREADS)
    else()
      target_compile_options(multistockfish_fairy PRIVATE -std=c++17 -fno-exceptions -DNNUE_EMBEDDING_OFF -DUSE_PTHREADS -DNDEBUG -O3)
    endif()
  endif()
endif()
