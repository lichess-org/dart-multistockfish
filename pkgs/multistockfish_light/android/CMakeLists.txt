# The Flutter tooling requires that developers have CMake 3.10 or later
# installed. You should not increase this version, as doing so will cause
# the plugin to fail to compile for some customers of the plugin.
cmake_minimum_required(VERSION 3.10)

project(multistockfish_light_library VERSION 0.1.0 LANGUAGES CXX)

file(GLOB_RECURSE sfPaths "../ios/multistockfish_light/Sources/multistockfish_light/StockfishLight/src/*.cpp")

# src/universal/ holds the entry points and the NNUE embedding used by upstream's
# macOS universal-binary build. They are not part of a normal build: the entry_*
# files call into per-arch `StockfishLight_<arch>::main` namespaces that only
# exist in that build, and nnue_embed.cpp defines a second `gEmbeddedNNUEData`.
# Compiling either here fails to link.
list(FILTER sfPaths EXCLUDE REGEX "/StockfishLight/src/universal/")

add_library(
  multistockfish_light
  SHARED
  ../ios/multistockfish_light/Sources/multistockfish_light/stockfish_light.cpp
  ../ios/multistockfish_light/Sources/multistockfish_light/sfio.cpp
  ${sfPaths}
)

set_target_properties(multistockfish_light PROPERTIES
  PUBLIC_HEADER multistockfish_light.h
  OUTPUT_NAME "multistockfish_light"
)

target_compile_definitions(multistockfish_light PUBLIC DART_SHARED_LIB)

# Support Android 15 16k page size
target_link_options(multistockfish_light PRIVATE "-Wl,-z,max-page-size=16384")

# Unlike multistockfish_chess, this package does NOT define NNUE_EMBEDDING_OFF:
# its ~1.1MB net is compiled into the library by `INCBIN(EmbeddedNNUE, ...)` in
# nnue/network.cpp. The `.incbin` directive resolves the file against the
# assembler's working directory, which for this build is CMAKE_BINARY_DIR --
# which is why the download below targets exactly that directory.
if(ANDROID_ABI STREQUAL arm64-v8a)
  if (CMAKE_BUILD_TYPE STREQUAL "Debug")
    target_compile_options(multistockfish_light PRIVATE -std=c++17 -DUSE_PTHREADS -DIS_64BIT -DUSE_POPCNT -DUSE_NEON=8)
  else()
    target_compile_options(multistockfish_light PRIVATE -std=c++17 -fno-exceptions -DUSE_PTHREADS -DNDEBUG -funroll-loops -O3 -DIS_64BIT -DUSE_POPCNT -DUSE_NEON=8)
  endif()

else()

  if (CMAKE_BUILD_TYPE STREQUAL "Debug")
    target_compile_options(multistockfish_light PRIVATE -std=c++17 -DUSE_PTHREADS)
  else()
    target_compile_options(multistockfish_light PRIVATE -std=c++17 -DUSE_PTHREADS -fno-exceptions -DNDEBUG -funroll-loops -O3)
  endif()
endif()

file(DOWNLOAD https://tests.stockfishchess.org/api/nn/nn-61e7af4bb97d.nnue ${CMAKE_BINARY_DIR}/nn-61e7af4bb97d.nnue
     EXPECTED_HASH SHA256=61e7af4bb97d51eeeb25d322916f86513b5cd3a827ce189c98c6e31946f99e5b)
