# The Flutter tooling requires that developers have CMake 3.10 or later
# installed. You should not increase this version, as doing so will cause
# the plugin to fail to compile for some customers of the plugin.
cmake_minimum_required(VERSION 3.10)

project(multistockfish_hce_library VERSION 0.1.0 LANGUAGES CXX)

file(GLOB_RECURSE cppPaths "../ios/Stockfish11/src/*.cpp")
add_library(
  multistockfish_hce
  SHARED
  ../ios/Classes/multistockfish_hce.cpp
  ${cppPaths}
)

set_target_properties(multistockfish_hce PROPERTIES
  PUBLIC_HEADER multistockfish_hce.h
  OUTPUT_NAME "multistockfish_hce"
)

target_compile_definitions(multistockfish_hce PUBLIC DART_SHARED_LIB)

if (ANDROID)
  # Support Android 15 16k page size
  target_link_options(multistockfish_hce PRIVATE "-Wl,-z,max-page-size=16384")

  if(ANDROID_ABI STREQUAL arm64-v8a)
    if (CMAKE_BUILD_TYPE STREQUAL "Debug")
      target_compile_options(multistockfish_hce PRIVATE -std=c++11 -DIS_64BIT -DUSE_POPCNT)
    else()
      target_compile_options(multistockfish_hce PRIVATE -std=c++11 -fno-exceptions -DNDEBUG -O3 -DIS_64BIT -DUSE_POPCNT)
    endif()
  else()
    if (CMAKE_BUILD_TYPE STREQUAL "Debug")
      target_compile_options(multistockfish_hce PRIVATE -std=c++11)
    else()
      target_compile_options(multistockfish_hce PRIVATE -std=c++11 -fno-exceptions -DNDEBUG -O3)
    endif()
  endif()
endif()
