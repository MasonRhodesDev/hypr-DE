cmake_minimum_required(VERSION 3.27)

project(gate-fixture LANGUAGES CXX)

set(FIXTURE_BAD "" CACHE STRING "Compile in one known-bad case, named in the gate script's self-test")
if(NOT FIXTURE_BAD STREQUAL "NOSAFETY")
    include(../../../plugins/cmake/Safety.cmake)
endif()

set(CMAKE_CXX_STANDARD 23)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)

set(bad_option_NOWARN -Wno-conversion)
set(bad_option_NOWARNINGS -w)
set(bad_option_WEAKSTACK -fno-stack-protector)
set(bad_option_NOASSERT -U_GLIBCXX_ASSERTIONS)
set(bad_option_NOSANITIZE -fno-sanitize=all)
set(bad_option_RESPONSEFILE @${CMAKE_CURRENT_SOURCE_DIR}/weak.rsp)
set(bad_option_WP -Wp,-U_FORTIFY_SOURCE)
set(bad_option_MANUALENDBR -mmanual-endbr)
set(bad_link_RPATH -Wl,-rpath,/tmp/gate-fixture)

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
elseif(FIXTURE_BAD STREQUAL "PRAGMAOPEN")
    # a header outside the source tree that leaves an optimize pragma open
    file(WRITE "$ENV{HOME}/gate-vendor/vendor.hpp" "#pragma GCC optimize (\"O0\")\n")
elseif(FIXTURE_BAD STREQUAL "GENSOURCE")
    file(CONFIGURE OUTPUT "${CMAKE_BINARY_DIR}/generated/gensource.cpp" CONTENT "const char* generatedBytes(const int& value) {
    return reinterpret_cast<const char*>(&value);
}
")
endif()

add_library(gate-fixture MODULE src/fixture.cpp)
add_executable(gate-fixture-test tests/test.cpp src/fixture.cpp)

foreach(target gate-fixture gate-fixture-test)
    target_include_directories(${target} PRIVATE src)
    if(DEFINED bad_option_${FIXTURE_BAD})
        target_compile_options(${target} PRIVATE ${bad_option_${FIXTURE_BAD}})
    elseif(DEFINED bad_link_${FIXTURE_BAD})
        target_link_options(${target} PRIVATE ${bad_link_${FIXTURE_BAD}})
    elseif(FIXTURE_BAD)
        target_compile_definitions(${target} PRIVATE FIXTURE_BAD_${FIXTURE_BAD})
        target_include_directories(${target} PRIVATE ../cpp-fixture-sibling "${CMAKE_BINARY_DIR}/generated" "$ENV{HOME}/gate-vendor")
    endif()
endforeach()

if(FIXTURE_BAD STREQUAL "GENSOURCE")
    target_sources(gate-fixture PRIVATE "${CMAKE_BINARY_DIR}/generated/gensource.cpp")
    set_source_files_properties("${CMAKE_BINARY_DIR}/generated/gensource.cpp" PROPERTIES COMPILE_OPTIONS -fno-stack-protector)
elseif(FIXTURE_BAD STREQUAL "UNITY")
    set_target_properties(gate-fixture PROPERTIES UNITY_BUILD ON)
    target_compile_options(gate-fixture PRIVATE -fno-stack-protector)
elseif(FIXTURE_BAD STREQUAL "SYSTEM")
    target_include_directories(gate-fixture SYSTEM PRIVATE ../cpp-fixture-sibling)
elseif(FIXTURE_BAD STREQUAL "LAUNCHER")
    set_property(TARGET gate-fixture PROPERTY RULE_LAUNCH_COMPILE "python3 ${CMAKE_CURRENT_SOURCE_DIR}/strip-hardening.py")
elseif(FIXTURE_BAD STREQUAL "NORELRO")
    target_link_options(gate-fixture PRIVATE -Wl,-z,norelro -Wl,-z,lazy -Wl,-z,execstack)
    set_target_properties(gate-fixture PROPERTIES LIBRARY_OUTPUT_DIRECTORY ${CMAKE_BINARY_DIR}/CMakeFiles/out)
elseif(FIXTURE_BAD STREQUAL "ENVCI")
    if(NOT DEFINED ENV{CI})
        target_compile_options(gate-fixture PRIVATE -fno-stack-protector)
    endif()
elseif(FIXTURE_BAD STREQUAL "CUSTOM" OR FIXTURE_BAD STREQUAL "BYPASS")
    # CUSTOM goes through the compiler on PATH; BYPASS names the compiler by its full path, past the gate's stand-in
    set(compiler c++)
    if(FIXTURE_BAD STREQUAL "BYPASS")
        set(compiler /usr/bin/c++)
    endif()
    string(TOLOWER ${FIXTURE_BAD} name)
    add_custom_command(OUTPUT ${CMAKE_BINARY_DIR}/${name}.so
        COMMAND ${compiler} -x c++ -shared -fPIC -O0 -fno-stack-protector -fcf-protection
            -Wl,-z,relro,-z,now,-z,noexecstack -o ${CMAKE_BINARY_DIR}/${name}.so ${CMAKE_CURRENT_SOURCE_DIR}/src/custom.cpp.txt
        DEPENDS src/custom.cpp.txt)
    add_custom_target(${name} ALL DEPENDS ${CMAKE_BINARY_DIR}/${name}.so)
    install(FILES ${CMAKE_BINARY_DIR}/${name}.so DESTINATION lib/gate-fixture)
elseif(FIXTURE_BAD STREQUAL "BUILDID")
    # after the link, a blob built past the shim takes the library's place under the same build ID
    add_custom_command(TARGET gate-fixture POST_BUILD
        COMMAND sh ${CMAKE_CURRENT_SOURCE_DIR}/swap-blob.sh $<TARGET_FILE:gate-fixture> ${CMAKE_CURRENT_SOURCE_DIR}/src/custom.cpp.txt)
elseif(FIXTURE_BAD STREQUAL "ASM")
    add_custom_command(OUTPUT ${CMAKE_BINARY_DIR}/asm.so
        COMMAND c++ -x assembler-with-cpp -shared -fPIC -Wl,-z,relro,-z,now,-z,noexecstack -o ${CMAKE_BINARY_DIR}/asm.so ${CMAKE_CURRENT_SOURCE_DIR}/src/blob.S.txt
        DEPENDS src/blob.S.txt)
    add_custom_target(asm ALL DEPENDS ${CMAKE_BINARY_DIR}/asm.so)
    install(FILES ${CMAKE_BINARY_DIR}/asm.so DESTINATION lib/gate-fixture)
elseif(FIXTURE_BAD STREQUAL "LTO")
    set_target_properties(gate-fixture PROPERTIES INTERPROCEDURAL_OPTIMIZATION ON)
elseif(FIXTURE_BAD STREQUAL "STATIC")
    # a source no file in the tree holds, so only its archive member ties it to the library
    file(WRITE "${CMAKE_BINARY_DIR}/generated/member.cpp" "int memberValue(int value) { return value + 1; }\n")
    add_library(member STATIC "${CMAKE_BINARY_DIR}/generated/member.cpp")
    target_compile_options(member PRIVATE -fno-stack-protector)
    target_link_libraries(gate-fixture PRIVATE member)
elseif(FIXTURE_BAD STREQUAL "NEEDED")
    # a library the package does not ship, named by a path its users would load it from
    file(WRITE "${CMAKE_BINARY_DIR}/generated/helper.cpp" "int helperValue() { return 1; }\n")
    add_library(fixture-helper SHARED "${CMAKE_BINARY_DIR}/generated/helper.cpp")
    target_link_options(fixture-helper PRIVATE -Wl,-soname,/tmp/gate-fixture-helper.so)
    target_link_libraries(gate-fixture PRIVATE fixture-helper)
endif()

install(TARGETS gate-fixture LIBRARY DESTINATION lib/gate-fixture)
if(FIXTURE_BAD STREQUAL "SETID")
    install(CODE "execute_process(COMMAND chmod 4755 \"\$ENV{DESTDIR}${CMAKE_INSTALL_PREFIX}/lib/gate-fixture/$<TARGET_FILE_NAME:gate-fixture>\")")
endif()

enable_testing()
add_test(NAME fixture COMMAND gate-fixture-test)
