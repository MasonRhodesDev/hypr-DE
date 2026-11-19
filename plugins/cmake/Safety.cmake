include_guard(GLOBAL)

option(HYPR_DE_SANITIZE "Build with AddressSanitizer and UndefinedBehaviorSanitizer" OFF)

include(CheckCXXCompilerFlag)
include(CheckPIESupported)

set(CMAKE_EXPORT_COMPILE_COMMANDS ON)
set(CMAKE_POSITION_INDEPENDENT_CODE ON)
check_pie_supported(LANGUAGES CXX)

add_compile_options(-Wall -Wextra -Wconversion -Wshadow -fstack-protector-strong -fstack-clash-protection)
add_compile_definitions(_GLIBCXX_ASSERTIONS)
add_link_options(LINKER:-z,relro LINKER:-z,now)

# only x86 has control-flow protection
check_cxx_compiler_flag(-fcf-protection HYPR_DE_HAS_CF_PROTECTION)
if(HYPR_DE_HAS_CF_PROTECTION)
    add_compile_options(-fcf-protection)
endif()

if(HYPR_DE_SANITIZE)
    # without -fno-sanitize-recover, undefined behaviour is printed and the test still passes
    add_compile_options(-fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer)
    add_link_options(-fsanitize=address,undefined)
else()
    # fortify needs optimisation, and it hides overflows from AddressSanitizer
    add_compile_options($<$<NOT:$<CONFIG:Debug>>:-U_FORTIFY_SOURCE> $<$<NOT:$<CONFIG:Debug>>:-D_FORTIFY_SOURCE=3>)
endif()

# A plugin cannot fix a warning inside a header this repository does not own, so
# every include directory outside the repository is treated as a system one.
cmake_path(SET _hypr_de_repository NORMALIZE "${CMAKE_CURRENT_LIST_DIR}/../..")
function(_hypr_de_third_party_includes_are_system directory)
    get_property(targets DIRECTORY "${directory}" PROPERTY BUILDSYSTEM_TARGETS)
    foreach(target IN LISTS targets)
        get_target_property(includes ${target} INCLUDE_DIRECTORIES)
        if(NOT includes)
            continue()
        endif()
        foreach(include IN LISTS includes)
            if(include MATCHES "\\$<")
                continue()
            endif()
            cmake_path(IS_PREFIX _hypr_de_repository "${include}" NORMALIZE in_repository)
            cmake_path(IS_PREFIX CMAKE_BINARY_DIR "${include}" NORMALIZE in_build)
            if(NOT in_repository AND NOT in_build)
                target_include_directories(${target} SYSTEM PRIVATE "${include}")
            endif()
        endforeach()
    endforeach()
    get_property(children DIRECTORY "${directory}" PROPERTY SUBDIRECTORIES)
    foreach(child IN LISTS children)
        _hypr_de_third_party_includes_are_system("${child}")
    endforeach()
endfunction()
cmake_language(DEFER DIRECTORY "${CMAKE_SOURCE_DIR}" CALL _hypr_de_third_party_includes_are_system "${CMAKE_SOURCE_DIR}")
