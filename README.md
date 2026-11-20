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
it. A `lock-cmd.sh` that has not returned after 120 s is killed, a critical
notification says so, and its failsafe runs unless a locker holds the lock.
The next request runs it again.

A session counts as locked only when the compositor holds the lock **and** a
locker of yours is alive on this display. If `hyprctl locked` gives no answer
in three tries, that never reads as unlocked: a live locker counts as the lock,
and with none the run recovers as on a crashed lock screen. So a compositor
that stalls just as you unlock can lock the session again. Two requests at once are safe:
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
that screen does the same. Super+L is a locked bind, so it works on the
lock-dead screen too; while a locker is alive it starts nothing. There is one
watcher per Wayland display, and any request on a locked session restarts one
that was lost. The password is still required; the session is never unlocked
in between. The respawn passes `--grace 0`, so a `lock.grace_secs` in the vigil
config never opens a grace window after a crash. Only `vigil-lock` from `/usr/local/bin:/usr/bin:/bin`
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

(`fallbacks` and `verify_tries` are settable there too.) A third-party lock
screen (anything but vigil-lock, swaylock, gtklock, hyprlock or waylock) counts
as a live locker only if `fallbacks` lists it: the first word of each entry is
matched against process names. Unlisted, it reads as a crashed lock screen and
vigil-lock replaces it. A listed entry also runs as a fallback when vigil-lock
fails. A failed lock then
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

### Safety gates

CI refuses unsafe patterns in new code. `tests/gates/check.sh` runs every gate,
or the ones named on its command line:

| Gate | What it refuses |
|------|-----------------|
| `classify` | A file the other gates cannot place that `tests/gates/classified.tsv` does not list: a file with no suffix or a suffix outside the gate's known list, a `CMakeLists.txt` other than a plugin's own, a C or C++ file outside a plugin directory. A `PKGBUILD` not classified `pkgbuild` and a spec not classified `spec`. A committed object file, archive or ELF binary. Opaque data (over 7 bits of entropy per byte in 1 KiB or more, or a long run of base64, hex or escaped bytes) not classified `blob` with a reason. A listed class that a shebang or the executable bit contradicts, and a `cpp-test` row on a file that is not C or C++. A spec that compiles (it asks for a compiler or a C or C++ build system in `BuildRequires`, or names one in its build sections, macros included) and runs anything in `%prep`, `%conf`, `%build` or `%install` but `%autosetup`, `%cmake -S <directory>`, `%cmake_build` and `%cmake_install`, so it can pass no option or flag of its own. A spec that redefines a flags macro, or turns off the annobin notes (`_annotated_build`) the `rpm` gate reads. Never baselined. |
| `shell` | Anything `shellcheck` reports with every optional check on, in every shell script, `PKGBUILD`, `.install` file and RPM scriptlet (`%post` and the rest), and a `shellcheck disable` directive. An RPM scriptlet that writes into a program or library directory. A script is found by its suffix (`.sh`, `.bash`), by a shebang that names a shell, or by its class in `classified.tsv`. A shebang or scriptlet interpreter that `shellcheck` cannot read, such as `zsh`, fails and is never baselined. |
| `python` | `ruff` with the bandit, bugbear and pylint rules in `ruff.toml`, and a `noqa` or `ruff:` comment. |
| `lua` | `luacheck` findings (`.luacheckrc`) and inline `luacheck:` comments. |
| `cpp-harden` | What the packages ship, described below. |
| `cpp-sanitize` | A plugin whose tests fail under AddressSanitizer and UndefinedBehaviorSanitizer, that registers no test with `add_test`, or that compiles a source of its own with a sanitizer off. |
| `cpp-tidy` | `clang-tidy` findings from `plugins/.clang-tidy` in every compile `cpp-harden` checks, in every header of this repository they include and in every file their build writes. |
| `cpp-selftest` | The C++ gates themselves, if they stop catching a known-bad case of `tests/gates/cpp-fixture` or report anything in its clean build. Never baselined. |
| `rpm` | Each binary RPM named with `--rpms`, read as it installs: no setuid, setgid, world-writable or non-root file; every ELF file passes the same ELF checks as `cpp-harden`'s; and `annocheck` passes it, reading the notes Fedora's GCC records for each compile from the debuginfo package, so it sees optimisation, the stack protector, stack clash protection, fortify, `_GLIBCXX_ASSERTIONS` and CET per compile. Every ELF file must carry those notes, in it or in its debuginfo, or it fails as `annobin-missing`, since without them `annocheck` has little to read. A run given no binary RPM fails, and so does a package built for an architecture (not `noarch`) that holds no ELF file, since nothing in it was audited. `all` does not run it. The `rpm` job in `.github/workflows/scene-plugin.yml` runs it on the RPM it builds. |

A suppression comment does not change a result. `ruff` runs with
`--config ruff.toml --ignore-noqa`. `shellcheck` runs with
`--rcfile=.shellcheckrc` and `luacheck` with `--config .luacheckrc`, both on
copies that have their inline directives removed. So the finding under a
suppression is counted, and so is the suppression. A linter configuration file
in a subdirectory is not read. C++ has no switch for this, so each `NOLINT`
comment and diagnostic pragma is counted by its whole line.

#### What the C++ gates judge

The C++ gates judge what a package ships and what the compiler saw, not what
a build file says. `cpp-harden` runs `makepkg` on every `PKGBUILD` that
`classified.tsv` lists as `pkgbuild`: its own `prepare()`, `build()`,
`check()` and `package()`, from a tarball of the tracked files with no `.git`,
with an empty environment, and with the distribution's compiler flags emptied
so that only what this repository asks for counts. `check()` runs between
`build()` and `package()`, as it does when the package ships, so what it
changes in the build is audited too. The CI job installs each package's
`makedepends` and `checkdepends` for it. Some tests fail under the trace
described below, as the main package's lock tests do. A package whose build
fails under it is built again untraced, and that build counts only if it
ships no ELF file, so none of its compiles is held to the shipping set and
only its archive, scriptlet and file checks apply. A package that ships an
ELF file keeps the traced build's `build-failed`. As root it builds as an unprivileged
user. The tarball stands in for the `PKGBUILD`'s remote source, unpacked as
`<last part of url>-<pkgver>`, the way a forge's release archive unpacks.

`tests/gates/shim.py` stands in for the GCC drivers on `PATH` during the
build. For each compile it keeps GCC's own job list (`-###`) and the
preprocessor's view of the source with the compile's own arguments
(`-E -dD -C`). For each link it keeps every file the linker read. When the
call ends it sends that record to the gate over a unix socket, so the build
can add a record but never change or delete one. A call that compiles and
links nothing, such as `c++ --version`, sends none; a call with several
sources sends one without a preprocessed view, so what it makes is
unattributed if it ships.

The build user owns only the build's source, build, output and home
directories. The shim, its wrappers and the socket's directory stay the
gate's. The whole build runs under `strace -f`, which lists every program it
starts. A compiler, assembler or linker that no shim process started fails as
`unshimmed`, unless it was a probe that names no input and no output, as CMake
asks `ld -v`. A record from a process that never ran the shim fails as
`forged-record`, and one the gate cannot read as `malformed-record`. The
sanitizer build in `cpp-sanitize` runs the same way, as the build user.

A compile stage comes only from the system. Every program a shim process runs,
the driver, `cc1plus`, `as`, `collect2`, `ld` and the rest, must be owned by
root and sit in directories only root can change, outside the gate's work
directory; anything else fails as `untrusted-tool`. A compile whose driver
options, after GCC has read every response file, hold `-B`, `-specs`,
`-fplugin` or `-iplugindir` fails as `driver-override`, since each one
changes which programs run or what they are told past what `-###` and `-E`
show. GCC reads a linker option such as `-Bsymbolic-functions` given to the
driver as `-B` and a directory, so the FAIL names `-Wl,-Bsymbolic-functions`,
the way to hand it to the linker. GCC does not list `-wrapper` among those
options, so `driver-override` never names it; the program it runs is
`untrusted-tool` if the build user could have written it, and what a wrapper
makes is unattributed if it ships. The wrappers drop `COMPILER_PATH`, `GCC_EXEC_PREFIX`,
`LIBRARY_PATH`, `GCC_COMPARE_DEBUG` and every `LD_*` variable before the shim
starts. `CC` and `CXX` name the wrappers, so `tests/run`, which clears the
environment for each test, keeps them, and a test's compiles in `check()` go
through the shim too.

Then, for every ELF file in the package:

* It is position independent, has full RELRO and immediate binding, a stack
  that is not executable, the CET note on x86-64, no `RPATH` or `RUNPATH` and
  no text relocations.
* It imports no plain `printf`, `sprintf`, `vsnprintf`, `syslog` or their
  siblings, which fortify always replaces. A plain `memcpy` or `strcpy` is
  fortify's own answer when it cannot see a buffer's size, so it counts for
  nothing.
* Its build ID matches a link the shim saw, every section it loads, code and
  data, is what that link wrote (apart from the dynamic section and its
  strings, which CMake's install rewrites to drop the build tree's `RPATH`),
  and every object that link read comes from a compile
  the shim saw, or from a file the build user cannot write. Anything else is
  `unattributed`, which is never baselined. So is an object built with LTO,
  since the gate cannot see what LTO makes of it. When two records match one
  object or one build ID, both are judged.
* Every library it needs (`DT_NEEDED`) is one the package ships, or one that
  a package in its declared `depends`, or their dependencies, installs. A
  library named by a path fails.

Each package archive `makepkg` wrote has no setuid, setgid, world-writable or
non-root file, read from the archive as it installs. Its install scriptlet
(`install=`) names a program or library directory, or a directory the package
ships an ELF file in, only as the command it runs, never as a place it writes.

For every compile behind a shipped ELF file (a test's own compile in
`check()`, or a library the package builds and never installs, ships
nothing, so it is not held to this set):

* `_FORTIFY_SOURCE` and glibc's `__USE_FORTIFY_LEVEL` are 3,
  `_GLIBCXX_ASSERTIONS` is defined and `NDEBUG` is not, at every `#include`
  and at the end. Once the unit has left glibc's `features.h`, which sets
  `__USE_FORTIFY_LEVEL`, an undefined level counts as fortify off. The preprocessor's own `#define` and `#undef` lines show
  where each one changed, so a response file, `-Wp,-U...`, a launcher that
  drops flags or an `#undef` hidden by a comment or a line splice all show.
* GCC's own macros show optimisation (`__OPTIMIZE__`), the strong stack
  protector, position independent code and full CET. Stack clash protection
  and `-Wall -Wextra -Wconversion -Wshadow` are read from the arguments GCC
  hands its compiler, after it has expanded response files. A warning turned
  off there (`-Wno-*`, `-w`) counts once per package.
* No header in the tree is compiled as a system header, by `SYSTEM`,
  `-isystem` or `#pragma GCC system_header`, since GCC hides its warnings.
* In the tree's own lines of the preprocessed source, with comments and
  strings lexed out and macros expanded: an `optimize`, `target`,
  `no_stack_protector`, `no_sanitize` or `nocf_check` attribute, a
  `#pragma GCC optimize`, `push_options` or `target`, a diagnostic pragma that
  ignores a warning, and a `NOLINT` comment.
* In the whole unit, headers outside the tree included: a `#pragma GCC
  optimize` or `target`, or a `push_options`, still in force when the unit
  ends.
* No `-mmanual-endbr`, which keeps `__CET__` and the CET note and drops
  `endbr64` from every function not marked `cf_check`.
* No object defines `__stack_chk_fail`, `__chk_fail` or `__fortify_fail`,
  which would turn a failed check into a call that returns.

Compiler warnings are read from what each compile wrote, as the shim saw it,
so a `build()` that discards its output keeps every count. A call that only
assembles or preprocesses is not a compile the gate can judge, so what it
makes is unattributed. A C or C++ file in a
plugin directory that no compile behind a shipped file read, and that
`classified.tsv` does not list, fails as `not-built`. `cpp-tidy` runs on the
compiles `cpp-harden` judges, so it sees what GCC compiled, unity files and
generated sources included.
`cpp-sanitize` builds each plugin with `HYPR_DE_SANITIZE=ON` through the same
shim and runs its tests.

Every reviewed attack on these gates is a case in `tests/gates/attacks.py`,
which makes each change on a fresh clone of `HEAD`, runs the gates and checks
for the exact FAIL line. Its C++ cases build only the plugin's package
(`--pkgbuild`), the one each case changes; CI builds every package. A gate
that cannot see all the code, because a build
failed, a tool ran outside the shim or an ELF is unattributed, prints that and
stays silent about the counts it can no longer check. Run it where the C++ gates run:
`python3 -I tests/gates/attacks.py [case ...]`. The self-test covers the same
mechanisms on the fixture in every CI run.

#### What still passes

* The build user can still write into its own processes' memory through
  `/proc`, so a build step can change what a running shim sends. That is a
  deliberate attack in the build's own code, which review sees.
* The wrappers' own shell starts with the build's environment, so an
  `LD_PRELOAD` library the build exports loads into it before the wrapper
  drops the variable. Such a library can change what the shim reports, as a
  `/proc` write can. It is code the build compiles or ships in the tree,
  which review sees.
* A compiler copied under a name the trace does not know, such as `mycc`,
  runs unseen by the trace. What it makes is still unattributed if it ships.
* A probe as the trace defines it, a tool called with options only, is not
  judged. `as` with no arguments reads standard input and writes `a.out`;
  that file is unattributed if it ships.
* The install scriptlet check reads paths as written. A scriptlet that builds
  a path at run time, such as `"/usr/l""ib"`, is not caught.
* Inline assembly, `.incbin` and linker script data are judged only as part of
  the compile that holds them.
* Fortify is proven per compile, not per call. A call fortify cannot size
  stays unchecked by design, and a call through a function pointer to
  anything but the printf family goes unseen.
* The build may reach the network. Code it downloads and links is
  unattributed, but a downloaded script or data file is not judged.
* Only the compiles behind a shipped ELF file are held to the shipping set,
  so a CMake probe or a test's own build is not judged. Code the build compiles and ships in another form, such as a compressed
  or encoded file a program unpacks later, is not judged; `classify` sees
  it only if it is committed opaque data.
* A `check()` that fails only under the trace makes the gate judge the
  untraced build, which counts only if the package ships no ELF file. That
  build has no trace, so a compile outside the shim (`unshimmed`) and a
  forged record go unseen there. What it can hide is compiled code shipped
  in another form, as above. A probe of `TracerPid` in `check()` stands out
  in review.
* `-Wl,--wrap=__stack_chk_fail` with a `__wrap___stack_chk_fail` of the
  package's own is not reported. The guard check looks for the exact names,
  and with the wrap the library no longer imports `__stack_chk_fail`, so a
  smashed stack returns instead of aborting. The link option and the
  function both stand out in review.
* `-wrapper` is not among the options GCC reports, so `driver-override`
  never names it. A wrapper the build wrote fails as `untrusted-tool`, and
  what it makes as unattributed if it ships, but the gate does not say
  `-wrapper` was the cause.
* `packaging/` is outside CODEOWNERS and the ratchet's configuration list,
  since every release bumps the versions there. A spec's build sections,
  its flag macros and its annobin switch are checked by `classify`, which
  is under both, and the `rpm` gate requires the notes.
* The `rpm` cases in `tests/gates/attacks.py` need Fedora's `rpmbuild` and
  `annocheck`, so a run where the C++ gates run reports them as not run;
  they run in a container like the `rpm` job's.
* The gates build with GCC. A compile by another compiler bypasses the shim
  and shows as unattributed, so it fails rather than passes.
* The `rpm` gate judges what `annocheck` reads from the compiler's notes and
  what the ELF checks see. The warnings, pragmas, `NOLINT` comments and
  source-level checks `cpp-harden` makes are made on the Arch build only. The
  RPM it audits is the one `scene-plugin.yml` builds from the spec on
  `fedora:latest` with the COPR's Hyprland, not one a release builds in COPR.
* A file with a known data suffix that a script sources is linted only once
  `classified.tsv` lists it as `sh` or `bash`, as `packaging/paths.conf` is.
* The gates are code in this repository, reviewed like any other. GitHub runs
  the pull request's own copy of each workflow, so a pull request can remove
  a step. The ratchet reports that edit, and only branch protection makes it
  matter; see below.

#### How the audited build differs from the shipped one

* Flags. The gate empties Arch's `CFLAGS`, `CXXFLAGS`, `CPPFLAGS` and
  `LDFLAGS`, so only what this repository asks for counts. Arch's stock flags
  harden on their own, so the gate is stricter than an Arch build there.
* LTO and debug packages. The gate builds with `!lto !debug`. Stock
  `makepkg` turns both on, so the shipped code is what LTO makes of each
  compile, which the gate never judges, and the debug symbols are split out.
* Packages. The gate's compiler and headers come from one Arch Linux Archive
  day (`ARCH_SNAPSHOT`); a release or a user's build uses what is current.
* Source. The gate builds a tarball of the files git tracks. A release builds
  the forge's archive of its tag, which holds the same files while the
  repository has no `.gitattributes` export rules.
* Dependencies. The gate builds with `--nodeps`; CI installs each package's
  `makedepends` and `checkdepends`, not its `depends`.
* `check()` runs in both.

#### Branch protection the gates need

`.github/CODEOWNERS` names the owner for the gates, the workflows, the
hardening flags and the linter configurations. Neither CODEOWNERS nor a
failing check stops a merge until `main` has a branch protection rule (or a
ruleset) with these settings, which only the repository's owner can set:

* Require a pull request before merging, with 1 approval, "Require review
  from Code Owners", "Dismiss stale pull request approvals when new commits
  are pushed" and "Require approval of the most recent reviewable push".
* Require status checks to pass, with "Require branches to be up to date
  before merging", and these checks required: `Shell, Python and Lua` and
  `C++ packages, sanitizers and clang-tidy` (Safety gates),
  `Build against Hyprland headers, sealed` and `SRPM → RPM (%check) →
  rpmlint` (Scene plugin), `lint` (CI), and the checks of the `arch` and
  `rpm` jobs in `package.yml` and the `arch` job in `scene-plugin.yml`,
  which GitHub names after the reusable workflows' own jobs.
* "Do not allow bypassing the above settings", so an administrator's merge
  is held to them too, and no force pushes or deletions.

GitHub does not let anyone approve their own pull request. With one code
owner, the owner's own pull requests that touch these paths cannot then be
approved by anyone else who counts. They need a second code owner, or the
owner turns off "Do not allow bypassing" for that merge, which the audit log
records. A pull request from anyone else needs the owner's approval.

CI builds C++ with the packages of one Arch Linux Archive day, `ARCH_SNAPSHOT`
in `.github/workflows/safety-gates.yml`, so a GCC, Clang or Hyprland release
changes no count until that line moves. To move it, pick a later day under
`https://archive.archlinux.org/repos/`, run the C++ gates in
`archlinux:latest` with that day's mirror (the workflow's install step shows
how), and commit the new day with whatever `--update --allow-growth` writes.
The pull request names what each new baseline line is, like any baseline
growth. A local run uses whatever compiler is installed, so its counts can
differ from CI's. A local run judges only the files git tracks. Without a tool
the C++ gates need, a run fails with `toolchain cannot-run`, locally as in CI.

What already broke a rule when its gate arrived is counted in
`tests/gates/baseline.tsv`, one line per gate, file, rule and the text the
finding names: the source lines for a linter or compiler finding, the rule
for a whole compile or ELF file. The line carries the text and its hash, so
fixing one finding and adding another of the same rule in the same file
fails. A count may only fall. Finding more than the count fails, and so does
finding fewer until the line is lowered with
`tests/gates/check.sh <gate> --update`.

A line that moves keeps its text, so its row still counts it. A line that is
edited keeps its row too: when a baselined text is no longer found, and the
lines of the file most like it now (by `difflib`, at least 0.6 alike) carry a
new finding of the same rule, the row's count moves to that text. A fixed
line and a new line of the same rule elsewhere in the file do not match this
way, since the fixed line is still the one most like the old text. The
match runs over one to four lines at a time, so a statement that a formatter
wraps over several lines, or joins into one, keeps its rows: each new finding
of the rule on the lines most like the old text takes its share of the
count. `--update` then writes the new text, and the ratchet takes those
rewritten rows by the same test, so a pure reformat needs no `Gate-change:`
reason. When an edit both fixes a finding and adds one of the same rule
elsewhere, the gate prints one FAIL, for the new finding, with the
`--update --allow-growth` hint.

A new or higher line in the baseline is an ordinary edit
(`--update --allow-growth` writes it). On a pull request,
`tests/gates/ratchet.py` compares the base commit's baseline, file classes and
configurations with the pull request's. CI runs the base branch's copy of it,
so a pull request cannot loosen the ratchet itself. A new or higher baseline
line, a new file in a class no gate reads (a `cpp-test` source excepted,
since it ships nothing), a changed class, or any change to a linter
configuration, `plugins/cmake/`, `tests/gates/` (the gates, their fixtures
and pinned tools) or `.github/` (the workflows and CODEOWNERS) fails, unless
a commit or the pull request body has a line that starts with `Gate-change:`
and says why. The step prints each such change beside the reasons, for
review, and on GitHub it is also a warning on the run and a line in the job's
summary. GitHub does not rerun a workflow when only the body changes, so a
reason added to the body later needs a rerun of the `Shell, Python and Lua`
job.

The gates need `shellcheck`, `ruff` and `clang-tidy` at the versions pinned in
`tests/gates/requirements.txt`, `luacheck` 1.2.0, and for C++ `makepkg`,
`fakeroot`, `cmake`, GCC, `readelf`, `strace` and `setpriv`, with each
`PKGBUILD`'s build dependencies installed.

## License

MIT
