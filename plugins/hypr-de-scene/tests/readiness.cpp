#include "../src/Readiness.hpp"

#include <format>
#include <functional>
#include <iostream>
#include <optional>
#include <string>
#include <vector>

using namespace Scene;
using std::chrono::milliseconds;

static int failures = 0;

static void check(bool ok, const std::string& what) {
    std::cout << (ok ? "ok   " : "FAIL ") << what << "\n";
    if (!ok)
        failures++;
}

static const Instant T0 = Instant{} + std::chrono::hours(1);

static Instant       at(long ms) {
    return T0 + milliseconds(ms);
}

static std::string show(const std::optional<Instant>& when) {
    return when ? std::format("{}ms", std::chrono::duration_cast<milliseconds>(*when - T0).count()) : "none";
}

static SRecord holding(bool await = true) {
    SRecord record;
    record.await   = await;
    record.start   = T0;
    record.outputs = {{"A", T0}, {"B", T0}};
    return record;
}

struct SRow {
    std::string                    name;
    std::function<SRecord()>       record;
    long                           now;
    eReason                        reason;
    std::optional<long>            next;
    std::vector<std::string>       missing = {};
};

int main() {
    const SBounds BOUNDS;

    const std::vector<SRow> ROWS = {
        {"nothing covers yet, so nothing is decided", [] { SRecord r; r.await = true; return r; }, 9000, eReason::HOLD, std::nullopt},
        {"the session has not spoken, so it waits for quiet", [] { return holding(); }, 100, eReason::HOLD, 1500},
        {"ready with nothing expected releases at once", [] { auto r = holding(); sessionReady(r, at(40)); return r; }, 40, eReason::READY, std::nullopt},
        {"a Hyprland no service manager started waits for nothing", [] { return holding(false); }, 0, eReason::READY, std::nullopt},
        {"no message for the quiet span releases", [] { return holding(); }, 1500, eReason::QUIET, std::nullopt},
        {"a message restarts the quiet span", [] { auto r = holding(); expectLayer(r, "wallpaper", at(1000)); dropLayer(r, "wallpaper"); return r; }, 1600, eReason::HOLD, 2500},
        {"a message before the first frame counts from the first frame", [] { auto r = holding(); r.lastMessage = T0 - milliseconds(500); return r; }, 1499, eReason::HOLD, 1500},
        {"a declared layer that never maps holds until the timeout", [] { auto r = holding(); expectLayer(r, "waybar", at(10)); sessionReady(r, at(20)); return r; }, 4999, eReason::HOLD, 5000, {"waybar on A", "waybar on B"}},
        {"the timeout releases whatever else is true", [] { auto r = holding(); expectLayer(r, "waybar", at(10)); sessionReady(r, at(20)); return r; }, 5000, eReason::TIMEOUT, std::nullopt, {"waybar on A", "waybar on B"}},
        {"the timeout bounds a session that never speaks", [] { auto r = holding(); expectLayer(r, "waybar", at(10)); return r; }, 5000, eReason::TIMEOUT, std::nullopt},
        {"quiet never releases a layer that has not mapped", [] { auto r = holding(); expectLayer(r, "waybar", at(10)); return r; }, 3000, eReason::HOLD, 5000},
        {"a layer on one output waits the spread", [] { auto r = holding(); expectLayer(r, "waybar", at(10)); sessionReady(r, at(20)); mapLayer(r, "waybar", "A", at(1000)); return r; }, 1100, eReason::HOLD, 1250, {"waybar on B"}},
        {"a layer on one output releases after the spread", [] { auto r = holding(); expectLayer(r, "waybar", at(10)); sessionReady(r, at(20)); mapLayer(r, "waybar", "A", at(1000)); return r; }, 1250, eReason::READY, std::nullopt},
        {"a layer on every output releases at once", [] { auto r = holding(); expectLayer(r, "waybar", at(10)); sessionReady(r, at(20)); mapLayer(r, "waybar", "A", at(300)); mapLayer(r, "waybar", "B", at(301)); return r; }, 301, eReason::READY, std::nullopt},
        {"a layer that maps before it is declared counts", [] { auto r = holding(); expectLayer(r, "waybar", at(10)); mapLayer(r, "waybar", "A", at(10)); mapLayer(r, "waybar", "B", at(10)); sessionReady(r, at(20)); return r; }, 20, eReason::READY, std::nullopt},
        {"an unmapped layer no longer counts", [] { auto r = holding(); expectLayer(r, "waybar", at(10)); sessionReady(r, at(20)); mapLayer(r, "waybar", "A", at(300)); mapLayer(r, "waybar", "B", at(301)); unmapLayer(r, "waybar", "B"); unmapLayer(r, "waybar", "A"); return r; }, 900, eReason::HOLD, 5000},
        {"a dropped expectation no longer holds", [] { auto r = holding(); expectLayer(r, "waybar", at(10)); sessionReady(r, at(20)); dropLayer(r, "waybar"); return r; }, 30, eReason::READY, std::nullopt},
        {"an expectation after ready still holds", [] { auto r = holding(); sessionReady(r, at(20)); expectLayer(r, "waybar", at(30)); return r; }, 30, eReason::HOLD, 5000},
        {"a layer mapped only on a removed output does not count", [] { auto r = holding(); expectLayer(r, "waybar", at(10)); sessionReady(r, at(20)); mapLayer(r, "waybar", "C", at(30)); return r; }, 900, eReason::HOLD, 5000},
        {"an output added while covering must show the layer too", [] { auto r = holding(); r.outputs.emplace("C", T0); expectLayer(r, "waybar", at(10)); sessionReady(r, at(20)); mapLayer(r, "waybar", "A", at(100)); mapLayer(r, "waybar", "B", at(100)); return r; }, 200, eReason::HOLD, 350, {"waybar on C"}},
        {"a map nobody expects does not count", [] { auto r = holding(); sessionReady(r, at(20)); return mapLayer(r, "waybar", "A", at(30)) ? SRecord{} : r; }, 30, eReason::READY, std::nullopt},
        {"Hyprland's own wallpaper is waited for on every output", [] { auto r = holding(); r.wallpaper = true; r.wallpaperReady = {"A"}; sessionReady(r, at(20)); return r; }, 20, eReason::HOLD, 2000, {"background on B"}},
        {"Hyprland's own wallpaper that never shows counts as failed after its bound", [] { auto r = holding(); r.wallpaper = true; r.wallpaperReady = {"A"}; sessionReady(r, at(20)); return r; }, 2000, eReason::READY, std::nullopt, {"background on B"}},
        {"each background that shows gives the next its own bound", [] { auto r = holding(); r.wallpaper = true; showWallpaper(r, "A", at(1800)); sessionReady(r, at(20)); return r; }, 2500, eReason::HOLD, 3800, {"background on B"}},
        {"an output covered later gets the whole wallpaper bound", [] { auto r = holding(); r.outputs.emplace("C", at(1500)); r.wallpaper = true; r.wallpaperReady = {"A", "B"}; sessionReady(r, at(20)); return r; }, 2000, eReason::HOLD, 3500, {"background on C"}},
        {"Hyprland's own wallpaper on every output releases", [] { auto r = holding(); r.wallpaper = true; r.wallpaperReady = {"A", "B"}; sessionReady(r, at(20)); return r; }, 20, eReason::READY, std::nullopt},
        {"quiet waits for Hyprland's own wallpaper", [] { auto r = holding(); r.wallpaper = true; return r; }, 1500, eReason::HOLD, 2000},
        {"a drop does not restart the quiet span", [] { auto r = holding(); expectLayer(r, "waybar", at(1000)); dropLayer(r, "waybar"); return r; }, 2500, eReason::QUIET, std::nullopt},
        {"an output covered after the last map waits the spread from its own cover", [] { auto r = holding(); r.outputs.emplace("C", at(3000)); expectLayer(r, "waybar", at(10)); sessionReady(r, at(20)); mapLayer(r, "waybar", "A", at(100)); mapLayer(r, "waybar", "B", at(100)); return r; }, 3100, eReason::HOLD, 3250, {"waybar on C"}},
        {"an output covered after the last map releases a spread after its cover", [] { auto r = holding(); r.outputs.emplace("C", at(3000)); expectLayer(r, "waybar", at(10)); sessionReady(r, at(20)); mapLayer(r, "waybar", "A", at(100)); mapLayer(r, "waybar", "B", at(100)); return r; }, 3250, eReason::READY, std::nullopt},
        {"no counted output leaves nothing to wait for", [] { auto r = holding(); r.outputs.clear(); r.wallpaper = true; expectLayer(r, "waybar", at(10)); sessionReady(r, at(20)); return r; }, 20, eReason::READY, std::nullopt},
    };

    for (const auto& row : ROWS) {
        const auto RECORD  = row.record();
        const auto VERDICT = decide(RECORD, BOUNDS, at(row.now));
        const auto NEXT    = row.next ? std::optional<Instant>{at(*row.next)} : std::nullopt;
        check(VERDICT.reason == row.reason && (row.reason != eReason::HOLD || VERDICT.next == NEXT),
              std::format("{}: {} at {}ms, next deadline {} (got {}, next {})", row.name, reasonName(row.reason), row.now, show(NEXT), reasonName(VERDICT.reason),
                          show(VERDICT.next)));
        if (!row.missing.empty()) {
            const auto MISSING = missing(RECORD, BOUNDS, at(row.now));
            check(MISSING == row.missing, std::format("{}: missing {}", row.name, row.missing.front()));
        }
    }

    {
        auto record = holding();
        for (size_t i = 0; i < MAX_EXPECTED; i++)
            check(expectLayer(record, std::format("layer{}", i), at(10)), std::format("expectation {} of {} is kept", i + 1, MAX_EXPECTED));
        check(!expectLayer(record, "one-more", at(20)), "an expectation past the cap is refused");
        check(record.lastMessage == at(10) && record.expect.size() == MAX_EXPECTED, "a refused expectation changes nothing, not even the quiet span");
        check(expectLayer(record, "layer0", at(30)), "declaring a kept expectation again still works at the cap");
    }

    const std::vector<std::pair<std::string, bool>> NAMES = {
        {"waybar", true},        {"wallpaper", true},           {"quickshell:bar", true},    {"wall.paper-1_x", true},
        {std::string(MAX_NAMESPACE, 'a'), true},                {std::string(MAX_NAMESPACE + 1, 'a'), false},
        {"", false},             {"a b", false},                {"a\"b", false},              {"a\\b", false},
        {"a\nb", false},         {"a\tb", false},               {"a/b", false},               {"\xc3\xa9", false},
        {std::string("a\0b", 3), false},
    };
    for (const auto& [name, valid] : NAMES)
        check(validName(name) == valid, std::format("{:?} is {}", name, valid ? "a valid name" : "refused"));

    struct SParse {
        std::string request;
        bool        ok;
        eVerb       verb = eVerb::SHOW;
        std::string name = "";
    };
    const std::vector<SParse> PARSES = {
        {"scene", true, eVerb::SHOW},
        {"scene expect layer waybar", true, eVerb::EXPECT, "waybar"},
        {"scene drop layer waybar", true, eVerb::DROP, "waybar"},
        {"scene ready session", true, eVerb::READY},
        {"scene release", true, eVerb::RELEASE, "hyprctl"},
        {"scene release test", true, eVerb::RELEASE, "test"},
        {"scenery", false},
        {"scene expect window foot", false},
        {"scene expect layer", false},
        {"scene expect layer a b", false},
        {"scene expect layer a\"b", false},
        {"scene expect layer " + std::string(MAX_NAMESPACE + 1, 'a'), false},
        {"scene  expect layer waybar", false},
        {"scene expect layer waybar ", false},
        {"scene ready", false},
        {"scene ready now", false},
        {"scene release a b", false},
        {"scene release a;b", false},
        {"scene hold", false},
        {"scene " + std::string(300, 'a'), false},
    };
    for (const auto& p : PARSES) {
        const auto PARSED = parseCommand(p.request);
        const bool OK     = PARSED.has_value() == p.ok && (!p.ok || (PARSED->verb == p.verb && PARSED->name == p.name));
        check(OK, std::format("{:?} is {}", p.request.size() > 80 ? p.request.substr(0, 40) + "..." : p.request, p.ok ? "accepted" : "refused"));
    }

    check(jsonString("a\"b\\c") == "\"a\\\"b\\\\c\"", "JSON escapes quotes and backslashes");
    check(jsonString("a\nb\x01") == "\"a\\nb\\u0001\"", "JSON escapes control characters");

    for (const auto REASON : {eReason::HOLD, eReason::READY, eReason::QUIET, eReason::TIMEOUT, eReason::LOCK, eReason::MANUAL, eReason::BROKEN})
        check(!reasonName(REASON).empty() && reasonName(REASON) != "?", std::format("reason {} has a name", static_cast<int>(REASON)));
    check(reasonName(eReason::QUIET) == "quiet" && reasonName(eReason::MANUAL) == "manual", "reasons are named as the journal lines say");

    std::cout << (failures ? std::format("{} failed\n", failures) : "all passed\n");
    return failures ? 1 : 0;
}
