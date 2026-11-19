#pragma once

#include "FirstFrame.hpp"
#include "Geometry.hpp"
#include "Readiness.hpp"
#include "Spec.hpp"
#include "Sprite.hpp"

#include <hyprland/src/desktop/DesktopTypes.hpp>
#include <hyprland/src/event/EventBus.hpp>
#include <hyprland/src/helpers/signal/Signal.hpp>
#include <hyprland/src/helpers/time/Time.hpp>
#include <hyprland/src/managers/eventLoop/EventLoopTimer.hpp>
#include <hyprland/src/render/Texture.hpp>
#include <aquamarine/buffer/Buffer.hpp>
#include <array>
#include <map>
#include <string>
#include <string_view>
#include <vector>

namespace Scene {
    struct SSettings {
        std::string dataDir;
        SBounds     bounds;
        Span        fade;
        bool        await = false;
        std::string dumpDir;
    };

    class CScene {
      public:
        CScene(const SSettings& settings);
        ~CScene();

        CScene(const CScene&)            = delete;
        CScene&     operator=(const CScene&) = delete;

        std::string command(std::string_view request);

      private:
        enum class eState : uint8_t {
            COVERING,
            FADING,
            RELEASED,
        };

        struct SOutput {
            PHLMONITORREF monitor;
            std::string   name;
            // the buffer the scene was last drawn into; a commit of any other buffer needs a first frame
            WP<Aquamarine::IBuffer> drawn;
            CHyprSignalListener     commit;
            bool                    cursorLocked = false;
            bool                    logged       = false;
            bool                    foreign      = false;
            int                     passes       = 0;
            int                     dumps        = 0;
            std::array<int, 3> dumped = {};
        };

        struct SLogo {
            UP<CSprite>          sprite;
            SP<Render::ITexture> texture;
            // the logo over the ground, so a fading scene blends with the desktop as one image
            SP<Render::ITexture> opaque;
        };

        void                     onPreCommit(PHLMONITOR monitor);
        void                     onRenderPre(PHLMONITOR monitor);
        void                     onRenderStage(const Event::SRenderStageEvent& event);
        void                     onLayer(PHLLS layer, bool opened);
        void                     onWindowOpen(PHLWINDOW window);
        void                     onMonitorRemoved(PHLMONITOR monitor);
        void                     onTimer();

        class CKeyHold;
        template <typename TSignal>
        void                     holdInput(TSignal& signal, const char* kind);
        bool                     swallow(const char* kind);
        void                     drop(const char* kind);
        void                     holdKeys();
        void                     releaseKeys();

        void                     evaluate();
        void                     fade(eReason reason);
        void                     finish();
        void                     unlockCursors();
        void                     dropTimer();
        void                     wake(Span after);

        SOutput*                 outputFor(PHLMONITOR monitor);
        void                     forget(const SOutput& output);
        void                     countOutputs();
        SLogo*                   logoFor(int size);
        void                     holdStill(PHLMONITOR monitor);
        void                     seed(const std::string& name);
        void                     checkWallpaper(SOutput& output);
        void                     drawFirstFrame(SOutput& output, SP<Aquamarine::IBuffer> buffer);
        void                     drawInPass(SOutput& output, Render::CRenderContext& ctx);
        void                     logFirstCommit(SOutput& output);
        void                     dump(SOutput& output, SP<Aquamarine::IBuffer> buffer, const std::string& kind);
        std::string              describe() const;
        float                    alpha() const;

        SSettings                m_settings;
        SSpec                    m_spec;
        eState                   m_state = eState::COVERING;
        eReason                  m_reason = eReason::HOLD;
        SRecord                  m_record;
        Time::steady_tp          m_fadeStart;
        int                      m_dropped       = 0;
        bool                     m_fallbackNoted = false;
        SP<CKeyHold>             m_keyHold;

        std::vector<UP<SOutput>> m_outputs;
        std::map<int, SLogo>     m_logos;
        CFirstFrame              m_firstFrame;
        SP<CEventLoopTimer>      m_timer;

        struct {
            CHyprSignalListener              preCommit;
            CHyprSignalListener              renderPre;
            CHyprSignalListener              renderStage;
            CHyprSignalListener              layerOpened;
            CHyprSignalListener              layerClosed;
            CHyprSignalListener              windowOpen;
            CHyprSignalListener              monitorRemoved;
            CHyprSignalListener              lock;
            std::vector<CHyprSignalListener> input;
        } m_listeners;
    };
}
