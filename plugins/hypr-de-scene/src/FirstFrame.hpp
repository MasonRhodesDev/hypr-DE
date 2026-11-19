#pragma once

#include <hyprland/src/render/Renderbuffer.hpp>
#include <hyprland/src/helpers/math/Math.hpp>
#include <hyprland/src/helpers/memory/Memory.hpp>
#include <GLES3/gl32.h>
#include <array>
#include <cstdint>

namespace Scene {
    class CSprite;

    // Draws the scene into an output buffer with its own program. The first commits of an
    // output happen before the monitor has a size, so a Hyprland render pass cannot start yet.
    class CFirstFrame {
      public:
        ~CFirstFrame();

        bool draw(SP<Render::IRenderbuffer> rbo, wl_output_transform transform, const std::array<uint8_t, 3>& background, const CSprite& logo, const CBox& transformedBox);

      private:
        bool   init();

        GLuint m_program = 0;
        GLuint m_vao     = 0;
        GLuint m_vbo     = 0;
        GLint  m_proj    = -1;
        GLint  m_tex     = -1;
    };
}
