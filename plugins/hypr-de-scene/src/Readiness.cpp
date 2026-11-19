#include "Readiness.hpp"

#include <algorithm>
#include <format>
#include <functional>
#include <ranges>

using namespace Scene;

static constexpr size_t MAX_REQUEST = 256;

static void             heard(SRecord& record, Instant now) {
    record.lastMessage = now;
}

bool Scene::expectLayer(SRecord& record, const std::string& name, Instant now) {
    if (!record.expect.contains(name) && record.expect.size() >= MAX_EXPECTED)
        return false;

    record.expect.try_emplace(name);
    heard(record, now);
    return true;
}

void Scene::dropLayer(SRecord& record, const std::string& name) {
    record.expect.erase(name);
}

void Scene::sessionReady(SRecord& record, Instant now) {
    record.session = true;
    heard(record, now);
}

bool Scene::mapLayer(SRecord& record, const std::string& name, const std::string& output, Instant now) {
    const auto IT = record.expect.find(name);
    if (IT == record.expect.end())
        return false;

    IT->second.insert_or_assign(output, now);
    return true;
}

void Scene::unmapLayer(SRecord& record, const std::string& name, const std::string& output) {
    if (const auto IT = record.expect.find(name); IT != record.expect.end())
        IT->second.erase(output);
}

void Scene::showWallpaper(SRecord& record, const std::string& output, Instant now) {
    record.wallpaperReady.insert(output);
    record.lastWallpaper = now;
}

namespace {
    struct SWait {
        bool                   satisfied = true;
        std::optional<Instant> at;
    };

    // an output still without it is excused a bound after the later of its cover and the last progress,
    // and with no progress at all nothing is excused
    SWait waitFor(const SRecord& record, const std::function<bool(const std::string&)>& shown, std::optional<Instant> progress, Span bound, Instant now) {
        SWait wait;
        for (const auto& [output, since] : record.outputs) {
            if (shown(output))
                continue;
            if (!progress) {
                wait.satisfied = false;
                continue;
            }
            const Instant AT = std::max(*progress, since) + bound;
            wait.at          = wait.at ? std::max(*wait.at, AT) : AT;
        }
        wait.satisfied = wait.satisfied && (!wait.at || now >= *wait.at);
        return wait;
    }

    // a layer shown on some outputs waits the spread for the rest, from its last map or the later cover
    SWait layerWait(const SRecord& record, const std::map<std::string, Instant>& mapped, const SBounds& bounds, Instant now) {
        std::optional<Instant> last;
        for (const auto& output : record.outputs | std::views::keys) {
            if (const auto IT = mapped.find(output); IT != mapped.end())
                last = last ? std::max(*last, IT->second) : IT->second;
        }
        return waitFor(record, [&mapped](const std::string& output) { return mapped.contains(output); }, last, bounds.spread, now);
    }

    SWait wallpaperWait(const SRecord& record, const SBounds& bounds, Instant now) {
        if (!record.wallpaper)
            return {};
        const auto PROGRESS = record.lastWallpaper.value_or(*record.start);
        return waitFor(record, [&record](const std::string& output) { return record.wallpaperReady.contains(output); }, PROGRESS, bounds.background, now);
    }

    Instant quietAt(const SRecord& record, Instant start, const SBounds& bounds) {
        return std::max(start, record.lastMessage.value_or(start)) + bounds.quiet;
    }
}

SVerdict Scene::decide(const SRecord& record, const SBounds& bounds, Instant now) {
    if (!record.start)
        return {};

    const Instant START     = *record.start;
    bool          satisfied = true;
    Instant       next      = START + bounds.timeout;
    const auto    include   = [&satisfied, &next, now](const SWait& wait) {
        satisfied = satisfied && wait.satisfied;
        if (wait.at && *wait.at > now)
            next = std::min(next, *wait.at);
    };

    include(wallpaperWait(record, bounds, now));
    for (const auto& mapped : record.expect | std::views::values)
        include(layerWait(record, mapped, bounds, now));

    const bool WAITING = record.await && !record.session;
    if (satisfied && !WAITING)
        return {.reason = eReason::READY, .next = std::nullopt};

    if (WAITING) {
        const auto QUIET = quietAt(record, START, bounds);
        if (satisfied && now >= QUIET)
            return {.reason = eReason::QUIET, .next = std::nullopt};
        if (QUIET > now)
            next = std::min(next, QUIET);
    }

    if (now >= START + bounds.timeout)
        return {.reason = eReason::TIMEOUT, .next = std::nullopt};

    return {.reason = eReason::HOLD, .next = next};
}

std::vector<std::string> Scene::missing(const SRecord& record, const SBounds& bounds, Instant now) {
    std::vector<std::string> result;
    for (const auto& [name, mapped] : record.expect) {
        if (layerWait(record, mapped, bounds, now).satisfied)
            continue;
        for (const auto& output : record.outputs | std::views::keys) {
            if (!mapped.contains(output))
                result.push_back(std::format("{} on {}", name, output));
        }
    }

    if (record.wallpaper) {
        for (const auto& output : record.outputs | std::views::keys) {
            if (!record.wallpaperReady.contains(output))
                result.push_back(std::format("background on {}", output));
        }
    }

    return result;
}

std::string_view Scene::reasonName(eReason reason) {
    switch (reason) {
        case eReason::HOLD: return "hold";
        case eReason::READY: return "ready";
        case eReason::QUIET: return "quiet";
        case eReason::TIMEOUT: return "timeout";
        case eReason::LOCK: return "lock";
        case eReason::MANUAL: return "manual";
        case eReason::BROKEN: return "broken";
    }
    return "?";
}

bool Scene::validName(std::string_view name) {
    const auto ALLOWED = [](char c) { return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '.' || c == '_' || c == '-' || c == ':'; };
    return !name.empty() && name.size() <= MAX_NAMESPACE && std::ranges::all_of(name, ALLOWED);
}

std::expected<SCommand, std::string> Scene::parseCommand(std::string_view request) {
    if (request.size() > MAX_REQUEST)
        return std::unexpected("request too long");

    std::vector<std::string_view> words;
    for (const auto WORD : std::views::split(request, ' '))
        words.emplace_back(WORD.begin(), WORD.end());

    const auto WORD = [&words](size_t i) { return i < words.size() ? words.at(i) : std::string_view{}; };
    if (WORD(0) != "scene")
        return std::unexpected("unknown request");

    const auto NAMED = [&words](eVerb verb, std::string_view name) -> std::expected<SCommand, std::string> {
        if (!validName(name))
            return std::unexpected(std::format("a name is 1 to {} letters, digits, '.', '_', '-' or ':'", MAX_NAMESPACE));
        return SCommand{.verb = verb, .name = std::string{name}};
    };

    const auto VERB = WORD(1);
    if (words.size() == 1)
        return SCommand{.verb = eVerb::SHOW, .name = ""};
    if (words.size() == 4 && VERB == "expect" && WORD(2) == "layer")
        return NAMED(eVerb::EXPECT, WORD(3));
    if (words.size() == 4 && VERB == "drop" && WORD(2) == "layer")
        return NAMED(eVerb::DROP, WORD(3));
    if (words.size() == 3 && VERB == "ready" && WORD(2) == "session")
        return SCommand{.verb = eVerb::READY, .name = ""};
    if (words.size() == 2 && VERB == "release")
        return SCommand{.verb = eVerb::RELEASE, .name = "hyprctl"};
    if (words.size() == 3 && VERB == "release")
        return NAMED(eVerb::RELEASE, WORD(2));

    return std::unexpected("usage: scene [expect layer NAME | drop layer NAME | ready session | release [WHO]]");
}

std::string Scene::jsonString(std::string_view text) {
    std::string out = "\"";
    for (const char C : text) {
        switch (C) {
            case '"': out += "\\\""; break;
            case '\\': out += "\\\\"; break;
            case '\n': out += "\\n"; break;
            default:
                if (static_cast<unsigned char>(C) < 0x20)
                    out += std::format("\\u{:04x}", static_cast<unsigned>(static_cast<unsigned char>(C)));
                else
                    out += C;
        }
    }
    return out + "\"";
}
