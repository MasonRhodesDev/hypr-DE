#!/usr/bin/env python3

import asyncio
import json
import os
import signal
import subprocess
import time
from collections import deque

import evdev

RUNTIME = os.environ["XDG_RUNTIME_DIR"]
SOCKET2 = "{}/hypr/{}/.socket2.sock".format(
    RUNTIME, os.environ["HYPRLAND_INSTANCE_SIGNATURE"]
)
LOG_PATH = f"{RUNTIME}/bp-game-focus.log"

BP_TITLE = "Steam Big Picture Mode"
BTN_MODE = evdev.ecodes.BTN_MODE
GUIDE_COOLDOWN = 0.4
FULLSCREEN_GRACE = 0.3
BP_LAUNCH_TIMEOUT = 20.0

STEAM_HOME = os.path.expanduser("~/.local/share/Steam")
CEF_LOG = f"{STEAM_HOME}/logs/cef_log.txt"
WEBHELPER_WRAP = f"{STEAM_HOME}/ubuntu12_64/steamwebhelper_sniper_wrap.sh"
CEF_RECOVER_FLAG = "--disable-gpu-process-crash-limit"
STEAM_LAUNCH = ["uwsm", "app", "--", "steam", "-cef-force-glx"]
CRASH_WINDOW = 45.0
CRASH_LIMIT = 3
RESTART_DEBOUNCE = 300.0

_log_file = open(LOG_PATH, "w", buffering=1)


def lua_str(value: str) -> str:
    escaped = value.replace("\\", "\\\\").replace('"', '\\"')
    return f'"{escaped}"'


def log(msg: str) -> None:
    _log_file.write(f"{time.strftime('%H:%M:%S')} {msg}\n")


def hyprctl(*args: str) -> str:
    p = subprocess.run(["hyprctl", *args], capture_output=True, text=True)
    if p.returncode != 0:
        log(f"hyprctl {' '.join(args)} failed ({p.returncode}): {p.stderr.strip()}")
    return p.stdout


def clients() -> list:
    return json.loads(hyprctl("clients", "-j") or "[]")


def active_window() -> dict:
    out = hyprctl("activewindow", "-j").strip()
    return json.loads(out) if out.startswith("{") else {}


def window_workspace(addr: str) -> str | None:
    return next(
        (c["workspace"]["name"] for c in clients() if c["address"] == addr), None
    )


def close_special_except(keep: str | None) -> None:
    for mon in json.loads(hyprctl("monitors", "-j") or "[]"):
        name = mon.get("specialWorkspace", {}).get("name", "")
        if name and name != keep:
            log(f"closing special workspace {name}")
            hyprctl("dispatch", f'hl.dsp.workspace.toggle_special({lua_str(name.removeprefix("special:"))})')


def ensure_webhelper_patch() -> None:
    try:
        with open(WEBHELPER_WRAP) as f:
            content = f.read()
    except OSError:
        return
    if CEF_RECOVER_FLAG in content:
        return
    target = 'exec ./steamwebhelper "$@"'
    if target not in content:
        log("webhelper patch: exec line not found, skipping")
        return
    try:
        with open(WEBHELPER_WRAP, "w") as f:
            f.write(content.replace(target, f"{target} {CEF_RECOVER_FLAG}"))
        log("webhelper patch: re-applied crash-limit flag (effective next launch)")
    except OSError as e:
        log(f"webhelper patch failed: {e}")


def restart_steam(reason: str) -> None:
    log(f"auto-recover: restarting Steam ({reason})")
    script = (
        "/usr/bin/steam -shutdown >/dev/null 2>&1; "
        "for _ in $(seq 30); do pgrep -x steam >/dev/null || break; sleep 1; done; "
        "pgrep -x steam >/dev/null && { pkill -x steam; sleep 2; }; "
        f"{' '.join(STEAM_LAUNCH)}"
    )
    subprocess.Popen(
        ["bash", "-c", script],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        start_new_session=True,
    )


LAUNCHER_CLASSES = {"org.prismlauncher.PrismLauncher"}


def window_pid(addr: str) -> int | None:
    return next((c["pid"] for c in clients() if c["address"] == addr), None)


def under_steam_launch(pid: int | None) -> bool:
    for _ in range(40):
        if not pid or pid <= 1:
            return False
        try:
            with open(f"/proc/{pid}/cmdline", "rb") as f:
                if b"SteamLaunch" in f.read():
                    return True
            with open(f"/proc/{pid}/stat") as f:
                stat = f.read()
        except OSError:
            return False
        pid = int(stat.rpartition(")")[2].split()[1])
    return False


def is_game(cls: str, title: str, pid: int | None = None) -> bool:
    if cls in LAUNCHER_CLASSES or cls == "steam":
        return False
    if cls.startswith("steam_app_") or cls == "gamescope" or title == "Godot":
        return True
    return under_steam_launch(pid)


class SteamSession:
    DESKTOP, BP, GAME = "DESKTOP", "BP", "GAME"

    def __init__(self) -> None:
        self.state = self.DESKTOP
        self.bp_addr: str | None = None
        self.games: dict[str, str] = {}
        self._last_guide = 0.0
        self._pending_bp = 0.0
        self.resync()

    def resync(self) -> None:
        self.bp_addr = None
        self.games.clear()
        for c in clients():
            if c["class"] == "steam" and c["title"] == BP_TITLE:
                self.bp_addr = c["address"]
            elif is_game(c["class"], c["title"], c["pid"]):
                self.games[c["address"]] = c["class"]
        self.on_active(active_window().get("address"))
        log(f"resync: state={self.state} bp={self.bp_addr} games={list(self.games)}")

    def on_open(self, addr: str, cls: str, title: str) -> None:
        if cls == "steam" and title == BP_TITLE:
            self.bp_addr = addr
            log(f"BP opened: {addr}")
            if time.monotonic() - self._pending_bp < BP_LAUNCH_TIMEOUT:
                self._pending_bp = 0.0
                log("guide-launched BP -> focus + close special")
                asyncio.create_task(self.focus_bp(addr))
        elif is_game(cls, title, window_pid(addr)):
            self.games[addr] = cls
            if self.state in (self.BP, self.GAME):
                log(f"game {cls} opened in {self.state} -> steal focus")
                asyncio.create_task(self.focus_fullscreen(addr))
            else:
                log(f"game {cls} opened on {self.state} -> background")

    def on_close(self, addr: str) -> None:
        if addr == self.bp_addr:
            self.bp_addr = None
            log("BP closed")
        elif self.games.pop(addr, None):
            log(f"game closed: {addr}")

    def on_active(self, addr: str | None) -> None:
        prev = self.state
        if addr and addr == self.bp_addr:
            self.state = self.BP
            self.ensure_bp_fullscreen()
        elif addr in self.games:
            self.state = self.GAME
        else:
            self.state = self.DESKTOP
        if self.state != prev:
            log(f"state: {prev} -> {self.state}")

    def on_fullscreen(self, flag: str) -> None:
        if flag == "0" and self.state == self.BP:
            self.ensure_bp_fullscreen()

    def on_guide(self) -> None:
        now = time.monotonic()
        if now - self._last_guide < GUIDE_COOLDOWN:
            return
        self._last_guide = now

        if self.games:
            addr = next(reversed(self.games))
            log(f"guide -> focus game {self.games[addr]}")
            asyncio.create_task(self.focus_fullscreen(addr))
        elif self.bp_addr:
            log("guide -> focus Big Picture")
            asyncio.create_task(self.focus_bp(self.bp_addr))
        else:
            log("guide -> launching Big Picture")
            self._pending_bp = now
            subprocess.Popen(
                ["uwsm", "app", "--", "steam", "steam://open/bigpicture"],
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
            )

    async def focus_bp(self, addr: str) -> None:
        hyprctl("dispatch", f'hl.dsp.focus({{ window = {lua_str(f"address:{addr}")} }})')
        close_special_except(window_workspace(addr))
        await asyncio.sleep(FULLSCREEN_GRACE)
        self.ensure_bp_fullscreen()

    async def focus_fullscreen(self, addr: str) -> None:
        hyprctl("dispatch", f'hl.dsp.focus({{ window = {lua_str(f"address:{addr}")} }})')
        close_special_except(window_workspace(addr))
        await asyncio.sleep(FULLSCREEN_GRACE)
        aw = active_window()
        if aw.get("address") == addr and aw.get("fullscreen") != 2:
            hyprctl("dispatch", 'hl.dsp.window.fullscreen({ mode = "fullscreen", action = "set" })')

    def ensure_bp_fullscreen(self) -> None:
        aw = active_window()
        if aw.get("address") == self.bp_addr and aw.get("fullscreen") != 2:
            log("re-fullscreening Big Picture")
            hyprctl("dispatch", 'hl.dsp.window.fullscreen({ mode = "fullscreen", action = "set" })')



async def hypr_events(sm: SteamSession) -> None:
    reader, writer = await asyncio.open_unix_connection(SOCKET2)
    try:
        await _read_events(reader, sm)
    finally:
        writer.close()


async def _read_events(reader: asyncio.StreamReader, sm: SteamSession) -> None:
    while line := await reader.readline():
        event, _, data = line.decode(errors="replace").rstrip("\n").partition(">>")
        if event == "openwindow":
            addr, _, rest = data.partition(",")
            _ws, _, rest = rest.partition(",")
            cls, _, title = rest.partition(",")
            sm.on_open("0x" + addr, cls, title)
        elif event == "closewindow":
            sm.on_close("0x" + data)
        elif event == "activewindowv2":
            sm.on_active("0x" + data if data else None)
        elif event == "fullscreen":
            sm.on_fullscreen(data)
    log("Hyprland socket closed, exiting")


async def watch_gamepad(sm: SteamSession, dev: evdev.InputDevice, watched: set) -> None:
    try:
        async for ev in dev.async_read_loop():
            if ev.type == evdev.ecodes.EV_KEY and ev.code == BTN_MODE and ev.value == 1:
                log(f"guide press from {dev.name}")
                sm.on_guide()
    except OSError:
        log(f"gamepad disconnected: {dev.name}")
    finally:
        watched.discard(dev.path)
        try:
            dev.close()
        except OSError:
            pass


async def gamepad_scanner(sm: SteamSession) -> None:
    watched: set[str] = set()
    while True:
        for path in evdev.list_devices():
            if path in watched:
                continue
            try:
                dev = evdev.InputDevice(path)
                if BTN_MODE in dev.capabilities().get(evdev.ecodes.EV_KEY, []):
                    watched.add(path)
                    log(f"watching gamepad: {dev.name} ({path})")
                    asyncio.create_task(watch_gamepad(sm, dev, watched))
                else:
                    dev.close()
            except OSError:
                pass
        await asyncio.sleep(3)


async def cef_log_watch(sm: SteamSession) -> None:
    crashes: deque[float] = deque()
    last_restart = 0.0
    last_patch = time.monotonic()
    f = None
    inode = None
    while True:
        try:
            if f is None:
                f = open(CEF_LOG)
                st_ino = os.fstat(f.fileno()).st_ino
                if inode is None or st_ino == inode:
                    f.seek(0, 2)
                inode = st_ino
            line = f.readline()
            if not line:
                st = os.stat(CEF_LOG)
                if st.st_ino != inode or st.st_size < f.tell():
                    f.close()
                    f = None
                    continue
                if time.monotonic() - last_patch > 120:
                    last_patch = time.monotonic()
                    ensure_webhelper_patch()
                await asyncio.sleep(1.0)
                continue
            if "GPU process exited unexpectedly" not in line:
                continue
            now = time.monotonic()
            crashes.append(now)
            while crashes and now - crashes[0] > CRASH_WINDOW:
                crashes.popleft()
            log(f"CEF GPU crash detected ({len(crashes)} within {int(CRASH_WINDOW)}s)")
            if (
                len(crashes) >= CRASH_LIMIT
                and not sm.games
                and now - last_restart > RESTART_DEBOUNCE
            ):
                last_restart = now
                crashes.clear()
                restart_steam(f"{CRASH_LIMIT} GPU crashes within {int(CRASH_WINDOW)}s")
        except FileNotFoundError:
            f = None
            await asyncio.sleep(2.0)
        except OSError as e:
            log(f"cef_log_watch error: {e}")
            if f is not None:
                f.close()
            f = None
            await asyncio.sleep(2.0)


async def main() -> None:
    ensure_webhelper_patch()
    sm = SteamSession()
    asyncio.get_running_loop().add_signal_handler(signal.SIGUSR1, sm.on_guide)
    gamepads = asyncio.create_task(gamepad_scanner(sm))
    cefwatch = asyncio.create_task(cef_log_watch(sm))
    await hypr_events(sm)
    gamepads.cancel()
    cefwatch.cancel()


if __name__ == "__main__":
    asyncio.run(main())
