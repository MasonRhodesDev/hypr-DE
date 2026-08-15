Name:           hypr-de
Version:        0.2.1
Release:        1%{?dist}
Summary:        Alpha Hyprland desktop environment (not ready)

License:        MIT
URL:            https://github.com/MasonRhodesDev/hypr-DE
Source0:        %{url}/archive/v%{version}/hypr-DE-%{version}.tar.gz

BuildArch:      noarch
BuildRequires:  systemd-rpm-macros
BuildRequires:  file
# %%check's gen-deps.sh drift gate parses deps.toml with python3/tomllib
BuildRequires:  python3

# Runtime deps are generated from deps.toml — edit THAT file and re-run
# packaging/gen-deps.sh print fedora main; CI (gen-deps.sh check) gates drift.
Requires:       SwayNotificationCenter
Requires:       blueman
Requires:       brightnessctl
Requires:       fira-code-fonts
Requires:       fuzzel
Requires:       google-noto-sans-fonts
Recommends:     gpu-screen-recorder
Requires:       grim
Requires:       hypridle
Requires:       hyprland
Requires:       hyprland-voice-dictation
Requires:       hyprpicker
Requires:       hyprpolkitagent
Requires:       hyprpwcenter
Requires:       hyprstate
Requires:       jetbrains-mono-fonts
Requires:       jq
Requires:       kitty
Requires:       /usr/bin/notify-send
Requires:       lmtt
Requires:       logind-idle-control
Requires:       matugen
Requires:       network-manager-applet
Requires:       pavucontrol
Requires:       playerctl
Requires:       python3
Requires:       python3-dbus
Requires:       python3-gobject
Requires:       slurp
Requires:       sni-watcher
Requires:       socat
Requires:       swappy
Requires:       swaybg
Requires:       udiskie
Requires:       uwsm
Requires:       vigil
Requires:       waybar
Requires:       waybar-workspace-buttons
Requires:       wireplumber
Requires:       wl-clipboard
Requires:       xdg-desktop-portal-hyprland

Recommends:     satty
Recommends:     thunar

%description
hypr-DE is alpha and not ready. It composes supporting tools that need to
stabilize first.

hypr-DE is an opinionated Hyprland desktop composition:
compositor configuration (Lua), waybar, swaync with notification recovery,
fuzzel, Material You theming via lmtt, monitor profiles via hyprstate,
screenshot/recording tooling, and a uwsm-managed wayland session — installed
system-wide with a thin per-user override surface (~/.config/hypr/local.lua,
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
# Syntax-check every shipped shell script and the Lua payload
find dist-build/bin dist-build/libexec -type f -exec sh -c 'head -1 "$1" | grep -q "^#!/bin/bash" && bash -n "$1"' _ {} \;
./packaging/gen-deps.sh check

%install
LIBEXECDIR=%{_libexecdir}/hypr-de \
    ./packaging/install.sh dist-build %{buildroot} main
LIBEXECDIR=%{_libexecdir}/hypr-de \
    ./packaging/install.sh dist-build %{buildroot} gaming
# lmtt system modules (searched by lmtt's system module path)
install -d %{buildroot}%{_datadir}/lmtt/modules
install -Dpm644 dist-build/lmtt-system-modules/* -t %{buildroot}%{_datadir}/lmtt/modules/

%post
%systemd_user_post swaybg.service waybar-reload.path waybar-reload.service waybar-watchdog.service waybar-watchdog.timer wayland-env-guard.path wayland-env-guard.service wayland-env-guard.timer hyprland-configreload-listener.service notification-focus-proxy.service

%preun
%systemd_user_preun swaybg.service waybar-reload.path waybar-reload.service waybar-watchdog.service waybar-watchdog.timer wayland-env-guard.path wayland-env-guard.service wayland-env-guard.timer hyprland-configreload-listener.service notification-focus-proxy.service

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
%{_libexecdir}/hypr-de/
%exclude %{_libexecdir}/hypr-de/bp-game-focus.py
%exclude %{_libexecdir}/hypr-de/steam-clean-shutdown.sh
%{_datadir}/hypr-de/
%exclude %{_datadir}/hypr-de/gaming/
%{_datadir}/lmtt/modules/hypr-de-waybar.toml
%{_datadir}/lmtt/modules/hypr-de-swaync.toml
%{_prefix}/lib/systemd/user/*
%exclude %{_prefix}/lib/systemd/user/bp-game-focus.service
%exclude %{_prefix}/lib/systemd/user/steam-clean-shutdown.service
%exclude %{_prefix}/lib/systemd/user/app-.scope.d/
%{_prefix}/lib/systemd/user-preset/90-hypr-de.preset
%{_prefix}/lib/environment.d/60-hypr-de.conf
%config(noreplace) %{_sysconfdir}/xdg/uwsm/env
%config(noreplace) %{_sysconfdir}/xdg/uwsm/env-hyprland
%{_sysconfdir}/skel/.config/hypr/hyprland.lua

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
