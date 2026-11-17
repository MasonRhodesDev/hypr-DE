dofile("@DATADIR@/hypr/main.lua")
local config = os.getenv("XDG_CONFIG_HOME")
if not config or config == "" then
    config = os.getenv("HOME") .. "/.config"
end
pcall(dofile, config .. "/hypr/local.lua")
