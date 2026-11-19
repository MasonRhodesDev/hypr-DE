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

A lock request never fails open. If `vigil-lock` cannot take the session,
`lock-cmd.sh` retries outside its transient scope, then tries any other
installed locker (default `swaylock -f|gtklock -d|hyprlock &`), and if nothing
locks it **terminates the session** rather than hand back a live desktop the
user believes is locked. (Since 0.2.25 nothing blanks an unlocked session, so
an exposed desktop at least stays visibly exposed — but it is still exposed,
which is what the failsafe exists to prevent.)

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

`graphical-session.target` waits for uwsm to see the Wayland environment.
hypr-DE's `/etc/xdg/uwsm/env-hyprland` sets `UWSM_WAIT_VARNAMES_SETTLETIME`
to 0, because hypr-DE exports the session's variables in one call, and that
takes uwsm's 0.2 s settle pause off every login. A value set earlier in the environment,
or in `~/.config/uwsm/env-hyprland`, wins.

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
| `classify` | A file the other gates cannot place that `tests/gates/classified.tsv` does not list: a file with no suffix or a suffix outside the gate's known list, a `CMakeLists.txt` other than a plugin's own, a C or C++ file outside a plugin directory. A committed object file, archive or ELF binary. A listed class that a shebang or the executable bit contradicts. Never baselined. |
| `shell` | Anything `shellcheck` reports with every optional check on, in every shell script, `PKGBUILD`, `.install` file and RPM scriptlet (`%post` and the rest), and a `shellcheck disable` directive. A script is found by its suffix (`.sh`, `.bash`), by a shebang that names a shell, or by its class in `classified.tsv`. A shebang or scriptlet interpreter that `shellcheck` cannot read, such as `zsh`, fails and is never baselined. |
| `python` | `ruff` with the bandit, bugbear and pylint rules in `ruff.toml`, and a `noqa` or `ruff:` comment. |
| `lua` | `luacheck` findings (`.luacheckrc`) and inline `luacheck:` comments. |
| `cpp-harden` | What the packages ship, described below. |
| `cpp-sanitize` | A plugin whose tests fail under AddressSanitizer and UndefinedBehaviorSanitizer, that registers no test with `add_test`, or that compiles a source of its own with a sanitizer off. |
| `cpp-tidy` | `clang-tidy` findings from `plugins/.clang-tidy` in every compile `cpp-harden` checks, in every header of this repository they include and in every file their build writes. |
| `cpp-selftest` | The C++ gates themselves, if they stop catching a known-bad case of `tests/gates/cpp-fixture` or report anything in its clean build. Never baselined. |

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
`classified.tsv` lists as `pkgbuild`: its own `prepare()`, `build()` and
`package()`, from a tarball of the tracked files with no `.git`, with an empty
environment, and with the distribution's compiler flags emptied so that only
what this repository asks for counts. As root it builds as an unprivileged
user. The tarball stands in for the `PKGBUILD`'s remote source, unpacked as
`<last part of url>-<pkgver>`, the way a forge's release archive unpacks.

`tests/gates/shim.py` stands in for the GCC drivers on `PATH` during the
build. For each compile it keeps GCC's own job list (`-###`) and the
preprocessor's view of the source with the compile's own arguments
(`-E -dD -C`). For each link it keeps every file the linker read. Then, for
every ELF file in the package:

* It is position independent, has full RELRO and immediate binding, a stack
  that is not executable, the CET note on x86-64, no `RPATH` or `RUNPATH` and
  no text relocations.
* It imports no plain `printf`, `sprintf`, `vsnprintf`, `syslog` or their
  siblings, which fortify always replaces. A plain `memcpy` or `strcpy` is
  fortify's own answer when it cannot see a buffer's size, so it counts for
  nothing.
* Its build ID matches a link the shim saw, its executable sections are the
  ones that link wrote, and every object that link read comes from a compile
  the shim saw, or from a file the build user cannot write. Anything else is `unattributed`, which is never baselined. So is an
  object built with LTO, since the gate cannot see what LTO makes of it.

For every compile behind a shipped file, and every compile of a tracked
source:

* `_FORTIFY_SOURCE` and glibc's `__USE_FORTIFY_LEVEL` are 3,
  `_GLIBCXX_ASSERTIONS` is defined and `NDEBUG` is not, at every `#include`
  and at the end. The preprocessor's own `#define` and `#undef` lines show
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
  `no_stack_protector` or `no_sanitize` attribute, a `#pragma GCC optimize`,
  `push_options` or `target`, a diagnostic pragma that ignores a warning, and
  a `NOLINT` comment.

Compiler warnings are read from what each compile wrote, as the shim saw it,
so a `build()` that discards its output keeps every count. A call that only
assembles or preprocesses is not a compile the gate can judge, so what it
makes is unattributed. A C or C++ file in a
plugin directory that no compile read, and that `classified.tsv` does not
list, fails as `not-built`. `cpp-tidy` runs on the compiles the shim recorded,
so it sees what GCC compiled, unity files and generated sources included.
`cpp-sanitize` builds each plugin with `HYPR_DE_SANITIZE=ON` through the same
shim and runs its tests.

Every reviewed attack on these gates is a case in `tests/gates/attacks.py`,
which makes each change on a fresh clone of `HEAD`, runs the gates and checks
for the exact FAIL line. Run it where the C++ gates run:
`python3 -I tests/gates/attacks.py [case ...]`. The self-test covers the same
mechanisms on the fixture in every CI run.

#### What still passes

* The shim's records live where the build user can write. A build that forges
  them, rather than weakening a flag, is not caught; a reviewer sees a build
  step that writes into the gate's directory.
* A compile that ships nothing and whose source is not tracked, such as a
  CMake probe, is not judged.
* Inline assembly, `.incbin` and linker script data are judged only as part of
  the compile that holds them.
* Fortify is proven per compile, not per call. A call fortify cannot size
  stays unchecked by design, and a call through a function pointer to
  anything but the printf family goes unseen.
* The build may reach the network. Code it downloads and links is
  unattributed, but a downloaded script or data file is not judged.
* The gates build with GCC. A compile by another compiler bypasses the shim
  and shows as unattributed, so it fails rather than passes.
* Arch's stock `makepkg` flags harden on their own; the gate empties them, so
  it is stricter than an Arch build, and it does not exercise stock LTO or
  debug splitting.
* The RPM spec is not built, so its `%build` is not audited. Its scriptlets are
  linted. Building it needs a Fedora container, which CI does not have yet.
* A file with a known data suffix that a script sources is linted only once
  `classified.tsv` lists it as `sh` or `bash`, as `packaging/paths.conf` is.
* The gates are code in this repository, reviewed like any other. A pull
  request that changes `gate.py` or `shim.py` is also judged by its base
  branch's gates, so loosening a rule and leaning on it in the same change
  shows up as a failing step. GitHub runs the pull request's own copy of the
  workflow, so a change can also remove that step; the reviewer sees the
  workflow edit. A change that renames a rule fails that step on purpose, and
  the reviewer judges it.

CI builds C++ with the packages of one Arch Linux Archive day, `ARCH_SNAPSHOT`
in `.github/workflows/safety-gates.yml`, so a GCC, Clang or Hyprland release
changes no count until that line moves. To move it, pick a later day under
`https://archive.archlinux.org/repos/`, run the C++ gates in
`archlinux:latest` with that day's mirror (the workflow's install step shows
how), and commit the new day with whatever `--update --allow-growth` writes.
The pull request names what each new baseline line is, like any baseline
growth. A local run uses whatever compiler is installed, so its counts can
differ from CI's. Without `makepkg` a local run prints `skipped` for the C++
gates. CI may not skip.

What already broke a rule when its gate arrived is counted in
`tests/gates/baseline.tsv`, one line per gate, file and rule. A count may only
fall. Finding more than the count fails, and so does finding fewer until the
line is lowered with `tests/gates/check.sh <gate> --update`.

A new or higher line in the baseline is an ordinary edit
(`--update --allow-growth` writes it). The pull request says why it is needed,
and the usual independent review judges that, as it judges a change to a linter
configuration, to `plugins/cmake/Safety.cmake` or to the gates themselves.

The gates need `shellcheck`, `ruff` and `clang-tidy` at the versions pinned in
`tests/gates/requirements.txt`, `luacheck` 1.2.0, and for C++ `makepkg`,
`fakeroot`, `cmake`, GCC and `readelf`, with each `PKGBUILD`'s build
dependencies installed.

## License

MIT
