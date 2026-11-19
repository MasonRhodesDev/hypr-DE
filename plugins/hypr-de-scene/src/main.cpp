#include "Log.hpp"
#include "Scene.hpp"

#include <hyprland/src/plugins/PluginAPI.hpp>
#include <hyprland/src/state/MonitorState.hpp>
#include <chrono>
#include <cstdlib>
#include <stdexcept>
#include <syslog.h>

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
        .probeOnly        = env("HYPR_DE_SCENE_MODE", "") == "probe",
    };
}

APICALL EXPORT std::string PLUGIN_API_VERSION() {
    return HYPRLAND_API_VERSION;
}

APICALL EXPORT PLUGIN_DESCRIPTION_INFO PLUGIN_INIT(HANDLE handle) {
    openlog("hypr-de-scene", LOG_PID, LOG_USER);

    const std::string RUNNING = __hyprland_api_get_hash();
    const std::string BUILT   = __hyprland_api_get_client_hash();

    // Hyprland hands plugins its C++ objects, so any other build has a different layout
    if (RUNNING != BUILT) {
        syslog(LOG_WARNING, "built for Hyprland %s but %s is running, not loading", BUILT.c_str(), RUNNING.c_str());
        throw std::runtime_error("hypr-de-scene was built for another Hyprland");
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

    return {"hypr-de-scene", "Keeps the boot scene on screen from Hyprland's first frame", "hypr-DE", "0.1.0"};
}

APICALL EXPORT void PLUGIN_EXIT() {
    scene.reset();
}
