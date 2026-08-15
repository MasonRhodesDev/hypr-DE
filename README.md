# hypr-DE

**Alpha. Not ready.** This repo composes the rest of the stack into a
packaged Hyprland session. It stays alpha until those supporting tools
reach stability and quality first: [vigil](https://github.com/MasonRhodesDev/vigil),
[hyprstate](https://github.com/MasonRhodesDev/hyprstate),
[lmtt](https://github.com/MasonRhodesDev/linux-multi-theme-toggle),
[sni-watcher](https://github.com/MasonRhodesDev/sni-watcher),
[logind-idle-control](https://github.com/MasonRhodesDev/logind-idle-control),
and the rest of the `[mason]` set.

An opinionated Hyprland desktop composition for **Fedora** and **Arch**:
compositor config (Lua), waybar, swaync with click-to-focus notification
recovery, fuzzel, Material You theming via lmtt, monitor profiles via
hyprstate, screenshot/recording tooling, and a uwsm-managed session entry.

Configs and styles are **package-owned** and live in system paths; your home
directory carries only a 3-line entry stub, your monitor profiles, your
wallpaper, and whatever you choose to override.

> **Compositor caveat:** hypr-DE's configuration uses Hyprland's Lua config
> API, which is newer than what distro packages currently ship. Until a
> Lua-capable `hyprland` package is published here, you need a Hyprland
> build from recent `main`. This is the gate for hypr-DE 1.0. (The Lua
> config is being adopted across the ecosystem — end_4's illogical-impulse
> already requires Hyprland ≥ 0.55 — so a stable upstream release may close
> this gap before a bespoke package does.)

## Install

Expect breakage. Prefer installing the supporting tools on their own until
this is out of alpha.

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
# Import the signing key first: https://github.com/MasonRhodesDev/arch-repo#use-it
SigLevel = Required DatabaseRequired
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

## Keybinds

Press **SUPER + /** for a searchable cheatsheet of every bind (grouped by
category — type a category word like `Windows` or `Media` to filter). The
list is generated live from the compositor, so binds you add in
`~/.config/hypr/local.lua` appear too; give them a
`{ desc = "Category: text" }` option to label them (undescribed binds show
as `(custom)`).

## Themes

A hypr-DE theme is a directory: `theme.toml` (metadata + a subset of
[lmtt](https://github.com/MasonRhodesDev/linux-multi-theme-toggle)'s config —
wallpaper, matugen scheme type, pinned palettes, accent pins, GTK/cursor/font
knobs) plus optional wallpaper, palette JSONs, and lmtt template modules. The
shipped `gradient` theme (`/usr/share/hypr-de/themes/gradient/`) is a
commented reference for authors.

```bash
hypr-de-theme list                 # shipped + installed themes
hypr-de-theme apply gradient       # apply (backs up lmtt config first)
hypr-de-theme install ./my-theme   # copy into ~/.local/share/hypr-de/themes
hypr-de-theme reset                # remove all theme edits, restore your values
```

Applying merges the theme's knobs into `~/.config/lmtt/config.toml` as
individually tagged lines (`# hypr-de-theme`); your own edits and comments
are preserved, replaced values are recorded in the tag and restored by
`reset`, and a timestamped backup lands in `~/.config/hypr-de/` either way.

## Pre-update snapshots (recommended)

On Fedora with btrfs, `dnf install snapper python3-dnf-plugin-snapper` and
`sudo snapper create-config /` make every dnf transaction — including hypr-DE
updates — automatically snapshotted and rollback-able. On Arch, `snap-pac`
provides the same for pacman (or use Timeshift). hypr-DE deliberately ships
no bespoke updater: updates arrive through the package manager, so your
existing snapshot/rollback tooling covers them.

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
