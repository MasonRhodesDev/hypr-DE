#include "Sprite.hpp"

using namespace Scene;

CSprite::CSprite(const std::string& pngPath, int size) : m_size(size) {
    const auto SOURCE = cairo_image_surface_create_from_png(pngPath.c_str());

    if (cairo_surface_status(SOURCE) == CAIRO_STATUS_SUCCESS && size > 0) {
        m_surface     = cairo_image_surface_create(CAIRO_FORMAT_ARGB32, size, size);
        const auto CR = cairo_create(m_surface);

        cairo_scale(CR, static_cast<double>(size) / cairo_image_surface_get_width(SOURCE), static_cast<double>(size) / cairo_image_surface_get_height(SOURCE));
        cairo_set_source_surface(CR, SOURCE, 0, 0);
        cairo_pattern_set_filter(cairo_get_source(CR), CAIRO_FILTER_BEST);
        cairo_paint(CR);
        cairo_destroy(CR);
        cairo_surface_flush(m_surface);
    }

    cairo_surface_destroy(SOURCE);
}

CSprite::~CSprite() {
    if (m_surface)
        cairo_surface_destroy(m_surface);
}

bool CSprite::good() const {
    return m_surface && cairo_surface_status(m_surface) == CAIRO_STATUS_SUCCESS;
}

int CSprite::size() const {
    return m_size;
}

cairo_surface_t* CSprite::surface() const {
    return m_surface;
}
