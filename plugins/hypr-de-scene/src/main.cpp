#include "Log.hpp"
#include "Scene.hpp"

#include <hyprland/src/plugins/PluginAPI.hpp>
#include <hyprland/src/state/MonitorState.hpp>
#include <chrono>
#include <cstdlib>
#include <format>
#include <string_view>
#include <syslog.h>

static_assert(std::string_view{HYPR_DE_SCENE_LOADER_API_VERSION} == HYPRLAND_API_VERSION,
              "the loader copied another API version than the one this module is built against");

static UP<Scene::CScene> scene;

static std::string       env(const char* name, const std::string& fallback) {
    const char* VALUE = std::getenv(name);
    return VALUE && *VALUE ? VALUE : fallback;
}

static Scene::SSettings settings() {
    char*        end     = nullptr;
    const auto   TEXT    = env("HYPR_DE_SCENE_TIMEOUT", "5");
    const double SECONDS = std::strtod(TEXT.c_str(), &end);

    return {
        .dataDir          = env("HYPR_DE_SCENE_DATA", env("DESKTOP_BOOT_DATA", "/usr/share/desktop-boot")),
        .handoffNamespace = env("HYPR_DE_SCENE_HANDOFF", "desktop-boot-splash"),
        .timeout          = std::chrono::milliseconds(end != TEXT.c_str() && SECONDS > 0 ? sc<long>(SECONDS * 1000) : 5000),
        .dumpDir          = env("HYPR_DE_SCENE_DUMP", ""),
    };
}

APICALL EXPORT std::string PLUGIN_API_VERSION() {
    return HYPRLAND_API_VERSION;
}

static PLUGIN_DESCRIPTION_INFO describedAs(const std::string& description) {
    return {"hypr-de-scene", description, "hypr-DE", "0.1.0"};
}

APICALL EXPORT PLUGIN_DESCRIPTION_INFO PLUGIN_INIT(HANDLE handle) {
    // syslog keeps this pointer, so the module has to closelog before it is unloaded
    openlog("hypr-de-scene", LOG_PID, LOG_USER);

    const std::string RUNNING = __hyprland_api_get_hash();
    const std::string BUILT   = __hyprland_api_get_client_hash();

    // Hyprland hands plugins its C++ objects, so any other build has a different layout.
    // Throwing would put Hyprland's failed-to-load notification on screen.
    if (RUNNING != BUILT) {
        const auto REASON =
            std::format("idle, boot scene off: built for Hyprland {} but {} is running. Rebuild the hypr-de-scene package against the installed Hyprland", BUILT, RUNNING);
        syslog(LOG_ERR, "%s", REASON.c_str());
        closelog();
        return describedAs(REASON);
    }

    const auto SETTINGS = settings();
    Scene::logTo(SETTINGS.dumpDir);
    Scene::note("scene: loaded into Hyprland {}", RUNNING);

    // loaded into a running session, the scene would cover a desktop that is already up
    if (!State::monitorState()->allMonitors().empty())
        Scene::note("scene: outputs already exist, so no session is starting, staying out of the way");
    else if (!Scene::CSprite(SETTINGS.dataDir + "/logo.png", 16).good())
        Scene::note("scene: no readable logo.png in {}, staying out of the way", SETTINGS.dataDir);
    else
        scene = makeUnique<Scene::CScene>(SETTINGS);

    return describedAs("Keeps the boot scene on screen from Hyprland's first frame");
}

APICALL EXPORT void PLUGIN_EXIT() {
    scene.reset();
    closelog();
}
