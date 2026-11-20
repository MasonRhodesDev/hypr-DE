#include "fixture.hpp"

#include <array>
#include <climits>
#include <cstdlib>

int main() {
    const std::array<std::byte, 4> bytes{std::byte{1}, std::byte{2}, std::byte{3}, std::byte{4}};
    volatile std::size_t           count = 4;
    volatile int                   large = INT_MAX;
    const bool                     ok    = fixture::checksum(bytes) != 0 && fixture::layoutWidth() > 0 && fixture::lastOf(count, count) == 1 &&
        fixture::next(large) != 0;
    return ok ? EXIT_SUCCESS : EXIT_FAILURE;
}
