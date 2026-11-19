#pragma once

#include <chrono>
#include <cstddef>
#include <cstdint>
#include <expected>
#include <map>
#include <optional>
#include <set>
#include <string>
#include <string_view>
#include <vector>

// What the session said it will show, what Hyprland has shown, and the rule that decides when
// the scene lets go. Nothing here knows Hyprland, so the rule is tested without a compositor.
namespace Scene {
    using Instant = std::chrono::steady_clock::time_point;
    using Span    = std::chrono::milliseconds;

    enum class eReason : uint8_t {
        HOLD,
        READY,
        QUIET,
        TIMEOUT,
        LOCK,
        MANUAL,
        // the scene cannot be drawn, so it gets out of the way
        BROKEN,
    };

    struct SBounds {
        Span timeout = Span{5000};
        Span quiet   = Span{1500};
        Span spread  = Span{250};
    };

    struct SRecord {
        // Hyprland runs as a systemd service, so the session will say when its components started
        bool                   await   = false;
        bool                   session = false;
        std::optional<Instant> start;
        std::optional<Instant> lastMessage;
        // namespace, then each output it is mapped on and when it last mapped there
        std::map<std::string, std::map<std::string, Instant>> expect;
        std::set<std::string>                                 outputs;
        // Hyprland draws its own wallpaper, which loads on its own and fades in
        bool                  wallpaper = false;
        std::set<std::string> wallpaperReady;
    };

    struct SVerdict {
        eReason                reason = eReason::HOLD;
        std::optional<Instant> next;
    };

    // false when the cap on expectations is reached, and then the record is unchanged
    bool                     expectLayer(SRecord& record, const std::string& name, Instant now);
    void                     dropLayer(SRecord& record, const std::string& name, Instant now);
    void                     sessionReady(SRecord& record, Instant now);
    // true when the namespace is expected, so the map counts
    bool                     mapLayer(SRecord& record, const std::string& name, const std::string& output, Instant now);
    void                     unmapLayer(SRecord& record, const std::string& name, const std::string& output);

    SVerdict                 decide(const SRecord& record, const SBounds& bounds, Instant now);
    std::vector<std::string> missing(const SRecord& record, const SBounds& bounds, Instant now);
    std::string_view         reasonName(eReason reason);

    inline constexpr size_t MAX_EXPECTED  = 32;
    inline constexpr size_t MAX_NAMESPACE = 64;

    bool                    validName(std::string_view name);

    enum class eVerb : uint8_t {
        SHOW,
        EXPECT,
        DROP,
        READY,
        RELEASE,
    };

    struct SCommand {
        eVerb       verb = eVerb::SHOW;
        std::string name;
    };

    // the request as Hyprland's socket hands it over, after hyprctl's flags
    std::expected<SCommand, std::string> parseCommand(std::string_view request);

    std::string                          jsonString(std::string_view text);
}
