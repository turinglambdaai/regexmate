cmake_minimum_required(VERSION 3.24)
project(rivet-linux-host LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)

# RIVET_ROOT points at the installed Rivet package. `raco rivet build` sets
# it; manual builds may export it themselves.
if(NOT DEFINED ENV{RIVET_ROOT})
  message(FATAL_ERROR "RIVET_ROOT is not set. Export RIVET_ROOT to a Rivet checkout.")
endif()
set(RIVET_ROOT "$ENV{RIVET_ROOT}")

# RIVET_RACKET_LIBRARY is the exact embeddable Racket CS library. The lib-dir
# fallback supports installations that expose an unversioned linker name.
if(NOT DEFINED ENV{RIVET_RACKET_INCLUDE})
  message(FATAL_ERROR "RIVET_RACKET_INCLUDE is not set. Point it at the Racket include directory.")
endif()

find_package(PkgConfig REQUIRED)
find_package(Curses REQUIRED)
find_package(Threads REQUIRED)
find_package(ZLIB REQUIRED)
find_library(LZ4_LIBRARY NAMES lz4 REQUIRED)
pkg_check_modules(GTK4 REQUIRED IMPORTED_TARGET gtk4)
if(DEFINED ENV{RIVET_RACKET_LIBRARY})
  set(RACKETCS_LIBRARY "$ENV{RIVET_RACKET_LIBRARY}")
elseif(DEFINED ENV{RIVET_RACKET_LIB_DIR})
  find_library(RACKETCS_LIBRARY
    NAMES racketcs
    PATHS "$ENV{RIVET_RACKET_LIB_DIR}"
    NO_DEFAULT_PATH
    REQUIRED
  )
else()
  message(FATAL_ERROR "Set RIVET_RACKET_LIBRARY to libracketcs, or RIVET_RACKET_LIB_DIR to its directory.")
endif()

add_executable(RivetHost
  src/main.cpp
  "${RIVET_ROOT}/platform/linux/runtime/backend.cpp"
  "${RIVET_ROOT}/runtime/src/protocol.cpp"
)

target_include_directories(RivetHost PRIVATE
  "${CMAKE_CURRENT_SOURCE_DIR}"
  "${RIVET_ROOT}/platform/linux/runtime"
  "${RIVET_ROOT}/runtime/include"
  "$ENV{RIVET_RACKET_INCLUDE}"
)

target_link_libraries(RivetHost PRIVATE
  PkgConfig::GTK4
  ${RACKETCS_LIBRARY}
  ZLIB::ZLIB
  ${LZ4_LIBRARY}
  ${CURSES_LIBRARIES}
  Threads::Threads
  ${CMAKE_DL_LIBS}
)

target_compile_options(RivetHost PRIVATE -Wall -Wextra -Wpedantic)
