# hypr-DE

An opinionated, fully packaged Hyprland desktop environment for **Fedora**
and **Arch**: compositor config (Lua), waybar, swaync with click-to-focus
notification recovery, fuzzel, Material You theming via
[lmtt](https://github.com/MasonRhodesDev/linux-multi-theme-toggle), monitor
profiles via [hyprstate](https://github.com/MasonRhodesDev/hyprstate),
screenshot/recording tooling, and a uwsm-managed session entry.

Configs and styles are **package-owned** and live in system paths; your home
directory carries only a 3-line entry stub, your monitor profiles, your
wallpaper, and whatever you choose to override.

> **Compositor caveat:** hypr-DE's configuration uses Hyprland's Lua config
> API, which is newer than what distro packages currently ship. Until a
> Lua-capable `hyprland` package is published here, you need a Hyprland
> build from recent `main`. This is the gate for hypr-DE 1.0.

## Install

**Fedora**

```bash
sudo dnf copr enable solaris765/hypr-de solaris765/hyprstate solaris765/lmtt \
    solaris765/logind-idle-control solaris765/hyprland-voice-dictation \
    solaris765/waybar-workspace-buttons
sudo dnf copr enable solopasha/hyprland heus-sueh/packages   # hyprland stack, matugen
sudo dnf install hypr-de            # + hypr-de-gaming if you want the gaming layer
```

**Arch** — add the [`[mason]` repo](https://masonrhodesdev.github.io/arch-repo/)
to `/etc/pacman.conf`, then install with an AUR helper (matugen resolves from
the AUR):

```ini
[mason]
SigLevel = Optional TrustAll
Server = https://masonrhodesdev.github.io/arch-repo/x86_64
```

```bash
paru -S hypr-de        # + hypr-de-gaming
```

**Then, per user:**

```bash
hypr-de-setup          # seeds the entry stub, presets user units, primes theming
```

Log out and pick the **hypr-DE** session at your greeter.

## Customizing

| What | Where |
|---|---|
| Keybinds, rules, autostart | `~/.config/hypr/local.lua` (see `/usr/share/hypr-de/hypr/local.lua.example`) |
| Monitor layouts | `~/.config/hypr/profiles/*.lua` — `hyprstate profile save <name>` captures the current layout; profiles auto-apply by connected-monitor match |
| Wallpaper | `hypr-de-set-wallpaper <image>` |
| Theme (dark/light + palette from wallpaper) | `lmtt switch` (bound to SUPER+T) |
| Bar / notification styles | shadow the shipped lmtt module: copy from `/usr/share/lmtt/modules/hypr-de-*.toml` to `~/.config/lmtt/modules/` and edit |
| Unit behavior | systemd user drop-ins (`systemctl --user edit waybar.service`) |
| Per-app notification click recovery | plugins in `~/.config/hypr-de/notify-plugins/<app>.sh` |

## Development

- All install paths in `dist/` are `@TOKENS@` substituted at build time from
  `packaging/paths.conf` — never hardcode a path (CI rejects it).
- Runtime dependencies are declared in `deps.toml`; `packaging/gen-deps.sh
  check` gates spec/PKGBUILD drift.
- Release: bump `packaging/hypr-de.spec` Version + `packaging/PKGBUILD`
  pkgver in one commit, `git tag vX.Y.Z && git push --tags` — CI publishes
  COPR + GitHub release; the `[mason]` repo picks it up.

## License

MIT
