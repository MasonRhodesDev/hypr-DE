#include "PluginEntry.hpp"

#include <bit>
#include <dlfcn.h>
#include <format>
#include <string>
#include <syslog.h>
#include <utility>

namespace {
    using FVersion = std::string (*)();
    using FInit    = PLUGIN_DESCRIPTION_INFO (*)(void*);
    using FExit    = void (*)();
    using FHash    = const char* (*)();

    struct SModule {
        void* handle = nullptr;
        FExit exit   = nullptr;
    };

    SModule    module;
    const char anchor = 0;

    template <typename Fn>
    Fn entry(void* handle, const char* name) {
        return std::bit_cast<Fn>(dlsym(handle, name));
    }

    PLUGIN_DESCRIPTION_INFO describedAs(const std::string& description) {
        return {"hypr-de-scene", description, "hypr-DE", "0.1.0"};
    }

    PLUGIN_DESCRIPTION_INFO idle(const std::string& why) {
        const auto REASON = std::format("idle, boot scene off: {}. Rebuild the hypr-de-scene package against the installed Hyprland", why);
        openlog("hypr-de-scene", LOG_PID, LOG_USER);
        syslog(LOG_ERR, "%s", REASON.c_str());
        // syslog keeps the tag's pointer, which unloading the loader would leave dangling
        closelog();
        return describedAs(REASON);
    }

    std::string lastError() {
        const char* ERROR = dlerror();
        return ERROR ? ERROR : "the dynamic linker gave no reason";
    }

    std::string modulePath() {
        Dl_info self = {};
        if (dladdr(&anchor, &self) == 0 || !self.dli_fname)
            return {};

        const std::string LOADER = self.dli_fname;
        if (!LOADER.starts_with('/'))
            return {};

        return LOADER.substr(0, LOADER.rfind('/') + 1) + HYPR_DE_SCENE_MODULE;
    }

    PLUGIN_DESCRIPTION_INFO start(void* handle) {
        // looked up rather than linked, so that no Hyprland can fail to load the loader
        const auto  HASH    = entry<FHash>(RTLD_DEFAULT, "__hyprland_api_get_hash");
        const char* RUNNING = HASH ? HASH() : nullptr;
        if (!RUNNING)
            return idle("this Hyprland does not name its build");

        const std::string BUILT = builtFor();
        if (BUILT != RUNNING)
            return idle(std::format("built for Hyprland {} but {} is running", BUILT, RUNNING));

        const auto PATH = modulePath();
        if (PATH.empty())
            return idle("the loader was not loaded by an absolute path, so it cannot find its module");

        void* opened = dlopen(PATH.c_str(), RTLD_NOW | RTLD_LOCAL);
        if (!opened)
            return idle(lastError());

        const auto VERSION = entry<FVersion>(opened, "pluginAPIVersion");
        const auto INIT    = entry<FInit>(opened, "pluginInit");
        const auto EXIT    = entry<FExit>(opened, "pluginExit");
        if (!VERSION || !INIT || !EXIT || VERSION() != HYPRLAND_API_VERSION) {
            dlclose(opened);
            return idle(std::format("{} is not the module this loader was built with", PATH));
        }

        // Hyprland keys everything a plugin registers, and the pluginExit it calls, on this handle
        PLUGIN_DESCRIPTION_INFO info;
        bool                    started = true;
        try {
            info = INIT(handle);
        } catch (...) { started = false; }

        // outside the catch block, since the exception may live in the module being closed
        if (!started) {
            EXIT();
            dlclose(opened);
            return idle(std::format("{} failed to start", PATH));
        }

        module = {.handle = opened, .exit = EXIT};
        return info;
    }
}

extern "C" std::string pluginAPIVersion() {
    return HYPRLAND_API_VERSION;
}

extern "C" PLUGIN_DESCRIPTION_INFO pluginInit(void* handle) {
    // Hyprland puts its failed-to-load notification on screen for anything that escapes
    try {
        return start(handle);
    } catch (...) { return {}; }
}

extern "C" void pluginExit() {
    const auto [OPENED, EXIT] = std::exchange(module, {});
    if (!OPENED)
        return;

    bool stopped = true;
    try {
        EXIT();
    } catch (...) { stopped = false; }

    // a module that did not stop may still have a timer in Hyprland's event loop
    if (stopped)
        dlclose(OPENED);
}
