cmake_minimum_required(VERSION 3.27)

project(hypr-de-scene VERSION 0.1.0 LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 26)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)

find_package(PkgConfig REQUIRED)
pkg_check_modules(headers REQUIRED hyprland pixman-1)
pkg_check_modules(libs REQUIRED IMPORTED_TARGET cairo libdrm glesv2)

add_library(hypr-de-scene SHARED
    src/main.cpp
    src/Scene.cpp
    src/FirstFrame.cpp
    src/Sprite.cpp
    src/Log.cpp
    src/Geometry.cpp
    src/Spec.cpp)

set_target_properties(hypr-de-scene PROPERTIES PREFIX "")
target_include_directories(hypr-de-scene PRIVATE ${headers_INCLUDE_DIRS})
# the placement must round exactly as the Python reference does
target_compile_options(hypr-de-scene PRIVATE ${headers_CFLAGS_OTHER} -Wall -Wextra -Wno-unused-parameter -ffp-contract=off)
# Hyprland has its own libraries loaded already. Naming them here would tie the plugin to their
# sonames, and then a library bump stops the load before the plugin can say what is wrong.
target_link_libraries(hypr-de-scene PRIVATE PkgConfig::libs)
# Hyprland's header keeps the build a plugin was compiled for in a symbol the whole process
# shares, so whichever plugin asks first would answer for this one too.
target_link_options(hypr-de-scene PRIVATE -Wl,--version-script=${CMAKE_CURRENT_SOURCE_DIR}/src/private.map)
set_property(TARGET hypr-de-scene APPEND PROPERTY LINK_DEPENDS ${CMAKE_CURRENT_SOURCE_DIR}/src/private.map)

include(GNUInstallDirs)
install(TARGETS hypr-de-scene LIBRARY DESTINATION ${CMAKE_INSTALL_LIBDIR}/hypr-de)
