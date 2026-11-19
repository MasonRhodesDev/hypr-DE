#pragma once

#include <cstddef>
#include <span>

namespace fixture {
    unsigned checksum(std::span<const std::byte> bytes);
    int      vendorValue(long value);
    int      lastOf(std::size_t count, std::size_t index);
    int      next(int value);
}
