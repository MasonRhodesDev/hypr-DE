// stands in for the module and reports what the loader hands it and when it is closed.
// Built without GNU unique symbols, like the packaged module, since glibc never closes a library that has them.
#include <cstdio>
#include <format>
#include <string>

struct SInfo {
    std::string name, description, author, version;
};

extern "C" __attribute__((visibility("default"))) std::string pluginAPIVersion() {
    return HYPRLAND_API_VERSION;
}

extern "C" __attribute__((visibility("default"))) SInfo pluginInit(void* handle) {
    return {"echo", std::format("handle {}", handle), "", ""};
}

extern "C" __attribute__((visibility("default"))) void pluginExit() {
    printf("module exit\n");
}

__attribute__((destructor)) static void closed() {
    printf("module closed\n");
}
