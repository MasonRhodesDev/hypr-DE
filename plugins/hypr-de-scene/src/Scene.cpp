#include "Scene.hpp"
#include "Log.hpp"

#include <hyprland/src/desktop/view/LayerSurface.hpp>
#include <hyprland/src/managers/eventLoop/EventLoopManager.hpp>
#include <hyprland/src/output/Monitor.hpp>
#include <hyprland/src/pointer/PointerManager.hpp>
#include <hyprland/src/render/OpenGL.hpp>
#include <hyprland/src/render/Renderer.hpp>
#include <hyprland/src/render/pass/RectPassElement.hpp>
#include <hyprland/src/render/pass/TexPassElement.hpp>
#include <aquamarine/backend/DRM.hpp>
#include <xf86drmMode.h>
#include <fstream>
#include <memory>
#include <sstream>

using namespace Scene;

static constexpr int MAX_DUMPS = 8;

struct SFramebufferID {
    uint32_t    id = 0;
    std::string source;
};

// the id the kernel reports for the buffer on this output's planes, which is what a scanout audit sees
static SFramebufferID committedFramebuffer(PHLMONITOR monitor, SP<Aquamarine::IBuffer> buffer) {
    const auto BACKEND = monitor->m_output->getBackend();
    if (BACKEND->type() != Aquamarine::AQ_BACKEND_DRM)
        return {0, "none"};

    if (const auto ATTACHMENT = buffer->attachments.get<Aquamarine::CDRMBufferAttachment>(); ATTACHMENT && ATTACHMENT->fb)
        return {ATTACHMENT->fb->id, "buffer"};

    // a second GPU scans out a copy, so the buffer drawn here has no framebuffer of its own
    const auto OUTPUT = dynamicPointerCast<Aquamarine::CDRMOutput>(monitor->m_output);
    if (!OUTPUT)
        return {0, "none"};

    const auto CONNECTOR =
        std::unique_ptr<drmModeConnector, decltype(&drmModeFreeConnector)>(drmModeGetConnectorCurrent(BACKEND->drmFD(), OUTPUT->getConnectorID()), drmModeFreeConnector);
    if (!CONNECTOR || !CONNECTOR->encoder_id)
        return {0, "none"};

    const auto ENCODER = std::unique_ptr<drmModeEncoder, decltype(&drmModeFreeEncoder)>(drmModeGetEncoder(BACKEND->drmFD(), CONNECTOR->encoder_id), drmModeFreeEncoder);
    if (!ENCODER || !ENCODER->crtc_id)
        return {0, "none"};

    const auto CRTC = std::unique_ptr<drmModeCrtc, decltype(&drmModeFreeCrtc)>(drmModeGetCrtc(BACKEND->drmFD(), ENCODER->crtc_id), drmModeFreeCrtc);
    if (!CRTC)
        return {0, "none"};

    return {CRTC->buffer_id, "crtc"};
}

CScene::CScene(const SSettings& settings) : m_settings(settings) {
    logTo(m_settings.dumpDir);

    std::ifstream     file(m_settings.dataDir + "/scene.json");
    std::stringstream text;
    text << file.rdbuf();
    m_spec = parseSpec(text.str());

    m_listeners.preCommit   = Event::bus()->m_events.monitor.preCommit.listen([this](PHLMONITOR monitor) { onPreCommit(monitor); });
    m_listeners.renderPre   = Event::bus()->m_events.render.pre.listen([this](PHLMONITOR monitor) { onRenderPre(monitor); });
    m_listeners.renderStage = Event::bus()->m_events.render.stage.listen([this](const Event::SRenderStageEvent& event) { onRenderStage(event); });

    note("scene: ready, ref_short_side {}, background #{:02x}{:02x}{:02x}, handoff to layer {}", m_spec.refShortSide, m_spec.background[0], m_spec.background[1],
         m_spec.background[2], m_settings.handoffNamespace);
}

CScene::~CScene() {
    for (auto& output : m_outputs) {
        if (output->covering)
            release(*output, "unload");
    }

    dropTimer();
}

// The event loop holds the timer too, and its callback is code in this module. Left there,
// it would be destroyed after the module is unmapped.
void CScene::dropTimer() {
    if (!m_timer)
        return;

    g_pEventLoopManager->removeTimer(m_timer);
    m_timer.reset();
}

CScene::SOutput* CScene::outputFor(PHLMONITOR monitor) {
    std::erase_if(m_outputs, [](const auto& output) { return output->monitor.expired(); });

    for (auto& output : m_outputs) {
        if (output->monitor == monitor)
            return output.get();
    }

    if (m_expired)
        return nullptr;

    if (!m_timer) {
        m_timer = makeShared<CEventLoopTimer>(m_settings.timeout, [this](SP<CEventLoopTimer>, void*) { onTimeout(); }, nullptr);
        g_pEventLoopManager->addTimer(m_timer);
    }

    auto& output    = m_outputs.emplace_back(makeUnique<SOutput>());
    output->monitor = monitor;
    output->commit  = monitor->m_output->events.commit.listen([this, raw = output.get()] { logFirstCommit(*raw); });

    // a cursor plane sits above anything drawn here
    Pointer::mgr()->lockSoftwareForMonitor(monitor);

    return output.get();
}

CScene::SLogo* CScene::logoFor(int size) {
    auto it = m_logos.find(size);
    if (it == m_logos.end())
        it = m_logos.emplace(size, SLogo{.sprite = makeUnique<CSprite>(m_settings.dataDir + "/logo.png", size), .texture = nullptr}).first;

    return &it->second;
}

// a new monitor renders zoomed in until five frames were presented, which would scale the scene
void CScene::holdStill(PHLMONITOR monitor) {
    monitor->m_zoomAnimFrameCounter = 5;
    monitor->m_zoomAnimProgress->setValueAndWarp(1.F);
}

bool CScene::handedOff(PHLMONITOR monitor) {
    for (const auto& layer : monitor->m_layerSurfaceLayers) {
        for (const auto& ref : layer) {
            const auto SURFACE = ref.lock();
            if (!SURFACE || !SURFACE->mapped() || SURFACE->m_namespace != m_settings.handoffNamespace)
                continue;

            if (SURFACE->alpha().getTotal() >= 1.F && SURFACE->m_geometry.width >= monitor->m_size.x && SURFACE->m_geometry.height >= monitor->m_size.y)
                return true;
        }
    }

    return false;
}

void CScene::release(SOutput& output, const std::string& reason) {
    output.covering = false;

    const auto MONITOR = output.monitor.lock();
    if (!MONITOR)
        return;

    Pointer::mgr()->unlockSoftwareForMonitor(MONITOR);
    g_pHyprRenderer->damageMonitor(MONITOR);
    note("scene: released {} on {} after {} frames at {:.3f}", MONITOR->m_name, reason, output.passes, monotonic());
}

void CScene::onTimeout() {
    m_expired = true;

    for (auto& output : m_outputs) {
        if (output->covering)
            release(*output, "timeout");
    }

    m_listeners = {};
    m_outputs.clear();
    m_logos.clear();
    dropTimer();
}

void CScene::onPreCommit(PHLMONITOR monitor) {
    const auto& STATE = monitor->m_output->state->state();
    const auto  MODE  = STATE.mode ? STATE.mode.lock() : STATE.customMode;
    if (!STATE.enabled || !MODE)
        return;

    const auto OUTPUT = outputFor(monitor);
    if (!OUTPUT || !OUTPUT->covering)
        return;

    holdStill(monitor);

    auto buffer = STATE.buffer;
    if (buffer && buffer == OUTPUT->drawn)
        return;

    // the backend swaps in a blank swapchain buffer when this one does not fit the mode
    if (!buffer || buffer->size != MODE->pixelSize) {
        buffer = monitor->m_output->swapchain->next(nullptr);
        monitor->m_output->swapchain->rollback();
        if (!buffer)
            return;

        monitor->m_output->state->setBuffer(buffer);
    }

    drawFirstFrame(*OUTPUT, buffer);
}

void CScene::drawFirstFrame(SOutput& output, SP<Aquamarine::IBuffer> buffer) {
    const auto MONITOR = output.monitor.lock();
    const auto RBO     = g_pHyprRenderer->getOrCreateRenderbuffer(buffer, MONITOR->m_drmFormat);
    if (!RBO) {
        note("scene: no renderbuffer for {}, its first frame stays as Hyprland left it", MONITOR->m_name);
        return;
    }

    const SSize SIZE = transformedSize({sc<int>(buffer->size.x), sc<int>(buffer->size.y)}, MONITOR->m_transform);
    const auto  BOX  = logoBox(SIZE, m_spec.refShortSide);
    const auto  LOGO = logoFor(BOX.w);

    if (!m_firstFrame.draw(RBO, MONITOR->m_transform, m_spec.background, *LOGO->sprite, CBox(BOX.x, BOX.y, BOX.w, BOX.h))) {
        note("scene: could not draw the first frame for {}", MONITOR->m_name);
        return;
    }

    output.drawn = buffer;
    note("scene: drew {} before its commit, mode {}x{} transform {} scale {:.2f}, logo {}px at {},{}", MONITOR->m_name, sc<int>(buffer->size.x), sc<int>(buffer->size.y),
         sc<int>(MONITOR->m_transform), MONITOR->m_scale, BOX.w, BOX.x, BOX.y);
    dump(output, buffer, "first");
}

void CScene::logFirstCommit(SOutput& output) {
    const auto MONITOR = output.monitor.lock();
    const auto BUFFER  = output.drawn.lock();
    if (output.logged || !MONITOR || !BUFFER)
        return;

    output.logged = true;

    const auto FB = committedFramebuffer(MONITOR, BUFFER);
    note("scene: first frame on {} fb {} at {:.3f} via {}", MONITOR->m_name, FB.id, monotonic(), FB.source);
}

void CScene::onRenderPre(PHLMONITOR monitor) {
    const auto OUTPUT = outputFor(monitor);
    if (!OUTPUT || !OUTPUT->covering)
        return;

    if (handedOff(monitor)) {
        release(*OUTPUT, "handoff");
        return;
    }

    holdStill(monitor);
}

void CScene::onRenderStage(const Event::SRenderStageEvent& event) {
    const auto OUTPUT = outputFor(event.monitor);
    if (!OUTPUT || !OUTPUT->covering)
        return;

    if (event.stage == RENDER_LAST_MOMENT && event.context)
        drawInPass(*OUTPUT, event.context->get());

    if (event.stage == RENDER_POST && event.monitor->m_output->state->state().buffer)
        dump(*OUTPUT, event.monitor->m_output->state->state().buffer, "pass");
}

void CScene::drawInPass(SOutput& output, Render::CRenderContext& ctx) {
    const auto  MONITOR = output.monitor.lock();
    const SSize SIZE    = {sc<int>(MONITOR->m_transformedSize.x), sc<int>(MONITOR->m_transformedSize.y)};
    const auto  BOX     = logoBox(SIZE, m_spec.refShortSide);
    const auto  LOGO    = logoFor(BOX.w);

    if (!LOGO->texture)
        LOGO->texture = g_pHyprRenderer->createTexture(LOGO->sprite->surface());

    // Hyprland turns blending on at the end of each frame and its texture draws rely on that,
    // so in the first frame it ever renders the logo would lose its alpha
    g_pHyprRenderer->blend(true);

    CRectPassElement::SRectData ground;
    ground.box   = CBox(0, 0, SIZE.w, SIZE.h);
    ground.color = CHyprColor(m_spec.background[0] / 255.F, m_spec.background[1] / 255.F, m_spec.background[2] / 255.F, 1.F);
    Render::IHyprRenderer::addPassElement(ctx, makeUnique<CRectPassElement>(ground));

    CTexPassElement::SRenderData logo;
    logo.tex = LOGO->texture;
    logo.box = CBox(BOX.x, BOX.y, BOX.w, BOX.h);
    Render::IHyprRenderer::addPassElement(ctx, makeUnique<CTexPassElement>(std::move(logo)));

    output.drawn = ctx.m_currentBuffer;
    output.passes++;
}

void CScene::dump(SOutput& output, SP<Aquamarine::IBuffer> buffer, const std::string& kind) {
    if (m_settings.dumpDir.empty() || output.dumps >= MAX_DUMPS)
        return;

    const auto MONITOR = output.monitor.lock();
    const auto RBO     = g_pHyprRenderer->getOrCreateRenderbuffer(buffer, MONITOR->m_drmFormat);
    if (!RBO)
        return;

    const int            W = buffer->size.x;
    const int            H = buffer->size.y;
    std::vector<uint8_t> rgba(sc<size_t>(W) * H * 4);

    RBO->bind();
    glReadPixels(0, 0, W, H, GL_RGBA, GL_UNSIGNED_BYTE, rgba.data());
    RBO->unbind();

    std::ofstream file(std::format("{}/{}-{}-{}.ppm", m_settings.dumpDir, MONITOR->m_name, output.dumps++, kind), std::ios::binary);
    file << "P6\n" << W << " " << H << "\n255\n";
    for (size_t i = 0; i < rgba.size(); i += 4)
        file.write(rc<const char*>(&rgba[i]), 3);
}
