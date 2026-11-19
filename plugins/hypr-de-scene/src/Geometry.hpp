#pragma once

namespace Scene {
    struct SSize {
        int  w = 0;
        int  h = 0;

        bool operator==(const SSize&) const = default;
    };

    struct SBox {
        int  x = 0;
        int  y = 0;
        int  w = 0;
        int  h = 0;

        bool operator==(const SBox&) const = default;
    };

    SSize transformedSize(const SSize& mode, int wlTransform);

    // refShortSide 0 means the short side of the output itself
    SBox logoBox(const SSize& transformed, int refShortSide);
}
