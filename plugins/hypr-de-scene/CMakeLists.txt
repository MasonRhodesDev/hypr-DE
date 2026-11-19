cmake_minimum_required(VERSION 3.27)

project(hypr-de-scene VERSION 0.1.0 LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 26)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)

find_package(PkgConfig REQUIRED)
pkg_check_modules(deps REQUIRED IMPORTED_TARGET hyprland cairo libdrm pixman-1 glesv2)

add_library(hypr-de-scene SHARED
    src/main.cpp
    src/Scene.cpp
    src/FirstFrame.cpp
    src/Sprite.cpp
    src/Log.cpp
    src/Geometry.cpp
    src/Spec.cpp)

set_target_properties(hypr-de-scene PROPERTIES PREFIX "")
# the placement must round exactly as the Python reference does
target_compile_options(hypr-de-scene PRIVATE -Wall -Wextra -Wno-unused-parameter -ffp-contract=off)
target_link_libraries(hypr-de-scene PRIVATE PkgConfig::deps)

include(GNUInstallDirs)
install(TARGETS hypr-de-scene LIBRARY DESTINATION ${CMAKE_INSTALL_LIBDIR}/hypr-de)
