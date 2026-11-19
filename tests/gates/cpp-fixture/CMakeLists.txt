cmake_minimum_required(VERSION 3.27)

project(gate-fixture LANGUAGES CXX)

set(FIXTURE_BAD "" CACHE STRING "Compile in one known-bad case, named in the gate script's self-test")
if(NOT FIXTURE_BAD STREQUAL "NOSAFETY")
    include(../../../plugins/cmake/Safety.cmake)
endif()

set(CMAKE_CXX_STANDARD 23)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)

# The stand-in for a header this repository does not own has to be included from outside it.
cmake_path(SET vendor NORMALIZE "${CMAKE_BINARY_DIR}/../vendor")
file(COPY ../cpp-fixture-vendor/vendor.hpp DESTINATION "${vendor}")

set(bad_option_NOWARN -Wno-conversion)
set(bad_option_WEAKSTACK -fstack-protector)
set(bad_option_NOASSERT -U_GLIBCXX_ASSERTIONS)
set(bad_option_NOSANITIZE -fno-sanitize=all)

# a header the build writes, once composed so that no template holds the pragma and once from a template
if(FIXTURE_BAD STREQUAL "GENERATED")
    string(CONCAT pragma "#" "pragma GCC diagnostic ignored \"-Wconversion\"")
    file(WRITE "${CMAKE_BINARY_DIR}/generated/generated.hpp" "#pragma once\n${pragma}\n")
elseif(FIXTURE_BAD STREQUAL "TEMPLATE")
    file(CONFIGURE OUTPUT "${CMAKE_BINARY_DIR}/generated/template.hpp" CONTENT "#pragma once

inline const char* templateBytes(const int& value) {
    return reinterpret_cast<const char*>(&value);
}
")
endif()

add_library(gate-fixture MODULE src/fixture.cpp)
add_executable(gate-fixture-test tests/test.cpp src/fixture.cpp)

foreach(target gate-fixture gate-fixture-test)
    # not SYSTEM on purpose, because a plugin adds Hyprland's headers the same way
    target_include_directories(${target} PRIVATE src "${vendor}")
    if(DEFINED bad_option_${FIXTURE_BAD})
        target_compile_options(${target} PRIVATE ${bad_option_${FIXTURE_BAD}})
    elseif(FIXTURE_BAD)
        target_compile_definitions(${target} PRIVATE FIXTURE_BAD_${FIXTURE_BAD})
        target_include_directories(${target} PRIVATE ../cpp-fixture-sibling "${CMAKE_BINARY_DIR}/generated")
    endif()
endforeach()

enable_testing()
add_test(NAME fixture COMMAND gate-fixture-test)
