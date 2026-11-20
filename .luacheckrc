std = "lua54"
-- line length is style
max_line_length = false

files["dist/hypr"] = { read_globals = { "hl" } }
files["dist/xdg/hypr"] = { read_globals = { "hl", "hyprland" } }
files["dist/gaming"] = { read_globals = { "hl" } }
-- a Neovim config sets fields of vim, so it is not read-only
files["dist/nvim"] = { std = "luajit", globals = { "vim" } }
