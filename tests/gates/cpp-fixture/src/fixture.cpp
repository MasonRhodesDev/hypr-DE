#include "fixture.hpp"

#include <array>
#include <cstring>
#include <vector>
#include <vendor.hpp>

unsigned fixture::checksum(std::span<const std::byte> bytes) {
    std::array<std::byte, 32> window{};
    std::memcpy(window.data(), bytes.data(), bytes.size() < window.size() ? bytes.size() : window.size());
    unsigned sum = 0;
    for (const auto byte : window)
        sum = sum * 31U + std::to_integer<unsigned>(byte);
    return sum;
}

int fixture::vendorValue(long value) {
    return vendorNarrow(value);
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
