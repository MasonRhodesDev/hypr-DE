-- hypr-DE entry point. This stub is stable — do not edit it; put your
-- overrides in ~/.config/hypr/local.lua (see
-- @DATADIR@/hypr/local.lua.example) and monitor layouts in
-- ~/.config/hypr/profiles/.
dofile("@DATADIR@/hypr/main.lua")
pcall(dofile, os.getenv("HOME") .. "/.config/hypr/local.lua")
