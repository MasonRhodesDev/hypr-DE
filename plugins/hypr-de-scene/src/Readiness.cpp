#include "Readiness.hpp"

using namespace Scene;

bool Scene::expectLayer(SRecord& record, const std::string& name, Instant now) {
    return false;
}

void Scene::dropLayer(SRecord& record, const std::string& name, Instant now) {}

void Scene::sessionReady(SRecord& record, Instant now) {}

bool Scene::mapLayer(SRecord& record, const std::string& name, const std::string& output, Instant now) {
    return false;
}

void Scene::unmapLayer(SRecord& record, const std::string& name, const std::string& output) {}

SVerdict Scene::decide(const SRecord& record, const SBounds& bounds, Instant now) {
    return {};
}

std::vector<std::string> Scene::missing(const SRecord& record, const SBounds& bounds, Instant now) {
    return {};
}

std::string_view Scene::reasonName(eReason reason) {
    return "hold";
}

bool Scene::validName(std::string_view name) {
    return true;
}

std::expected<SCommand, std::string> Scene::parseCommand(std::string_view request) {
    return SCommand{};
}

std::string Scene::jsonString(std::string_view text) {
    return std::string{text};
}
