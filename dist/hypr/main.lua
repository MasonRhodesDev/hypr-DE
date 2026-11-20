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

local zones = {}

local function zone_owner()
    local ws = hl.get_active_workspace()
    return ws and ws.id or nil
end

function zones.toggle()
    local id = zone_owner()
    if id then hl.dispatch(hl.dsp.workspace.toggle_special(tostring(id))) end
end

function zones.move(follow)
    local id = zone_owner()
    if id then hl.dispatch(hl.dsp.window.move({ workspace = "special:" .. id, follow = follow })) end
end

mon = {}

function mon.valid_scale(w, h, target)
    local best, bestd = target, math.huge
    for k = 120, 360 do
        if (w * 120) % k == 0 and (h * 120) % k == 0 then
            local d = math.abs(k / 120 - target)
            if d < bestd then best, bestd = k / 120, d end
        end
    end
    return best
end

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
        local px = (e.transform and e.transform % 2 == 1) and e.h or e.w
        x = x + math.floor(px / s + 0.5)
    end
end

hl.monitor({ output = "", mode = "preferred", position = "auto", scale = 1 })

local active_profile = CONFIG .. "/hypr/profiles/.active.lua"
if file_exists(active_profile) then
    pcall(dofile, active_profile)
end

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

hl.config({
    general = {
        allow_tearing = false,
        border_size   = 4,
        gaps_in       = 5,
        gaps_out      = 5,
        layout        = "dwindle",
        col = {
            active_border   = c.primary,
            inactive_border = c.inactive_border,
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

    group = {
        col = {
            border_active        = c.active_border,
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
        mouse_move_enables_dpms = true,
        key_press_enables_dpms  = true,
        -- lock-cmd.sh respawns vigil-lock onto a crashed lock screen. Set false and a crash ends
        -- the session instead (or warns, per /etc/hypr-de/lock.conf).
        allow_session_lock_restore = true,
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

hl.config({ animations = { enabled = true } })
hl.curve("myBezier", { type = "bezier", points = { { 0.05, 0.9 }, { 0.1, 1.05 } } })
hl.animation({ leaf = "windows",     enabled = true, speed = 7,  bezier = "myBezier" })
hl.animation({ leaf = "windowsOut",  enabled = true, speed = 7,  bezier = "default", style = "popin 80%" })
hl.animation({ leaf = "border",      enabled = true, speed = 10, bezier = "default" })
hl.animation({ leaf = "borderangle", enabled = true, speed = 8,  bezier = "default" })
hl.animation({ leaf = "fade",        enabled = true, speed = 7,  bezier = "default" })
hl.animation({ leaf = "workspaces",  enabled = true, speed = 6,  bezier = "default" })

local mainMod = "SUPER"
local meh     = "CTRL + ALT + SHIFT"
local hyper   = "SUPER + ALT + SHIFT"

hl.bind(mainMod .. " + Q", hl.dsp.exec_cmd("uwsm app -- kitty"),  { desc = "Apps: Terminal" })
hl.bind(mainMod .. " + C", hl.dsp.window.close(),                 { desc = "Windows: Close window" })
hl.bind(mainMod .. " + E", hl.dsp.exec_cmd("uwsm app -- nautilus"), { desc = "Apps: File manager" })
hl.bind(mainMod .. " + V", function()
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
hl.bind(mainMod .. " + F", hl.dsp.window.fullscreen(),   { desc = "Windows: Fullscreen" })

hl.bind(mainMod .. " + left",  hl.dsp.focus({ direction = "left" }),  { desc = "Focus: Focus left" })
hl.bind(mainMod .. " + right", hl.dsp.focus({ direction = "right" }), { desc = "Focus: Focus right" })
hl.bind(mainMod .. " + up",    hl.dsp.focus({ direction = "up" }),    { desc = "Focus: Focus up" })
hl.bind(mainMod .. " + down",  hl.dsp.focus({ direction = "down" }),  { desc = "Focus: Focus down" })
hl.bind(meh .. " + h", hl.dsp.focus({ direction = "left" }),  { desc = "Focus: Focus left (vim)" })
hl.bind(meh .. " + j", hl.dsp.focus({ direction = "down" }),  { desc = "Focus: Focus down (vim)" })
hl.bind(meh .. " + k", hl.dsp.focus({ direction = "up" }),    { desc = "Focus: Focus up (vim)" })
hl.bind(meh .. " + l", hl.dsp.focus({ direction = "right" }), { desc = "Focus: Focus right (vim)" })

hl.bind(mainMod .. " + SHIFT + left",  hl.dsp.window.move({ direction = "left" }),  { desc = "Windows: Move window left" })
hl.bind(mainMod .. " + SHIFT + right", hl.dsp.window.move({ direction = "right" }), { desc = "Windows: Move window right" })
hl.bind(mainMod .. " + SHIFT + up",    hl.dsp.window.move({ direction = "up" }),    { desc = "Windows: Move window up" })
hl.bind(mainMod .. " + SHIFT + down",  hl.dsp.window.move({ direction = "down" }),  { desc = "Windows: Move window down" })

for i = 1, 9 do
    hl.bind(mainMod .. " + " .. i, hl.dsp.focus({ workspace = i }), { desc = "Workspaces: Go to workspace " .. i })
end
hl.bind(mainMod .. " + 0", hl.dsp.workspace.toggle_special("magic"), { desc = "Workspaces: Toggle scratchpad" })

for i = 1, 9 do
    hl.bind(mainMod .. " + SHIFT + " .. i, hl.dsp.window.move({ workspace = i }), { desc = "Workspaces: Move window to workspace " .. i })
end
hl.bind(mainMod .. " + SHIFT + 0", hl.dsp.window.move({ workspace = 10 }), { desc = "Workspaces: Move window to workspace 10" })

hl.bind(mainMod .. " + S",         hl.dsp.workspace.toggle_special("magic"),          { desc = "Workspaces: Toggle scratchpad" })
hl.bind(mainMod .. " + SHIFT + S", hl.dsp.window.move({ workspace = "special:magic" }), { desc = "Workspaces: Move window to scratchpad" })

hl.bind("SUPER + ALT + S",        function() zones.toggle() end,    { desc = "Workspaces: Toggle zone" })
hl.bind(hyper .. " + S",          function() zones.move(true) end,  { desc = "Workspaces: Move window to zone" })
hl.bind("SUPER + CTRL + ALT + S", function() zones.move(false) end, { desc = "Workspaces: Move window to zone (silent)" })

hl.bind(mainMod .. " + SHIFT + minus", hl.dsp.workspace.move({ monitor = "-1" }), { desc = "Workspaces: Move workspace to previous monitor" })
hl.bind(mainMod .. " + SHIFT + equal", hl.dsp.workspace.move({ monitor = "+1" }), { desc = "Workspaces: Move workspace to next monitor" })

hl.bind(mainMod .. " + mouse_down", hl.dsp.focus({ workspace = "e+1" }), { desc = "Workspaces: Next workspace (scroll)" })
hl.bind(mainMod .. " + mouse_up",   hl.dsp.focus({ workspace = "e-1" }), { desc = "Workspaces: Previous workspace (scroll)" })

hl.bind("Print",         hl.dsp.exec_cmd("@BINDIR@/hypr-de-snip"),   { desc = "Screenshots: Region screenshot + annotate" })
hl.bind("SHIFT + Print", hl.dsp.exec_cmd("@BINDIR@/hypr-de-record"), { desc = "Screenshots: Screen recording" })

-- Locked, so a crashed lock screen can be recovered from the keyboard; with a live locker it starts nothing.
hl.bind(mainMod .. " + L", hl.dsp.exec_cmd("@LIBEXECDIR@/lock-cmd.sh"), { locked = true, desc = "System: Lock screen" })
hl.bind(mainMod .. " + M", hl.dsp.exec_cmd("@LIBEXECDIR@/power-menu.sh"), { desc = "System: Power menu" })
hl.bind(mainMod .. " + T", hl.dsp.exec_cmd("lmtt switch"),                { desc = "System: Toggle light/dark theme" })
hl.bind(mainMod .. " + N", hl.dsp.exec_cmd("swaync-client -t -sw"),       { desc = "System: Notification center" })
hl.bind(mainMod .. " + slash",         hl.dsp.exec_cmd("@BINDIR@/hypr-de-help"), { desc = "Help: Welcome and keybinds" })
hl.bind(mainMod .. " + SHIFT + slash", hl.dsp.exec_cmd("@LIBEXECDIR@/hypr-de-cheatsheet"), { desc = "Help: Search keybinds" })
hl.bind(mainMod .. " + D", hl.dsp.exec_cmd([[wl-copy --clear && notify-send -t 2000 "Clipboard cleared" "Ready for drag-and-drop"]]), { desc = "System: Clear clipboard (drag-and-drop prep)" })

hl.bind("ALT + Tab", function()
    hl.dispatch(hl.dsp.window.cycle_next())
    hl.dispatch(hl.dsp.window.bring_to_top())
end, { desc = "Windows: Cycle floating windows" })
hl.bind("SHIFT + XF86AudioPlay", hl.dsp.exec_cmd("hyprpwcenter"), { desc = "System: Audio patchbay" })

hl.bind("XF86AudioPlay", hl.dsp.exec_cmd("@LIBEXECDIR@/osd/media-osd.sh play-pause"), { locked = true, desc = "Media: Play/pause" })
hl.bind("XF86AudioStop", hl.dsp.exec_cmd("@LIBEXECDIR@/osd/media-osd.sh stop"),        { locked = true, desc = "Media: Stop" })
hl.bind("XF86AudioMute", hl.dsp.exec_cmd("wpctl set-mute @DEFAULT_AUDIO_SINK@ toggle"),                 { locked = true, desc = "Media: Mute" })
hl.bind("XF86AudioNext", hl.dsp.exec_cmd("@LIBEXECDIR@/osd/media-osd.sh next"),        { locked = true, desc = "Media: Next track" })
hl.bind("XF86AudioPrev", hl.dsp.exec_cmd("@LIBEXECDIR@/osd/media-osd.sh previous"),    { locked = true, desc = "Media: Previous track" })

hl.bind("XF86AudioRaiseVolume", hl.dsp.exec_cmd("wpctl set-volume -l 1.5 @DEFAULT_AUDIO_SINK@ 1%+"), { locked = true, repeating = true, desc = "Media: Volume up" })
hl.bind("XF86AudioLowerVolume", hl.dsp.exec_cmd("wpctl set-volume -l 1.5 @DEFAULT_AUDIO_SINK@ 1%-"), { locked = true, repeating = true, desc = "Media: Volume down" })
hl.bind("XF86MonBrightnessUp",   hl.dsp.exec_cmd("@LIBEXECDIR@/osd/brightness-osd.sh up"),   { locked = true, repeating = true, desc = "Media: Brightness up" })
hl.bind("XF86MonBrightnessDown", hl.dsp.exec_cmd("@LIBEXECDIR@/osd/brightness-osd.sh down"), { locked = true, repeating = true, desc = "Media: Brightness down" })

hl.bind(mainMod .. " + mouse:272", hl.dsp.window.drag(),   { mouse = true, desc = "Windows: Drag window (mouse)" })
hl.bind(mainMod .. " + mouse:273", hl.dsp.window.resize(), { mouse = true, desc = "Windows: Resize window (mouse)" })

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

hl.on("hyprland.start", function()
    hl.exec_cmd("dbus-update-activation-environment --systemd WAYLAND_DISPLAY XDG_CURRENT_DESKTOP HYPRLAND_INSTANCE_SIGNATURE XDG_SESSION_TYPE XDG_SESSION_ID XDG_SESSION_DESKTOP")
    hl.exec_cmd("@LIBEXECDIR@/hypr-de-welcome")
end)
