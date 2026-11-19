#include "Geometry.hpp"

#include <algorithm>

static constexpr double LOGO_FRAC   = 0.16;
static constexpr double CENTRE_FRAC = 0.47;

static int              rnd(double x) {
    return static_cast<int>(x + 0.5);
}

Scene::SSize Scene::transformedSize(const SSize& mode, int wlTransform) {
    if (wlTransform % 2 == 1)
        return {mode.h, mode.w};

    return mode;
}

Scene::SBox Scene::logoBox(const SSize& transformed, int refShortSide) {
    const double S    = refShortSide > 0 ? refShortSide : std::min(transformed.w, transformed.h);
    const int    LOGO = rnd(S * LOGO_FRAC);
    const double CX   = transformed.w / 2.0;
    const double CY   = transformed.h / 2.0 + (CENTRE_FRAC - 0.5) * (refShortSide > 0 ? S : transformed.h);

    return {rnd(CX - LOGO / 2.0), rnd(CY - LOGO / 2.0), LOGO, LOGO};
}
