#include <dlfcn.h>
#include <syslog.h>
#include <unistd.h>
#include <cstdarg>
#include <cstdio>
#include <cstdlib>
#include <exception>
#include <string>

struct SInfo {
    std::string name, description, author, version;
};

extern "C" const char* __hyprland_api_get_hash();

static bool            logOpen = false;

extern "C" void        openlog(const char*, int, int) {
    logOpen = true;
}

extern "C" void closelog() {
    logOpen = false;
}

extern "C" void vsyslog(int priority, const char* format, va_list args) {
    char text[2048];
    vsnprintf(text, sizeof(text), format, args);
    printf("log %d %s\n", priority, text);
}

extern "C" void syslog(int priority, const char* format, ...) {
    va_list args;
    va_start(args, format);
    vsyslog(priority, format, args);
    va_end(args);
}

extern "C" void __vsyslog_chk(int priority, int, const char* format, va_list args) {
    vsyslog(priority, format, args);
}

extern "C" void __syslog_chk(int priority, int, const char* format, ...) {
    va_list args;
    va_start(args, format);
    vsyslog(priority, format, args);
    va_end(args);
}

static void* open(const char* path, const char* what) {
    void* module = dlopen(path, RTLD_LAZY);
    if (module)
        return module;

    printf("outcome %s did not load: %s\n", what, dlerror());
    _exit(0);
}

// runs inside the Hyprland binary before its main, which then never starts
__attribute__((constructor)) static void load() {
    const char* PLUGIN = getenv("SCENE_PLUGIN");
    if (!PLUGIN)
        return;

    setvbuf(stdout, nullptr, _IONBF, 0);
    printf("running %s\n", __hyprland_api_get_hash());

    void* module = open(PLUGIN, "the plugin");

    try {
        const auto INFO = reinterpret_cast<SInfo (*)(void*)>(dlsym(module, "pluginInit"))(module);
        printf("outcome returned\ndescription %s\n", INFO.description.c_str());
    } catch (const std::exception& e) { printf("outcome threw %s\n", e.what()); }

    printf("syslog %s\n", logOpen ? "open" : "closed");
    reinterpret_cast<void (*)()>(dlsym(module, "pluginExit"))();
    dlclose(module);
    _exit(0);
}
