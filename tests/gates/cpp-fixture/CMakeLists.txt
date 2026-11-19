cmake_minimum_required(VERSION 3.27)

project(gate-fixture LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 23)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)

set(FIXTURE_BAD "" CACHE STRING "Compile in one known-bad case: WARNING, NOWARN, OVERFLOW, UNDEFINED or TIDY")

add_library(gate-fixture MODULE src/fixture.cpp)
add_executable(gate-fixture-test tests/test.cpp src/fixture.cpp)

foreach(target gate-fixture gate-fixture-test)
    # not SYSTEM on purpose, because a plugin adds Hyprland's headers the same way
    target_include_directories(${target} PRIVATE src ../cpp-fixture-vendor)
    if(FIXTURE_BAD STREQUAL "NOWARN")
        target_compile_options(${target} PRIVATE -Wno-conversion)
    elseif(FIXTURE_BAD)
        target_compile_definitions(${target} PRIVATE FIXTURE_BAD_${FIXTURE_BAD})
    endif()
endforeach()

enable_testing()
add_test(NAME fixture COMMAND gate-fixture-test)
