-- hypr-de-gaming: window/workspace rules routing games to workspace 7
-- (chrome-less, idle-inhibited). Opt-in: dofile this from
-- ~/.config/hypr/local.lua.

-- Field names differ across Hyprland builds; current git wants
-- no_border/no_rounding, older accepted border/rounding. Try current
-- first — a failed attempt still logs to configerrors even under pcall.
if not pcall(hl.workspace_rule, { workspace = "7", no_border = true, no_rounding = true }) then
    hl.workspace_rule({ workspace = "7", border = false, rounding = false })
end

hl.window_rule({ name = "steam-bigpicture", match = { class = "^(steam)$", title = "^(Steam Big Picture Mode)$" }, workspace = "7", fullscreen = true, focus_on_activate = false })
hl.window_rule({ name = "steam-game",  match = { class = "^(steam_app_\\d+)$" }, workspace = "7 silent", no_initial_focus = true, focus_on_activate = false, immediate = true, opacity = "1.0 override", no_blur = true, idle_inhibit = "always", pin = false })
hl.window_rule({ name = "gamescope",   match = { class = "^(gamescope)$" }, workspace = "7 silent", no_initial_focus = true, focus_on_activate = false, pin = false })
hl.window_rule({ name = "godot-game",  match = { title = "^(Godot)$" }, workspace = "7 silent", no_initial_focus = true, focus_on_activate = false, immediate = true, opacity = "1.0 override", no_blur = true, idle_inhibit = "always", pin = false })
hl.window_rule({ name = "minecraft",   match = { class = "^(Minecraft.*)$" }, workspace = "7 silent", no_initial_focus = true, focus_on_activate = false, immediate = true, idle_inhibit = "always", pin = false })
