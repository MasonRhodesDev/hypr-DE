#include <hyprland/src/plugins/PluginAPI.hpp>

extern "C" EXPORT const char* builtFor() {
    return __hyprland_api_get_client_hash();
}
