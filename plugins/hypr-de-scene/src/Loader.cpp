#include "PluginEntry.hpp"

#include <bit>
#include <dlfcn.h>
#include <format>
#include <string>
#include <syslog.h>
#include <type_traits>
#include <utility>

namespace {
    using FVersion = std::string (*)();
    using FInit    = PLUGIN_DESCRIPTION_INFO (*)(void*);
    using FExit    = void (*)();
    using FHash    = const char* (*)();

    // exit is set while the module runs, and only a module that is not running is ever closed
    struct SModule {
        void* handle = nullptr;
        FExit exit   = nullptr;
    };

    SModule    module;
    const char anchor = 0;

    constexpr const char* UNEXPECTED = "idle, boot scene off: the loader stopped on an unexpected error. Rebuild the hypr-de-scene package against the installed Hyprland";

    template <typename Fn>
        requires std::is_pointer_v<Fn> && std::is_function_v<std::remove_pointer_t<Fn>>
    Fn entry(void* handle, const char* name) {
        return std::bit_cast<Fn>(dlsym(handle, name));
    }

    void journal(const char* line) noexcept {
        openlog("hypr-de-scene", LOG_PID, LOG_USER);
        syslog(LOG_ERR, "%s", line);
        // syslog keeps the tag's pointer, which unloading the loader would leave dangling
        closelog();
    }

    void stop() {
        if (!module.exit)
            return;

        try {
            std::exchange(module.exit, nullptr)();
        } catch (...) {
            // a module that did not stop may still have a timer in Hyprland's event loop, so it is never closed
            module = {};
        }
    }

    PLUGIN_DESCRIPTION_INFO describedAs(const std::string& description) {
        return {"hypr-de-scene", description, "hypr-DE", "0.1.0"};
    }

    PLUGIN_DESCRIPTION_INFO idle(const std::string& why) {
        const auto REASON = std::format("idle, boot scene off: {}. Rebuild the hypr-de-scene package against the installed Hyprland", why);
        journal(REASON.c_str());
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
        module.handle = opened;

        const auto VERSION = entry<FVersion>(opened, "pluginAPIVersion");
        const auto INIT    = entry<FInit>(opened, "pluginInit");
        const auto EXIT    = entry<FExit>(opened, "pluginExit");
        if (!VERSION || !INIT || !EXIT || VERSION() != HYPRLAND_API_VERSION)
            return idle(std::format("{} is not the module this loader was built with", PATH));

        // running from here, so a fault Hyprland catches inside init leaves the module open
        module.exit = EXIT;

        // Hyprland keys everything a plugin registers, and the pluginExit it calls, on this handle
        PLUGIN_DESCRIPTION_INFO info;
        bool                    started = true;
        try {
            info = INIT(handle);
        } catch (...) { started = false; }

        if (started)
            return info;

        stop();
        return idle(std::format("{} failed to start", PATH));
    }
}

extern "C" std::string pluginAPIVersion() {
    return HYPRLAND_API_VERSION;
}

extern "C" PLUGIN_DESCRIPTION_INFO pluginInit(void* handle) {
    // Hyprland puts its failed-to-load notification on screen for anything that escapes
    try {
        return start(handle);
    } catch (...) {
        journal(UNEXPECTED);
        try {
            return describedAs(UNEXPECTED);
        } catch (...) { return {}; }
    }
}

extern "C" void pluginExit() {
    stop();
}

// Hyprland closes the loader only after removing everything registered under the loader's handle,
// which is all the module could register, so no closing before then can leave Hyprland calling into it
__attribute__((destructor)) static void closeModule() {
    if (module.handle && !module.exit)
        dlclose(module.handle);
}
