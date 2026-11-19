#pragma once

#include <cairo/cairo.h>
#include <string>

namespace Scene {
    class CSprite {
      public:
        CSprite(const std::string& pngPath, int size);
        ~CSprite();

        CSprite(const CSprite&)                    = delete;
        CSprite&         operator=(const CSprite&) = delete;

        bool             good() const;
        int              size() const;
        cairo_surface_t* surface() const;

      private:
        cairo_surface_t* m_surface = nullptr;
        int              m_size    = 0;
    };
}
