#include "fixture.hpp"

#ifdef FIXTURE_BAD_EVASION
#include <evasion.hpp>
#endif
#ifdef FIXTURE_BAD_NDEBUG
#define NDEBUG
#include <cassert>
#undef NDEBUG
#endif

#include <array>
#include <cstdio>
#include <cstring>
#include <vector>

#ifdef FIXTURE_BAD_SIBLING
#include <sibling.hpp>
#endif
#ifdef FIXTURE_BAD_SYSTEM
#include <sibling.hpp>
#endif
#ifdef FIXTURE_BAD_GENERATED
#include <generated.hpp>
#endif
#ifdef FIXTURE_BAD_TEMPLATE
#include <template.hpp>
#endif

// Nothing below weakens the build, though a line-by-line reading of the text would say so:
// #pragma GCC optimize("O0") in a comment, a function named optimize, and an attribute in a string.
namespace {
    struct Layout {
        int width = 0;
    };
    [[nodiscard]] Layout optimize(const Layout& layout) {
        return Layout{layout.width + 1};
    }
    constexpr int       NOLINTER    = 1;
    constexpr const char* attributeText = "[[gnu::optimize(\"O0\")]] and #pragma GCC optimize";
}
#pragma GCC visibility push(default)
#line 40
int fixture::layoutWidth() {
    return optimize(Layout{NOLINTER}).width + static_cast<int>(std::strlen(attributeText));
}
#pragma GCC visibility pop

unsigned fixture::checksum(std::span<const std::byte> bytes) {
    std::array<std::byte, 32> window{};
    std::memcpy(window.data(), bytes.data(), bytes.size() < window.size() ? bytes.size() : window.size());
    unsigned sum = 0;
    for (const auto byte : window)
        sum = sum * 31U + std::to_integer<unsigned>(byte);
    return sum;
}

int fixture::lastOf(std::size_t count, std::size_t index) {
    std::vector<int> values(count);
#ifdef FIXTURE_BAD_OVERFLOW
    int* raw   = values.data();
    raw[index] = 1;
    return raw[index];
#else
    values.at(index % count) = 1;
    return values.at(index % count);
#endif
}

int fixture::next(int value) {
#ifdef FIXTURE_BAD_UNDEFINED
    return value + 1;
#else
    return value < 0 ? value : value - 1;
#endif
}

#ifdef FIXTURE_BAD_UNFORTIFIED
int fixture::format(char* out, int value) {
    // through a pointer, the call skips the header's fortified wrapper
    auto* volatile plain = &std::sprintf;
    return plain(out, "%d", value);
}
#endif

#ifdef FIXTURE_BAD_WARNING
int narrow(long value) {
    return value;
}
#endif

#ifdef FIXTURE_BAD_TIDY
const char* bytesOf(const int& value) {
    return reinterpret_cast<const char*>(&value);
}
#endif
