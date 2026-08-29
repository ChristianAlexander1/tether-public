cmake_minimum_required(VERSION 3.16)
project(TetherFakefs
        VERSION 1.0.0
        DESCRIPTION "Tether fakefs: pack an Alpine rootfs tar.gz into an efficient store"
        LANGUAGES C)

set(CMAKE_C_STANDARD 11)
set(CMAKE_C_STANDARD_REQUIRED ON)

if(NOT CMAKE_BUILD_TYPE)
  set(CMAKE_BUILD_TYPE RelWithDebInfo)
endif()

add_compile_options(-Wall -Wextra)

# --- libarchive (BSD-2-Clause) for tar.gz reading ----------------------
find_package(PkgConfig QUIET)
if(PkgConfig_FOUND)
  pkg_check_modules(LIBARCHIVE IMPORTED_TARGET libarchive)
endif()
if(LIBARCHIVE_FOUND)
  set(TETHER_ARCHIVE_LIB PkgConfig::LIBARCHIVE)
else()
  find_library(ARCHIVE_LIB archive REQUIRED)
  find_path(ARCHIVE_INC archive.h REQUIRED)
  add_library(tether_libarchive INTERFACE)
  target_include_directories(tether_libarchive INTERFACE ${ARCHIVE_INC})
  target_link_libraries(tether_libarchive INTERFACE ${ARCHIVE_LIB})
  set(TETHER_ARCHIVE_LIB tether_libarchive)
endif()

# --- library ------------------------------------------------------------
add_library(tether_fakefs
  src/tether_fakefs.c
  src/tether_fakefs_create.c
  src/tether_fakefs_overlay.c
  src/tether_path.c
  src/tether_crc32.c)
target_include_directories(tether_fakefs PUBLIC
  $<BUILD_INTERFACE:${CMAKE_CURRENT_SOURCE_DIR}/include>
  $<INSTALL_INTERFACE:include>)
target_link_libraries(tether_fakefs PRIVATE ${TETHER_ARCHIVE_LIB})

# --- CLI tools ------------------------------------------------------------
add_executable(fakefsify tools/fakefsify.c)
target_link_libraries(fakefsify PRIVATE tether_fakefs)

add_executable(fakefs_verify tools/fakefs_verify.c)
target_link_libraries(fakefs_verify PRIVATE tether_fakefs)

install(TARGETS tether_fakefs fakefsify fakefs_verify)
install(FILES include/tether_fakefs.h DESTINATION include)

# --- tests -----------------------------------------------------------------
enable_testing()

set(TEST_WORK_DIR ${CMAKE_CURRENT_BINARY_DIR}/test_work)
file(MAKE_DIRECTORY ${TEST_WORK_DIR})

function(tether_add_test name src)
  add_executable(${name} tests/${src})
  target_link_libraries(${name} PRIVATE tether_fakefs)
  target_compile_definitions(${name} PRIVATE
    TEST_DATA_DIR="${CMAKE_CURRENT_SOURCE_DIR}/tests/data"
    TEST_WORK_DIR="${TEST_WORK_DIR}")
  add_test(NAME ${name} COMMAND ${name})
endfunction()

tether_add_test(t1_create  test_create.c)   # T1: create from bundled tarball
tether_add_test(t2_read    test_read.c)     # T2: read known file bytes
tether_add_test(t3_symlink test_symlink.c)  # T3: symlink resolution
tether_add_test(t4_verify  test_verify.c)   # T4: verify 1000 paths + CRC
tether_add_test(t5_overlay test_overlay.c)  # T5: copy-up writes + whiteouts

# T1 (CLI flavor): the shipped binaries themselves must exit 0
add_test(NAME t1_cli_fakefsify
         COMMAND fakefsify ${CMAKE_CURRENT_SOURCE_DIR}/tests/data/mini_rootfs.tar.gz
                 ${TEST_WORK_DIR}/store_cli)
add_test(NAME t4_cli_verify
         COMMAND fakefs_verify ${TEST_WORK_DIR}/store_cli)
set_tests_properties(t4_cli_verify PROPERTIES DEPENDS t1_cli_fakefsify)
