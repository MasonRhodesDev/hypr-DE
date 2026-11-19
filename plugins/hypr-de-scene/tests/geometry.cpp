#include "../src/Geometry.hpp"
#include "../src/Spec.hpp"

#include <format>
#include <iostream>
#include <string>

struct SCase {
    std::string  name;
    Scene::SSize mode;
    int          transform    = 0;
    double       scale        = 1.0;
    int          refShortSide = 0;
    Scene::SSize transformed;
    Scene::SBox  logo;
};

static const SCase CASES[] = {
#include "fixtures.inc"
};

static int  failures = 0;

static void check(bool ok, const std::string& what) {
    std::cout << (ok ? "ok   " : "FAIL ") << what << "\n";
    if (!ok)
        failures++;
}

static std::string str(const Scene::SBox& b) {
    return std::format("{}x{} at {},{}", b.w, b.h, b.x, b.y);
}

int main() {
    for (const auto& c : CASES) {
        const auto SIZE = Scene::transformedSize(c.mode, c.transform);
        const auto LOGO = Scene::logoBox(SIZE, c.refShortSide);
        const auto NAME = std::format("{} scale {} ref {}", c.name, c.scale, c.refShortSide);

        check(SIZE == c.transformed, std::format("{}: scene is laid out on {}x{}", NAME, c.transformed.w, c.transformed.h));
        check(LOGO == c.logo, std::format("{}: logo {} (scene.py says {})", NAME, str(LOGO), str(c.logo)));
    }

    for (int transform = 0; transform < 8; transform++) {
        const auto SIZE = Scene::transformedSize({3840, 2160}, transform);
        const bool SWAP = transform % 2 == 1;
        check(SIZE == (SWAP ? Scene::SSize{2160, 3840} : Scene::SSize{3840, 2160}), std::format("transform {} {} the axes", transform, SWAP ? "swaps" : "keeps"));
    }

    const auto SPEC = Scene::parseSpec(R"({"version": 2, "ref_short_side": 1440, "palette": {"bg": "#0b0d10", "accent": "#1793d1"}})");
    check(SPEC.refShortSide == 1440, "spec: ref_short_side 1440");
    check(SPEC.background == std::array<uint8_t, 3>{0x0b, 0x0d, 0x10}, "spec: bg #0b0d10");

    const auto OTHER = Scene::parseSpec(R"({"ref_short_side": null, "palette": {"bg": "#A1b2C3"}})");
    check(OTHER.refShortSide == 0, "spec: null ref_short_side means per output");
    check(OTHER.background == std::array<uint8_t, 3>{0xa1, 0xb2, 0xc3}, "spec: bg #A1b2C3");

    check(Scene::parseSpec("not json") == Scene::SSpec{}, "spec: unreadable text keeps the defaults");

    return failures == 0 ? 0 : 1;
}
