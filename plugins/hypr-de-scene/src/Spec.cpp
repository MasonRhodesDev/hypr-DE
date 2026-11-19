#include "Spec.hpp"

#include <regex>

Scene::SSpec Scene::parseSpec(const std::string& json) {
    static const std::regex REF(R"re("ref_short_side"\s*:\s*([0-9]{1,6})\b)re");
    static const std::regex BG(R"re("bg"\s*:\s*"#([0-9a-fA-F]{6})")re");

    SSpec                   spec;
    std::smatch             match;

    if (std::regex_search(json, match, REF))
        spec.refShortSide = std::stoi(match[1].str());

    if (std::regex_search(json, match, BG)) {
        const auto RGB  = std::stoul(match[1].str(), nullptr, 16);
        spec.background = {static_cast<uint8_t>(RGB >> 16), static_cast<uint8_t>(RGB >> 8), static_cast<uint8_t>(RGB)};
    }

    return spec;
}
