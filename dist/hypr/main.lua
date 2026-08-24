-- hypr-DE: packaged Hyprland Lua configuration.
-- Loaded from /etc/xdg/hypr/hyprland.lua (XDG_CONFIG_DIRS) unless the user
-- has their own ~/.config/hypr/hyprland.lua. That entry dofiles this file,
-- then pcall's ~/.config/hypr/local.lua (last-wins) — EXCEPT monitor
-- config, which belongs in ~/.config/hypr/profiles/ (hyprstate selects the
-- matching profile; local.lua runs after the profile and the edp-off marker
-- and would clobber both).
--
-- Colors come from lmtt (dofile lmtt-colors.lua); monitors come from hyprstate
-- (dofile profiles/.active.lua). Both are guarded so a fresh machine still
-- boots before those files exist.

local HOME = os.getenv("HOME")
local CONFIG = os.getenv("XDG_CONFIG_HOME")
if not CONFIG or CONFIG == "" then
    CONFIG = HOME .. "/.config"
end

local function file_exists(p)
    local f = io.open(p, "r")
    if f then f:close() return true end
    return false
end

----------------------------------------------------------------------
-- COLORS (lmtt) -----------------------------------------------------
-- lmtt regenerates ~/.config/hypr/lmtt-colors.lua on every `lmtt switch`;
-- it returns a table of pre-formatted Hyprland color values. Fallback below
-- keeps borders sane on first boot before lmtt has run.
----------------------------------------------------------------------
local colors_path = CONFIG .. "/hypr/lmtt-colors.lua"
local c = {
    primary         = "rgb(ffb77a)",
    secondary       = "rgb(e3c0a5)",
    outline         = "rgb(9e8e82)",
    surface         = "rgb(19120c)",
    on_surface      = "rgb(efe0d6)",
    tertiary        = "rgb(c4cb97)",
    tertiary_container = "rgb(434a22)",
    active_border   = { colors = { "rgb(ffb77a)", "rgb(e3c0a5)" }, angle = 45 },
    inactive_border = "rgb(9e8e82)",
    shadow          = "rgb(000000)",
}
if file_exists(colors_path) then
    local ok, loaded = pcall(dofile, colors_path)
    if ok and type(loaded) == "table" then c = loaded end
end

----------------------------------------------------------------------
-- PLUGINS -----------------------------------------------------------
----------------------------------------------------------------------
-- workspace-zones (waybar-workspace-buttons repo): workspace N owns special:N,
-- auto-dismissed on leave. Wrapped in pcall: `hyprctl reload` re-executes this
-- file with the plugin already loaded, which would otherwise error and abort
-- the whole config.
--
-- A ~/.local copy wins so a hyprland-git rebuild is not shadowed by the
-- extra-hyprland .so the Arch package ships. Packaged paths cover a fresh
-- install that has never run hyprpm.
pcall(function()
    local home_plug = HOME .. "/.local/lib/hyprland-plugins/libworkspace-zones.so"
    local path
    if file_exists(home_plug) then
        path = home_plug
    else
        for _, candidate in ipairs({
            "/usr/lib/hyprland/plugins/libworkspace-zones.so",
            "/usr/lib64/hyprland/plugins/libworkspace-zones.so",
        }) do
            if file_exists(candidate) then
                path = candidate
                break
            end
        end
    end
    if path then
        hl.plugin.load(path)
    end
end)
-- Named specials (special:magic) dismiss via the built-in
-- binds.hide_special_on_workspace_change (see LOOK AND FEEL) — verified
-- same-monitor scoped: it hides only the special on the TARGET workspace's
-- monitor, and also covers switching to the workspace already underneath.

----------------------------------------------------------------------
-- MONITORS (hyprstate) ----------------------------------------------
-- hyprstate repoints profiles/.active.lua and runs `hyprctl reload`. The
-- active profile is a script that calls hl.monitor()/hl.workspace_rule()
-- directly, so we just execute it for side effects (idempotent on reload).
----------------------------------------------------------------------
-- Helpers for profile scripts (globals — .active.lua is dofile'd into this
-- same Lua state). Wayland fractional scaling only accepts scales k/120 that
-- yield an integer logical size for the mode; anything else Hyprland snaps to
-- the nearest valid value (logging a configerrors warning). mon.valid_scale
-- does that snap up front so profiles can just state a target.
mon = {}

function mon.valid_scale(w, h, target)
    local best, bestd = target, math.huge
    for k = 120, 360 do -- scales 1.0 .. 3.0 in 1/120 steps
        if (w * 120) % k == 0 and (h * 120) % k == 0 then
            local d = math.abs(k / 120 - target)
            if d < bestd then best, bestd = k / 120, d end
        end
    end
    return best
end

-- Row layout: place entries left-to-right at y=0. Each entry gets the closest
-- valid scale to its target and an x position accumulated from the previous
-- entries' logical widths — no hardcoded offsets to keep in sync.
-- Entry: { output=, w=, h=, hz=, scale=<target>, [transform=] }
function mon.row(entries)
    local x = 0
    for _, e in ipairs(entries) do
        local s = mon.valid_scale(e.w, e.h, e.scale)
        hl.monitor({
            output    = e.output,
            mode      = e.w .. "x" .. e.h .. "@" .. e.hz,
            position  = x .. "x0",
            scale     = s,
            transform = e.transform,
        })
        -- odd transforms rotate to portrait: logical width comes from e.h
        local px = (e.transform and e.transform % 2 == 1) and e.h or e.w
        x = x + math.floor(px / s + 0.5)
    end
end

-- Fallback catch-all FIRST: rules replace by output name and last-added wins,
-- so the profile's explicit rules (dofile'd below) override this, not the
-- other way around. Per-machine fallbacks belong in profiles (hyprstate's
-- lowest-priority profile plays that role), not here and not in local.lua.
hl.monitor({ output = "", mode = "preferred", position = "auto", scale = 1 })

local active_profile = CONFIG .. "/hypr/profiles/.active.lua"
if file_exists(active_profile) then
    pcall(dofile, active_profile)
end

-- hyprstate lid/dock policy: marker present = internal panel forced off.
-- Added last so it wins over both the fallback and the profile. Runtime state
-- owned by the hyprstate daemon (paths::edp_off_marker); deliberately
-- unmanaged. Absent marker = panel enabled, the fail-safe boot default.
-- A non-empty first line names the output to disable; an empty marker (what
-- hyprstate writes today) disables the common internal-panel names — a rule
-- for an absent output is a no-op.
if file_exists(CONFIG .. "/hypr/edp-off") then
    local f = io.open(CONFIG .. "/hypr/edp-off", "r")
    local name = f and f:read("l") or nil
    if f then f:close() end
    if name and name ~= "" then
        hl.monitor({ output = name, disabled = true })
    else
        hl.monitor({ output = "eDP-1", disabled = true })
        hl.monitor({ output = "eDP-2", disabled = true })
    end
end

----------------------------------------------------------------------
-- LOOK AND FEEL -----------------------------------------------------
----------------------------------------------------------------------
hl.config({
    general = {
        allow_tearing = false,
        border_size   = 4,
        gaps_in       = 5,
        gaps_out      = 5,
        layout        = "dwindle",
        col = {
            active_border   = c.primary,          -- solid primary
            inactive_border = c.inactive_border,  -- solid outline
        },
    },

    decoration = {
        rounding = 10,
        blur = {
            enabled = true,
            passes  = 1,
            size    = 3,
        },
    },

    dwindle = {
        preserve_split = true,
    },

    -- NOTE: group/groupbar gradient color accessors are version-sensitive in
    -- the Lua config; verify these render on first boot.
    group = {
        col = {
            border_active        = c.active_border,   -- gradient {colors, angle}
            border_inactive      = c.inactive_border,
            border_locked_active = "rgb(a584bb)",
        },
        groupbar = {
            text_color = "rgb(ffdea3)",
            col = {
                active   = c.active_border,
                inactive = c.inactive_border,
            },
        },
    },

    binds = {
        -- Changing workspaces hides the special open on the TARGET workspace's
        -- monitor (built-in same-monitor rule). Unlike the plugin's
        -- workspace.active listener, this also covers switching to the
        -- workspace already underneath the special (no event fires there).
        hide_special_on_workspace_change = true,
    },

    input = {
        kb_layout    = "us",
        follow_mouse = 1,
        sensitivity  = 0,
        touchpad = {
            natural_scroll = false,
        },
    },

    misc = {
        background_color        = "rgb(101c32)",
        disable_hyprland_logo   = false,
        disable_splash_rendering = false,
        force_default_wallpaper = 1,
        focus_on_activate       = true,
        -- Direct setDPMS(true) on input. After VT return with outputs
        -- DPMS-disabled, Aquamarine will not schedule frames (enabledState
        -- false); this path modesets without waiting for a frame.
        mouse_move_enables_dpms = true,
        key_press_enables_dpms  = true,
    },

    cursor = {
        no_hardware_cursors = true,
        use_cpu_buffer      = true,
        enable_hyprcursor   = true,
    },

    render = {
        direct_scanout = 0,
    },
})

----------------------------------------------------------------------
-- ANIMATIONS --------------------------------------------------------
----------------------------------------------------------------------
hl.config({ animations = { enabled = true } })
hl.curve("myBezier", { type = "bezier", points = { { 0.05, 0.9 }, { 0.1, 1.05 } } })
hl.animation({ leaf = "windows",     enabled = true, speed = 7,  bezier = "myBezier" })
hl.animation({ leaf = "windowsOut",  enabled = true, speed = 7,  bezier = "default", style = "popin 80%" })
hl.animation({ leaf = "border",      enabled = true, speed = 10, bezier = "default" })
hl.animation({ leaf = "borderangle", enabled = true, speed = 8,  bezier = "default" })
hl.animation({ leaf = "fade",        enabled = true, speed = 7,  bezier = "default" })
hl.animation({ leaf = "workspaces",  enabled = true, speed = 6,  bezier = "default" })

----------------------------------------------------------------------
-- KEYBINDINGS -------------------------------------------------------
----------------------------------------------------------------------
local mainMod = "SUPER"
local meh     = "CTRL + ALT + SHIFT"
local hyper   = "SUPER + ALT + SHIFT"

-- Apps / window management. Every bind carries desc = "Category: text" —
-- hypr-de-help (SUPER+/) and the fuzzel cheatsheet (SUPER+SHIFT+/) group
-- and filter on the category prefix. Follow the convention in local.lua.
hl.bind(mainMod .. " + Q", hl.dsp.exec_cmd("uwsm app -- kitty"),  { desc = "Apps: Terminal" })
hl.bind(mainMod .. " + C", hl.dsp.window.close(),                 { desc = "Windows: Close window" })
hl.bind(mainMod .. " + E", hl.dsp.exec_cmd("uwsm app -- nautilus"), { desc = "Apps: File manager" })
hl.bind(mainMod .. " + V", function()
    -- Hyprland bug workaround: unfloating a pinned window only clears the pin
    -- (window stays floating) AND skips the window-rule re-evaluation, leaving
    -- the pinned-border color stuck. Unpin via the dispatcher first (which
    -- refreshes rules), then unfloat — one press instead of two, correct border.
    local w = hl.get_active_window()
    if w and w.pinned then
        hl.dispatch(hl.dsp.window.pin())
    end
    hl.dispatch(hl.dsp.window.float({ action = "toggle" }))
end, { desc = "Windows: Toggle floating" })
hl.bind(mainMod .. " + SHIFT + V", hl.dsp.window.pin(),  { desc = "Windows: Pin (show on all workspaces)" })
hl.bind(mainMod .. " + R", hl.dsp.exec_cmd("pkill fuzzel || uwsm app -- fuzzel --config @DATADIR@/fuzzel/fuzzel.ini"), { desc = "Apps: App launcher" })
hl.bind(mainMod .. " + P", hl.dsp.window.pseudo(),       { desc = "Windows: Pseudo-tile" })
hl.bind(mainMod .. " + J", hl.dsp.layout("togglesplit"), { desc = "Windows: Toggle split direction" })
hl.bind(mainMod .. " + F", hl.dsp.window.fullscreen(),   { desc = "Windows: Fullscreen" }) -- defaults: mode=fullscreen, action=toggle

-- Focus movement
hl.bind(mainMod .. " + left",  hl.dsp.focus({ direction = "left" }),  { desc = "Focus: Focus left" })
hl.bind(mainMod .. " + right", hl.dsp.focus({ direction = "right" }), { desc = "Focus: Focus right" })
hl.bind(mainMod .. " + up",    hl.dsp.focus({ direction = "up" }),    { desc = "Focus: Focus up" })
hl.bind(mainMod .. " + down",  hl.dsp.focus({ direction = "down" }),  { desc = "Focus: Focus down" })
hl.bind(meh .. " + h", hl.dsp.focus({ direction = "left" }),  { desc = "Focus: Focus left (vim)" })
hl.bind(meh .. " + j", hl.dsp.focus({ direction = "down" }),  { desc = "Focus: Focus down (vim)" })
hl.bind(meh .. " + k", hl.dsp.focus({ direction = "up" }),    { desc = "Focus: Focus up (vim)" })
hl.bind(meh .. " + l", hl.dsp.focus({ direction = "right" }), { desc = "Focus: Focus right (vim)" })

-- Move window within layout
hl.bind(mainMod .. " + SHIFT + left",  hl.dsp.window.move({ direction = "left" }),  { desc = "Windows: Move window left" })
hl.bind(mainMod .. " + SHIFT + right", hl.dsp.window.move({ direction = "right" }), { desc = "Windows: Move window right" })
hl.bind(mainMod .. " + SHIFT + up",    hl.dsp.window.move({ direction = "up" }),    { desc = "Windows: Move window up" })
hl.bind(mainMod .. " + SHIFT + down",  hl.dsp.window.move({ direction = "down" }),  { desc = "Windows: Move window down" })

-- Workspace switching
for i = 1, 9 do
    hl.bind(mainMod .. " + " .. i, hl.dsp.focus({ workspace = i }), { desc = "Workspaces: Go to workspace " .. i })
end
hl.bind(mainMod .. " + 0", hl.dsp.workspace.toggle_special("magic"), { desc = "Workspaces: Toggle scratchpad" })

-- Move active window to workspace
for i = 1, 9 do
    hl.bind(mainMod .. " + SHIFT + " .. i, hl.dsp.window.move({ workspace = i }), { desc = "Workspaces: Move window to workspace " .. i })
end
hl.bind(mainMod .. " + SHIFT + 0", hl.dsp.window.move({ workspace = 10 }), { desc = "Workspaces: Move window to workspace 10" })

-- Special "magic" scratchpad
hl.bind(mainMod .. " + S",         hl.dsp.workspace.toggle_special("magic"),          { desc = "Workspaces: Toggle scratchpad" })
hl.bind(mainMod .. " + SHIFT + S", hl.dsp.window.move({ workspace = "special:magic" }), { desc = "Workspaces: Move window to scratchpad" })

-- workspace-zones plugin: first-party Lua functions (hl.plugin.zones.*),
-- registered by the plugin via addLuaFunction. Closures resolve at keypress
-- time, so plugin load order doesn't matter; if the plugin is missing the
-- press logs a Lua error instead of silently doing nothing.
hl.bind("SUPER + ALT + S",        function() hl.plugin.zones.toggle() end,     { desc = "Workspaces: Toggle zone" })
hl.bind(hyper .. " + S",          function() hl.plugin.zones.move() end,       { desc = "Workspaces: Move window to zone" })
hl.bind("SUPER + CTRL + ALT + S", function() hl.plugin.zones.movesilent() end, { desc = "Workspaces: Move window to zone (silent)" })

-- Move current workspace between monitors (relative monitor selectors)
hl.bind(mainMod .. " + SHIFT + minus", hl.dsp.workspace.move({ monitor = "-1" }), { desc = "Workspaces: Move workspace to previous monitor" })
hl.bind(mainMod .. " + SHIFT + equal", hl.dsp.workspace.move({ monitor = "+1" }), { desc = "Workspaces: Move workspace to next monitor" })

-- Scroll through workspaces
hl.bind(mainMod .. " + mouse_down", hl.dsp.focus({ workspace = "e+1" }), { desc = "Workspaces: Next workspace (scroll)" })
hl.bind(mainMod .. " + mouse_up",   hl.dsp.focus({ workspace = "e-1" }), { desc = "Workspaces: Previous workspace (scroll)" })

-- Screenshots
hl.bind("Print",         hl.dsp.exec_cmd("@BINDIR@/hypr-de-snip"),   { desc = "Screenshots: Region screenshot + annotate" })
hl.bind("SHIFT + Print", hl.dsp.exec_cmd("@BINDIR@/hypr-de-record"), { desc = "Screenshots: Screen recording" })

-- Utilities
-- Through logind, not a hardcoded locker: hypridle's lock_cmd answers the
-- Lock signal, so Meta+L, idle timeout, and suspend all produce the SAME
-- lock screen (they diverged once: hyprlock here, vigil-lock on suspend).
hl.bind(mainMod .. " + L", hl.dsp.exec_cmd("loginctl lock-session"), { desc = "System: Lock screen" })
hl.bind(mainMod .. " + M", hl.dsp.exec_cmd("@LIBEXECDIR@/power-menu.sh"), { desc = "System: Power menu" })
hl.bind(mainMod .. " + T", hl.dsp.exec_cmd("lmtt switch"),                { desc = "System: Toggle light/dark theme" })
hl.bind(mainMod .. " + N", hl.dsp.exec_cmd("swaync-client -t -sw"),       { desc = "System: Notification center" })
hl.bind(mainMod .. " + slash",         hl.dsp.exec_cmd("@BINDIR@/hypr-de-help"), { desc = "Help: Welcome and keybinds" })
hl.bind(mainMod .. " + SHIFT + slash", hl.dsp.exec_cmd("@LIBEXECDIR@/hypr-de-cheatsheet"), { desc = "Help: Search keybinds" })
hl.bind(mainMod .. " + D", hl.dsp.exec_cmd([[wl-copy --clear && notify-send -t 2000 "Clipboard cleared" "Ready for drag-and-drop"]]), { desc = "System: Clear clipboard (drag-and-drop prep)" })

-- Cycle windows (floating), then raise (two dispatchers -> Lua fn calling both)
hl.bind("ALT + Tab", function()
    hl.dispatch(hl.dsp.window.cycle_next())
    hl.dispatch(hl.dsp.window.bring_to_top())
end, { desc = "Windows: Cycle floating windows" })
hl.bind("SHIFT + XF86AudioPlay", hl.dsp.exec_cmd("hyprpwcenter"), { desc = "System: Audio patchbay" })

-- Media / brightness (locked = active on lockscreen)
hl.bind("XF86AudioPlay", hl.dsp.exec_cmd("@LIBEXECDIR@/osd/media-osd.sh play-pause"), { locked = true, desc = "Media: Play/pause" })
hl.bind("XF86AudioStop", hl.dsp.exec_cmd("@LIBEXECDIR@/osd/media-osd.sh stop"),        { locked = true, desc = "Media: Stop" })
hl.bind("XF86AudioMute", hl.dsp.exec_cmd("wpctl set-mute @DEFAULT_AUDIO_SINK@ toggle"),                 { locked = true, desc = "Media: Mute" })
hl.bind("XF86AudioNext", hl.dsp.exec_cmd("@LIBEXECDIR@/osd/media-osd.sh next"),        { locked = true, desc = "Media: Next track" })
hl.bind("XF86AudioPrev", hl.dsp.exec_cmd("@LIBEXECDIR@/osd/media-osd.sh previous"),    { locked = true, desc = "Media: Previous track" })

-- Volume / brightness (locked + repeating)
hl.bind("XF86AudioRaiseVolume", hl.dsp.exec_cmd("wpctl set-volume -l 1.5 @DEFAULT_AUDIO_SINK@ 1%+"), { locked = true, repeating = true, desc = "Media: Volume up" })
hl.bind("XF86AudioLowerVolume", hl.dsp.exec_cmd("wpctl set-volume -l 1.5 @DEFAULT_AUDIO_SINK@ 1%-"), { locked = true, repeating = true, desc = "Media: Volume down" })
hl.bind("XF86MonBrightnessUp",   hl.dsp.exec_cmd("@LIBEXECDIR@/osd/brightness-osd.sh up"),   { locked = true, repeating = true, desc = "Media: Brightness up" })
hl.bind("XF86MonBrightnessDown", hl.dsp.exec_cmd("@LIBEXECDIR@/osd/brightness-osd.sh down"), { locked = true, repeating = true, desc = "Media: Brightness down" })

-- Mouse move/resize
hl.bind(mainMod .. " + mouse:272", hl.dsp.window.drag(),   { mouse = true, desc = "Windows: Drag window (mouse)" })
hl.bind(mainMod .. " + mouse:273", hl.dsp.window.resize(), { mouse = true, desc = "Windows: Resize window (mouse)" })

----------------------------------------------------------------------
-- WINDOW / WORKSPACE RULES ------------------------------------------
----------------------------------------------------------------------
-- No float-pin catch-all: floating windows already render above tiled on
-- their own workspace, and pinning forces them onto the regular workspace —
-- a float launched over a special would open under it and dismiss the
-- special on close. Deliberate pins stay explicit per-rule below; manual
-- pinning is SUPER+SHIFT+V.
-- Pinned windows get a high-contrast border so they're identifiable at a
-- glance ("pin" is a dynamic match; legacy string = "<active> <inactive>").
hl.window_rule({ name = "pinned-border",    match = { pin = true }, border_color = (c.tertiary or c.on_surface) .. " " .. (c.tertiary_container or c.outline) })
hl.window_rule({ name = "kitty-size",       match = { class = "^(kitty)$" }, size = "100 100" })
hl.window_rule({ name = "helvum-float",     match = { title = "^(Helvum)$" }, float = true })
hl.window_rule({ name = "pip",              match = { title = "^(Picture in picture)$" }, float = true, pin = true, opacity = "0.9 0.9" })
hl.window_rule({ name = "mainpicker",       match = { title = "^(MainPicker)$" }, opacity = "1 1" })
hl.window_rule({ name = "meet-sharing",     match = { title = "^(meet.google.com is sharing.*)$" }, opacity = "1 1", float = true, pin = true })
hl.window_rule({ name = "huddle",           match = { title = "^(Huddle.*)$" }, opacity = "1 1" })
hl.window_rule({ name = "bitwarden-float",  match = { title = "^(.*Bitwarden.*)$" }, float = true })
hl.window_rule({ name = "gcr-prompter",     match = { class = "^(gcr-prompter)$" }, float = true, pin = true, center = true, stay_focused = true })
hl.window_rule({ name = "pre-sleep",        match = { title = "^(PRE_SLEEP_WINDOW)$" }, float = true, move = "-2000 -2000", size = "10000 10000", opacity = "0.95 override 0.95 override 0.95 override", xray = false })
hl.window_rule({ name = "google-signin",    match = { title = "^(Sign in - Google Accounts.*)$" }, float = true })
hl.window_rule({ name = "hyprpwcenter",     match = { class = "^(hyprpwcenter)$" }, float = true, center = true, size = "1000 600", stay_focused = true, pin = true })
hl.window_rule({ name = "overskride",       match = { class = "^(io\\.github\\.kaii_lb\\.Overskride)$" }, float = true, center = true, stay_focused = true })
hl.window_rule({ name = "hypr-de-help",     match = { class = "^(dev\\.mason\\.hypr-de-help)$" }, float = true, center = true, size = "860 600", stay_focused = true })
hl.window_rule({ name = "satty",            match = { class = "^(com.gabm.satty)$" }, float = true, pin = true, center = true, stay_focused = true })
hl.window_rule({ name = "zoom-annotate",    match = { class = "^(zoom)$", title = "^(annotate_toolbar)$" }, float = true, size = "1 1", move = "-9999 -9999", opacity = "0.0 override 0.0 override", border_size = 0, no_blur = true, no_shadow = true, no_initial_focus = true, no_focus = true })

----------------------------------------------------------------------
-- AUTOSTART ---------------------------------------------------------
-- App autostarts (chat clients, Steam, etc.) belong in ~/.config/hypr/local.lua
-- — see local.lua.example.
----------------------------------------------------------------------
hl.on("hyprland.start", function()
    hl.exec_cmd("dbus-update-activation-environment --all")
    hl.exec_cmd("sleep 1 & dbus-update-activation-environment --systemd WAYLAND_DISPLAY XDG_CURRENT_DESKTOP")
    hl.exec_cmd("@LIBEXECDIR@/hypr-de-welcome")  -- one-time help window; marker-gated
end)
