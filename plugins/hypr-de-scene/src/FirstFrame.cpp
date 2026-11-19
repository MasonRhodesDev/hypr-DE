#include "FirstFrame.hpp"
#include "Sprite.hpp"

#include <hyprland/src/render/OpenGL.hpp>
#include <hyprland/src/render/Renderer.hpp>
#include <hyprland/src/render/Framebuffer.hpp>

using namespace Scene;

static const char* const VERTEX = R"glsl(#version 300 es
uniform mat3 proj;
in vec2 pos;
out vec2 v_texcoord;

void main() {
    gl_Position = vec4(proj * vec3(pos, 1.0), 1.0);
    v_texcoord = pos;
}
)glsl";

// cairo's ARGB32 is BGRA in memory, uploaded as RGBA
static const char* const                FRAGMENT = R"glsl(#version 300 es
precision highp float;
uniform sampler2D tex;
in vec2 v_texcoord;
out vec4 fragColor;

void main() {
    fragColor = texture(tex, v_texcoord).bgra;
}
)glsl";

static constexpr std::array<GLfloat, 8> QUAD = {0.F, 0.F, 0.F, 1.F, 1.F, 0.F, 1.F, 1.F};

// Hyprland caches what it bound last, so every binding made here goes back as it was
class CBindingGuard {
  public:
    CBindingGuard() {
        glGetIntegerv(GL_CURRENT_PROGRAM, &m_program);
        glGetIntegerv(GL_VERTEX_ARRAY_BINDING, &m_vao);
        glGetIntegerv(GL_ARRAY_BUFFER_BINDING, &m_vbo);
        glGetIntegerv(GL_ACTIVE_TEXTURE, &m_unit);
        glActiveTexture(GL_TEXTURE0);
        glGetIntegerv(GL_TEXTURE_BINDING_2D, &m_texture);
        glGetIntegerv(GL_UNPACK_ROW_LENGTH, &m_rowLength);
    }

    ~CBindingGuard() {
        glPixelStorei(GL_UNPACK_ROW_LENGTH, m_rowLength);
        glBindTexture(GL_TEXTURE_2D, m_texture);
        glActiveTexture(m_unit);
        glBindBuffer(GL_ARRAY_BUFFER, m_vbo);
        glBindVertexArray(m_vao);
        glUseProgram(m_program);
    }

  private:
    GLint m_program   = 0;
    GLint m_vao       = 0;
    GLint m_vbo       = 0;
    GLint m_unit      = GL_TEXTURE0;
    GLint m_texture   = 0;
    GLint m_rowLength = 0;
};

static GLuint compile(GLenum type, const char* source) {
    const GLuint SHADER = glCreateShader(type);
    glShaderSource(SHADER, 1, &source, nullptr);
    glCompileShader(SHADER);

    GLint ok = GL_FALSE;
    glGetShaderiv(SHADER, GL_COMPILE_STATUS, &ok);
    if (ok == GL_TRUE)
        return SHADER;

    glDeleteShader(SHADER);
    return 0;
}

CFirstFrame::~CFirstFrame() {
    if (!m_program || !Render::GL::g_pHyprOpenGL)
        return;

    Render::GL::g_pHyprOpenGL->makeEGLCurrent();
    glDeleteProgram(m_program);
    glDeleteVertexArrays(1, &m_vao);
    glDeleteBuffers(1, &m_vbo);
}

bool CFirstFrame::init() {
    if (m_program)
        return true;

    const GLuint VERT = compile(GL_VERTEX_SHADER, VERTEX);
    const GLuint FRAG = compile(GL_FRAGMENT_SHADER, FRAGMENT);
    if (!VERT || !FRAG) {
        glDeleteShader(VERT);
        glDeleteShader(FRAG);
        return false;
    }

    const GLuint PROGRAM = glCreateProgram();
    glAttachShader(PROGRAM, VERT);
    glAttachShader(PROGRAM, FRAG);
    glBindAttribLocation(PROGRAM, 0, "pos");
    glLinkProgram(PROGRAM);
    glDeleteShader(VERT);
    glDeleteShader(FRAG);

    GLint ok = GL_FALSE;
    glGetProgramiv(PROGRAM, GL_LINK_STATUS, &ok);
    if (ok != GL_TRUE) {
        glDeleteProgram(PROGRAM);
        return false;
    }

    m_program = PROGRAM;
    m_proj    = glGetUniformLocation(m_program, "proj");
    m_tex     = glGetUniformLocation(m_program, "tex");

    glGenVertexArrays(1, &m_vao);
    glGenBuffers(1, &m_vbo);
    glBindVertexArray(m_vao);
    glBindBuffer(GL_ARRAY_BUFFER, m_vbo);
    glBufferData(GL_ARRAY_BUFFER, sizeof(QUAD), QUAD.data(), GL_STATIC_DRAW);
    glEnableVertexAttribArray(0);
    glVertexAttribPointer(0, 2, GL_FLOAT, GL_FALSE, 0, nullptr);

    return true;
}

bool CFirstFrame::draw(SP<Render::IRenderbuffer> rbo, wl_output_transform transform, const std::array<uint8_t, 3>& background, const CSprite& logo, const CBox& transformedBox) {
    Render::GL::g_pHyprOpenGL->makeEGLCurrent();

    const bool     BLENDING = Render::GL::g_pHyprOpenGL->blendEnabled();
    const Vector2D SIZE     = rbo->getFB()->m_size;
    const Vector2D TFMD     = transform % 2 == 1 ? Vector2D{SIZE.y, SIZE.x} : SIZE;

    // the same matrices a render pass builds for a framebuffer target, so both land on the same pixels
    const Mat3x3        TARGET     = Mat3x3::identity().translate(SIZE / 2.0).transform(Math::wlTransformToHyprutils(transform)).translate(-TFMD / 2.0);
    const Mat3x3        PROJECTION = Mat3x3::outputProjection(SIZE, HYPRUTILS_TRANSFORM_NORMAL).multiply(TARGET.projectBox(transformedBox, HYPRUTILS_TRANSFORM_NORMAL, 0));

    const CBindingGuard GUARD;

    if (!init())
        return false;

    // binding an output buffer leaves the viewport of whatever was drawn last
    rbo->bind();
    Render::GL::g_pHyprOpenGL->setViewport(0, 0, SIZE.x, SIZE.y);
    g_pHyprRenderer->disableScissor();
    glClearColor(background[0] / 255.F, background[1] / 255.F, background[2] / 255.F, 1.F);
    glClear(GL_COLOR_BUFFER_BIT);

    GLuint texture = 0;
    glGenTextures(1, &texture);
    glBindTexture(GL_TEXTURE_2D, texture);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_NEAREST);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_NEAREST);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
    glPixelStorei(GL_UNPACK_ROW_LENGTH, cairo_image_surface_get_stride(logo.surface()) / 4);
    glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA, logo.size(), logo.size(), 0, GL_RGBA, GL_UNSIGNED_BYTE, cairo_image_surface_get_data(logo.surface()));

    g_pHyprRenderer->blend(true);
    glUseProgram(m_program);
    glUniformMatrix3fv(m_proj, 1, GL_TRUE, PROJECTION.getMatrix().data());
    glUniform1i(m_tex, 0);
    glBindVertexArray(m_vao);
    glDrawArrays(GL_TRIANGLE_STRIP, 0, 4);

    glDeleteTextures(1, &texture);
    g_pHyprRenderer->blend(BLENDING);
    rbo->unbind();

    // the commit this buffer goes out on carries no fence
    glFinish();

    return true;
}
