#pragma once

#include "FirstFrame.hpp"
#include "Geometry.hpp"
#include "Spec.hpp"
#include "Sprite.hpp"

#include <hyprland/src/desktop/DesktopTypes.hpp>
#include <hyprland/src/event/EventBus.hpp>
#include <hyprland/src/helpers/signal/Signal.hpp>
#include <hyprland/src/helpers/time/Time.hpp>
#include <hyprland/src/managers/eventLoop/EventLoopTimer.hpp>
#include <hyprland/src/render/Texture.hpp>
#include <aquamarine/buffer/Buffer.hpp>
#include <map>
#include <string>
#include <vector>

namespace Scene {
    struct SSettings {
        std::string      dataDir;
        std::string      handoffNamespace;
        Time::steady_dur timeout;
        std::string      dumpDir;
    };

    class CScene {
      public:
        CScene(const SSettings& settings);
        ~CScene();

      private:
        struct SOutput {
            PHLMONITORREF monitor;
            // the buffer the scene was last drawn into; a commit of any other buffer needs a first frame
            WP<Aquamarine::IBuffer> drawn;
            CHyprSignalListener     commit;
            bool                    covering = true;
            bool                    logged   = false;
            int                     passes   = 0;
            int                     dumps    = 0;
        };

        struct SLogo {
            UP<CSprite>          sprite;
            SP<Render::ITexture> texture;
        };

        void                     onPreCommit(PHLMONITOR monitor);
        void                     onRenderPre(PHLMONITOR monitor);
        void                     onRenderStage(const Event::SRenderStageEvent& event);
        void                     onTimeout();

        SOutput*                 outputFor(PHLMONITOR monitor);
        SLogo*                   logoFor(int size);
        void                     holdStill(PHLMONITOR monitor);
        bool                     handedOff(PHLMONITOR monitor);
        void                     release(SOutput& output, const std::string& reason);
        void                     drawFirstFrame(SOutput& output, SP<Aquamarine::IBuffer> buffer);
        void                     drawInPass(SOutput& output, Render::CRenderContext& ctx);
        void                     logFirstCommit(SOutput& output);
        void                     dump(SOutput& output, SP<Aquamarine::IBuffer> buffer, const std::string& kind);

        SSettings                m_settings;
        SSpec                    m_spec;
        bool                     m_expired = false;

        std::vector<UP<SOutput>> m_outputs;
        std::map<int, SLogo>     m_logos;
        CFirstFrame              m_firstFrame;
        SP<CEventLoopTimer>      m_timer;

        struct {
            CHyprSignalListener preCommit;
            CHyprSignalListener renderPre;
            CHyprSignalListener renderStage;
        } m_listeners;
    };
}
