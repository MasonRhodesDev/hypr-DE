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

Every repository it enables is pinned: the Arch `[mason]` key by fingerprint,
and each COPR against the fingerprint recorded in `COPR_KEYS`. A repo serving
a different signing key is refused rather than trusted, and a signature that
does not verify fails immediately — the installer never retries past one.
Enabling the COPRs by hand (below) skips those checks; `dnf copr enable`
accepts whatever key the repo serves.

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
| Wallpaper | Dials › Displays (select a monitor, Wallpaper › Choose…), or `hypr-de-set-wallpaper <image>`; swaybg and hyprlock follow through the `hypr-de-wallpaper` lmtt module |
| Theme (dark/light + palette from wallpaper) | `lmtt switch` (bound to SUPER+T) |
| Bar / notification styles | shadow the shipped lmtt module: copy from `/usr/share/lmtt/modules/hypr-de-*.toml` to `~/.config/lmtt/modules/` and edit |
| Idle timeouts (lock, blank, suspend) | `~/.config/hypr-de/hypridle.conf`, one `$lock_timeout = 600` style line per knob (see below) |
| Unit behavior | systemd user drop-ins (`systemctl --user edit waybar.service`) |
| Per-app notification click recovery | plugins in `~/.config/hypr-de/notify-plugins/<app>.sh` |
| Lock-failure behavior | `/etc/hypr-de/lock.conf`, root-owned (see below) |

### Lock integrity

Every lock goes through `lock-cmd.sh`, and only the idle lock needs hypridle:

| Request | Who runs `lock-cmd.sh` |
|---|---|
| Super+L, power menu's Lock | the binding, directly |
| `loginctl lock-session` from any tool, lid close (hyprstate asks logind) | `hypr-de-lock.service`, which answers logind's Lock for your session |
| Before sleep | `hypr-de-lock.service` holds a logind sleep delay until the lock is up; hypridle's `before_sleep_cmd` too |
| Idle | hypridle only. With hypridle disabled nothing locks on idle |

`hypr-de-lock.service` is pulled in by every graphical session through a
`graphical-session.target` drop-in, not a preset, so an upgraded install runs
it from its next login; `systemctl --user mask hypr-de-lock.service` turns it off.
Outside Hyprland it logs that and exits. It binds to the session Hyprland runs
in (logind's session for Hyprland's pid, else Hyprland's own `XDG_SESSION_ID`),
and accepts only an active wayland session on Hyprland's seat. Until one
resolves it logs why and retries every 2 s, and systemd never stops restarting
it. A `lock-cmd.sh` that has not returned after 90 s is killed, a critical
notification says so, and the next request runs it again.

A session counts as locked only when the compositor holds the lock **and** a
locker of yours is alive on this display. Two requests at once are safe:
vigil-lock joins a lock that is already starting, and only one `lock-cmd.sh`
at a time may fall back (a lock file in `$XDG_RUNTIME_DIR`), so a second run
finds the first one's locker and stops there instead of reaching the failsafe.
vigil-lock's wait is bounded at 10 s (plus the idle warning).

Sleep waits for the lock only as long as logind's `InhibitDelayMaxSec`
(default 5 s, see `logind.conf(5)`); after that the machine suspends anyway
and the lock lands on resume. hypr-DE does not change that system-wide
setting.

The locker's output goes to the journal (`journalctl --user -t vigil-lock`),
and so do `lock-cmd.sh`'s own lines (`-t hypr-de-lock`), even from a binding
whose output Hyprland discards.

A lock request never fails open. If `vigil-lock` cannot take the session,
`lock-cmd.sh` retries outside its transient scope, then tries any other
installed locker (default `swaylock -f|gtklock -d|hyprlock &`), and if nothing
locks it **terminates the session** rather than hand back a live desktop the
user believes is locked. (Since 0.2.25 nothing blanks an unlocked session, so
an exposed desktop at least stays visibly exposed — but it is still exposed,
which is what the failsafe exists to prevent.)

A crashed lock screen is recovered, not ended. When the locker dies, Hyprland
keeps the session locked on its lock-dead screen, and hypr-DE ships
`misc:allow_session_lock_restore = true` so a new locker may take that lock
over. A watcher that `lock-cmd.sh` starts beside each lock notices the locker
die and respawns vigil-lock within about a second, and any lock request on
that screen does the same. The password is still required; the session is
never unlocked in between. Only `vigil-lock` from `/usr/local/bin:/usr/bin:/bin`
is respawned (lock-cmd.sh pins its `PATH`), and only once no locker of yours is
left alive, because Hyprland also hands a healthy lock to a newcomer. One run at
a time respawns, under the same lock file as the fallbacks. Respawns are counted
in `$XDG_RUNTIME_DIR/hypr-de-lock-respawns`: after 3 in 30 s the fallbacks run,
then the failsafe, so a locker that keeps crashing ends the session rather than
loop. Each step is logged as `hypr-de-lock`.

If your Hyprland config sets `misc:allow_session_lock_restore = false`, no
locker can take a crashed lock screen over, so a request on it goes straight
to the failsafe below and the journal says why.

To keep the session instead, create `/etc/hypr-de/lock.conf`:

```ini
failsafe = warn
```

(`fallbacks` and `verify_tries` are settable there too.) A failed lock then
posts a critical "Screen NOT locked" notification, and the screen stays
lit: an obviously unlocked desktop, never a dark one that
passes for locked. On a crashed lock screen it posts "Lock screen crashed"
instead, telling the user to switch to a TTY (Ctrl+Alt+F2) to recover; the
lock-dead screen may hide that notification. A fallback locker must
daemonize once it holds the lock (`swaylock -f`, `gtklock -d`) or end in `&`;
`lock-cmd.sh` never kills a locker.

The file must be **owned by root and not writable by anyone else**, or it is
ignored with a warning. That is deliberate: an environment variable or a
user-writable config would let anything running in the session switch the
failsafe off and durably re-open the hole this closes
(desktop-commons `BAR-017`, no-unprivileged-security-bypass). Loosening a
security failsafe is an operator decision, not a session one.

### Idle blanking

The session has exactly one DPMS-off, and it fires only while the compositor
holds the lock: a hypridle listener that blanks 30 s after input stops,
gated on `hyprctl locked` (`condition_cmd=session-locked.sh`) by both its
condition and its on-timeout.

**Your own idle inhibitor keeps a locked screen lit; an app's does not.**
hypridle counts three kinds — the deliberate `logind-idle-control` toggle,
the freedesktop `org.freedesktop.ScreenSaver` D-Bus API, and Wayland surface
inhibitors that video players, browsers and call apps set silently. Honouring
all three would let a paused video nobody remembers keep a locked screen lit
all night with no visible cause, so the listener ignores the accounting
wholesale and `session-locked.sh` re-admits only the toggle you set yourself.
Locking on purpose releases that toggle, so a deliberate lock still goes
dark.
Because it is input-driven, waking a locked screen never re-blanks it under
your hands — with hyprstate ≥ 2.5.0, which no longer blanks at all (older
hyprstate still runs its own 30 s timer; the package floors it). A session
that goes idle first and locks later still goes dark, via the condition
retry.

**An unlocked session is never blanked.** A dark screen over a live desktop
is indistinguishable from a locked one, and the 240 s unlocked blanker
removed in 0.2.25 could reach exactly that state whenever a lock was
cancelled without input (an output hotplug cancels vigil's warning) — while
hyprstate relit it a tick later regardless, so all it produced was a flash.
An idle session locks at 3 minutes; if that lock is cancelled or fails, the
screen stays honestly lit. The cost is power and burn-in on a session that
is never locked at all.

Needs hypridle ≥ 0.1.8 and Hyprland ≥ 0.48. Known gap: resuming from suspend
without touching anything leaves a locked screen lit until the next
input→idle cycle (#29).

### Per-host timeouts

The packaged policy declares three knobs at its top, in seconds:
`$lock_timeout` (180), `$blank_timeout` (30) and `$suspend_timeout` (900).
A host changes any of them without copying the policy:

```
# ~/.config/hypr-de/hypridle.conf
$lock_timeout = 600
$suspend_timeout = 1800
```

then `systemctl --user restart hypridle`. The launcher splices those lines
in after the packaged defaults and runs the result from the runtime dir; the
policy itself (what each listener does, what gates it) is not overridable
there, and any other line is reported in the journal and dropped. Values run
1 to 4294967; a stage a host never wants can be set to the ceiling.

## Boot scene plugin

`hypr-de-scene` is a separate package that holds a Hyprland plugin. With
[desktop-boot](https://github.com/MasonRhodesDev/desktop-boot) installed it
draws the boot scene's ground and logo into every output from Hyprland's
first frame, so a login shows no black or empty frame and nothing of the
desktop while it assembles. `hypr-de` does not depend on it. Load it with
the `hl.plugin.load` line in `local.lua.example`.

This readiness rule and desktop-boot's removal of its own login splash
([desktop-boot#32](https://github.com/MasonRhodesDev/desktop-boot/pull/32))
go together. This change merges first, then that one, and the two packages
must be installed in the same upgrade.

The session says what to wait for, and the plugin decides when it has
arrived. Each component that draws at rest declares the layer it maps from
its own user unit, and the package ships the declarations for waybar
(`waybar`) and swaybg (`wallpaper`). A component that is not enabled
declares nothing, so nobody waits for it. Once every component ordered
before it has started, `hypr-de-scene-ready.service`, pulled in by
`graphical-session.target`, says so. The scene then lets go on the first
frame in which every declared layer is mapped on every output, and Hyprland's
own wallpaper has loaded when it draws one. Every output fades together over
0.2 s, and input and the cursor come back on the first faded frame.

`graphical-session.target` waits until uwsm's wait list is in the user
manager's environment: `WAYLAND_DISPLAY`, plus whatever `UWSM_WAIT_VARNAMES`
names (uwsm adds `HYPRLAND_INSTANCE_SIGNATURE` for Hyprland). hypr-DE keeps
that guard and makes it quick. A drop-in runs `wayland-session-waitenv.service`
with hypr-DE's `hypr-de-waitenv` in place of `uwsm aux waitenv`. It reads the
same variables, timeout and settle, and logs the same lines. It checks every
10 ms for the first 2 s, then every 100 ms, where uwsm checks every 0.5 s. On
timeout it exits 1 as uwsm does, so the unit fails and uwsm shuts the session
down rather than start it half configured. A failed read of the manager's
environment is retried for up to 2 s before the waiter gives up. The drop-in
applies to every uwsm compositor, since the waiter keeps uwsm's semantics. To
go back to uwsm's own waiter, mask the drop-in for your user with
`ln -s /dev/null ~/.config/systemd/user/wayland-session-waitenv.service.d/hypr-de.conf`
(create the directory first), then log in again.
`/etc/xdg/uwsm/env-hyprland` also sets `UWSM_WAIT_VARNAMES_SETTLETIME` to 0,
because hypr-DE exports the session's variables in one call, and that takes
uwsm's 0.2 s settle pause off every login. A value set earlier in the
environment, or in `~/.config/uwsm/env-hyprland`, wins.

Every output there means each output that shows a frame of its own. A mirror,
an output that is off or disabled, and the `FALLBACK` output Hyprland puts in
while no real one exists do not count, and the scene never covers `FALLBACK`.
Hyprland loads its wallpaper once per output, one after another, so the scene
waits up to 2 s for each next one before it counts that wallpaper as failed.

While the scene covers an output, layers and windows that map under it skip
their open animation, and nothing typed lands in a window nobody can see.
Hyprland's keybinds and its VT switch still run first, so Super+L locks the
session and Ctrl+Alt+F2 reaches a text console; a key no bind takes is kept
from every client. Clicks, scrolls, touches and gestures are dropped before
Hyprland's binds see them, so a mouse bind such as Super+scroll waits for the
fade. While no output is covered, nothing is held.

It never holds for long. It lets go 1.5 s after the last `scene expect` or
`scene ready` when the session never says it is ready, after 5 s whatever
else is true, at once on a session lock, and on `hyprctl scene release`. The
5 s count from the first output it covers, and a release or lock before then
ends the scene at once. A Hyprland that no service manager started (no
`MANAGERPID`) waits only for declared layers.

A bar other than waybar declares itself with a drop-in on its own unit:

```ini
# ~/.config/systemd/user/my-bar.service.d/hypr-de-scene.conf
[Unit]
Before=hypr-de-scene-ready.service

[Service]
ExecStartPost=-/usr/bin/hyprctl scene expect layer my-bar-namespace
ExecStopPost=-/usr/bin/hyprctl scene drop layer my-bar-namespace
```

`hyprctl scene` prints what the scene waits for as JSON, and
`journalctl -b -t hypr-de-scene` has a line for every declaration, map,
and the release with its reason: `scene: fading` marks the desktop usable
and `scene: released` the scene gone. A name is 1 to 64 letters, digits,
`.`, `_`, `-` or `:`, and the scene keeps at most 32 declarations.

| Setting | Default | Meaning |
|---|---|---|
| `HYPR_DE_SCENE_TIMEOUT` | 5 | seconds before it lets go whatever else is true, 10 at most |
| `HYPR_DE_SCENE_QUIET` | 1.5 | seconds after the last `expect` or `ready` when the session never says it is ready |
| `HYPR_DE_SCENE_SPREAD` | 0.25 | seconds a layer shown on only some outputs waits for the rest, from its last map or from when the scene covered that output, whichever is later |
| `HYPR_DE_SCENE_FADE` | 0.2 | seconds the fade takes, 0 to cut, 1 at most |
| `HYPR_DE_SCENE_AWAIT_SESSION` | auto | 1 waits for `hyprctl scene ready session`, 0 does not; auto waits when `MANAGERPID` is set |

A session that starts its bar from `exec-once` sets
`HYPR_DE_SCENE_AWAIT_SESSION=1` and ends its startup with
`hyprctl scene ready session`.

`plugins/hypr-de-scene/tests/nested-cases.sh` runs each of these cases in a
sealed nested Hyprland and checks the journal lines, readbacks and
screenshots.

A Hyprland plugin is compiled against one Hyprland build and cannot run in
another. The package does not pin a Hyprland version, so Hyprland upgrades
are never held back. After an upgrade the plugin loads and stays idle
instead: the frames it covered come back, nothing is shown on screen, and
the journal says why and names both builds:

```bash
journalctl -b -t hypr-de-scene
```

`hyprctl plugin list` shows the same line as the plugin's description.

The path above is a small loader that needs nothing from Hyprland. It
opens the plugin itself, from `hypr-de-scene-impl.so` beside it, and only
in the Hyprland build both were compiled for. When the plugin cannot be
opened, for example because the new Hyprland no longer has a symbol it
needs, the loader stays idle the same way and the journal line gives the
dynamic linker's reason.

Rebuild the package on the machine, against the Hyprland now installed,
and log in again.

One upgrade the loader cannot cover is a change to Hyprland's plugin API
version, which is `0.2` in Hyprland 0.57.2 and on its main branch. Hyprland
checks it before any plugin code runs and shows its own failed-to-load
notification.

**Arch**, from a checkout:

```bash
cd packaging/hypr-de-scene
ver=$(sed -n 's/^pkgver=//p' PKGBUILD)
git archive --prefix "hypr-de-scene-$ver/" -o "hypr-de-scene-$ver.tar.gz" HEAD
makepkg -si --skipchecksums
```

**Fedora**, from a checkout:

```bash
SPEC_NAME=hypr-de-scene ./packaging/build-srpm.sh --head
sudo dnf builddep ~/rpmbuild/SRPMS/hypr-de-scene-*.src.rpm
rpmbuild --rebuild ~/rpmbuild/SRPMS/hypr-de-scene-*.src.rpm
sudo dnf install ~/rpmbuild/RPMS/*/hypr-de-scene-[0-9]*.rpm
```

## Development

- All install paths in `dist/` are `@TOKENS@` substituted at build time from
  `packaging/paths.conf` — never hardcode a path (CI rejects it).
- Runtime dependencies are declared in `deps.toml`; `packaging/gen-deps.sh
  check` gates spec/PKGBUILD drift.
- Release: bump Version in `packaging/hypr-de.spec` and
  `packaging/hypr-de-scene.spec`, and pkgver in `packaging/PKGBUILD` and
  `packaging/hypr-de-scene/PKGBUILD`, in one commit, then
  `git tag vX.Y.Z && git push --tags`. CI publishes `hypr-de` to COPR and
  a GitHub release; the `[mason]` repo picks it up.
- `hypr-de-scene` is built and checked by the Scene plugin workflow on
  every push. The release workflow does not publish it yet.

## License

MIT
