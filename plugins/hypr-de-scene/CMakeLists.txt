cmake_minimum_required(VERSION 3.27)

project(hypr-de-scene VERSION 0.1.0 LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 26)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)

find_package(PkgConfig REQUIRED)
pkg_check_modules(headers REQUIRED hyprland pixman-1)
pkg_check_modules(libs REQUIRED IMPORTED_TARGET cairo libdrm glesv2)

add_library(hypr-de-scene-impl SHARED
    src/main.cpp
    src/Scene.cpp
    src/FirstFrame.cpp
    src/Sprite.cpp
    src/Log.cpp
    src/Geometry.cpp
    src/Spec.cpp)

set_target_properties(hypr-de-scene-impl PROPERTIES PREFIX "")
target_include_directories(hypr-de-scene-impl PRIVATE ${headers_INCLUDE_DIRS})
# the placement must round exactly as the Python reference does
target_compile_options(hypr-de-scene-impl PRIVATE ${headers_CFLAGS_OTHER} -Wall -Wextra -Wno-unused-parameter -ffp-contract=off)
# Hyprland has its own libraries loaded already. Naming them here would tie the plugin to their
# sonames, and then a library bump stops the load before the plugin can say what is wrong.
target_link_libraries(hypr-de-scene-impl PRIVATE PkgConfig::libs)
# Hyprland's header keeps the build a plugin was compiled for in a symbol the whole process
# shares, so whichever plugin asks first would answer for this one too.
target_link_options(hypr-de-scene-impl PRIVATE -Wl,--version-script=${CMAKE_CURRENT_SOURCE_DIR}/src/private.map)
set_property(TARGET hypr-de-scene-impl APPEND PROPERTY LINK_DEPENDS ${CMAKE_CURRENT_SOURCE_DIR}/src/private.map)

# The module imports Hyprland's C++ symbols, so after an upgrade that renames one it fails to
# load before it runs, and Hyprland puts a notification on screen. Hyprland loads this loader
# instead, which opens the module only in the build it was made for. PluginAPI.hpp would bring
# Hyprland's C++ globals into the loader, so it takes only what it needs from that header.
find_file(HYPRLAND_PLUGIN_API src/plugins/PluginAPI.hpp PATHS ${headers_INCLUDE_DIRS} NO_DEFAULT_PATH REQUIRED)
set_property(DIRECTORY APPEND PROPERTY CMAKE_CONFIGURE_DEPENDS ${HYPRLAND_PLUGIN_API})
file(READ ${HYPRLAND_PLUGIN_API} api)
string(REGEX MATCH "#define HYPRLAND_API_VERSION ([^\n]+)" api_version "${api}")
set(api_version "${CMAKE_MATCH_1}")
# CMake 4.3 drops a semicolon that ends a match, so the template supplies it
string(REGEX MATCH "using PLUGIN_DESCRIPTION_INFO = struct {[^}]+}" description "${api}")
string(FIND "${api}" "__hyprland_api_get_client_hash() {" hash_begin)
if(NOT api_version OR NOT description OR hash_begin EQUAL -1)
    message(FATAL_ERROR "${HYPRLAND_PLUGIN_API} no longer has the API version, PLUGIN_DESCRIPTION_INFO and client hash the loader copies")
endif()
# the module checks the loader's copy of the API version against the macro it compiles with
target_compile_definitions(hypr-de-scene-impl PRIVATE HYPR_DE_SCENE_LOADER_API_VERSION=${api_version})
string(SUBSTRING "${api}" ${hash_begin} -1 hash)
string(FIND "${hash}" "\n}\n" hash_end)
string(SUBSTRING "${hash}" 0 ${hash_end} hash)
string(REPLACE "__hyprland_api_get_client_hash()" "builtFor()" hash "${hash}")
file(CONFIGURE OUTPUT ${CMAKE_CURRENT_BINARY_DIR}/loader/PluginEntry.hpp @ONLY CONTENT "#pragma once

#include <hyprland/src/version.h>
#include <format>
#include <string>
#include <string_view>

#define HYPRLAND_API_VERSION @api_version@

@description@;

inline const char* @hash@
}
")

add_library(hypr-de-scene SHARED src/Loader.cpp)
set_target_properties(hypr-de-scene PROPERTIES PREFIX "")
target_include_directories(hypr-de-scene PRIVATE ${CMAKE_CURRENT_BINARY_DIR}/loader ${headers_INCLUDE_DIRS})
target_compile_options(hypr-de-scene PRIVATE -Wall -Wextra)
target_compile_definitions(hypr-de-scene PRIVATE HYPR_DE_SCENE_MODULE="$<TARGET_FILE_NAME:hypr-de-scene-impl>")
target_link_options(hypr-de-scene PRIVATE -Wl,--version-script=${CMAKE_CURRENT_SOURCE_DIR}/src/loader.map)
set_property(TARGET hypr-de-scene APPEND PROPERTY LINK_DEPENDS ${CMAKE_CURRENT_SOURCE_DIR}/src/loader.map)

# hypr-de has no architecture and names this path in its configuration, so it cannot follow lib64
install(TARGETS hypr-de-scene hypr-de-scene-impl LIBRARY DESTINATION lib/hypr-de)
