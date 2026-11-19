#include "Scene.hpp"
#include "Log.hpp"

#include <hyprland/src/config/ConfigValue.hpp>
#include <hyprland/src/desktop/view/LayerSurface.hpp>
#include <hyprland/src/desktop/view/window/Window.hpp>
#include <hyprland/src/managers/SessionLockManager.hpp>
#include <hyprland/src/managers/eventLoop/EventLoopManager.hpp>
#include <hyprland/src/managers/input/InputManager.hpp>
#include <hyprland/src/output/Monitor.hpp>
#include <hyprland/src/pointer/PointerManager.hpp>
#include <hyprland/src/render/OpenGL.hpp>
#include <hyprland/src/render/Renderer.hpp>
#include <hyprland/src/render/pass/RectPassElement.hpp>
#include <hyprland/src/render/pass/TexPassElement.hpp>
#include <hyprland/src/state/MonitorState.hpp>
#include <aquamarine/backend/DRM.hpp>
#include <xf86drmMode.h>
#include <algorithm>
#include <fstream>
#include <memory>
#include <ranges>
#include <sstream>

using namespace Scene;

// readbacks per output while covering, during the fade, and after release
static constexpr std::array<int, 3> DUMP_BUDGET = {8, 1, 2};

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

// Hyprland keeps whether its wallpaper failed to load to itself. Without it a missing asset
// would hold every login for the full timeout.
struct SRendererState : Render::IHyprRenderer {
    static bool wallpaperFailed() {
        return (*g_pHyprRenderer).*(&SRendererState::m_backgroundResourceFailed);
    }
};

static long msBetween(Time::steady_tp from, Time::steady_tp to) {
    return static_cast<long>(std::chrono::duration_cast<Span>(to - from).count());
}

// a journal line stays short however many layers a client declared
static std::string joined(const std::vector<std::string>& items) {
    constexpr size_t SHOWN = 8;
    if (items.empty())
        return "none";

    std::string out;
    for (const auto& item : items | std::views::take(SHOWN))
        out += (out.empty() ? "" : ", ") + item;
    if (items.size() > SHOWN)
        out += std::format(" and {} more", items.size() - SHOWN);
    return out;
}

CScene::CScene(const SSettings& settings) : m_settings(settings) {
    logTo(m_settings.dumpDir);
    m_record.await = m_settings.await;

    std::ifstream     file(m_settings.dataDir + "/scene.json");
    std::stringstream text;
    text << file.rdbuf();
    m_spec = parseSpec(text.str());

    auto& events                    = Event::bus()->m_events;
    m_listeners.preCommit           = events.monitor.preCommit.listen([this](PHLMONITOR monitor) { onPreCommit(monitor); });
    m_listeners.renderPre           = events.render.pre.listen([this](PHLMONITOR monitor) { onRenderPre(monitor); });
    m_listeners.renderStage         = events.render.stage.listen([this](const Event::SRenderStageEvent& event) { onRenderStage(event); });
    m_listeners.layerOpened         = events.layer.opened.listen([this](PHLLS layer) { onLayer(layer, true); });
    m_listeners.layerClosed         = events.layer.closed.listen([this](PHLLS layer) { onLayer(layer, false); });
    m_listeners.windowOpen          = events.window.openLate.listen([this](PHLWINDOW window) { onWindowOpen(window); });
    m_listeners.monitorRemoved      = events.monitor.removed.listen([this](PHLMONITOR monitor) { onMonitorRemoved(monitor); });
    m_listeners.key                 = events.input.keyboard.key.listen([this](const IKeyboard::SKeyEvent& event, Event::SCallbackInfo& info) { onKey(event, info); });

    holdInput(events.input.mouse.button, "button");
    holdInput(events.input.mouse.axis, "axis");
    holdInput(events.input.touch.down, "touch");
    holdInput(events.input.touch.up, "touch");
    holdInput(events.input.touch.motion, "touch");
    holdInput(events.input.tablet.axis, "tablet");
    holdInput(events.input.tablet.button, "tablet");
    holdInput(events.input.tablet.proximity, "tablet");
    holdInput(events.input.tablet.tip, "tablet");
    holdInput(events.gesture.swipe.begin, "gesture");
    holdInput(events.gesture.swipe.update, "gesture");
    holdInput(events.gesture.swipe.end, "gesture");
    holdInput(events.gesture.pinch.begin, "gesture");
    holdInput(events.gesture.pinch.update, "gesture");
    holdInput(events.gesture.pinch.end, "gesture");

    note("scene: armed, ref_short_side {}, background #{:02x}{:02x}{:02x}, timeout {}, quiet {}, spread {}, fade {}, await_session {}", m_spec.refShortSide,
         m_spec.background[0], m_spec.background[1], m_spec.background[2], m_settings.bounds.timeout.count(), m_settings.bounds.quiet.count(),
         m_settings.bounds.spread.count(), m_settings.fade.count(), m_settings.await ? "yes" : "no");
}

CScene::~CScene() {
    if (m_state != eState::RELEASED) {
        note("scene: released at {:.3f}, unload while {}", monotonic(), m_state == eState::COVERING ? "covering" : "fading");
        // the last frame drawn still has the scene in it
        for (const auto& output : m_outputs) {
            if (const auto MONITOR = output->monitor.lock())
                g_pHyprRenderer->damageMonitor(MONITOR);
        }
    }

    unlockCursors();
    dropTimer();
}

template <typename TSignal>
void CScene::holdInput(TSignal& signal, const char* kind) {
    m_listeners.input.emplace_back(signal.listen([this, kind](const auto&, Event::SCallbackInfo& info) {
        if (swallow(kind))
            info.cancelled = true;
    }));
}

// The event loop holds the timer too, and its callback is code in this module. Left there,
// it would be destroyed after the module is unmapped.
void CScene::dropTimer() {
    if (!m_timer)
        return;

    g_pEventLoopManager->removeTimer(m_timer);
    m_timer.reset();
}

void CScene::wake(Span after) {
    if (m_timer)
        m_timer->updateTimeout(std::max(after, Span{1}));
}

void CScene::unlockCursors() {
    for (auto& output : m_outputs) {
        const auto MONITOR = output->monitor.lock();
        if (output->cursorLocked && MONITOR)
            Pointer::mgr()->unlockSoftwareForMonitor(MONITOR);
        output->cursorLocked = false;
    }
}

CScene::SOutput* CScene::outputFor(PHLMONITOR monitor) {
    for (auto& output : m_outputs) {
        if (output->monitor.expired())
            forget(*output);
    }
    std::erase_if(m_outputs, [](const auto& output) { return output->monitor.expired(); });

    for (auto& output : m_outputs) {
        if (output->monitor == monitor)
            return output.get();
    }

    if (m_state != eState::COVERING)
        return nullptr;

    const auto NOW = Time::steadyNow();
    if (!m_record.start) {
        m_record.start     = NOW;
        m_record.wallpaper = !*CConfigValue<Config::INTEGER>("misc:disable_hyprland_logo");
        // the bound holds from the moment the scene starts covering, whatever happens to the first frame
        m_timer = makeShared<CEventLoopTimer>(m_settings.bounds.timeout, [this](SP<CEventLoopTimer>, void*) { onTimer(); }, nullptr);
        g_pEventLoopManager->addTimer(m_timer);
    } else
        note("scene: output {} added while covering at {:.3f}", monitor->m_name, monotonic());

    auto& output    = m_outputs.emplace_back(makeUnique<SOutput>());
    output->monitor = monitor;
    output->name    = monitor->m_name;
    output->commit  = monitor->m_output->events.commit.listen([this, raw = output.get()] { logFirstCommit(*raw); });
    m_record.outputs.insert(output->name);

    // a cursor plane sits above anything drawn here
    Pointer::mgr()->lockSoftwareForMonitor(monitor);
    output->cursorLocked = true;

    return output.get();
}

void CScene::forget(const SOutput& output) {
    m_record.outputs.erase(output.name);
    m_record.wallpaperReady.erase(output.name);
}

void CScene::onMonitorRemoved(PHLMONITOR monitor) {
    const auto IT = std::ranges::find_if(m_outputs, [&monitor](const auto& output) { return output->monitor == monitor; });
    if (IT == m_outputs.end())
        return;

    if ((*IT)->cursorLocked)
        Pointer::mgr()->unlockSoftwareForMonitor(monitor);
    forget(**IT);
    m_outputs.erase(IT);

    if (m_state == eState::COVERING) {
        note("scene: output {} removed while covering at {:.3f}", monitor->m_name, monotonic());
        evaluate();
    }
}

CScene::SLogo* CScene::logoFor(int size) {
    auto it = m_logos.find(size);
    if (it != m_logos.end())
        return &it->second;

    auto sprite = makeUnique<CSprite>(m_settings.dataDir + "/logo.png", size);
    if (!sprite->good())
        return nullptr;

    return &m_logos.emplace(size, SLogo{.sprite = std::move(sprite), .texture = nullptr, .opaque = nullptr}).first->second;
}

// a new monitor renders zoomed in until five frames were presented, which would scale the scene
void CScene::holdStill(PHLMONITOR monitor) {
    monitor->m_zoomAnimFrameCounter = 5;
    monitor->m_zoomAnimProgress->setValueAndWarp(1.F);
}

void CScene::evaluate() {
    if (m_state != eState::COVERING)
        return;

    if (g_pSessionLockManager->isSessionLocked()) {
        fade(eReason::LOCK);
        return;
    }

    const auto NOW     = Time::steadyNow();
    const auto VERDICT = decide(m_record, m_settings.bounds, NOW);
    if (VERDICT.reason != eReason::HOLD)
        fade(VERDICT.reason);
    else if (VERDICT.next)
        wake(std::chrono::ceil<Span>(*VERDICT.next - NOW));
}

void CScene::fade(eReason reason) {
    if (m_state != eState::COVERING)
        return;

    const auto NOW = Time::steadyNow();
    m_state        = eState::FADING;
    m_reason       = reason;
    m_fadeStart    = NOW;

    note("scene: fading at {:.3f}, reason {}, {} after first frame, missing {}, dropped {} input events", monotonic(), reasonName(reason),
         m_record.start ? std::format("{}ms", msBetween(*m_record.start, NOW)) : "no frame", joined(missing(m_record, m_settings.bounds, NOW)), m_dropped);

    // the desktop is usable from this frame, so the cursor comes back with it
    unlockCursors();
    for (const auto& output : m_outputs) {
        if (const auto MONITOR = output->monitor.lock())
            g_pHyprRenderer->damageMonitor(MONITOR);
    }

    wake(m_settings.fade);
}

void CScene::finish() {
    m_state = eState::RELEASED;
    note("scene: released at {:.3f}, fade {}ms", monotonic(), msBetween(m_fadeStart, Time::steadyNow()));

    for (const auto& output : m_outputs) {
        if (const auto MONITOR = output->monitor.lock())
            g_pHyprRenderer->damageMonitor(MONITOR);
    }

    const bool DUMPING = !m_settings.dumpDir.empty();
    auto       stage   = std::move(m_listeners.renderStage);
    m_listeners        = {};
    m_logos.clear();
    m_swallowedKeys.clear();

    // a test reads back the frames after the scene is gone, and then the last listener goes
    if (DUMPING) {
        m_listeners.renderStage = std::move(stage);
        wake(Span{500});
        return;
    }

    m_outputs.clear();
    dropTimer();
}

void CScene::onTimer() {
    switch (m_state) {
        case eState::COVERING: evaluate(); break;
        case eState::FADING:
            if (Time::steadyNow() - m_fadeStart >= m_settings.fade)
                finish();
            else
                wake(std::chrono::ceil<Span>(m_settings.fade - (Time::steadyNow() - m_fadeStart)));
            break;
        case eState::RELEASED:
            m_listeners = {};
            m_outputs.clear();
            dropTimer();
            break;
    }
}

bool CScene::swallow(const char* kind) {
    if (m_state != eState::COVERING)
        return false;

    // the lock screen takes input as soon as it exists
    if (g_pSessionLockManager->isSessionLocked()) {
        fade(eReason::LOCK);
        return false;
    }

    if (m_dropped++ == 0)
        note("scene: holding input, first dropped {} at {:.3f}", kind, monotonic());
    return true;
}

void CScene::onKey(const IKeyboard::SKeyEvent& event, Event::SCallbackInfo& info) {
    if (event.state != WL_KEYBOARD_KEY_STATE_PRESSED) {
        // a client that never saw the press must not see its release either
        if (m_swallowedKeys.erase(event.keycode))
            info.cancelled = true;
        return;
    }

    // Ctrl+Alt reaches Hyprland's VT switch, so the text console stays one chord away
    const auto MODS = g_pInputManager->getModsFromAllKBs();
    if ((MODS & Input::HL_MODIFIER_CTRL) == Input::HL_MODIFIER_CTRL && (MODS & Input::HL_MODIFIER_ALT) == Input::HL_MODIFIER_ALT)
        return;

    if (swallow("key")) {
        info.cancelled = true;
        m_swallowedKeys.insert(event.keycode);
    }
}

void CScene::onLayer(PHLLS layer, bool opened) {
    if (m_state == eState::RELEASED || !layer)
        return;

    // released at rest, so nothing is still fading in when the scene lifts
    if (opened) {
        layer->finishAnimation();
        layer->alpha().warp();
    }

    const auto MONITOR = layer->m_monitor.lock();
    if (m_state != eState::COVERING || !MONITOR)
        return;

    if (!opened)
        unmapLayer(m_record, layer->m_namespace, MONITOR->m_name);
    else if (!layer->m_geometry.empty() && mapLayer(m_record, layer->m_namespace, MONITOR->m_name, Time::steadyNow())) {
        const auto& MAPPED = m_record.expect.at(layer->m_namespace);
        const auto  SHOWN  = std::ranges::count_if(m_record.outputs, [&MAPPED](const auto& name) { return MAPPED.contains(name); });
        note("scene: layer {} mapped on {} at {:.3f}, {} of {} outputs", layer->m_namespace, MONITOR->m_name, monotonic(), SHOWN, m_record.outputs.size());
    }

    evaluate();
}

void CScene::onWindowOpen(PHLWINDOW window) {
    if (m_state == eState::RELEASED || !window)
        return;

    window->finishAnimation();
    window->alpha().warp();
}

// a layer that mapped before its component declared it still counts
void CScene::seed(const std::string& name) {
    const auto NOW = Time::steadyNow();
    for (const auto& monitor : State::monitorState()->allMonitors()) {
        for (const auto& layers : monitor->m_layerSurfaceLayers) {
            for (const auto& ref : layers) {
                const auto SURFACE = ref.lock();
                if (SURFACE && SURFACE->mapped() && SURFACE->m_namespace == name && !SURFACE->m_geometry.empty())
                    mapLayer(m_record, name, monitor->m_name, NOW);
            }
        }
    }
}

void CScene::checkWallpaper(SOutput& output) {
    if (!m_record.wallpaper || m_record.wallpaperReady.contains(output.name))
        return;

    const auto MONITOR = output.monitor.lock();
    if (!MONITOR)
        return;

    const bool SHOWN = MONITOR->m_background != nullptr;
    if (!SHOWN && !SRendererState::wallpaperFailed())
        return;

    if (SHOWN)
        MONITOR->m_backgroundOpacity->warp();
    m_record.wallpaperReady.insert(output.name);
    note("scene: background {} on {} at {:.3f}", SHOWN ? "ready" : "failed", output.name, monotonic());
    evaluate();
}

std::string CScene::command(std::string_view request) {
    const auto PARSED = parseCommand(request);
    if (!PARSED)
        return "error: " + PARSED.error();

    if (PARSED->verb == eVerb::SHOW)
        return describe();

    if (m_state != eState::COVERING)
        return "ok, the scene is already released";

    const auto NOW = Time::steadyNow();
    switch (PARSED->verb) {
        case eVerb::EXPECT:
            if (!expectLayer(m_record, PARSED->name, NOW))
                return std::format("error: the scene already expects {} layers", MAX_EXPECTED);
            note("scene: expect layer {} at {:.3f}", PARSED->name, monotonic());
            seed(PARSED->name);
            break;
        case eVerb::DROP:
            dropLayer(m_record, PARSED->name, NOW);
            note("scene: drop layer {} at {:.3f}", PARSED->name, monotonic());
            break;
        case eVerb::READY:
            sessionReady(m_record, NOW);
            note("scene: session ready at {:.3f}", monotonic());
            break;
        case eVerb::RELEASE:
            note("scene: release asked by {} at {:.3f}", PARSED->name, monotonic());
            fade(eReason::MANUAL);
            return "ok";
        case eVerb::SHOW: break;
    }

    evaluate();
    return "ok";
}

std::string CScene::describe() const {
    const auto  NOW   = Time::steadyNow();
    const auto  STATE = m_state == eState::COVERING ? "covering" : m_state == eState::FADING ? "fading" : "released";
    const auto  LIST  = [](const auto& names) {
        std::string out;
        for (const auto& name : names)
            out += (out.empty() ? "" : ",") + jsonString(name);
        return "[" + out + "]";
    };

    std::string expect;
    for (const auto& [name, mapped] : m_record.expect)
        expect += std::format("{}{}:{}", expect.empty() ? "" : ",", jsonString(name), LIST(mapped | std::views::keys));

    return std::format(R"({{"state":"{}","reason":"{}","await":{},"session":{},"held_ms":{},"outputs":{},"expect":{{{}}},"wallpaper":{{"drawn":{},"ready":{}}},)"
                       R"("missing":{},"dropped":{}}})",
                       STATE, reasonName(m_reason), m_record.await, m_record.session, m_record.start ? msBetween(*m_record.start, NOW) : 0, LIST(m_record.outputs), expect,
                       m_record.wallpaper, LIST(m_record.wallpaperReady), LIST(missing(m_record, m_settings.bounds, NOW)), m_dropped);
}

void CScene::onPreCommit(PHLMONITOR monitor) {
    const auto& STATE = monitor->m_output->state->state();
    const auto  MODE  = STATE.mode ? STATE.mode.lock() : STATE.customMode;
    if (!STATE.enabled || !MODE)
        return;

    const auto OUTPUT = outputFor(monitor);
    if (!OUTPUT || m_state != eState::COVERING)
        return;

    holdStill(monitor);

    auto buffer = STATE.buffer;
    if (buffer && buffer == OUTPUT->drawn)
        return;

    const auto SWAPCHAIN = monitor->m_output->swapchain;
    const bool FITS      = buffer && buffer->size == MODE->pixelSize;

    // a buffer that fits the mode and is not the output's own is a client's, scanned out as it is
    if (FITS && !SWAPCHAIN->contains(buffer)) {
        if (!OUTPUT->foreign)
            note("scene: {} commits a buffer that is not its own, leaving it as it is", monitor->m_name);
        OUTPUT->foreign = true;
        return;
    }

    // the backend swaps in a blank swapchain buffer when this one does not fit the mode
    if (!FITS) {
        buffer = SWAPCHAIN->next(nullptr);
        SWAPCHAIN->rollback();
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
    if (!LOGO) {
        note("scene: a logo.png that cannot be drawn at {}px", BOX.w);
        fade(eReason::BROKEN);
        return;
    }

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
    if (!OUTPUT)
        return;

    if (m_state == eState::COVERING) {
        evaluate();
        holdStill(monitor);
    }

    // every frame of the fade redraws the whole output, and asks for the next
    if (m_state == eState::FADING)
        g_pHyprRenderer->damageMonitor(monitor);
}

void CScene::onRenderStage(const Event::SRenderStageEvent& event) {
    const auto OUTPUT = outputFor(event.monitor);
    if (!OUTPUT)
        return;

    if (event.stage == RENDER_LAST_MOMENT && event.context && m_state != eState::RELEASED)
        drawInPass(*OUTPUT, event.context->get());

    if (event.stage != RENDER_POST)
        return;

    if (m_state == eState::COVERING)
        checkWallpaper(*OUTPUT);

    const auto BUFFER = event.monitor->m_output->state->state().buffer;
    if (!BUFFER)
        return;

    dump(*OUTPUT, BUFFER, m_state == eState::COVERING ? "pass" : m_state == eState::FADING ? "fade" : "after");
}

float CScene::alpha() const {
    if (m_state == eState::COVERING)
        return 1.F;
    if (m_state == eState::RELEASED || m_settings.fade.count() <= 0)
        return 0.F;

    const std::chrono::duration<float> ELAPSED = Time::steadyNow() - m_fadeStart;
    const std::chrono::duration<float> FADE    = m_settings.fade;
    return std::clamp(1.F - ELAPSED / FADE, 0.F, 1.F);
}

static cairo_surface_t* overGround(const CSprite& sprite, const std::array<uint8_t, 3>& ground) {
    const auto SURFACE = cairo_image_surface_create(CAIRO_FORMAT_ARGB32, sprite.size(), sprite.size());
    const auto CR      = cairo_create(SURFACE);
    cairo_set_source_rgb(CR, ground.at(0) / 255.0, ground.at(1) / 255.0, ground.at(2) / 255.0);
    cairo_paint(CR);
    cairo_set_source_surface(CR, sprite.surface(), 0, 0);
    cairo_paint(CR);
    cairo_destroy(CR);
    cairo_surface_flush(SURFACE);
    return SURFACE;
}

void CScene::drawInPass(SOutput& output, Render::CRenderContext& ctx) {
    const auto  MONITOR = output.monitor.lock();
    const SSize SIZE    = {sc<int>(MONITOR->m_transformedSize.x), sc<int>(MONITOR->m_transformedSize.y)};
    const auto  BOX     = logoBox(SIZE, m_spec.refShortSide);
    const auto  LOGO    = logoFor(BOX.w);
    const float ALPHA   = alpha();
    if (!LOGO) {
        note("scene: a logo.png that cannot be drawn at {}px", BOX.w);
        fade(eReason::BROKEN);
        return;
    }
    if (ALPHA <= 0.F)
        return;

    // Hyprland turns blending on at the end of each frame and its texture draws rely on that,
    // so in the first frame it ever renders the logo would lose its alpha
    g_pHyprRenderer->blend(true);

    const auto GROUND = CHyprColor(m_spec.background[0] / 255.F, m_spec.background[1] / 255.F, m_spec.background[2] / 255.F, ALPHA);
    const auto RECT   = [&ctx, &GROUND](double x, double y, double w, double h) {
        if (w <= 0 || h <= 0)
            return;
        CRectPassElement::SRectData ground;
        ground.box   = CBox(x, y, w, h);
        ground.color = GROUND;
        Render::IHyprRenderer::addPassElement(ctx, makeUnique<CRectPassElement>(ground));
    };

    CTexPassElement::SRenderData logo;
    logo.box = CBox(BOX.x, BOX.y, BOX.w, BOX.h);

    if (ALPHA >= 1.F) {
        if (!LOGO->texture)
            LOGO->texture = g_pHyprRenderer->createTexture(LOGO->sprite->surface());
        RECT(0, 0, SIZE.w, SIZE.h);
        logo.tex = LOGO->texture;
    } else {
        // the ground around the logo and the logo over its own ground, so every pixel blends once
        if (!LOGO->opaque) {
            const auto SURFACE = overGround(*LOGO->sprite, m_spec.background);
            LOGO->opaque       = g_pHyprRenderer->createTexture(SURFACE);
            cairo_surface_destroy(SURFACE);
        }
        RECT(0, 0, SIZE.w, BOX.y);
        RECT(0, BOX.y + BOX.h, SIZE.w, SIZE.h - BOX.y - BOX.h);
        RECT(0, BOX.y, BOX.x, BOX.h);
        RECT(BOX.x + BOX.w, BOX.y, SIZE.w - BOX.x - BOX.w, BOX.h);
        logo.tex = LOGO->opaque;
        logo.a   = ALPHA;
    }
    Render::IHyprRenderer::addPassElement(ctx, makeUnique<CTexPassElement>(std::move(logo)));

    output.drawn = ctx.m_currentBuffer;
    output.passes++;
}

void CScene::dump(SOutput& output, SP<Aquamarine::IBuffer> buffer, const std::string& kind) {
    const size_t PHASE = static_cast<size_t>(m_state);
    if (m_settings.dumpDir.empty() || output.dumped.at(PHASE) >= DUMP_BUDGET.at(PHASE))
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

    const auto NAME = std::format("{}-{}-{}.ppm", MONITOR->m_name, output.dumps++, kind);
    output.dumped.at(PHASE)++;

    std::ofstream file(std::format("{}/{}", m_settings.dumpDir, NAME), std::ios::binary);
    file << "P6\n" << W << " " << H << "\n255\n";
    for (size_t i = 0; i < rgba.size(); i += 4)
        file.write(rc<const char*>(&rgba[i]), 3);

    if (m_state != eState::COVERING)
        note("scene: dumped {} at {:.3f}", NAME, monotonic());

    // a second frame after release shows whether anything was still moving
    if (m_state == eState::RELEASED)
        g_pHyprRenderer->damageMonitor(MONITOR);
}
