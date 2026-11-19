#pragma once

#include <array>
#include <cstdint>
#include <string>

namespace Scene {
    struct SSpec {
        int                    refShortSide = 0;
        std::array<uint8_t, 3> background   = {0x0b, 0x0d, 0x10};

        bool                   operator==(const SSpec&) const = default;
    };

    SSpec parseSpec(const std::string& json);
}
