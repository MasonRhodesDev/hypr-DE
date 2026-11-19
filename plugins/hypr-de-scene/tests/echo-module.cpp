// stands in for the module and reports what the loader hands it and when it is closed.
// Built without GNU unique symbols, like the packaged module, since glibc never closes a library that has them.
#include <cstdio>
#include <format>
#include <stdexcept>
#include <string>

struct SInfo {
    std::string name, description, author, version;
};

extern "C" __attribute__((visibility("default"))) std::string pluginAPIVersion() {
#ifdef ECHO_VERSION_THROWS
    throw std::runtime_error("the module cannot name its API version");
#endif
    return HYPRLAND_API_VERSION;
}

extern "C" __attribute__((visibility("default"))) SInfo pluginInit(void* handle) {
#ifdef ECHO_INIT_THROWS
    throw std::runtime_error("the module failed to start");
#endif
    return {"echo", std::format("handle {}", handle), "", ""};
}

#ifndef ECHO_WITHOUT_EXIT
extern "C" __attribute__((visibility("default"))) void pluginExit() {
    printf("module exit\n");
}
#endif

__attribute__((destructor)) static void closed() {
    printf("module closed\n");
}
