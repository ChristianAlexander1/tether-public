#
# TetherWasm — wasm32-wasi command runner
# SPDX-License-Identifier: MIT
#
# Builds the static library `tetherwasm`, the `tether-wasm` CLI driver used by
# the tests, and the test suite itself.
#
#   cmake -B build && cmake --build build && ctest --test-dir build --output-on-failure
#

cmake_minimum_required(VERSION 3.16)
project(TetherWasm VERSION 1.0.0 LANGUAGES C)

set(CMAKE_C_STANDARD 11)
set(CMAKE_C_STANDARD_REQUIRED ON)

if(NOT CMAKE_BUILD_TYPE AND NOT CMAKE_CONFIGURATION_TYPES)
    set(CMAKE_BUILD_TYPE Release CACHE STRING "Build type" FORCE)
endif()

option(TETHER_WASM_BUILD_TESTS "Build the TetherWasm test suite" ON)

# --- vendored wasm3 interpreter core ---------------------------------------
# Only the interpreter is vendored. wasm3's own WASI layer (m3_api_wasi.c) is
# deliberately excluded: it keeps global state and writes to the host's real
# fds 0/1/2, which cannot express this runner's per-call streams and cwd.
# Sources/TetherWasm/tether_wasi.c replaces it.
add_library(tether_wasm3 STATIC
    Sources/CWasm3/m3_bind.c
    Sources/CWasm3/m3_code.c
    Sources/CWasm3/m3_compile.c
    Sources/CWasm3/m3_core.c
    Sources/CWasm3/m3_env.c
    Sources/CWasm3/m3_exec.c
    Sources/CWasm3/m3_function.c
    Sources/CWasm3/m3_info.c
    Sources/CWasm3/m3_module.c
    Sources/CWasm3/m3_parse.c
    Sources/CWasm3/m3_validate.c
)

target_include_directories(tether_wasm3 PUBLIC Sources/CWasm3/include)

# wasm3 implements the f32/f64 sqrt opcodes with the C library's sqrt/sqrtf,
# which live in libm on most Unix systems.
include(CheckLibraryExists)
check_library_exists(m sqrt "" TETHER_HAVE_LIBM)
if(TETHER_HAVE_LIBM)
    target_link_libraries(tether_wasm3 PUBLIC m)
endif()

# wasm3 compares u32 against i32 in a few places; not our code to fix.
if(NOT MSVC)
    target_compile_options(tether_wasm3 PRIVATE -Wno-sign-compare)
endif()

# --- the runner -------------------------------------------------------------
add_library(tetherwasm STATIC
    Sources/TetherWasm/tether_wasm.c
    Sources/TetherWasm/tether_wasi.c
)

target_include_directories(tetherwasm
    PUBLIC  Sources/TetherWasm/include
    PRIVATE Sources/TetherWasm
)

target_link_libraries(tetherwasm PRIVATE tether_wasm3)

if(NOT MSVC)
    target_compile_options(tetherwasm PRIVATE -Wall -Wextra -Wno-unused-parameter)
endif()

# --- CLI driver -------------------------------------------------------------
# Thin wrapper over the C API; the tests drive the runner through it.
add_executable(tether-wasm Tests/tether_wasm_cli.c)
target_link_libraries(tether-wasm PRIVATE tetherwasm)

# --- tests ------------------------------------------------------------------
if(TETHER_WASM_BUILD_TESTS)
    enable_testing()

    add_executable(tether_wasm_tests Tests/test_tether_wasm.c)

    # The suite exercises cancellation from a second thread.
    set(THREADS_PREFER_PTHREAD_FLAG ON)
    find_package(Threads REQUIRED)

    target_link_libraries(tether_wasm_tests PRIVATE tetherwasm Threads::Threads)
    target_include_directories(tether_wasm_tests PRIVATE Sources/TetherWasm/include)

    if(NOT MSVC)
        target_compile_options(tether_wasm_tests PRIVATE -Wall -Wextra -Wno-unused-parameter)
    endif()

    # The suite locates sample/*.wasm relative to the source tree.
    add_test(NAME tether_wasm_tests COMMAND tether_wasm_tests)
    set_tests_properties(tether_wasm_tests PROPERTIES
        ENVIRONMENT "TETHER_WASM_SAMPLE_DIR=${CMAKE_CURRENT_SOURCE_DIR}/sample"
    )
endif()

install(TARGETS tetherwasm tether-wasm
        ARCHIVE DESTINATION lib
        RUNTIME DESTINATION bin)
install(FILES Sources/TetherWasm/include/tether_wasm.h DESTINATION include)
