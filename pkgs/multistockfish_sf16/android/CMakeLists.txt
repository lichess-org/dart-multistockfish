# The Flutter tooling requires that developers have CMake 3.10 or later
# installed. You should not increase this version, as doing so will cause
# the plugin to fail to compile for some customers of the plugin.
cmake_minimum_required(VERSION 3.10)

project(multistockfish_sf16_library VERSION 0.1.0 LANGUAGES CXX)

file(GLOB_RECURSE sf16Paths "../ios/Stockfish16/src/*.cpp")

add_library(
  multistockfish_sf16
  SHARED
  ../ios/Classes/stockfish16.cpp
  ${sf16Paths}
)

set_target_properties(multistockfish_sf16 PROPERTIES
  PUBLIC_HEADER multistockfish_sf16.h
  OUTPUT_NAME "multistockfish_sf16"
)

target_compile_definitions(multistockfish_sf16 PUBLIC DART_SHARED_LIB)

# Support Android 15 16k page size
target_link_options(multistockfish_sf16 PRIVATE "-Wl,-z,max-page-size=16384")

if(ANDROID_ABI STREQUAL arm64-v8a)
  if (CMAKE_BUILD_TYPE STREQUAL "Debug")
    target_compile_options(multistockfish_sf16 PRIVATE -std=c++17 -DUSE_PTHREADS -DIS_64BIT -DUSE_POPCNT -DUSE_NEON=8)
  else()
    target_compile_options(multistockfish_sf16 PRIVATE -std=c++17 -fno-exceptions -DUSE_PTHREADS -DNDEBUG -O3 -DIS_64BIT -DUSE_POPCNT -DUSE_NEON=8)
  endif()

else()

  if (CMAKE_BUILD_TYPE STREQUAL "Debug")
    target_compile_options(multistockfish_sf16 PRIVATE -std=c++17 -DUSE_PTHREADS)
  else()
    target_compile_options(multistockfish_sf16 PRIVATE -std=c++17 -DUSE_PTHREADS -fno-exceptions -DNDEBUG -O3)
  endif()
endif()

file(DOWNLOAD https://tests.stockfishchess.org/api/nn/nn-5af11540bbfe.nnue ${CMAKE_BINARY_DIR}/nn-5af11540bbfe.nnue)
