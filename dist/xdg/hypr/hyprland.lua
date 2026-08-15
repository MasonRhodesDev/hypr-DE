-- Packaged Hyprland config. Hyprland loads this from XDG_CONFIG_DIRS
-- (/etc/xdg) when ~/.config/hypr/hyprland.lua is absent. Do not edit this
-- file; put overrides in ~/.config/hypr/local.lua (see
-- @DATADIR@/hypr/local.lua.example).
dofile("@DATADIR@/hypr/main.lua")
local config = os.getenv("XDG_CONFIG_HOME")
if not config or config == "" then
    config = os.getenv("HOME") .. "/.config"
end
pcall(dofile, config .. "/hypr/local.lua")
