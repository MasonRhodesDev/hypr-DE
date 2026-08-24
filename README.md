# hypr-DE

**Alpha. Not ready.** This repo is a packaged Hyprland configuration plus
the other `[mason]` packages it needs. It is not a greeter session and
does not register a desktop environment. It stays alpha until those
supporting tools reach stability and quality first: [vigil](https://github.com/MasonRhodesDev/vigil),
[hyprstate](https://github.com/MasonRhodesDev/hyprstate),
[lmtt](https://github.com/MasonRhodesDev/linux-multi-theme-toggle),
[sni-watcher](https://github.com/MasonRhodesDev/sni-watcher),
[logind-idle-control](https://github.com/MasonRhodesDev/logind-idle-control),
and the rest of the set.

An opinionated Hyprland config set for **Fedora** and **Arch**: compositor
Lua config, waybar, swaync with click-to-focus notification recovery,
fuzzel, Material You theming via lmtt, monitor profiles via hyprstate, and
screenshot/recording tooling. Log into **Hyprland (uwsm-managed)** from the
Hyprland package.

Configs and styles are **package-owned** and live in `/usr` and `/etc/xdg`.
Home carries only what you own: `~/.config/hypr/local.lua`, monitor
profiles, wallpaper, and optional module/unit overrides.

> **Compositor:** hypr-DE requires Hyprland **0.56 or newer** (Lua config
> API landed in 0.55, but 0.55 can segfault when a monitor disconnects while
> a window is fullscreen — fixed in 0.56.0). extra/COPR `hyprland` 0.56+
> qualifies. `hyprland-git` qualifies when it `Provides: hyprland=0.56` or
> higher — install the git stack first so `hypr-de` does not pull extra
> Hyprland. Mixing extra and `-git` hyprwm packages is unsupported.

## Install

Expect breakage. Prefer installing the supporting tools on their own until
this is out of alpha.

```bash
curl -fsSL https://raw.githubusercontent.com/MasonRhodesDev/hypr-DE/main/get-hypr-de.sh | sudo sh
```

Same script via wget: `wget -qO- … | sudo sh`. Pass `--gaming` after `sh -s --`
to also install `hypr-de-gaming`. The script adds the package repo (Arch
`[mason]`, Fedora COPRs), installs `hypr-de`, and runs `hypr-de-setup` for
the sudo-invoking user.

**Fedora** (manual)

```bash
sudo dnf copr enable solaris765/hypr-de solaris765/hyprstate solaris765/lmtt \
    solaris765/logind-idle-control \
    solaris765/waybar-workspace-buttons solaris765/vigil solaris765/sni-watcher \
    solaris765/dials solaris765/hypr-de-extras
sudo dnf copr enable nett00n/hyprland heus-sueh/packages   # hyprland 0.56+ stack, matugen
sudo dnf install hypr-de            # + hypr-de-gaming if you want the gaming layer
```

Voice Dictation is an optional suite application. It remains available from
the `[mason]` Arch repository and `solaris765/wayland-voice-dictation` COPR,
but `hypr-de` does not install or activate it.

**Arch** (manual) — add the [`[mason]` repo](https://masonrhodesdev.github.io/arch-repo/)
to `/etc/pacman.conf`:

```ini
[mason]
# Import the signing key first: https://github.com/MasonRhodesDev/arch-repo#use-it
SigLevel = Required DatabaseRequired
Server = https://masonrhodesdev.github.io/arch-repo/x86_64
```

```bash
sudo pacman -Syu hypr-de        # + hypr-de-gaming
```

**Then, per user:**

```bash
hypr-de-setup          # presets user units; seeds xdph.conf (XDPH is home-only)
```

Log out and pick **Hyprland (uwsm-managed)** at the vigil greeter.

If you still have a leftover `~/.config/hypr/hyprland.lua` stub from an
older hypr-DE, `hypr-de-setup --adopt` backs it up and removes it so the
packaged `/etc/xdg/hypr/hyprland.lua` is used. Put personal binds in
`~/.config/hypr/local.lua`.

## Keybinds

Press **SUPER + /** for the help window: how the session works, plus every
bind loaded live from the compositor. **SUPER + SHIFT + /** is a fuzzel
quick-search of the same list. Binds you add in `~/.config/hypr/local.lua`
appear too; give them a `{ desc = "Category: text" }` option to label them
(undescribed binds show as `(custom)`). `man hypr-de` and
`man workspace-zones` are the prose versions.

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
| Lock-failure behavior | `/etc/hypr-de/lock.conf`, root-owned (see below) |

### Lock integrity

A lock request never fails open. If `vigil-lock` cannot take the session,
`lock-cmd.sh` retries outside its transient scope, then tries any other
installed locker (default `swaylock -f|gtklock -d|hyprlock &`), and if nothing
locks it **terminates the session** rather than hand back a desktop that
hypridle is about to blank into looking locked.

To keep the session instead, create `/etc/hypr-de/lock.conf`:

```ini
failsafe = warn
```

(`fallbacks` and `verify_tries` are settable there too.) The screen then stays
lit on a failed lock — an obviously unlocked desktop, never a dark one that
passes for locked.

The file must be **owned by root and not writable by anyone else**, or it is
ignored with a warning. That is deliberate: an environment variable or a
user-writable config would let anything running in the session switch the
failsafe off and durably re-open the hole this closes
(desktop-commons `BAR-017`, no-unprivileged-security-bypass). Loosening a
security failsafe is an operator decision, not a session one.

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
