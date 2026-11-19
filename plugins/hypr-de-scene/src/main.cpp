#include "Log.hpp"
#include "Scene.hpp"

#include <hyprland/src/ipc/s1/S1.hpp>
#include <hyprland/src/plugins/PluginAPI.hpp>
#include <hyprland/src/state/MonitorState.hpp>
#include <algorithm>
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

// seconds from the environment, kept within bounds so no setting can hold the scene for long
static Scene::Span seconds(const char* name, double fallback, double most) {
    const auto TEXT  = env(name, "");
    char*      end   = nullptr;
    double     value = std::strtod(TEXT.c_str(), &end);
    if (TEXT.empty() || end == TEXT.c_str() || *end || !(value >= 0))
        value = fallback;

    return std::chrono::duration_cast<Scene::Span>(std::chrono::duration<double>(std::min(value, most)));
}

static Scene::SSettings settings() {
    Scene::SBounds bounds;
    bounds.timeout = seconds("HYPR_DE_SCENE_TIMEOUT", 5, 10);
    if (bounds.timeout.count() <= 0)
        bounds.timeout = Scene::Span{5000};
    bounds.quiet  = std::min(seconds("HYPR_DE_SCENE_QUIET", 1.5, 10), bounds.timeout);
    bounds.spread = std::min(seconds("HYPR_DE_SCENE_SPREAD", 0.25, 10), bounds.timeout);

    // Hyprland run by a service manager has a session that says when its components started
    const auto AWAIT = env("HYPR_DE_SCENE_AWAIT_SESSION", "");

    return {
        .dataDir = env("HYPR_DE_SCENE_DATA", env("DESKTOP_BOOT_DATA", "/usr/share/desktop-boot")),
        .bounds  = bounds,
        .fade    = seconds("HYPR_DE_SCENE_FADE", 0.2, 1),
        .await   = AWAIT == "1" || (AWAIT != "0" && std::getenv("MANAGERPID")),
        .dumpDir = env("HYPR_DE_SCENE_DUMP", ""),
    };
}

static IPC::Socket1::SResponse sceneCommand(const IPC::Socket1::SRequest& request) {
    if (!scene) {
        const auto PARSED = Scene::parseCommand(request.command);
        return PARSED ? R"({"state":"idle"})" : "error: " + PARSED.error();
    }

    return scene->command(request.command);
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

    // registered even when idle, so the session's units hear an answer and not an unknown request
    HyprlandAPI::registerHyprCtlCommand(handle, {.name = "scene", .match = IPC::Socket1::COMMAND_MATCH_PREFIX, .handler = sceneCommand});

    return describedAs("Keeps the boot scene on screen from Hyprland's first frame");
}

APICALL EXPORT void PLUGIN_EXIT() {
    scene.reset();
    closelog();
}
