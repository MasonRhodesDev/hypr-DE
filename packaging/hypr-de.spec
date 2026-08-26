Name:           hypr-de
Version:        0.2.28
Release:        1%{?dist}
Summary:        Alpha Hyprland config set (not ready)

License:        MIT
URL:            https://github.com/MasonRhodesDev/hypr-DE
Source0:        %{url}/archive/v%{version}/hypr-DE-%{version}.tar.gz

BuildArch:      noarch
BuildRequires:  systemd-rpm-macros
BuildRequires:  file
# %%check's gen-deps.sh drift gate parses deps.toml with python3/tomllib
BuildRequires:  python3
# %check drives the waybar colorpicker, which builds its JSON with jq.
BuildRequires:  jq

# Runtime deps are generated from deps.toml — edit THAT file and re-run
# packaging/gen-deps.sh print fedora main; CI (gen-deps.sh check) gates drift.
Requires:       SwayNotificationCenter
Requires:       bluez
Requires:       bluez-obexd
Requires:       brightnessctl
Requires:       fira-code-fonts
Requires:       fuzzel
Requires:       gnome-keyring
Requires:       google-noto-sans-fonts
Recommends:     gpu-screen-recorder
Requires:       grim
Requires:       gtk4
Requires:       hypridle >= 0.1.8
Requires:       hyprland >= 0.56
Requires:       hyprland-guiutils
Requires:       hyprland-qt-support
Requires:       hyprland-workspace-zones
Requires:       hyprpicker
Requires:       hyprpolkitagent
Requires:       hyprpwcenter
Requires:       hyprshutdown
Requires:       hyprstate >= 2.5.0
Requires:       dials
Requires:       jetbrains-mono-fonts
# Nerd variants come from hypr-de-extras (none exist in Fedora proper); the
# waybar/swaync stylesheets request these families by name
Requires:       jetbrains-mono-nerd-fonts
Requires:       jq
Requires:       kitty
Requires:       neovim
Requires:       libadwaita
Requires:       /usr/bin/notify-send
Requires:       lmtt
Requires:       logind-idle-control >= 0.2.4
Requires:       man-db
Requires:       matugen
Requires:       nautilus
Requires:       NetworkManager
Requires:       network-manager-applet
Requires:       nerd-fonts-symbols
Requires:       overskride
Requires:       papirus-icon-theme
Requires:       pavucontrol
Requires:       pipewire
Requires:       pipewire-alsa
Requires:       pipewire-pulseaudio
Requires:       playerctl
Requires:       python3
Requires:       python3-dbus
Requires:       python3-gobject
# nett00n's uwsm RPM omits this; without the xdg module uwsm tracebacks on
# import and every greeter login dies instantly (see deps.toml [session])
Requires:       python3-pyxdg
Requires:       qt6ct
Requires:       slurp
Requires:       sni-watcher
Requires:       socat
Requires:       swappy
Requires:       swaybg
Requires:       udiskie
Requires:       uwsm
Requires:       vigil >= 0.3.0
Requires:       waybar
Requires:       waybar-workspace-buttons >= 1.1.2
Requires:       wireplumber
Requires:       wl-clipboard
Requires:       xdg-desktop-portal
Requires:       xdg-desktop-portal-gtk
Requires:       xdg-desktop-portal-hyprland

Recommends:     hyprsunset
Recommends:     satty

%description
hypr-DE is alpha and not ready. It composes supporting tools that need to
stabilize first.

hypr-DE is a packaged Hyprland configuration and the runtime packages it
needs: compositor Lua config, waybar, swaync with notification recovery,
fuzzel, Material You theming via lmtt, monitor profiles via hyprstate,
screenshot/recording tooling. It is not a greeter session. Log into
Hyprland (uwsm-managed) from the Hyprland package; hypr-DE supplies /etc/xdg and
/usr defaults plus a thin per-user override surface (~/.config/hypr/local.lua,
lmtt module shadowing, systemd drop-ins).

NOTE: requires a Lua-config-capable Hyprland build; distro packages older
than the Lua config API cannot run this configuration (see README).

%package gaming
Summary:        Gaming additions for hypr-DE (game workspace routing, Steam session hygiene)
Requires:       hypr-de = %{version}-%{release}
Requires:       python3
Recommends:     steam
Recommends:     gamemode

%description gaming
Optional gaming layer: routes games to a chrome-less idle-inhibited
workspace, focuses Steam Big Picture on controller wake, and cleans up Steam
scopes on session shutdown. Opt in by adding
  dofile("/usr/share/hypr-de/gaming/game-rules.lua")
to ~/.config/hypr/local.lua and enabling the bp-game-focus /
steam-clean-shutdown user units.

%prep
%autosetup -n hypr-DE-%{version}

%build
cp -a dist dist-build
LIBEXECDIR=%{_libexecdir}/hypr-de \
WAYBAR_CFFI=%{_libdir}/waybar/workspace_buttons.so \
    ./packaging/substitute.sh dist-build
# lmtt modules install under the generic system module dir
mkdir -p dist-build/lmtt-system-modules
mv dist-build/lmtt/modules/* dist-build/lmtt-system-modules/

%check
# Syntax-check every shipped shell script, the Lua payload, and Python helpers
find dist-build/bin dist-build/libexec -type f -exec sh -c 'head -1 "$1" | grep -q "^#!/bin/bash" && bash -n "$1"' _ {} \;
find dist-build/bin dist-build/libexec -type f -exec sh -c 'head -1 "$1" | grep -q python && python3 -m py_compile "$1"' _ {} \;
./packaging/gen-deps.sh check
./packaging/check-units.sh
./tests/lock-policy.sh
./tests/command-construction.sh
./tests/user-config-safety.sh
./tests/privacy-privilege.sh
./tests/installer-trust.sh
./tests/steam-launch-options.sh
./tests/runtime-paths.sh
./tests/pam-rewrite.sh
./tests/share-consent.sh

%install
LIBEXECDIR=%{_libexecdir}/hypr-de \
    ./packaging/install.sh dist-build %{buildroot} main
LIBEXECDIR=%{_libexecdir}/hypr-de \
    ./packaging/install.sh dist-build %{buildroot} gaming
# lmtt system modules (searched by lmtt's system module path)
install -d %{buildroot}%{_datadir}/lmtt/modules
install -Dpm644 dist-build/lmtt-system-modules/* -t %{buildroot}%{_datadir}/lmtt/modules/

%post
%systemd_user_post swaybg.service waybar-reload.path waybar-reload.service waybar-watchdog.service waybar-watchdog.timer wayland-env-guard.path wayland-env-guard.service wayland-env-guard.timer hyprland-configreload-listener.service hypr-de-prime-theme.service logind-idle-control-tray.service
%{_libexecdir}/hypr-de/hypr-de-sys-setup >/dev/null 2>&1 || :

%posttrans
# Same reason as the Arch pacman hook: rpm replaces watched config files by
# unlinking and rewriting them, which can latch a bogus Hyprland config
# error banner on a live session. Reload once, best-effort.
%{_libexecdir}/hypr-de/hypr-de-reload-sessions >/dev/null 2>&1 || :

%preun
%systemd_user_preun swaybg.service waybar-reload.path waybar-reload.service waybar-watchdog.service waybar-watchdog.timer wayland-env-guard.path wayland-env-guard.service wayland-env-guard.timer hyprland-configreload-listener.service hypr-de-prime-theme.service logind-idle-control-tray.service

%post gaming
%systemd_user_post bp-game-focus.service steam-clean-shutdown.service

%preun gaming
%systemd_user_preun bp-game-focus.service steam-clean-shutdown.service

%files
%license LICENSE
%doc README.md
%{_bindir}/hypr-de-setup
%{_bindir}/hypr-de-set-wallpaper
%{_bindir}/hypr-de-snip
%{_bindir}/hypr-de-record
%{_bindir}/hypr-de-theme
%{_bindir}/hypr-de-help
%{_mandir}/man1/hypr-de-help.1*
%{_mandir}/man7/hypr-de.7*
%{_libexecdir}/hypr-de/
%exclude %{_libexecdir}/hypr-de/bp-game-focus.py
%exclude %{_libexecdir}/hypr-de/steam-clean-shutdown.sh
%{_datadir}/hypr-de/
%exclude %{_datadir}/hypr-de/gaming/
%{_datadir}/lmtt/modules/hypr-de-waybar.toml
%{_datadir}/lmtt/modules/hypr-de-swaync.toml
%{_datadir}/lmtt/modules/hypr-de-nvim.toml
%{_prefix}/lib/systemd/user/*
%exclude %{_prefix}/lib/systemd/user/bp-game-focus.service
%exclude %{_prefix}/lib/systemd/user/steam-clean-shutdown.service
%exclude %{_prefix}/lib/systemd/user/app-.scope.d/
%{_prefix}/lib/systemd/user-preset/90-hypr-de.preset
%{_prefix}/lib/environment.d/60-hypr-de.conf
%config(noreplace) %{_sysconfdir}/xdg/uwsm/env
%config(noreplace) %{_sysconfdir}/xdg/uwsm/env-hyprland
%{_datadir}/nvim/site/plugin/hypr-de-defaults.lua
%{_datadir}/nvim/site/colors/lmtt-material-you.lua
%config(noreplace) %{_sysconfdir}/greetd/vigil.toml
%{_sysconfdir}/xdg/hypr/hyprland.lua

%files gaming
%{_datadir}/hypr-de/gaming/
%{_libexecdir}/hypr-de/bp-game-focus.py
%{_libexecdir}/hypr-de/steam-clean-shutdown.sh
%{_bindir}/steam-set-launch-options
%{_prefix}/lib/systemd/user/bp-game-focus.service
%{_prefix}/lib/systemd/user/steam-clean-shutdown.service
%{_prefix}/lib/systemd/user/app-.scope.d/
%{_prefix}/lib/systemd/user-preset/90-hypr-de-gaming.preset
%{_prefix}/lib/environment.d/70-hypr-de-gaming.conf

%changelog
* Wed Aug 26 2026 Mason Rhodes <mrhodesdev@gmail.com> - 0.2.28-1
- Drop the idle-inhibitor check from the locked-screen condition. Being
  locked while the toggle is held is unreachable -- the idle lock obeys the
  toggle rather than surviving it, every deliberate lock releases it, and
  the tray is behind the lock surface -- so the check was dead code that
  also put a subprocess on hypridle's synchronous condition path.

* Tue Aug 26 2026 Mason Rhodes <mrhodesdev@gmail.com> - 0.2.27-1
- Require logind-idle-control >= 0.2.4. Below that it holds only a logind
  idle inhibitor, which hypridle cannot see, so the toggle never suppressed
  the 180 s idle lock and the session locked itself with the inhibitor on.

* Tue Aug 25 2026 Mason Rhodes <mrhodesdev@gmail.com> - 0.2.26-1
- A locked screen now stays lit while the user's own idle inhibitor is on.
  0.2.25 blanked it regardless, which defeated the point of holding one.
  Only the deliberate logind-idle-control toggle counts: the listener keeps
  ignore_inhibit, so Wayland surface inhibitors and ScreenSaver D-Bus
  cookies -- which video players and browsers set silently -- cannot hold a
  locked screen lit, and session-locked.sh re-admits the toggle alone.
- Locking on purpose (manual or before-sleep) releases a held idle
  inhibitor: deliberately locking ends the session's claim to stay awake,
  so the screen is free to blank. The idle lock deliberately does not --
  an inhibitor is exactly the signal that the session was meant to stay up.

* Tue Aug 25 2026 Mason Rhodes <mrhodesdev@gmail.com> - 0.2.25-1
- Lock scripts resolve the logind session by id: `loginctl show-session
  self` never worked from hypridle's cgroup, so the 240 s blank ignored the
  lock and lock-cmd.sh could not confirm one.
- hypridle owns locked-screen blanking: a 30 s input-idle listener
  (ignore_inhibit, condition_cmd=session-locked.sh on the compositor lock,
  condition_retry, lock-aware on-timeout) blanks locked outputs whether or
  not an inhibitor is held and never re-blanks a screen the user just woke
  (hyprstate#24). Requires hypridle >= 0.1.8 and hyprstate >= 2.5.0.
- The unlocked 240 s blanker is gone: an unlocked session is never blanked,
  since a dark screen over a live desktop is indistinguishable from a locked
  one and hyprstate 2.5.0 relit it a tick later regardless.
- No DPMS poke after an idle lock; tests/lock-policy.sh runs in CI.

* Mon Aug 24 2026 Mason Rhodes <mrhodesdev@gmail.com> - 0.2.24-1
- Require hyprland-workspace-zones on Fedora: the zones compositor plugin is
  stack-managed now (RPM pinned to the exact hyprland version) instead of a
  manual local rebuild, so zones keybinds work on a fresh install.

* Mon Aug 24 2026 Mason Rhodes <mrhodesdev@gmail.com> - 0.2.23-1
- Retire the notification-focus-proxy service; the swaync action-script hook
  is the sole click-to-focus path.
- Stop focusing the sender window when a notification is dismissed via the
  close button or Clear All.

* Sun Aug 23 2026 Mason Rhodes <mrhodesdev@gmail.com> - 0.2.22-1
- Reload live Hyprland sessions after an upgrade so replacing a watched config
  file can no longer leave a stale "Your config has errors" banner on screen.

* Sun Aug 23 2026 Mason Rhodes <mrhodesdev@gmail.com> - 0.2.21-1
- Ship the Neovim baseline in /usr/share/nvim/site instead of /etc/xdg/nvim/sysinit.vim, which the neovim package owns (0.2.20 aborted every Arch install with a file conflict).

* Sun Aug 23 2026 Mason Rhodes <mrhodesdev@gmail.com> - 0.2.20-1
- Declare the new deps in deps.toml (neovim, waybar-workspace-buttons floor); 0.2.19 failed its dependency drift gate.

* Sun Aug 23 2026 Mason Rhodes <mrhodesdev@gmail.com> - 0.2.19-1
- Default editor: install neovim, set EDITOR/VISUAL, hypr-de-help resolves a real editor (fixes the nano-missing failure).
- Ship a package-owned Neovim config + lmtt Material You colorscheme module.
- hypr-de-help view tabs get symbolic icons (no more missing-icon placeholders).
- swaync stylesheet is self-contained (colors inline) so the control-center is no longer transparent.
- Enable logind-idle-control-tray so the idle inhibitor shows in the waybar tray.
- Floor waybar-workspace-buttons at 1.1.2: older builds dispatch the classic
  'hyprctl dispatch workspace N', which newer Hyprland parses as Lua and
  rejects, so clicking a workspace button silently did nothing.

* Sat Aug 22 2026 Mason Rhodes <mrhodesdev@gmail.com> - 0.2.18-1
- Depend on dials (formerly hyprstate-gui); voice dictation is wayland-voice-dictation.

* Thu Aug 20 2026 Mason Rhodes <mrhodesdev@gmail.com> - 0.2.14-1
- Add the cancelable Vigil frost warning only to idle-triggered locks.
- Keep manual and before-sleep locks immediate and enable safe lock restore.

* Thu Aug 20 2026 Mason Rhodes <mrhodesdev@gmail.com> - 0.2.12-1
- Make Voice Dictation an independently installed optional suite application.
- Stop requiring, enabling, or validating its service from Hypr-DE.

* Tue Aug 18 2026 Mason Rhodes <mrhodesdev@gmail.com> - 0.2.11-1
- First-boot hypr-de-setup applies the packaged gradient theme when none
  is recorded, so lmtt-colors.lua and waybar.css exist before first login
- User-facing copy names the greeter entry Hyprland (uwsm-managed)
- Wallpaper re-render uses --no-notify when no Wayland display so setup
  does not stall waiting for a notification daemon

* Mon Aug 17 2026 Mason Rhodes <mrhodesdev@gmail.com> - 0.2.10-1
- prime-theme passes --no-notify: its notification blocked on a daemon
  ordered after itself, freezing login for ~90s before waybar appeared
- Fedora: require python3-pyxdg (uwsm tracebacks without it and every
  greeter login dies instantly), Nerd fonts from hypr-de-extras, and
  papirus-icon-theme; fuzzel and gsettings default to Papirus

* Mon Aug 17 2026 Mason Rhodes <mrhodesdev@gmail.com> - 0.2.9-1
- Ship /etc/greetd/vigil.toml defaulting the greeter to the uwsm-managed
  Hyprland session: without it a fresh install logs into a bare compositor
  (graphical-session.target never activates, so waybar and swaync never start)

* Sun Aug 16 2026 Mason Rhodes <mrhodesdev@gmail.com> - 0.2.8-1
- Depend on man-db so hypr-de-help man buttons work on a minimal install.
- Load workspace-zones from the packaged plugin path, not ~/.local only.
- Drop `which` from the waybar notifications exec-if (not on cloud images).
- Watch %t/hypr for wayland-env-guard so a fresh login does not hit the
  path trigger limit.

* Sun Aug 16 2026 Mason Rhodes <mrhodesdev@gmail.com> - 0.2.7-1
- Pass release secrets explicitly and always publish COPR and [mason].

* Sun Aug 16 2026 Mason Rhodes <mrhodesdev@gmail.com> - 0.2.6-1
- Always initialize the pacman keyring before locally signing [mason].

* Sun Aug 16 2026 Mason Rhodes <mrhodesdev@gmail.com> - 0.2.5-1
- Init pacman-key before signing the [mason] extra repo in CI.

* Sun Aug 16 2026 Mason Rhodes <mrhodesdev@gmail.com> - 0.2.4-1
- Snapshot Arch sources on tag builds; pull [mason] during makepkg.
- Lint RPMs with binaries, not the SRPM alone (libadwaita filter).

* Sun Aug 16 2026 Mason Rhodes <mrhodesdev@gmail.com> - 0.2.3-1
- Filter rpmlint explicit-lib-dependency for libadwaita (noarch help UI).

* Sun Aug 16 2026 Mason Rhodes <mrhodesdev@gmail.com> - 0.2.2-1
- Skip DPMS-off while the session is locked; force DPMS on after lock.
- Wake DPMS from mouse/key so VT return can modeset disabled outputs.

* Fri Aug 14 2026 Mason Rhodes <mrhodesdev@gmail.com> - 0.2.1-1
- Route wallpaper changes through the shared appearance-profiles registry.

* Tue Aug 04 2026 Mason Rhodes <mrhodesdev@gmail.com> - 0.2.0-1
- Keybind cheatsheet (SUPER+slash) with descriptions on every bind
- First-login welcome notification (hypr-de-welcome)
- Waybar updates module highlights pending hypr-DE releases
- hypr-de-theme: install/apply/reset themes (tagged lmtt config merge); gradient example
- hypr-de-set-wallpaper now syncs lmtt palette extraction (wallpaper changes retheme)

* Tue Aug 04 2026 Mason Rhodes <mrhodesdev@gmail.com> - 0.1.4-1
- Require hyprpwcenter (bound to SHIFT+XF86AudioPlay)

* Tue Aug 04 2026 Mason Rhodes <mrhodesdev@gmail.com> - 0.1.3-1
- hypridle drop-in + hyprlock -c against packaged configs; xdph.conf seeding;
  waybar restart drop-in no longer overrides ExecStart

* Tue Aug 04 2026 Mason Rhodes <mrhodesdev@gmail.com> - 0.1.2-1
- gpu-screen-recorder becomes a weak dep on Fedora (no repo package exists yet)

* Tue Aug 04 2026 Mason Rhodes <mrhodesdev@gmail.com> - 0.1.1-1
- hypr-de-setup bootstraps rendered stylesheets from templates (pre-lmtt-patch safety)

* Tue Aug 04 2026 Mason Rhodes <mrhodesdev@gmail.com> - 0.1.0-1
- Initial package: DE extracted from personal dotfiles
